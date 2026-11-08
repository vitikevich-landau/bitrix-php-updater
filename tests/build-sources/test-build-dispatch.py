#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Настоящие проверки запуска Bash, сеансов, подтверждений, исходников и зависимостей для Python 2.7 или 3.

Подменён только rpmbuild -ba. Запускать в одноразовом контейнере CentOS 7 со всеми
установленными зависимостями сборки и минимум 8 ГБ свободного места по данным df.
Использование: BITRIX_TEST_DISPOSABLE=1 python test-build-dispatch.py INSTALLER SRPM82 SRPM83 OUTPUT
"""
from __future__ import print_function
import errno
import glob
import io
import os
import pty
import select
import subprocess
import sys
import time

if os.environ.get('BITRIX_TEST_DISPOSABLE') != '1' or not os.path.isfile('/.dockerenv'):
    sys.exit('Отказ: необходимы одноразовый Docker-контейнер и BITRIX_TEST_DISPOSABLE=1.')
if len(sys.argv) != 5:
    sys.exit('Использование: test-build-dispatch.py INSTALLER SRPM82 SRPM83 OUTPUT')
installer, srpm82, srpm83, output = [os.path.abspath(v) for v in sys.argv[1:]]
if not os.path.isdir(output):
    os.makedirs(output)
library = os.path.join(output, 'library.sh')
with io.open(installer, encoding='utf-8') as fh:
    source = fh.read()
marker = u'# Мутирующие операции:'
assert marker in source, 'не найдена граница CLI полного установщика'
with io.open(library, 'w', encoding='utf-8') as fh:
    fh.write(source.split(marker, 1)[0])
fixture = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dispatch-entry.sh')

def run(name, args, expected, reply=None, compile_result='success'):
    state = os.path.join(output, name)
    command = ['bash', fixture, library, state] + args
    env = dict(os.environ, COMPILE_RESULT=compile_result)
    if reply is None:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        data = proc.communicate()[0]
    else:
        master, slave = pty.openpty()
        proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=env)
        os.close(slave)
        data = b''
        sent = False
        deadline = time.time() + 120
        while True:
            if time.time() > deadline:
                proc.kill()
                raise AssertionError(name + ': истекло время ожидания')
            ready = select.select([master], [], [], 0.2)[0]
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                data += chunk
                if not sent and b'\r\n> ' in data:
                    os.write(master, reply.encode('utf-8') + b'\n')
                    sent = True
            elif proc.poll() is not None:
                break
        os.close(master)
        proc.wait()
        assert sent, name + ': отсутствует запрос подтверждения'
    with open(os.path.join(output, name + '.log'), 'wb') as fh:
        fh.write(data)
    assert proc.returncode == expected, '%s: ожидался код завершения %s, получен %s; см. %s.log' % (name, expected, proc.returncode, name)
    return state

def untouched(state):
    assert not os.path.exists(state), state + ': проверка разрешила запись сеанса'

# Выявляемый сбой: profile_check отклоняет чистую среду сборки или сбрасывает её ветку.
untouched(run('missing-builder', ['--build', '--branch', '8.3'], 40))
untouched(run('noninteractive', ['--build', '--builder', '--branch', '8.3'], 12))
untouched(run('declined', ['--build', '--builder', '--branch', '8.3'], 12, u'NO'))
untouched(run('unsupported', ['--build', '--builder', '--branch', '8.4'], 2))
print('PASS: --builder, настоящее подтверждение TTY и проверка поддерживаемой ветки до записи сеанса')

confirm = u'\u042d\u0422\u041e \u041a\u041b\u041e\u041d'
state = run('wrong-srpm', ['--build', '--builder', '--branch', '8.3', '--srpm', srpm82], 41, confirm)
assert not os.path.exists(os.path.join(state, 'compile-boundary.log'))
states = glob.glob(os.path.join(state, 'sessions', '*', 'state'))
assert len(states) == 1 and open(states[0]).read().strip() == 'failed_prepare'
assert not glob.glob(os.path.join(state, 'work', '*', 'source-entries.txt'))
print('PASS: настоящий диспетчер отклоняет SRPM другой ветки до распаковки или компиляции')

for name, args, version, spec in [
    ('explicit83', ['--branch', '8.3', '--srpm', srpm83], '8.3.36', 'php83.spec'),
    ('default82', ['--srpm', srpm82], '8.2.35', 'php82.spec')
]:
    state = run(name, ['--build', '--builder'] + args, 0, confirm)
    states = glob.glob(os.path.join(state, 'sessions', '*', 'state'))
    assert len(states) == 1 and open(states[0]).read().strip() == 'built'
    compile_call = open(os.path.join(state, 'compile-boundary.log')).read().strip()
    assert compile_call.endswith('/SPECS/' + spec), name + ': скомпилирована неверная спецификация'
    rpm_dir = open(os.path.join(os.path.dirname(states[0]), 'rpm-dir')).read().strip()
    assert os.path.isfile(os.path.join(rpm_dir, 'php-' + version + '-1.el7.1.x86_64.rpm'))
    subprocess.check_call(['sha256sum', '-c', 'SHA256SUMS'], cwd=rpm_dir)
    print('PASS: %s настоящий запуск, сеанс, GPG/%%prep исходников и зависимости; подменён только вызов компиляции' % name)
print('Регрессионные проверки запуска сборки завершены. Результаты: ' + output)
