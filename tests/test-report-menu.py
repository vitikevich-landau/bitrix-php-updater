"""Report selection/comparison through the real Bash -> Python terminal path.

Run in a disposable Linux container. Fixtures never invoke a diagnostic or an
update; report menus and --compare only read the deliberately supplied JSON.
"""
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import termios
import time


installer = Path(sys.argv[1]).resolve(strict=True)
HOST = socket.gethostname()
SCHEMA = 'bitrix-server-master/diagnostic-v1'
failed = 0
total = 0


def report(name, valid, detail=''):
    global failed, total
    total += 1
    print(('PASS ' if valid else 'FAIL ') + name, flush=True)
    if not valid:
        failed += 1
        print(detail[-6500:], flush=True)


def diagnostic(stamp, php='8.2.20', host=HOST, alerts=None):
    return {'schema': SCHEMA, 'hostname': host, 'timestamp_utc': stamp,
            'mode': 'full', 'system': {'name': 'CentOS Linux 7'},
            'bitrix': {'version': '7.5.5', 'environment': {}},
            'php': {'version': php}, 'web': {'apache': {'version': '2.4.6', 'active': True},
                                          'nginx': {'version': '1.20.2'}},
            'rpm': {'core_php': {'status': 'consistent'}},
            'update_check': {'status': 'offline'}, 'site_probe': None,
            'alerts': [] if alerts is None else alerts}


def alert(code, level, title):
    return {'code': code, 'level': level, 'title': title, 'detail': 'Подробности: ' + title}


class Fixture:
    def __init__(self, directory):
        self.root = Path(directory)
        self.cwd = self.root / 'working files'
        self.home = self.root / 'admin home'
        self.script_dir = self.root / 'script files'
        for folder in (self.cwd, self.home, self.script_dir):
            folder.mkdir()
        self.script = self.script_dir / 'install.sh'
        shutil.copyfile(installer, self.script)
        self.env = dict(os.environ, HOME=str(self.home), TERM='xterm')
        self.env.pop('NO_COLOR', None)
        self.env.pop('BASH_ENV', None)

    def save(self, name, obj, folder=None):
        path = (folder or self.cwd) / name
        path.write_text(json.dumps(obj, ensure_ascii=False), encoding='utf-8')
        return path

    def pair(self, folder=None, host=HOST):
        before = self.save('before with spaces.json', diagnostic('2026-11-07T10:00:00Z', host=host), folder)
        after = self.save('after with spaces.json', diagnostic('2026-11-08T10:00:00Z', php='8.2.35', host=host), folder)
        return before, after

    def tty(self, inputs, env=None, args=('--compare-menu',)):
        master, slave = pty.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        child = subprocess.Popen(['/bin/bash', str(self.script), *args], cwd=self.cwd,
                                 stdin=slave, stdout=slave, stderr=slave,
                                 env=dict(self.env, **(env or {})))
        os.close(slave)
        os.write(master, inputs.encode())
        data = bytearray()
        deadline = time.monotonic() + 5
        timeout = False
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    data.extend(chunk)
                elif child.poll() is not None:
                    break
            try:
                rc = child.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                timeout = True
                child.kill()
                rc = child.wait()
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)
        return rc, data.decode(errors='replace'), timeout

    def cli(self, *args):
        result = subprocess.run(['/bin/bash', str(self.script), *args], cwd=self.cwd,
                                env=self.env, capture_output=True, text=True, timeout=5)
        return result.returncode, result.stdout + result.stderr


def pty_case(name, setup, inputs, check, env=None):
    with tempfile.TemporaryDirectory() as directory:
        fixture = Fixture(directory)
        setup(fixture)
        before = {p: p.read_bytes() for folder in (fixture.cwd, fixture.home, fixture.script_dir)
                  for p in folder.iterdir() if p.is_file() and not p.is_symlink()}
        rc, output, timeout = fixture.tty(inputs(fixture) if callable(inputs) else inputs, env)
        unchanged = all(p.read_bytes() == data for p, data in before.items())
        valid = rc == 0 and not timeout and 'Traceback' not in output and unchanged and check(output)
        report(name, valid, f'rc={rc}, timeout={timeout}, unchanged={unchanged}\n{output}')


