"""Contextual menu regressions against real Bash readiness and navigation.

Run in disposable Linux containers. PHP/RPM/Apache and child CLI operations
are controlled boundaries; no update, service mutation or network is allowed.
"""
import codecs
import os
from pathlib import Path
import pty
import re
import select
import shlex
import subprocess
import sys
import tempfile
import termios
import time


installer = Path(sys.argv[1]).resolve(strict=True)
source = installer.read_text(encoding='utf-8')
prefix = source.split('# Мутирующие операции:', 1)[0]
assert prefix != source, 'Installer CLI boundary missing'
# Redirect only this filesystem boundary; the real profile check stays intact.
prefix = prefix.replace('[ -d /etc/httpd/bx ]', '[ -d "$ROOT/httpd/bx" ]')

boundaries = r'''
CURRENT=${CURRENT:-8.2.20}
platform_check() { if [ "${BAD_PLATFORM:-0}" = 1 ]; then err 'fixture unsupported platform'; return 20; fi; }
need() { :; }
php() { [ "${PHP_FAIL:-0}" = 0 ] || return 1; printf '%s' "$CURRENT"; }
httpd() {
    if [ "${BAD_APACHE:-0}" = 1 ]; then printf ' mpm_event_module (shared)\n';
    else printf ' php_module (shared)\n mpm_prefork_module (shared)\n'; fi
}
systemctl() { return 3; }
rpm() {
    if [ "$1" = -qa ]; then
        [ "${RPM_FAIL:-0}" = 0 ] || return 1
        if [[ "$*" == *'%{VERSION}'* ]]; then
            printf 'php|(none)|%s|1.el7.remi|x86_64\n' "$CURRENT"
            printf 'php-cli|(none)|%s|1.el7.remi|x86_64\n' "$CURRENT"
            printf 'php-common|(none)|%s|1.el7.remi|x86_64\n' "${RPM_COMMON:-$CURRENT}"
        else printf 'php\nphp-cli\nphp-common\n'; fi
        return
    fi
    case "${@: -1}" in
      bitrix-env)
        if [ -n "${ENV_VERSION:-}" ]; then printf '%s\n' "$ENV_VERSION";
        else printf 'package bitrix-env is not installed\n'; return 1; fi ;;
      bitrix-env-crm) printf 'package bitrix-env-crm is not installed\n'; return 1 ;;
      php|php-cli) printf '%s' "$CURRENT" ;;
      *) return 1 ;;
    esac
}
'''

failed = 0
total = 0


def report(name, valid, detail=''):
    global failed, total
    total += 1
    print(('PASS ' if valid else 'FAIL ') + name, flush=True)
    if not valid:
        failed += 1
        print(detail[-5000:], flush=True)


def environment(directory):
    root = Path(directory)
    (root / 'httpd/bx').mkdir(parents=True)
    (root / 'events').touch()
    return dict(os.environ, ROOT=str(root), EVENTS=str(root / 'events'),
                OUTPUT=str(root / 'output'), TERM='xterm')


def shell_case(name, body, expected=0):
    with tempfile.TemporaryDirectory() as directory:
        env = environment(directory)
        script = Path(directory) / 'case.sh'
        script.write_text(prefix + '\n' + boundaries + '\n' + body, encoding='utf-8')
        result = subprocess.run(['/bin/bash', str(script)], env=env,
                                capture_output=True, text=True, timeout=8)
        report(name, result.returncode == expected,
               f'rc={result.returncode}\n{result.stdout}\n{result.stderr}')


