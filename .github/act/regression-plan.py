#!/usr/bin/env python3
"""Turn the declared kernel matrix into a bounded, reproducible job matrix."""
import argparse
import csv
import json
import hashlib
import pathlib
import re


def plan(text, kernel='all', targets='', parallel=2):
    if not 1 <= parallel <= 16:
        raise ValueError('Parallel builds must be between 1 and 16')
    requested = {value.strip() for value in targets.split(',') if value.strip()}
    rows = []
    seen = set()
    for row in csv.DictReader(text.splitlines(), delimiter='\t'):
        if not re.fullmatch(r'[A-Za-z0-9_]+/[A-Za-z0-9_]+', row['target']):
            raise ValueError('Invalid target')
        if not re.fullmatch(r'\d+\.\d+', row['kernel']) or not re.fullmatch(r'\d+\.\d+\.\d+', row['release']):
            raise ValueError('Invalid kernel version')
        if not row['release'].startswith(row['kernel'] + '.') or row['testing'] not in ('0', '1'):
            raise ValueError('Inconsistent kernel metadata')
        if kernel != 'all' and row['kernel'] != kernel:
            continue
        if requested and row['target'] not in requested:
            continue
        identity = row['target'], row['release']
        if identity in seen:
            continue
        seen.add(identity)
        target, subtarget = row['target'].split('/')
        expected_key = target + '-' + subtarget + '-k' + row['kernel']
        if row['key'] != expected_key:
            raise ValueError('Inconsistent matrix key')
        rows.append({'key': expected_key, 'target': target, 'subtarget': subtarget,
                     'kernel': row['kernel'], 'release': row['release'], 'testing': row['testing'] == '1'})
    found = {row['target'] + '/' + row['subtarget'] for row in rows}
    if not rows or requested - found:
        raise ValueError('No supported combinations for requested filters')
    if len(rows) > 256:
        raise ValueError('Matrix needs sharding beyond GitHub\'s 256-job limit')
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=pathlib.Path)
    parser.add_argument('--kernel', default='all')
    parser.add_argument('--targets', default='')
    parser.add_argument('--parallel', type=int, default=2)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--github-output', type=pathlib.Path)
    parser.add_argument('--scope', choices=('packages', 'firmware'), default='packages')
    parser.add_argument('--feeds', choices=('locked', 'none'), default='locked')
    parser.add_argument('--feed-lock', type=pathlib.Path, default=pathlib.Path('.github/regression/feeds.lock.json'))
    args = parser.parse_args()
    rows = plan(args.matrix.read_text(), args.kernel, args.targets, args.parallel)
    counts = {}
    for row in rows:
        counts[row['release']] = counts.get(row['release'], 0) + 1
    data = {'scope': args.scope, 'feeds': args.feeds, 'combinations': len(rows), 'kernels': counts, 'matrix': rows}
    if args.feeds == 'locked':
        data['expected_feeds'] = sorted(feed['name'] for feed in json.loads(args.feed_lock.read_text())['feeds'])
        data['feed_lock_sha256'] = hashlib.sha256(args.feed_lock.read_bytes()).hexdigest()
    args.output.write_text(json.dumps(data, indent=2) + '\n')
    if args.github_output:
        with args.github_output.open('a') as output:
            output.write('matrix=' + json.dumps(rows, separators=(',', ':')) + '\n')
            output.write('parallel=' + str(args.parallel) + '\n')
    print(json.dumps({'combinations': len(rows), 'kernels': counts}, indent=2))


if __name__ == '__main__':
    main()
