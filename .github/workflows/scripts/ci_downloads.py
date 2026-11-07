#!/usr/bin/env python3
"""Select and verify CI toolchains from one complete snapshot manifest."""
import argparse
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import time


def manifest_entries(path):
    entries = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](.+)', line)
        if not match:
            raise ValueError('Invalid or incomplete SHA256 manifest')
        digest, name = match.groups()
        if name in entries and entries[name] != digest.lower():
            raise ValueError('Conflicting checksums for ' + name)
        entries[name] = digest.lower()
    if not entries:
        raise ValueError('Empty SHA256 manifest')
    return entries


def fetch(url, destination, validate=None, max_time=600):
    attempts = int(os.environ.get('CI_DOWNLOAD_ATTEMPTS', '5'))
    delay = float(os.environ.get('CI_DOWNLOAD_DELAY', '2'))
    if attempts < 1 or attempts > 10 or delay < 0:
        raise ValueError('Invalid download retry settings')
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + '.' + str(os.getpid()) + '.part')
    try:
        for attempt in range(attempts):
            part.unlink(missing_ok=True)
            try:
                subprocess.run([
                    'curl', '--fail', '--location', '--silent', '--show-error', '--compressed',
                    '--connect-timeout', '20', '--max-time', str(max_time),
                    '--speed-limit', '1024', '--speed-time', '60',
                    '--output', str(part), url,
                ], check=True)
                if validate:
                    validate(part)
                os.replace(part, destination)
                return destination
            except (subprocess.CalledProcessError, ValueError, UnicodeError) as error:
                print('Download attempt {}/{} failed for {}: {}'.format(
                    attempt + 1, attempts, url, error), file=sys.stderr)
                if attempt + 1 == attempts:
                    raise
                time.sleep(delay * 2 ** attempt)
    finally:
        part.unlink(missing_ok=True)


def cached_manifest(url, cache):
    path = cache / (hashlib.sha256(url.encode()).hexdigest() + '.sha256sums')
    if path.exists():
        try:
            manifest_entries(path)
            return path
        except (ValueError, UnicodeError):
            path.unlink()
    return fetch(url, path, manifest_entries)


def artifact(entries, kind):
    prefixes = {'toolchain': 'openwrt-toolchain-', 'sdk': 'openwrt-sdk-'}
    matches = []
    for name in entries:
        if pathlib.PurePosixPath(name).name != name or not re.fullmatch(r'[A-Za-z0-9_.+-]+', name):
            continue
        if not name.endswith(('.tar.xz', '.tar.zst')):
            continue
        if (kind == 'llvm' and 'llvm-bpf' in name) or name.startswith(prefixes.get(kind, '\0')):
            matches.append(name)
    stems = {re.sub(r'\.tar\.(xz|zst)$', '', name) for name in matches}
    if len(stems) > 1:
        raise ValueError('Ambiguous {} archives: {}'.format(kind, ', '.join(sorted(matches))))
    return sorted(matches, key=lambda name: not name.endswith('.zst'))[0] if matches else ''


def emit(path, values):
    with open(path, 'a') as output:
        for key, value in values.items():
            if '\n' in value or '\r' in value:
                raise ValueError('Invalid workflow output')
            output.write(key + '=' + value + '\n')


def select(args):
    if args.kind == 'toolchain' and args.external_toolchain.is_dir():
        emit(args.output, {'toolchain-type': 'external_container'})
        emit(args.env, {'TOOLCHAIN_FILE': '', 'TOOLCHAIN_NAME': ''})
        return
    entries = manifest_entries(cached_manifest(args.url, args.cache))
    if args.kind == 'llvm':
        name = artifact(entries, 'llvm')
        emit(args.env, {'LLVM_FILE': name})
        if name:
            emit(args.output, {'llvm-type': 'external'})
    else:
        name = artifact(entries, 'toolchain')
        kind = 'external_toolchain' if name else 'internal'
        if not name:
            name = artifact(entries, 'sdk')
            kind = 'external_sdk' if name else 'internal'
        emit(args.env, {'TOOLCHAIN_FILE': name, 'TOOLCHAIN_NAME': re.sub(r'\.tar\.(xz|zst)$', '', name)})
        emit(args.output, {'toolchain-type': kind})


def extract(args):
    name = args.artifact
    if not re.fullmatch(r'[A-Za-z0-9_.+-]+\.tar\.(xz|zst)', name):
        raise ValueError('Invalid archive filename')
    manifest = cached_manifest(args.url, args.cache)
    expected = manifest_entries(manifest).get(name)
    if expected is None:
        raise ValueError('Archive absent from selected manifest: ' + name)
    signature = fetch(args.url + '.asc', manifest.with_suffix('.asc'))
    # Verify the exact manifest used for selection; never disable signature checks.
    subprocess.run(['gpg', '--with-fingerprint', '--verify', str(signature), str(manifest)], check=True)

    def verify(path):
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise ValueError('SHA256 mismatch for ' + name)

    archive = fetch(args.url.rsplit('/', 1)[0] + '/' + name, pathlib.Path(name), verify, max_time=1800)
    subprocess.run(['tar', '-xf', str(archive)], check=True)
    archive.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('select', 'extract'):
        p = sub.add_parser(command)
        p.add_argument('--url', required=True)
        p.add_argument('--cache', type=pathlib.Path, default=pathlib.Path('openwrt/tmp/ci-downloads'))
        if command == 'select':
            p.add_argument('--kind', choices=('toolchain', 'llvm'), required=True)
            p.add_argument('--env', default=os.environ.get('GITHUB_ENV'))
            p.add_argument('--output', default=os.environ.get('GITHUB_OUTPUT'))
            p.add_argument('--external-toolchain', type=pathlib.Path, default=pathlib.Path('/external-toolchain'))
        else:
            p.add_argument('--artifact', required=True)
    args = parser.parse_args()
    if args.command == 'select' and (not args.env or not args.output):
        parser.error('GITHUB_ENV and GITHUB_OUTPUT or explicit output paths are required')
    {'select': select, 'extract': extract}[args.command](args)


if __name__ == '__main__':
    main()
