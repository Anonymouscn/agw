#!/usr/bin/env python3
"""Print distinct make targets for selected out-of-tree kernel packages."""
import pathlib
import re
import sys


def targets(config, packageinfo):
    selected = set(re.findall(r'^CONFIG_PACKAGE_(kmod-[^=]+)=[ym]$', config, re.M))
    seen = set()
    result = set()
    source = None
    for line in packageinfo.splitlines():
        if line.startswith('Source-Makefile: '):
            source = line.split(': ', 1)[1]
        elif line.startswith('Package: '):
            name = line.split(': ', 1)[1]
            if name not in selected:
                continue
            seen.add(name)
            path = pathlib.PurePosixPath(source or '')
            if (not source or path.is_absolute() or '..' in path.parts or
                    not source.startswith('package/') or path.name != 'Makefile'):
                raise ValueError('Invalid package source for ' + name)
            if source != 'package/kernel/linux/Makefile':
                result.add(str(path.parent) + '/compile')
    missing = selected - seen
    if missing:
        raise ValueError('Selected kmods missing package metadata: ' + ', '.join(sorted(missing)))
    return sorted(result)


if __name__ == '__main__':
    config = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.config')
    metadata = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else 'tmp/.packageinfo')
    for target in targets(config.read_text(), metadata.read_text()):
        print(target)