# Catches trusting a successful diagnostic or checking only PHP/CLI RPMs.
for name, settings, wanted, target in [
    ('supported PHP 8.2 is ready', 'CURRENT=8.2.20', 'ready', '8.2.35'),
    ('supported PHP 8.3 stays on its branch', 'CURRENT=8.3.8', 'ready', '8.3.36'),
    ('old PHP requires migration plan', 'CURRENT=7.4.33', 'legacy', ''),
    ('current PHP does not offer update', 'CURRENT=8.2.35', 'current', '8.2.35'),
    ('newer PHP is not downgraded', 'CURRENT=8.3.37', 'newer', '8.3.36'),
    ('unsupported PHP stays blocked', 'CURRENT=8.4.1', 'unsupported', ''),
    ('unknown version stays blocked', 'CURRENT=8.3.36RC1', 'unknown', ''),
    ('missing PHP stays blocked', 'PHP_FAIL=1', 'unknown', ''),
    ('unsupported platform stays blocked', 'BAD_PLATFORM=1', 'blocked', '8.2.35'),
    ('FPM profile stays blocked', 'BAD_APACHE=1', 'blocked', '8.2.35'),
    ('BitrixEnv 9 stays blocked', 'ENV_VERSION=9.0', 'blocked', '8.2.35'),
    ('mismatching php-common stays blocked', 'RPM_COMMON=8.2.19', 'blocked', '8.2.35'),
    ('unreadable RPM database stays blocked', 'RPM_FAIL=1', 'blocked', '8.2.35'),
    ('non-root check cannot launch preparation', 'id() { if [ "$1" = -u ]; then echo 1000; else command id "$@"; fi; }', 'needs_root', '8.2.35'),
]:
    body = settings + '\nmenu_update_readiness\n'
    body += f'[ "${{NEXT_STATUS:-}}" = {wanted} ] || {{ echo "unexpected readiness: ${{NEXT_STATUS:-missing}}"; exit 1; }}\n'
    body += '[ -n "${NEXT_REASON:-}" ] || { echo "missing explanation"; exit 1; }\n'
    if target:
        body += f'[ "$NEXT_TARGET" = {target} ] || {{ echo "wrong target: $NEXT_TARGET"; exit 1; }}\n'
    shell_case(name, body)


AUTO = r'подготовить.*обнов|автообнов|автоматическ.*обнов|обновить.*выпуск'
PLAN = r'план'
ROLLBACK = r'откат'
SITE = 'https|shop.example|443|/home/bitrix/site with spaces'
ORIGINAL = '20261108T100000Z-111'
ATTEMPT = '20261108T110000Z-222'
STALE = '20261107T080000Z-999'


def pty_case(name, setup, action, choices=(), forbidden=(), calls=None, expected_rc=0,
             required=(), full_script=False, initial_input='', colored=(),
             env_updates=None, plain_output=False):
    """Drive actual prompts; select displayed labels instead of fixed positions."""
    with tempfile.TemporaryDirectory() as directory:
        env = environment(directory)
        env.pop('NO_COLOR', None)
        env.update(env_updates or {})
        script = Path(directory) / 'case.sh'
        if full_script:
            # Keep CLI entry, child process and metadata wiring intact. Inject
            # external fixtures after function definitions in every process.
            content = source.replace('[ -d /etc/httpd/bx ]', '[ -d "$ROOT/httpd/bx" ]')
            content = content.replace('# Мутирующие операции:',
                                      boundaries + '\n' + setup + '\n# Мутирующие операции:', 1)
        else:
            content = prefix + '\n' + boundaries + '\n' + setup + '\n' + action
        script.write_text(content, encoding='utf-8')
        master, slave = pty.openpty()
        settings = termios.tcgetattr(slave)
        settings[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, settings)
        child = subprocess.Popen(['/bin/bash', str(script)], stdin=slave,
                                 stdout=slave, stderr=slave, env=env)
        os.close(slave)
        if initial_input:
            os.write(master, initial_input.encode())
        output = ''
        pending = ''
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        queue = list(choices) + ['0']
        picked = []
        absent = []
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    text = decoder.decode(chunk)
                    output += text
                    pending += text
                    # All contextual prompts include the safe default [0].
                    if re.search(r'\[0\][^\r\n]*[:>] ?$', pending):
                        choice = queue.pop(0) if queue else '0'
                        if choice in ('0', '', 'invalid', 'EOF'):
                            answer = {'invalid': '999', 'EOF': '\x04'}.get(choice, choice)
                        else:
                            matches = [(n, label) for n, label in re.findall(r'^\s*(\d+)[.)]\s*(.+)$', pending, re.M)
                                       if re.search(choice, label, re.I)]
                            if len(matches) != 1:
                                absent.append(f'expected one option /{choice}/, found {matches}')
                                answer = '0'
                            else:
                                answer, label = matches[0]
                                picked.append(label)
                        os.write(master, answer.encode() + (b'' if answer == '\x04' else b'\n'))
                        if full_script and answer == '0':
                            # Return from the checks submenu, then exit main.
                            os.write(master, b'0\n0\n')
                        pending = ''
                elif child.poll() is not None:
                    break
            # Closing the last PTY descriptor can report EIO just before the
            # kernel marks the child exited. Allow that normal exit to finish.
            try:
                rc = child.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                child.kill()
                absent.append('prompt timed out')
                rc = child.wait()
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)
        events = (Path(directory) / 'events').read_text()
        option_labels = '\n'.join(re.findall(r'^\s*\d+[.)]\s*(.+)$', output, re.M))
        valid = rc == expected_rc and not absent and 'Что дальше' in output
        valid = valid and not any(re.search(item, option_labels, re.I) for item in forbidden)
        valid = valid and all(item in output for item in required)
        # The meaning-bearing text itself must be inside the ANSI span: an
        # unrelated colored heading must not satisfy a status-color assertion.
        for color, pattern in colored:
            spans = re.findall(rf'\x1b\[{color}m([^\x1b\r\n]*)\x1b\[0m', output)
            if not any(re.search(pattern, text, re.I) for text in spans):
                absent.append(f'missing color {color} around /{pattern}/')
                valid = False
        if plain_output and '\x1b' in output:
            absent.append('ANSI emitted with color disabled')
            valid = False
        if calls is not None:
            valid = valid and events.splitlines() == calls
        report(name, valid, f'rc={rc}; issues={absent}; chosen={picked}; calls={events}\n{output}')


