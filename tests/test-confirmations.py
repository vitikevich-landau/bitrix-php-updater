#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Confirmation regressions using real Bash PTYs, compatible with Python 2.7/3.

Run in Linux with an installer path. Python bootstrap uses the normal command
entry point but stops at its first mkdir after consent. No download, runtime
installation, package operation or service restart is performed.
"""
from __future__ import print_function, unicode_literals

import errno
import codecs
import io
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time

if sys.version_info[0] < 3:
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout)


PHRASES = [
    'ЭТО КЛОН',
    'УСТАНОВИТЬ ИНСТРУМЕНТЫ',
    'РАЗРЕШАЮ НА КЛОНЕ',
    'ВЫПОЛНИТЬ НА КЛОНЕ',
    'СНИМОК ПРОВЕРЕН',
    'ОБНОВИТЬ PHP',
    'ОТКАТИТЬ PHP',
]
YES = ['да', 'ДА', 'Да', 'дА', 'y', 'Y', 'yes', 'YES', 'YeS', ' \tДа\t ']
NO = ['нет', 'НЕТ', 'НеТ', 'нЕт', 'n', 'N', 'no', 'NO', 'No', ' \tN\t ', '']


def shell_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"


def write_text(path, text):
    with io.open(path, 'w', encoding='utf-8', newline='\n') as output:
        output.write(text)


def run_process(command, env, answers, tty=True):
    """Send cooked-terminal input, including explicit EOF when requested."""
    payload = answers.encode('utf-8')
    if not tty:
        child = subprocess.Popen(command, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 env=env)
        output = child.communicate(payload)[0]
        return child.returncode, output.decode('utf-8', 'replace')
    master, slave = pty.openpty()
    settings = termios.tcgetattr(slave)
    settings[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, settings)
    child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                             close_fds=True, env=env)
    os.close(slave)
    os.write(master, payload)
    chunks = []
    deadline = time.time() + 5
    timed_out = False
    try:
        while True:
            if time.time() > deadline:
                timed_out = True
                child.kill()
                break
            if select.select([master], [], [], .05)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            elif child.poll() is not None:
                break
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
        os.close(master)
    output = b''.join(chunks).decode('utf-8', 'replace')
    if timed_out:
        output += '\nTEST TIMEOUT'
    return child.returncode, output


def main():
    if len(sys.argv) != 2:
        sys.exit('Usage: python test-confirmations.py /path/install.sh')
    installer = os.path.abspath(sys.argv[1])
    with io.open(installer, encoding='utf-8') as source:
        text = source.read()
    marker = '# Мутирующие операции:'
    assert marker in text, 'Installer CLI boundary missing'
    found = re.findall(r"^\s*confirm_phrase '[^']*' '([^']+)'", text, re.M)
    assert set(found) == set(PHRASES), 'Review coverage for changed confirmation phrases'
    directory = tempfile.mkdtemp(prefix='confirmation-tests-')
    failed = 0
    total = 0
    try:
        library = os.path.join(directory, 'library.sh')
        runner = os.path.join(directory, 'run.sh')
        env_file = os.path.join(directory, 'bootstrap-env.sh')
        write_text(library, text.split(marker, 1)[0])
        write_text(env_file, '''
# Keep the complete --bootstrap-python entry point and stop before any writes.
id() { printf '4242\\n'; }
mkdir() { printf 'CONSENT_BOUNDARY\\n'; return 87; }
curl() { printf 'UNEXPECTED_DOWNLOAD\\n'; return 88; }
''')
        env = dict(os.environ, LC_ALL='C', LANG='C', TERM='xterm', HOME=directory)
        env.pop('BASH_ENV', None)

        def check(name, body, answers, expected, required=(), forbidden=(),
                  tty=True, bootstrap=False, min_prompts=0):
            test_env = dict(env)
            if bootstrap:
                command = ['bash', installer, '--bootstrap-python']
                test_env['BASH_ENV'] = env_file
            else:
                write_text(runner, 'source ' + shell_quote(library) + '\n' + body + '\n')
                command = ['bash', runner]
            result, output = run_process(command, test_env, answers, tty)
            valid = result == expected
            valid = valid and all(part in output for part in required)
            valid = valid and not any(part in output for part in forbidden)
            valid = valid and output.count('> ') >= min_prompts
            print(('PASS ' if valid else 'FAIL ') + name)
            if not valid:
                print('exit', result, 'expected', expected)
                print(output[-1400:])
            return not valid

        # Every existing action accepts Russian and Linux-style approvals.
        for phrase in PHRASES:
            body = "confirm_phrase 'Fixture action' " + shell_quote(phrase)
            for answer in ['да', 'Y', 'YeS', phrase, phrase.lower(), phrase.title()]:
                failed += check('action ' + phrase + ' accepts ' + repr(answer),
                                body, answer + '\n', 0)
                total += 1

        body = "confirm_phrase 'Fixture action' 'ОБНОВИТЬ PHP'"
        for answer in YES:
            failed += check('generic approval ' + repr(answer), body, answer + '\n', 0)
            total += 1
        for answer in NO:
            failed += check('generic decline ' + repr(answer), body, answer + '\n', 12)
            total += 1
        for answers, expected in [('maybe\ny\n', 0), ('maybe\nNo\n', 12),
                                  ('yess\nДА\n', 0), ('давай\nнет\n', 12)]:
            failed += check('invalid answer reprompts ' + repr(answers), body,
                            answers, expected, required=('Введите',), min_prompts=2)
            total += 1
        for name, answers, tty in [('terminal EOF', '\x04', True),
                                   ('partial yes then EOF', 'y\x04\x04', True),
                                   ('piped yes', 'y\n', False)]:
            failed += check(name, body, answers, 12, tty=tty)
            total += 1

        sequence = """
