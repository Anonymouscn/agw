#!/usr/bin/env python3
"""Aggregate coverage without treating absent jobs or unselected packages as passes."""
import argparse
import json
import pathlib


def aggregate(plan, reports):
    expected = {row['key']: row for row in plan['matrix']}
    by_key = {}
    catalog = {}
    selected = set()
    invalid = []
    for report in reports:
        key = report.get('key')
        if key not in expected or key in by_key:
            invalid.append('Unexpected or duplicate coverage report: ' + str(key))
            continue
        by_key[key] = report
        for package in report['packages']:
            identity = package['source'] + ':' + package['name'] + ':' + package.get('Build-Variant', '')
            catalog[identity] = package
            if not package['status'].startswith('NOT_SELECTED'):
                selected.add(identity)
    absent = sorted(set(expected) - set(by_key))
    failed = sorted(key for key, report in by_key.items() if not
                    (report.get('run_exit') == 0 and report['package_build_complete'] and report['all_userspace_selected'] and report['all_kmods_selected'] and
                     any(release == expected[key]['release'] or release.startswith(expected[key]['release'] + '-')
                         for release in report.get('compiled_releases', [])) and
                     ('firmware' not in report or report['firmware']['image_build_complete']) and
                     (plan.get('scope') != 'firmware' or report.get('firmware', {}).get('image_build_complete', False)) and
                     (plan.get('feeds') != 'locked' or
                      (report.get('feed_lock_sha256') == plan.get('feed_lock_sha256') and
                       set(plan.get('expected_feeds', [])) <= set(report.get('feeds_in_metadata', []))))))
    never_selected = sorted(set(catalog) - selected)
    return {'planned_combinations': len(expected), 'reported_combinations': len(by_key),
            'missing_or_not_run': absent, 'failed_or_incomplete': failed,
            'invalid_reports': invalid,
            'build_matrix_complete': not absent and not failed and not invalid,
            'catalog_definitions_seen': len(catalog), 'never_selected': never_selected,
            'all_catalog_definitions_compiled': not absent and not failed and not invalid and not never_selected,
            'limits': ['never-selected definitions require dependency/provider review',
                       'shadowed feed definitions are outside the installed catalog',
                       'compile results do not imply boot/runtime or upstream test-suite coverage']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=pathlib.Path, required=True)
    parser.add_argument('--reports', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--require-complete', action='store_true')
    args = parser.parse_args()
    reports = [json.loads(path.read_text()) for path in sorted(args.reports.rglob('packages.json'))
               if 'attempts' not in path.parts]
    result = aggregate(json.loads(args.plan.read_text()), reports)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'never_selected'}, indent=2))
    if args.require_complete and not result['build_matrix_complete']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