child_stub = r'''
menu_invoke() {
    printf 'CALL' >> "$EVENTS"; printf '|%s' "$@" >> "$EVENTS"; printf '\n' >> "$EVENTS"
    MENU_SESSION='' MENU_STATE='' MENU_ORIGIN='' MENU_SITE='' MENU_WEB=''
    return 0
}
'''

# These exercise the real renderer in a terminal. Missing semantic color,
# wrong severity, or coloring only the heading must fail these cases.
pty_case('current PHP explanation is green', 'CURRENT=8.2.35\n' + child_stub,
         'menu_action --check', forbidden=[AUTO],
         colored=[(32, r'уже установлена|не требуется')])
pty_case('available preparation is yellow while update is pending', child_stub,
         'menu_action --check', colored=[(33, r'подготовк.*обновления')])
for action, pattern in [('--check-site', r'Проверка.*сайта.*пройдена'),
                        ('--setup-update', r'Настройки.*сохранены')]:
    pty_case(action + ' successful outcome is green', child_stub,
             'menu_action ' + action, colored=[(32, pattern)])

for setting, pattern in [('BAD_APACHE=1', r'mod_php'),
                         ('RPM_COMMON=8.2.19', r'Пакеты PHP.*не согласованы')]:
    pty_case(setting + ' blocked explanation is red', setting + '\n' + child_stub,
             'menu_action --check', forbidden=[AUTO], colored=[(31, pattern)])

for setting in ['PHP_FAIL=1', 'CURRENT=8.3.36RC1']:
    pty_case(setting + ' unknown PHP explanation is yellow', setting + '\n' + child_stub,
             'menu_action --check', forbidden=[AUTO],
             colored=[(33, r'Версия PHP не определена')])

for action, pattern in [('--check-site', r'Проверка сайта отменена'),
                        ('--setup-update', r'Настройка отменена'),
                        ('--update', r'Операция отменена')]:
    pty_case(action + ' cancellation is yellow', child_stub.replace('return 0', 'return 12'),
             'menu_action ' + action, colored=[(33, pattern)])

for state, rc, color, pattern in [
    ('completed', 0, 32, r'Обновление завершено'),
    ('already_current', 0, 32, r'Обновление не требуется'),
    ('rollback_completed', 0, 32, r'Откат завершён'),
    ('installation_failed', 62, 31, r'Установка.*ошибкой'),
    ('verify_failed', 64, 31, r'проверка результата не завершена'),
    ('unknown_state', 0, 33, r'Состояние не подтверждено'),
    ('started', 0, 33, r'Подготовка операции'),
]:
    state_stub = child_stub.replace("MENU_STATE=''", 'MENU_STATE=' + state)
    pty_case(state + ' operation summary uses semantic color',
             state_stub.replace('return 0', f'return {rc}'),
             'menu_action --update', colored=[(color, pattern)])

pty_case('error and warning prefixes receive red and yellow', child_stub,
         "err color-error; warn color-warning; menu_action --check",
         colored=[(31, 'ОШИБКА: color-error'), (33, 'ВНИМАНИЕ: color-warning')])
pty_case('failed operation without metadata is red',
         child_stub.replace('return 0', 'return 51'), 'menu_action --update',
         colored=[(31, r'Операция остановлена')])

