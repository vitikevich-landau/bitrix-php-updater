# -*- coding: utf-8 -*-
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
    raise AssertionError('проба не дошла до транспортного уровня')
os.write(fd, b'\x03')
for unused in range(200):
    finished, status = os.waitpid(pid, os.WNOHANG)
    if finished:
        break
    time.sleep(.05)
else:
    os.killpg(pid, signal.SIGKILL)
    raise AssertionError('Ctrl-C не завершил пробу')
for unused in range(100):
    if not glob.glob('/var/www/rc9-probe-site/bitrix-master-probe-*') and not glob.glob('/root/managed-probe-test/state/probes/*'):
        break
    time.sleep(.05)
assert not glob.glob('/var/www/rc9-probe-site/bitrix-master-probe-*'), 'после Ctrl-C осталась публичная проба'
assert not glob.glob('/root/managed-probe-test/state/probes/*'), 'после Ctrl-C осталась запись о пробе'
assert status != 0, 'после Ctrl-C неожиданно получен успешный результат'
os.close(fd)
print('PASS очистка после настоящего Ctrl-C в терминале')