confirm_phrase 'First action' 'СНИМОК ПРОВЕРЕН' || exit $?
printf 'FIRST_APPROVED\\n'
confirm_phrase 'Second action' 'ОБНОВИТЬ PHP' || exit $?
printf 'BOTH_APPROVED\\n'
"""
        for name, answers, expected, required, forbidden in [
                ('two approvals', 'y\nда\n', 0, ('BOTH_APPROVED',), ()),
                ('decline second', 'yes\nn\n', 12, ('FIRST_APPROVED',), ('BOTH_APPROVED',)),
                ('EOF second', 'ДА\n\x04', 12, ('FIRST_APPROVED',), ('BOTH_APPROVED',)),
                ('decline first', 'N\ny\n', 12, (), ('FIRST_APPROVED', 'BOTH_APPROVED'))]:
            failed += check(name, sequence, answers, expected, required, forbidden)
            total += 1

        # Normal bootstrap dispatch, guarded at the first post-consent write.
        for answer in YES:
            failed += check('bootstrap approval ' + repr(answer), '', answer + '\n',
                            5, ('CONSENT_BOUNDARY',), ('UNEXPECTED_DOWNLOAD',), bootstrap=True)
            total += 1
        for answer in NO:
            failed += check('bootstrap decline ' + repr(answer), '', answer + '\n',
                            4, forbidden=('CONSENT_BOUNDARY', 'UNEXPECTED_DOWNLOAD'), bootstrap=True)
            total += 1
        for name, answers, expected, required, forbidden, tty in [
                ('bootstrap invalid then yes', 'maybe\nДа\n', 5, ('CONSENT_BOUNDARY',), (), True),
                ('bootstrap invalid then no', 'maybe\nNO\n', 4, ('Введите',), ('CONSENT_BOUNDARY',), True),
                ('bootstrap EOF', '\x04', 4, (), ('CONSENT_BOUNDARY',), True),
                ('bootstrap partial yes EOF', 'y\x04\x04', 4, (), ('CONSENT_BOUNDARY',), True),
                ('bootstrap piped yes', 'y\n', 5, ('интерактив',), ('CONSENT_BOUNDARY',), False)]:
            failed += check(name, '', answers, expected, required, forbidden,
                            tty=tty, bootstrap=True,
                            min_prompts=2 if 'invalid' in name else 0)
            total += 1
        print('{0}/{1} confirmation cases passed'.format(total - failed, total))
        return bool(failed)
    finally:
        shutil.rmtree(directory)


if __name__ == '__main__':
    sys.exit(main())