for settings in [{'NO_COLOR': '1'}, {'TERM': 'dumb'}]:
    pty_case(str(settings) + ' disables terminal color', 'CURRENT=8.2.35\n' + child_stub,
             'err color-error; warn color-warning; menu_action --check',
             env_updates=settings, plain_output=True,
             required=['ОШИБКА: color-error', 'ВНИМАНИЕ: color-warning'])

shell_case('captured messages preserve streams and prefixes without ANSI', r'''
err color-error > "$OUTPUT" 2> "$ROOT/errors"
warn color-warning >> "$OUTPUT" 2>> "$ROOT/errors"
[ ! -s "$OUTPUT" ] || exit 1
grep -Fxq 'ОШИБКА: color-error' "$ROOT/errors" || exit 1
grep -Fxq 'ВНИМАНИЕ: color-warning' "$ROOT/errors" || exit 1
status_line ok color-success >> "$OUTPUT"
menu_state_text completed >> "$OUTPUT"
CURRENT=8.2.35
menu_next_actions --check 0 <<< 0 >> "$OUTPUT"
case "$(cat "$OUTPUT" "$ROOT/errors")" in *$'\033'*) exit 1 ;; esac
''')

# Catches broken wiring between the real manual menu, internal CLI result
# channel, site selection and a subsequent child process. Only external site
# discovery/probing and the final update boundary are replaced here.
end_to_end = r'''
discover_managed_sites() {
    MANAGED_SITE_CANDIDATES=('http|other.example|80|/home/bitrix/other' 'https|shop.example|443|/home/bitrix/site with spaces')
    MANAGED_SITE_LABELS=('other.example:80 — /home/bitrix/other' 'shop.example:443 — /home/bitrix/site with spaces')
    MANAGED_SITE_ALIASES=('' '')
}
managed_http_check() {
    validate_managed_site "$MANAGED_SITE" || return 85
    printf 'PROBE|%s|%s\n' "$1" "$MANAGED_SITE" >> "$EVENTS"
}
auto_update_dispatch() {
    [ "$MENU_RESULT_ENABLED" = 1 ] || return 99
    printf 'AUTO' >> "$EVENTS"; printf '|%s' "$@" >> "$EVENTS"; printf '\n' >> "$EVENTS"
    err 'FIXTURE_AUTO_STOP'
    return 80
}
'''
pty_case('full menu carries selected site through real child result channel',
         end_to_end, '', [AUTO], full_script=True, initial_input='1\n5\n2\n',
         calls=['PROBE|8.2.20|' + SITE, 'AUTO|--site|' + SITE],
         required=['Выберите сайт для временной проверки PHP', 'FIXTURE_AUTO_STOP',
                   'Операция остановлена'])

# Child work is replaced to avoid system mutation; the real chooser decides the
# next command, arguments and safe default. Wrong routing changes recorded calls.
pty_case('ready quick check continues to auto-update', child_stub,
         'menu_action --check', [AUTO], calls=['CALL|--check', 'CALL|--auto-update'])
pty_case('diagnostic rc zero does not authorize blocked profile', 'BAD_APACHE=1\n' + child_stub,
         'menu_action --check', forbidden=[AUTO], calls=['CALL|--check'], required=['mod_php'])
pty_case('legacy PHP continues to migration plan', 'CURRENT=7.4.33\n' + child_stub,
         'menu_action --check', [PLAN], forbidden=[AUTO], calls=['CALL|--check', 'CALL|--plan'])
pty_case('already-current PHP has no auto-update shortcut', 'CURRENT=8.2.35\n' + child_stub,
         'menu_action --check', forbidden=[AUTO], calls=['CALL|--check'])
for action in ['--plan', '--audit --offline', '--setup-update']:
    pty_case(action + ' exposes explicit preparation shortcut', child_stub,
             'menu_action ' + action, [AUTO],
             calls=['CALL|' + action.replace(' ', '|'), 'CALL|--auto-update'])

comparison_stub = child_stub + r'''
bash() {
    [ "$1" = "$SELF" ] || return 99
    shift
    printf 'CALL' >> "$EVENTS"; printf '|%s' "$@" >> "$EVENTS"; printf '\n' >> "$EVENTS"
}
'''
pty_case('audit follow-up opens report selection and returns to next actions', comparison_stub,
         'menu_action --audit --offline', ['Сравнить.*отчёты'],
         calls=['CALL|--audit|--offline', 'CALL|--compare-menu'])