def compared(output):
    return 'СРАВНЕНИЕ ОТЧЁТОВ' in output


def pair_changed(output):
    return compared(output) and re.search(r'PHP CLI[^\r\n]*8\.2\.20[^\r\n]*8\.2\.35', output)


pty_case('empty discovery explains how to create reports', lambda f: None, '0\n',
         lambda out: not compared(out) and re.search(r'аудит|диагностик', out, re.I))
pty_case('one report cannot become a fabricated comparison',
         lambda f: f.save('only.json', diagnostic('2026-11-08T10:00:00Z')), '1\n0\n',
         lambda out: not compared(out) and re.search(r'два|двух|пары|пара|недостаточно', out, re.I))
pty_case('latest pair is selected without filename input', lambda f: f.pair(), '1\n0\n', pair_changed)
pty_case('manual before and after selections use numbers', lambda f: f.pair(), '2\n2\n1\n0\n', pair_changed)
pty_case('script directory reports are discovered from a different cwd',
         lambda f: f.pair(f.script_dir), '1\n0\n', pair_changed)
pty_case('home directory reports are discovered', lambda f: f.pair(f.home), '1\n0\n', pair_changed)


def chronology(f):
    f.pair()
    path = f.save('zzz-most-recent-filename.json', diagnostic('2026-11-06T10:00:00Z', php='8.2.1'))
    os.utime(path, (2000000000, 2000000000))


pty_case('latest means report timestamps rather than filename or mtime', chronology, '1\n0\n',
         lambda out: pair_changed(out) and not re.search(r'PHP CLI[^\r\n]*8\.2\.1\b', out))


def mixed_servers(f):
    f.pair()
    f.save('foreign-before.json', diagnostic('2026-11-08T11:00:00Z', php='8.3.1', host='foreign.example'))
    f.save('foreign-after.json', diagnostic('2026-11-08T12:00:00Z', php='8.3.36', host='foreign.example'))


pty_case('latest shortcut prefers the current host without mixing servers', mixed_servers, '1\n0\n',
         lambda out: pair_changed(out) and not re.search(r'PHP CLI[^\r\n]*8\.3\.', out))
pty_case('manual after list excludes different servers', mixed_servers, '2\n4\n1\n0\n', pair_changed)
pty_case('one foreign server pair can be selected automatically',
         lambda f: f.pair(host='copied-server.example'), '1\n0\n', pair_changed)


def ambiguous_hosts(f):
    f.pair(host='server-a.example')
    f.save('b-before.json', diagnostic('2026-11-08T11:00:00Z', host='server-b.example'))
    f.save('b-after.json', diagnostic('2026-11-08T12:00:00Z', host='server-b.example'))


pty_case('ambiguous foreign hosts require explicit report selection', ambiguous_hosts, '1\n0\n',
         lambda out: not compared(out) and re.search(r'выбер|выбор', out, re.I))


def same_date(f):
    f.save('one.json', diagnostic('2026-11-08T10:00:00Z'))
    f.save('two.json', diagnostic('2026-11-08T10:00:00Z'))


pty_case('same-date duplicates do not become before and after', same_date, '1\n0\n',
         lambda out: not compared(out))


def invalid_files(f):
    f.pair()
    for name, obj in [('array.json', []), ('foreign.json', {'schema': 'other'}),
                      ('fallback.json', {'schema': 'bitrix-server-master/fallback-v1'}),
                      ('missing-fields.json', {'schema': SCHEMA}),
                      ('broken-alerts.json', dict(diagnostic('2026-11-09T10:00:00Z'), alerts=[1]))]:
        f.save(name, obj)
    (f.cwd / 'broken-json.json').write_text('{broken', encoding='utf-8')
    (f.cwd / 'directory.json').mkdir()
    os.mkfifo(f.cwd / 'pipe.json')
    (f.cwd / 'alias.json').symlink_to(f.cwd / 'before with spaces.json')


