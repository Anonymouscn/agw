#!/usr/bin/env python3
"""Freeze configured feeds, including reviewed local edits, and restore them."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess


def git(path, *args, **kwargs):
    return subprocess.check_output(['git', '-C', str(path), *args], **kwargs)


def definitions(root):
    config = root / 'feeds.conf'
    if not config.exists():
        config = root / 'feeds.conf.default'
    result = []
    for line in config.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        fields = line.split()
        if len(fields) != 3 or fields[0] not in ('src-git', 'src-git-full'):
            raise ValueError('Only explicit git feeds are supported: ' + line)
        _, name, url = fields
        if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
            raise ValueError('Invalid feed name')
        # The actual checked-out commit, rather than a floating branch, is locked.
        result.append((name, re.split(r'[;^]', url, maxsplit=1)[0]))
    if len({name for name, _ in result}) != len(result):
        raise ValueError('Duplicate feed names')
    return result


def capture(root, output):
    feeds = []
    for name, url in definitions(root):
        path = root / 'feeds' / name
        commit = git(path, 'rev-parse', 'HEAD').decode().strip()
        patch = git(path, 'diff', 'HEAD', '--binary')
        untracked = git(path, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0')
        for filename in sorted(p for p in untracked if p):
            result = subprocess.run(['git', 'diff', '--no-index', '--binary', '--', '/dev/null',
                                     filename.decode()], cwd=path, capture_output=True)
            if result.returncode != 1:
                raise ValueError('Cannot freeze untracked feed file: ' + filename.decode())
            patch += result.stdout
        feeds.append({'name': name, 'url': url, 'commit': commit,
                      'patch': patch.decode(), 'patch_sha256': hashlib.sha256(patch).hexdigest()})
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'schema': 1, 'feeds': feeds}, indent=2) + '\n')


def load(root, lock):
    data = json.loads(lock.read_text())
    if data.get('schema') != 1:
        raise ValueError('Unsupported feed lock schema')
    expected = dict(definitions(root))
    actual = {}
    for feed in data['feeds']:
        name = feed['name']
        if name not in expected or name in actual or feed['url'] != expected[name]:
            raise ValueError('Feed lock does not match configured feeds: ' + name)
        if not re.fullmatch(r'[0-9a-f]{40}', feed['commit']):
            raise ValueError('Feed revision must be a full commit hash')
        patch = feed['patch'].encode()
        if hashlib.sha256(patch).hexdigest() != feed['patch_sha256']:
            raise ValueError('Feed overlay checksum mismatch: ' + name)
        actual[name] = feed
    if set(actual) != set(expected):
        raise ValueError('Feed lock omits configured feeds')
    return data


def restore(root, lock):
    data = load(root, lock)
    # Never reset or overwrite an existing developer checkout.
    for feed in data['feeds']:
        if (root / 'feeds' / feed['name']).exists():
            raise ValueError('Restore requires an isolated empty feed directory: ' + feed['name'])
    for feed in data['feeds']:
        path = root / 'feeds' / feed['name']
        path.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(path)], check=True)
        subprocess.run(['git', '-C', str(path), 'remote', 'add', 'origin', feed['url']], check=True)
        subprocess.run(['git', '-C', str(path), 'fetch', '--depth=1', 'origin', feed['commit']], check=True)
        subprocess.run(['git', '-C', str(path), 'checkout', '-q', '--detach', 'FETCH_HEAD'], check=True)
        if git(path, 'rev-parse', 'HEAD').decode().strip() != feed['commit']:
            raise ValueError('Wrong feed revision: ' + feed['name'])
        if feed['patch']:
            subprocess.run(['git', '-C', str(path), 'apply', '--binary', '-'],
                           input=feed['patch'].encode(), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('capture', 'validate', 'restore'))
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path('.'))
    parser.add_argument('--lock', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == 'capture':
        capture(args.root.resolve(), args.lock)
    elif args.command == 'validate':
        data = load(args.root.resolve(), args.lock)
        print(json.dumps({feed['name']: feed['commit'] for feed in data['feeds']}, indent=2))
    else:
        restore(args.root.resolve(), args.lock)


if __name__ == '__main__':
    main()
