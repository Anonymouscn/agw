#!/usr/bin/env python3
"""Audit actual APK identities against package metadata and the saved config."""
import argparse
import concurrent.futures
import hashlib
import functools
import json
import pathlib
import re
import subprocess


def metadata(text):
    result = {}
    source = None
    current = None
    description = False
    for line in text.splitlines():
        if line == '@@':
            current = None
            description = False
            continue
        if description:
            continue
        if line.startswith('Description:'):
            description = True
            continue
        if line.startswith('Source-Makefile: '):
            source = line.split(': ', 1)[1]
            current = None
        elif line.startswith('Package: '):
            name = line.split(': ', 1)[1]
            if name in result:
                raise ValueError('Duplicate installed package definition: ' + name)
            if not source:
                raise ValueError('Package is missing its source Makefile: ' + name)
            current = result[name] = {'name': name, 'source': source}
        elif current is not None and re.match(r'^[A-Za-z][A-Za-z-]*: ', line):
            key, value = line.split(': ', 1)
            if key in ('Version', 'Type', 'Build-Only', 'Build-Variant', 'Depends', 'Menu-Depends', 'Provides', 'Conflicts', 'Hidden', 'ABI-Version'):
                current[key] = value
    return result


def dependency_audit(archives, compare=None):
    providers = {}
    for entry in archives:
        providers.setdefault(entry['name'], []).append(entry.get('version'))
        for provided in entry.get('provides', []):
            match = re.fullmatch(r'([^<>=~]+)(?:=([^=]+))?', provided)
            if match:
                providers.setdefault(match[1], []).append(match[2])
    missing = []
    unverified = []
    for entry in archives:
        for requirement in entry.get('depends', []):
            if requirement.startswith('!'):
                continue  # Conflicting install combinations need separate runtime suites.
            match = re.fullmatch(r'([^<>=~]+)([<>=~]+)?(.*)', requirement)
            if not match or match[1] not in providers:
                missing.append({'package': entry['name'], 'requires': requirement})
                continue
            name, operator, version = match.groups()
            if not operator:
                continue
            verified = False
            unknown = False
            for candidate in providers[name]:
                if candidate is None:
                    unknown = True
                    continue
                order = '=' if candidate == version else compare(candidate, version) if compare else None
                accepted = {'=': '=', '>': '>', '<': '<', '>=': '>=', '<=': '<='}.get(operator)
                if order is None or accepted is None:
                    unknown = True
                elif order in accepted:
                    verified = True
                    break
            if not verified:
                (unverified if unknown else missing).append({'package': entry['name'], 'requires': requirement})
    return {'missing': missing, 'unverified_version_constraints': unverified,
            'complete': not missing and not unverified, 'install_conflicts_tested': False}


def audit(catalog, config, archives, build_exit, compare=None):
    selected = set(re.findall(r'^CONFIG_PACKAGE_([^=]+)=[ym]$', config, re.M)) & set(catalog)
    names = {entry['name'] for entry in archives}
    rows = []
    for name, info in sorted(catalog.items()):
        row = dict(info)
        abi = info.get('ABI-Version')
        source = info['source'].removeprefix('package/').removesuffix('/Makefile')
        origin = info.get('expected_origin', source if source.startswith('feeds/') else 'feeds/base/' + source)
        if abi:
            present = any(any(re.split(r'[<>=~]', value, maxsplit=1)[0] == name for value in entry.get('provides', [])) and entry.get('abi') == abi and
                          entry.get('origin') == origin for entry in archives)
        else:
            present = name in names
        if name not in selected:
            row['status'] = 'NOT_SELECTED_REVIEW_DEPENDENCIES_OR_PROVIDER'
        elif info.get('Build-Only') in ('1', 'y', 'yes') or not ({'ipkg', 'apk'} & set(info.get('Type', 'ipkg').split())):
            row['status'] = 'BUILD_ONLY_STAGE_SUCCEEDED' if build_exit == 0 else 'BUILD_ONLY_NOT_VERIFIED'
        elif present:
            row['status'] = 'APK_PRESENT'
        else:
            row['status'] = 'SELECTED_APK_MISSING'
        rows.append(row)
    missing = [row['name'] for row in rows if row['status'] == 'SELECTED_APK_MISSING']
    dependencies = dependency_audit(archives, compare)
    return {'selected_packages': len(selected), 'catalog_packages': len(catalog),
            'selected_apk_missing': missing, 'build_exit': build_exit,
            'package_build_complete': bool(selected) and build_exit == 0 and not missing and dependencies['complete'],
            'dependencies': dependencies,
            'not_selected_are_not_passes': True, 'packages': rows, 'archives': archives}


def archive_info(apk, path):
    result = subprocess.check_output([str(apk), 'adbdump', '--format', 'json', str(path)])
    info = json.loads(result)['info']
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    abi = next((tag.split('=', 1)[1] for tag in info.get('tags', []) if tag.startswith('openwrt:abiversion=')), None)
    return {'name': info['name'], 'version': info['version'], 'arch': info['arch'],
            'origin': info.get('origin'), 'provides': info.get('provides', []), 'abi': abi,
            'depends': info.get('depends', []),
            'path': str(path), 'sha256': digest.hexdigest(), 'bytes': path.stat().st_size}