pty_case('invalid fallback and special JSON files cannot block valid reports', invalid_files,
         '1\n0\n', lambda out: pair_changed(out) and re.search(r'пропущ|неподход|не удалось|сокращ', out, re.I))


def incomplete_report(f):
    f.pair()
    f.save('incomplete.json', {'schema': SCHEMA, 'mode': 'full', 'hostname': HOST,
                              'timestamp_utc': '2026-11-09T10:00:00Z', 'alerts': []})


pty_case('incomplete diagnostics cannot displace a valid latest pair', incomplete_report,
         '1\n0\n', pair_changed)


def large_file(f):
    f.pair()
    obj = diagnostic('2026-11-09T10:00:00Z', php='8.4.99')
    obj['padding'] = 'x' * (8 * 1024 * 1024)
    f.save('too-large.json', obj)


pty_case('oversized reports are ignored before JSON loading', large_file, '1\n0\n', pair_changed)


def other_directory(f):
    f.other = f.root / 'reports elsewhere'
    f.other.mkdir()
    f.pair(f.other)


pty_case('other directory with spaces requires no filenames', other_directory,
         lambda f: '3\n' + str(f.other) + '\n1\n0\n', pair_changed)
pty_case('Enter returns safely without choosing a report', lambda f: f.pair(), '\n',
         lambda out: not compared(out))
pty_case('EOF leaves the report menu without spinning', lambda f: f.pair(), '\x04',
         lambda out: not compared(out))
pty_case('invalid menu number can be corrected', lambda f: f.pair(), '999\n1\n0\n', pair_changed)
pty_case('NO_COLOR disables all comparison ANSI escapes', lambda f: f.pair(), '1\n0\n',
         lambda out: pair_changed(out) and '\x1b' not in out, {'NO_COLOR': '1'})
pty_case('dumb terminals receive readable plain comparison', lambda f: f.pair(), '1\n0\n',
         lambda out: pair_changed(out) and '\x1b' not in out, {'TERM': 'dumb'})


def changed_alerts(f):
    old = diagnostic('2026-11-07T10:00:00Z', alerts=[
        alert('RESOLVED', 'warning', 'Устранённая проблема'),
        alert('STAYS', 'critical', 'Оставшаяся критическая проблема')])
    new = diagnostic('2026-11-08T10:00:00Z', php='8.2.35', alerts=[
        alert('STAYS', 'critical', 'Оставшаяся критическая проблема'),
        alert('NEW', 'warning', 'Новое предупреждение')])
    f.save('before.json', old)
    f.save('after.json', new)


def alert_colors(out):
    return (compared(out) and
            re.search(r'\x1b\[32m[^\x1b]*Устранённая проблема[^\x1b]*\x1b\[0m', out) and
            re.search(r'\x1b\[31m[^\x1b]*Оставшаяся критическая проблема[^\x1b]*\x1b\[0m', out) and
            re.search(r'\x1b\[33m[^\x1b]*Новое предупреждение[^\x1b]*\x1b\[0m', out))


pty_case('resolved new and remaining alerts have readable colored titles', changed_alerts,
         '1\n0\n', alert_colors)


def scope_change(f):
    old = diagnostic('2026-11-07T10:00:00Z', alerts=[alert('PATCH', 'warning', 'Обновление найдено')])
    old['mode'] = 'quick'
    f.save('before.json', old)
    f.save('after.json', diagnostic('2026-11-08T10:00:00Z'))


pty_case('different diagnostic scopes explain disappearing alerts', scope_change, '1\n0\n',
         lambda out: compared(out) and re.search(r'условия|режим', out, re.I) and
         not re.search(r'\x1b\[32m[^\x1b]*Обновление найдено', out))


