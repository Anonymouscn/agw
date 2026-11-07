import os
import pathlib
import subprocess
import tempfile

gcc = next(pathlib.Path('/external-toolchain').glob('*/toolchain-*/bin/mips*-gcc'))
make = '/opt/agw-host-compiler/bin/make'
with tempfile.TemporaryDirectory(prefix='lto-jobserver-') as directory:
    root = pathlib.Path(directory)
    (root / 'a.c').write_text('int f(int); int main(int n,char **v){return f(n);}\n')
    (root / 'b.c').write_text('__attribute__((noinline)) int f(int n){return n+1;}\n')
    (root / 'Makefile').write_text('all:\n\t' + str(gcc) +
                                 ' -flto=auto -flto-partition=max -O2 a.c b.c -o test\n')
    base = dict(os.environ, MAKE='/usr/bin/make')
    bad = subprocess.run([make, '--jobserver-style=fifo', '-j2'], cwd=root,
                         env=base, text=True, capture_output=True)
    assert bad.returncode != 0 and 'invalid --jobserver-auth' in bad.stderr, bad.stdout + bad.stderr
    print('PASS: reproduced GCC LTO failure with old Make and FIFO tokens')
    fixed = dict(base, MAKE=make,
                 PATH='/opt/agw-host-compiler/bin:' + base['PATH'])
    good = subprocess.run([make, '--jobserver-style=fifo', '-j2'], cwd=root,
                          env=fixed, text=True, capture_output=True)
    assert good.returncode == 0, good.stdout + good.stderr
    assert (root / 'test').read_bytes()[:4] == b'\x7fELF'
    print('PASS: same MIPS GCC LTO link succeeds with matching Make 4.4')
