import json
import os
import pathlib
import subprocess
import sys
import tempfile

wrapper = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='agw-llvm-test-') as directory:
    root = pathlib.Path(directory)
    state = root / 'state'
    state.write_text('{"active":0,"peak":0}')
    fake = root / 'fake-ninja'
    fake.write_text('''#!/usr/bin/env python3
import fcntl,json,os,pathlib,sys,time
assert sys.argv[1:]==['-j4','build'],sys.argv
p=pathlib.Path(os.environ['STATE'])
def change(delta):
 with open(str(p)+'.lock','a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  s=json.loads(p.read_text());s['active']+=delta
  s['peak']=max(s['peak'],s['active']);p.write_text(json.dumps(s))
change(1);time.sleep(.5);change(-1)
''')
    fake.chmod(0o755)
    env = dict(os.environ, AGW_NINJA_REAL=str(fake),
               AGW_HEAVY_LOCK_DIR=str(root / 'locks'), STATE=str(state))
    children = [subprocess.Popen(['bash', wrapper, '-j99', 'build'],
                                cwd=root, env=env) for _ in range(6)]
    assert all(child.wait(timeout=30) == 0 for child in children)
    result = json.loads(state.read_text())
    assert result == {'active': 0, 'peak': 2}, result
    print('PASS: six LLVM requests, at most two concurrent; forced -j4 overrides -j99')
