#!/usr/bin/env python3
"""Reject Kconfig diagnostics even when a wrapper exits successfully."""
import argparse
import pathlib
import re
import subprocess


def valid_config(returncode, output):
    return returncode == 0 and not re.search(r'(?im)(?:^|[ :])error:|recursive dependency', output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.log.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(['scripts/config/conf', '--defconfig=.config', '-w',
                             'tmp/regression.config', 'Config.in'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    args.log.write_text(result.stdout)
    if not valid_config(result.returncode, result.stdout):
        raise SystemExit('Kconfig errors; see ' + str(args.log))


if __name__ == '__main__':
    main()