for action, summary in [('--check-site', 'Проверка сайта отменена'),
                        ('--setup-update', 'Настройка отменена')]:
    cancelled = child_stub.replace('return 0', 'return 12')
    pty_case(action + ' cancellation is explained before next choices', cancelled,
             'menu_action ' + action, calls=['CALL|' + action], required=[summary])

site_stub = child_stub.replace("MENU_SITE=''", 'MENU_SITE=' + shlex.quote(SITE))
pty_case('site continuation preserves exact descriptor', site_stub,
         'menu_action --check-site', [AUTO],
         calls=['CALL|--check-site', 'CALL|--auto-update|--site|' + SITE])

site_once = child_stub.replace('    return 0',
                               '    [ "$1" != --check-site ] || MENU_SITE=' + shlex.quote(SITE) + '\n    return 0')
pty_case('viewing plan preserves selected site for update', site_once,
         'menu_action --check-site', [PLAN, AUTO],
         calls=['CALL|--check-site', 'CALL|--plan', 'CALL|--auto-update|--site|' + SITE])

failed_web = site_once.replace('    return 0',
                               '    if [ "$1" = --check-site ]; then MENU_WEB=failed; return 85; fi\n    return 0')
pty_case('failed web check remains blocked after viewing plan', failed_web,
         'menu_action --check-site', [PLAN], forbidden=[AUTO],
         calls=['CALL|--check-site', 'CALL|--plan'],
         colored=[(31, r'PHP сайта.*не подтверждён')])

failed_prepare = f'''
UPDATER_STATE="$ROOT/state"
mkdir -p "$UPDATER_STATE/sessions/{STALE}"
printf 'completed\\n' > "$UPDATER_STATE/sessions/{STALE}/state"
menu_invoke() {{
    printf 'CALL|%s\\n' "$1" >> "$EVENTS"
    MENU_SESSION='' MENU_STATE='' MENU_ORIGIN='' MENU_SITE=''
    return 51
}}
'''
pty_case('failed preparation never offers stale rollback', failed_prepare,
         'menu_action --auto-update', forbidden=[ROLLBACK], calls=['CALL|--auto-update'])

def saved_session(state, session=ORIGINAL):
    return f'''
UPDATER_STATE="$ROOT/state"
mkdir -p -m700 "$UPDATER_STATE/sessions/{session}"
chmod 700 "$UPDATER_STATE" "$UPDATER_STATE/sessions" "$UPDATER_STATE/sessions/{session}"
printf '%s\\n' {state} > "$UPDATER_STATE/sessions/{session}/state"
chmod 600 "$UPDATER_STATE/sessions/{session}/state"
'''


precheck = saved_session('precheck_failed') + child_stub.replace(
    "MENU_SESSION='' MENU_STATE=''", f'MENU_SESSION={ORIGINAL} MENU_STATE=precheck_failed')
precheck = precheck.replace('return 0', 'return 61')
pty_case('failed precheck with own session has no rollback', precheck,
         'menu_action --update', forbidden=[ROLLBACK], calls=['CALL|--update'], required=[ORIGINAL])

for state, result in [('completed', 0), ('installation_failed', 62), ('verify_failed', 64)]:
    transaction = saved_session(state) + child_stub.replace(
        "MENU_SESSION='' MENU_STATE=''", f'MENU_SESSION={ORIGINAL} MENU_STATE={state}')
    transaction = transaction.replace('return 0', f'return {result}')
    pty_case('own update rollback after ' + state, transaction,
             'menu_action --auto-update', [ROLLBACK],
             calls=['CALL|--auto-update', 'CALL|--rollback|--session|' + ORIGINAL], required=[ORIGINAL])

rollback = child_stub.replace("MENU_SESSION='' MENU_STATE='' MENU_ORIGIN=''",
                              f'MENU_SESSION={ATTEMPT} MENU_STATE=rollback_failed MENU_ORIGIN={ORIGINAL}')
rollback = rollback.replace('return 0', 'return 72')
pty_case('failed rollback retries original update ID', saved_session('verify_failed') + rollback,
         f'menu_action --rollback --session {ORIGINAL}', [ROLLBACK],
         calls=['CALL|--rollback|--session|' + ORIGINAL] * 2, required=[ORIGINAL])

for label, answer, rc in [('Enter', '', 0), ('back', '0', 0), ('EOF', 'EOF', 1),
                          ('invalid choice', 'invalid', 0)]:
    pty_case(label + ' never starts mutation', child_stub, 'menu_action --check', [answer],
             calls=['CALL|--check'], expected_rc=rc)

