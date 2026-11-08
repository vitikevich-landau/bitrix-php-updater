import errno
import os
import pty
import select
import subprocess
import sys
import time

installer = os.path.abspath(sys.argv[1])
prefix = '''
source <(sed '/^# Мутирующие операции:/,$d' "$1")
err() { printf 'ОШИБКА: %s\\n' "$*" >&2; }
discover_managed_sites() {
  MANAGED_SITE_CANDIDATES=('http|one.example|8888|/srv/one' 'http|two.example|8888|/srv/two')
  MANAGED_SITE_LABELS=('one.example:8888 /srv/one' 'two.example:8888 /srv/two')
  MANAGED_SITE_ALIASES=('www.one.example' '')
}
select_managed_site '' "$2"
result=$?
printf '\\nRESULT:%s:%s\\n' "$result" "$MANAGED_SITE"
exit "$result"
'''
for name, answer, unattended, expected_rc, expected_site in [
    ('выбор второго сайта', b'2\n', '0', 0, 'http|two.example|8888|/srv/two'),
    ('выбор первого сайта', b'1\n', '0', 0, 'http|one.example|8888|/srv/one'),
    ('пустой ввод отменяет выбор', b'\n', '0', 12, ''),
    ('EOF отменяет выбор', b'\x04', '0', 12, ''),
    ('неверный номер отклоняется', b'3\n', '0', 83, ''),
    ('терминал в автоматическом режиме не запрашивает ввод', None, '1', 83, ''),
]:
    master, slave = pty.openpty()
    child = subprocess.Popen(['bash', '-c', prefix, 'fixture', installer, unattended], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], .05)
        if readable:
            try:
                chunk = os.read(master, 8192)
            except OSError as e:
                if e.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
            if answer is not None and not sent and 'Номер сайта'.encode() in output:
                os.write(master, answer)
                sent = True
        if child.poll() is not None and not readable:
            break
    if child.poll() is None:
        child.kill()
    child.wait()
    os.close(master)
    expected = f'RESULT:{expected_rc}:{expected_site}'.encode()
    assert child.returncode == expected_rc and expected in output, (name, child.returncode, output.decode(errors='replace'))
    if unattended == '1':
        assert 'Номер сайта'.encode() not in output
    print('PASS', name)
