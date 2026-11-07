from __future__ import print_function
import glob
import os
import pty
import signal
import sys
import time

control = '/root/managed-probe-test/control'
suite, installer, expected = sys.argv[1:]
marker = control + '/blocking'
if os.path.exists(marker):
    os.unlink(marker)
pid, fd = pty.fork()
if pid == 0:
    os.execv('/bin/bash', ['bash', os.path.join(suite, 'signal-driver.sh'), control, installer, expected])
for unused in range(200):
    if os.path.exists(marker):
        break
    time.sleep(.05)
else:
    os.killpg(pid, signal.SIGKILL)
    raise AssertionError('probe did not reach transport')
os.write(fd, b'\x03')
for unused in range(200):
    finished, status = os.waitpid(pid, os.WNOHANG)
    if finished:
        break
    time.sleep(.05)
else:
    os.killpg(pid, signal.SIGKILL)
    raise AssertionError('Ctrl-C did not terminate probe')
for unused in range(100):
    if not glob.glob('/var/www/rc9-probe-site/bitrix-master-probe-*') and not glob.glob('/root/managed-probe-test/state/probes/*'):
        break
    time.sleep(.05)
assert not glob.glob('/var/www/rc9-probe-site/bitrix-master-probe-*'), 'Ctrl-C left public probe'
assert not glob.glob('/root/managed-probe-test/state/probes/*'), 'Ctrl-C left lease'
assert status != 0, 'Ctrl-C unexpectedly succeeded'
os.close(fd)
print('PASS real terminal Ctrl-C cleanup')