shell_case('metadata channel disabled for ordinary CLI', r'''
MENU_RESULT_ENABLED=0
menu_record session 20261108T100000Z-111 3> "$OUTPUT" || exit 1
[ ! -s "$OUTPUT" ]
''')
shell_case('metadata channel carries literal values without evaluation', r'''
MENU_RESULT_ENABLED=1
value='http|site.test|80|/site with spaces/$(touch /root/should-never-exist)'
menu_record site "$value" 3> "$OUTPUT"
[ "$(cat "$OUTPUT")" = "$(printf 'site\t%s' "$value")" ] && [ ! -e /root/should-never-exist ]
''')
shell_case('child metadata resets stale session before failed preparation', r'''
MENU_SESSION=20261107T080000Z-999 MENU_STATE=completed MENU_ORIGIN=20261107T080000Z-999 MENU_SITE=stale
bash() { return 51; }
menu_invoke --auto-update; rc=$?
[ "$rc" = 51 ] && [ -z "$MENU_SESSION$MENU_STATE$MENU_ORIGIN$MENU_SITE" ]
''')
shell_case('child metadata parsed literally and only from private channel', r'''
bash() {
    [ "$1" = "$SELF" ] && [ "$2" = --menu-action ] && [ "$3" = --check-site ] || return 99
    printf 'session\t20261108T100000Z-111\nstate\tcompleted\n' >&3
    printf 'site\thttp|site.test|80|/site with spaces/$(touch %s/injected)\n' "$ROOT" >&3
    printf 'unexpected\t$(touch %s/injected)\n' "$ROOT" >&3
    printf 'session\t20261107T080000Z-999\n'
    return 0
}
menu_invoke --check-site || exit 1
[ "$MENU_SESSION" = 20261108T100000Z-111 ] && [ "$MENU_STATE" = completed ] &&
[ "$MENU_SITE" = 'http|site.test|80|/site with spaces/$(touch '"$ROOT"'/injected)' ] && [ ! -e "$ROOT/injected" ]
''')
shell_case('result channel rejects injected multiline records', r'''
MENU_RESULT_ENABLED=1
menu_record site $'/site\nsession\t20261107T080000Z-999' 3> "$OUTPUT"
! grep -q '^session' "$OUTPUT"
''')
shell_case('new session and state publish their own metadata', r'''
MENU_RESULT_ENABLED=1
UPDATER_STATE="$ROOT/state" UPDATER_LOG="$ROOT/logs" WORK_ROOT="$ROOT/work"
exec 3> "$OUTPUT"
session_setup || exit 1
mark_state verify_failed || exit 1
exec 3>&-
grep -Fx "$(printf 'session\t%s' "$SESSION_NAME")" "$OUTPUT" &&
grep -Fx "$(printf 'state\tverify_failed')" "$OUTPUT"
''')
shell_case('status identifies original update behind last rollback attempt',
           saved_session('verify_failed') + saved_session('rollback_failed', ATTEMPT) + f'''
printf '%s\\n' {ORIGINAL} > "$UPDATER_STATE/sessions/{ATTEMPT}/rollback-of"
chmod 600 "$UPDATER_STATE/sessions/{ATTEMPT}/rollback-of"
touch -t 202611081000 "$UPDATER_STATE/sessions/{ORIGINAL}"
touch -t 202611081100 "$UPDATER_STATE/sessions/{ATTEMPT}"
MENU_RESULT_ENABLED=1
show_status 3> "$OUTPUT" || exit 1
grep -Fx "$(printf 'session\\t{ATTEMPT}')" "$OUTPUT" &&
grep -Fx "$(printf 'origin\\t{ORIGINAL}')" "$OUTPUT"
''')

# Public CLI must remain noninteractive even if stdin is a terminal or has input.
with tempfile.TemporaryDirectory() as directory:
    php = Path(directory) / 'php'
    php.write_text('#!/bin/sh\nprintf 8.4.1\n')
    php.chmod(0o755)
    result = subprocess.run(['/bin/bash', str(installer), '--check'], input='1\n',
                            capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
    report('ordinary CLI check has no follow-up prompt', result.returncode == 0 and
           'Выберите действие' not in result.stdout and 'Что дальше' not in result.stdout,
           result.stdout + result.stderr)

print(f'{total - failed}/{total} contextual action cases passed')
raise SystemExit(bool(failed))