def severity_change(f):
    f.save('before.json', diagnostic('2026-11-07T10:00:00Z', alerts=[alert('SAME', 'warning', 'Стало критично')]))
    f.save('after.json', diagnostic('2026-11-08T10:00:00Z', alerts=[alert('SAME', 'critical', 'Стало критично')]))


pty_case('same alert code becoming critical remains visible in red', severity_change, '1\n0\n',
         lambda out: compared(out) and re.search(r'\x1b\[31m[^\x1b]*Стало критично', out))


def terminal_controls(f):
    f.save('before.json', diagnostic('2026-11-07T10:00:00Z'))
    f.save('after.json', diagnostic('2026-11-08T10:00:00Z', alerts=[alert('TERM', 'warning', 'escape\x1b[2J\ncontrol')]))


pty_case('report strings cannot inject terminal control sequences', terminal_controls, '1\n0\n',
         lambda out: compared(out) and '\x1b[2J' not in out and 'escape' in out, {'NO_COLOR': '1'})


def cli_case(name, operation):
    with tempfile.TemporaryDirectory() as directory:
        fixture = Fixture(directory)
        try:
            valid, detail = operation(fixture)
        except Exception as error:
            valid, detail = False, repr(error)
        report(name, valid, detail)


def json_contract(f):
    before, after = f.pair()
    rc, out = f.cli('--compare', str(before), str(after), '--json')
    result = json.loads(out)
    expected = {'server', 'before', 'after', 'changes', 'resolved_alerts', 'new_alerts'}
    return (rc == 0 and expected.issubset(result) and result['server'] == HOST and
            result['changes'] == [{'component': 'PHP CLI', 'before': '8.2.20', 'after': '8.2.35'}], out)


cli_case('existing compare JSON interface remains compatible', json_contract)


def reject_server_mix(f):
    before, after = f.pair()
    obj = json.loads(after.read_text())
    obj['hostname'] = 'different.example'
    after.write_text(json.dumps(obj))
    rc, out = f.cli('--compare', str(before), str(after))
    return rc != 0 and 'Traceback' not in out and re.search(r'разн.*сервер', out, re.I), out


cli_case('CLI rejects reports from different servers clearly', reject_server_mix)


def reject_malformed(f):
    before, after = f.pair()
    after.write_text(json.dumps(dict(diagnostic('2026-11-08T10:00:00Z'), alerts=[3])))
    rc, out = f.cli('--compare', str(before), str(after))
    return rc != 0 and 'Traceback' not in out and re.search(r'ошиб|некоррект|отчёт', out, re.I), out


cli_case('malformed diagnostic schema produces a useful error rather than traceback', reject_malformed)


def reject_incomplete(f):
    before, after = f.pair()
    after.write_text(json.dumps({'schema': SCHEMA, 'mode': 'full', 'hostname': HOST,
                                 'timestamp_utc': '2026-11-08T10:00:00Z', 'alerts': []}))
    rc, out = f.cli('--compare', str(before), str(after))
    return rc != 0 and 'Traceback' not in out and '[OK]' not in out, out


cli_case('missing diagnostic sections cannot produce a green CLI summary', reject_incomplete)


def no_python(f):
    marker = '# Мутирующие операции:'
    content = f.script.read_text(encoding='utf-8')
    f.script.write_text(content.replace(marker, '''python_path() { return 1; }
fallback_diagnose() { echo UNEXPECTED_FALLBACK_DIAGNOSIS; return 99; }
''' + marker, 1), encoding='utf-8')
    outputs = [f.cli('--compare-menu'), f.cli('--compare', 'old.json', 'new.json')]
    valid = all(rc == 3 and 'Python 3.8+' in out and 'UNEXPECTED_FALLBACK_DIAGNOSIS' not in out
                for rc, out in outputs)
    return valid, repr(outputs)


cli_case('without Python both comparison modes explain the missing dependency', no_python)
print(f'{total - failed}/{total} report comparison tests passed', flush=True)
sys.exit(bool(failed))
