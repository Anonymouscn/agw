import pathlib
import subprocess
import tarfile
import tempfile

root = pathlib.Path('/data/src/openwrt')
feed = root / 'feeds/packages'
patch = root / 'local-patches/009-postfix-linux7-platform.patch'


def run(args, cwd):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


with tempfile.TemporaryDirectory(prefix='postfix-regression-') as tmp:
    tmp = pathlib.Path(tmp)
    baseline = tmp / 'feed'
    (baseline / 'mail/postfix').mkdir(parents=True)
    original = run(['git', 'show', 'HEAD:mail/postfix/Makefile'], feed)
    (baseline / 'mail/postfix/Makefile').write_text(original)
    run(['git', 'init', '-q'], baseline)
    run(['git', 'apply', '--check', str(patch)], baseline)
    run(['git', 'apply', str(patch)], baseline)
    run(['git', 'apply', '--reverse', '--check', str(patch)], baseline)
    print('PASS: packaged feed patch applies to pristine feed and reverse-checks')
    archive = root / 'dl/postfix-3.8.2.tar.gz'
    with tarfile.open(archive) as tar:
        for name in ('makedefs', 'src/util/sys_defs.h'):
            member = tar.getmember('postfix-3.8.2/' + name)
            target = tmp / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(member).read())
    run(['patch', '-p1', '-i', str(baseline / 'mail/postfix/patches/300-linux-7-host-kernel.patch')], tmp)
    for major in (6, 7):
        macros = run(['cc', '-E', '-dM', '-xc', '-DNO_NIS',
                      '-DLINUX' + str(major), '-include', 'src/util/sys_defs.h',
                      '/dev/null'], tmp)
        for symbol in ('SUPPORTED', 'USE_STATFS', 'SOCKADDR_SIZE'):
            assert '#define ' + symbol in macros, (major, symbol)
        print('PASS: LINUX%d selects Linux platform/statfs/socket definitions' % major)
