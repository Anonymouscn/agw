import pathlib
import subprocess
import tempfile

root = pathlib.Path('/data/src/openwrt')
feed = root / 'feeds/packages'
patch = root / 'local-patches/010-runtime-cross-build.patch'
with tempfile.TemporaryDirectory(prefix='runtime-patch-') as directory:
    directory = pathlib.Path(directory)
    for name in ('containerd', 'runc', 'qemu'):
        relative = 'utils/' + name + '/Makefile'
        source = subprocess.check_output(['git', 'show', 'HEAD:' + relative], cwd=feed)
        target = directory / relative
        target.parent.mkdir(parents=True)
        target.write_bytes(source)
    subprocess.run(['git', 'init', '-q'], cwd=directory, check=True)
    for args in (['--check'], [], ['--reverse', '--check']):
        subprocess.run(['git', 'apply', *args, str(patch)], cwd=directory, check=True)
    for name in ('containerd', 'runc'):
        assert 'PKG_BUILD_FLAGS:=no-mips16' in (directory / 'utils' / name / 'Makefile').read_text()
    qemu = (directory / 'utils/qemu/Makefile').read_text()
    assert '--cpu=$(ARCH)' in qemu and '@ARCH_64BIT' in qemu
    assert '$(if $(filter mips%,$(ARCH)),-fPIE)' in qemu
    print('PASS: runtime patch applies to clean feed and reverse-checks')
    print('PASS: both cgo packages disable MIPS16; QEMU architecture settings retained')
