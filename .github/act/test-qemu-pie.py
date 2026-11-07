import os
import pathlib
import shlex
import subprocess

root = pathlib.Path('/workspace/openwrt')
build = root / 'build_dir/target-mips-openwrt-linux-musl_musl/qemu-11.1.1/build'
env = dict(os.environ, MAKE='/opt/agw-host-compiler/bin/make',
           STAGING_DIR=str(root / 'staging_dir/target-mips-openwrt-linux-musl_musl'))
env['PATH'] = '/opt/agw-host-compiler/bin:' + str(root / 'staging_dir/host/bin') + ':' + str(root / 'staging_dir/toolchain-mips_24kc_gcc-14.4.0_musl/bin') + ':' + env['PATH']
compiler = next(pathlib.Path('/external-toolchain').glob('*/toolchain-*/bin/mips*-gcc'))
env['PATH'] = str(compiler.parent) + ':' + env['PATH']
commands = subprocess.check_output([str(root / 'staging_dir/host/bin/ninja'), '-t', 'commands',
                                    'subprojects/libvhost-user/link-test'], cwd=build, text=True)
link = shlex.split(commands.strip().splitlines()[-1])
link = [arg for arg in link if arg not in ('-fPIE', '-fPIC')]
for extra in ([], ['-fPIE'], ['-fPIC']):
    result = subprocess.run(link + extra, cwd=build, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print('extra=%s exit=%d' % (extra, result.returncode))
    if result.returncode:
        print(result.stderr[:700])
    if not extra:
        assert result.returncode != 0 and 'R_MIPS_' in result.stderr
    else:
        assert result.returncode == 0, result.stderr
