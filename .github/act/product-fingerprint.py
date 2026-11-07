import hashlib
import os
import pathlib
import stat
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root))
names = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                 '--exclude-standard', '-z'], cwd=root).split(b'\0')
for name in sorted(set(names) - {b''}):
    if name.startswith(b'.github/act/') or name == b'scripts/act-kernel.sh':
        continue
    path = root / os.fsdecode(name)
    digest.update(name + b'\0')
    if not path.exists() and not path.is_symlink():
        digest.update(b'MISSING\0')
        continue
    mode = path.lstat().st_mode
    digest.update(str(stat.S_IFMT(mode)).encode() + b':' + str(mode & 0o111).encode())
    if path.is_symlink():
        digest.update(os.fsencode(os.readlink(path)))
    else:
        with path.open('rb') as handle:
            for block in iter(lambda: handle.read(1048576), b''):
                digest.update(block)
    digest.update(b'\0')
print(digest.hexdigest())