def expected_origin(root, source):
    relative = (root / source).resolve().relative_to(root.resolve()).as_posix()
    relative = relative.removesuffix('/Makefile')
    return relative if relative.startswith('feeds/') else 'feeds/base/' + relative.removeprefix('package/')


def image_audit(root, config):
    profiles = set()
    images = []
    missing = []
    for manifest in sorted((root / 'bin/targets').glob('*/*/profiles.json')):
        for name, profile in json.loads(manifest.read_text()).get('profiles', {}).items():
            profiles.add(name)
            if not profile.get('images'):
                missing.append(name + ': no declared images')
            for entry in profile.get('images', []):
                filename = entry['name']
                if pathlib.PurePosixPath(filename).name != filename:
                    raise ValueError('Unsafe image filename')
                path = manifest.parent / filename
                if not path.is_file():
                    missing.append(name + ': ' + filename)
                    continue
                digest = hashlib.sha256()
                with path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(block)
                actual = digest.hexdigest()
                if entry.get('sha256') and actual != entry['sha256']:
                    missing.append(name + ': checksum mismatch: ' + filename)
                images.append({'profile': name, 'path': str(path), 'sha256': actual})
    selected = set(re.findall(r'^CONFIG_TARGET(?:_DEVICE)?_.*_DEVICE_([^=]+)=y$', config, re.M))
    missing.extend(name + ': selected profile absent from profiles.json' for name in sorted(selected - profiles))
    all_profiles = 'CONFIG_TARGET_ALL_PROFILES=y' in config.splitlines()
    return {'profiles': sorted(profiles), 'images': images, 'missing_images': missing,
            'all_profiles_selected': all_profiles,
            'image_build_complete': bool(profiles and images) and all_profiles and not missing,
            'runtime_boot_tested': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path('.'))
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--build-exit-file', type=pathlib.Path, required=True)
    parser.add_argument('--require-complete', action='store_true')
    parser.add_argument('--images', action='store_true')
    parser.add_argument('--run-exit', type=int)
    args = parser.parse_args()
    root = args.root.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    config = (root / '.config').read_text()
    packages = metadata((root / 'tmp/.packageinfo').read_text())
    for info in packages.values():
        info['expected_origin'] = expected_origin(root, info['source'])
    files = sorted(path for path in (root / 'bin').rglob('*.apk') if path.is_file() and not path.is_symlink())
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        archives = list(pool.map(lambda path: archive_info(root / 'staging_dir/host/bin/apk', path), files))
    build_exit = int(args.build_exit_file.read_text().strip()) if args.build_exit_file.exists() else None
    @functools.lru_cache(maxsize=8192)
    def compare(left, right):
        return subprocess.check_output([str(root / 'staging_dir/host/bin/apk'), 'version', '-t', left, right], text=True).strip()

    report = audit(packages, config, archives, build_exit, compare)
    report['run_exit'] = args.run_exit
    board = re.search(r'^CONFIG_TARGET_BOARD="([^"]+)"$', config, re.M)
    subtarget = re.search(r'^CONFIG_TARGET_SUBTARGET="([^"]+)"$', config, re.M)
    kernel = re.search(r'^CONFIG_LINUX_(\d+)_(\d+)=y$', config, re.M)
    if board and subtarget and kernel:
        patchver = kernel[1] + '.' + kernel[2]
        report['key'] = board[1] + '-' + subtarget[1] + '-k' + patchver
        report['target'] = board[1] + '/' + subtarget[1]
        report['kernel'] = patchver
        releases = {path.read_text().strip() for path in (root / 'build_dir').glob('**/include/config/kernel.release')}
        report['compiled_releases'] = sorted(releases)
    report['config_sha256'] = hashlib.sha256(config.encode()).hexdigest()
    report['all_userspace_selected'] = 'CONFIG_ALL=y' in config.splitlines()
    report['all_kmods_selected'] = 'CONFIG_ALL_KMODS=y' in config.splitlines()
    report['feeds_in_metadata'] = sorted({info['source'].split('/')[2] for info in packages.values()
                                         if info['source'].startswith('package/feeds/')})
    lock = root / '.github/regression/feeds.lock.json'
    if lock.exists():
        report['feed_lock_sha256'] = hashlib.sha256(lock.read_bytes()).hexdigest()
    report['scope_limits'] = ['not every Kconfig combination', 'not runtime/boot verification',
                              'not every upstream unit test', 'not shadowed feed definitions']
    if args.images:
        report['firmware'] = image_audit(root, config)
    (args.output / 'packages.json').write_text(json.dumps(report, indent=2) + '\n')
    (args.output / 'config.final').write_text(config)
    summary = {key: value for key, value in report.items() if key not in ('packages', 'archives')}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    if args.require_complete and not (report['package_build_complete'] and
                                     report['all_userspace_selected'] and report['all_kmods_selected'] and
                                     (not args.images or report['firmware']['image_build_complete'])):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
