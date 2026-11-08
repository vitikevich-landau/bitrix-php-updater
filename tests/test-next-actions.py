"""Регрессионные проверки контекстного меню с настоящими проверками готовности и навигацией Bash.

Запускать в одноразовых Linux-контейнерах. PHP/RPM/Apache и дочерние операции CLI
подменяются на границах; обновления, изменения служб и сеть запрещены.
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
assert prefix != source, 'Не найдена граница CLI установщика'
# Перенаправляется только эта граница файловой системы; настоящая проверка профиля сохраняется.
prefix = prefix.replace('[ -d /etc/httpd/bx ]', '[ -d "$ROOT/httpd/bx" ]')

boundaries = r'''
CURRENT=${CURRENT:-8.2.20}
platform_check() { if [ "${BAD_PLATFORM:-0}" = 1 ]; then err 'тестовая неподдерживаемая платформа'; return 20; fi; }
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
               f'код={result.returncode}\n{result.stdout}\n{result.stderr}')


# Выявляет доверие успешной диагностике или проверку только RPM PHP/CLI.
for name, settings, wanted, target in [
    ('поддерживаемый PHP 8.2 готов', 'CURRENT=8.2.20', 'ready', '8.2.35'),
    ('поддерживаемый PHP 8.3 остаётся в своей ветке', 'CURRENT=8.3.8', 'ready', '8.3.36'),
    ('старый PHP требует плана миграции', 'CURRENT=7.4.33', 'legacy', ''),
    ('актуальный PHP не предлагает обновление', 'CURRENT=8.2.35', 'current', '8.2.35'),
    ('более новый PHP не понижается', 'CURRENT=8.3.37', 'newer', '8.3.36'),
    ('неподдерживаемый PHP остаётся заблокированным', 'CURRENT=8.4.1', 'unsupported', ''),
    ('неизвестная версия остаётся заблокированной', 'CURRENT=8.3.36RC1', 'unknown', ''),
    ('отсутствие PHP остаётся причиной блокировки', 'PHP_FAIL=1', 'unknown', ''),
    ('неподдерживаемая платформа остаётся заблокированной', 'BAD_PLATFORM=1', 'blocked', '8.2.35'),
    ('профиль FPM остаётся заблокированным', 'BAD_APACHE=1', 'blocked', '8.2.35'),
    ('BitrixEnv 9 остаётся заблокированным', 'ENV_VERSION=9.0', 'blocked', '8.2.35'),
    ('несовпадающий php-common остаётся причиной блокировки', 'RPM_COMMON=8.2.19', 'blocked', '8.2.35'),
    ('недоступная база RPM остаётся причиной блокировки', 'RPM_FAIL=1', 'blocked', '8.2.35'),
    ('проверка без root не может запустить подготовку', 'id() { if [ "$1" = -u ]; then echo 1000; else command id "$@"; fi; }', 'needs_root', '8.2.35'),
]:
    body = settings + '\nmenu_update_readiness\n'
    body += f'[ "${{NEXT_STATUS:-}}" = {wanted} ] || {{ echo "неожиданная готовность: ${{NEXT_STATUS:-missing}}"; exit 1; }}\n'
    body += '[ -n "${NEXT_REASON:-}" ] || { echo "отсутствует пояснение"; exit 1; }\n'
    if target:
        body += f'[ "$NEXT_TARGET" = {target} ] || {{ echo "неверная цель: $NEXT_TARGET"; exit 1; }}\n'
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
    """Отвечать на настоящие запросы; выбирать отображённые подписи, а не фиксированные позиции."""
    with tempfile.TemporaryDirectory() as directory:
        env = environment(directory)
        env.pop('NO_COLOR', None)
        env.update(env_updates or {})
        script = Path(directory) / 'case.sh'
        if full_script:
            # Сохраняем точку входа CLI, дочерний процесс и передачу метаданных. Вставляем
            # подмены внешних операций после определений функций в каждом процессе.
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
                    # Все контекстные запросы включают безопасный вариант по умолчанию [0].
                    if re.search(r'\[0\][^\r\n]*[:>] ?$', pending):
                        choice = queue.pop(0) if queue else '0'
                        if choice in ('0', '', 'invalid', 'EOF'):
                            answer = {'invalid': '999', 'EOF': '\x04'}.get(choice, choice)
                        else:
                            matches = [(n, label) for n, label in re.findall(r'^\s*(\d+)[.)]\s*(.+)$', pending, re.M)
                                       if re.search(choice, label, re.I)]
                            if len(matches) != 1:
                                absent.append(f'ожидался один пункт /{choice}/, найдено {matches}')
                                answer = '0'
                            else:
                                answer, label = matches[0]
                                picked.append(label)
                        os.write(master, answer.encode() + (b'' if answer == '\x04' else b'\n'))
                        if full_script and answer == '0':
                            # Возвращаемся из подменю проверок, затем выходим из главного меню.
                            os.write(master, b'0\n0\n')
                        pending = ''
                elif child.poll() is not None:
                    break
            # Закрытие последнего дескриптора PTY может вернуть EIO непосредственно перед тем,
            # как ядро отметит завершение дочернего процесса. Даём ему завершиться штатно.
            try:
                rc = child.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                child.kill()
                absent.append('истекло время ожидания запроса')
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
        # Сам значимый текст должен находиться внутри ANSI-диапазона:
        # посторонний цветной заголовок не должен удовлетворять проверке цвета состояния.
        for color, pattern in colored:
            spans = re.findall(rf'\x1b\[{color}m([^\x1b\r\n]*)\x1b\[0m', output)
            if not any(re.search(pattern, text, re.I) for text in spans):
                absent.append(f'отсутствует цвет {color} вокруг /{pattern}/')
                valid = False
        if plain_output and '\x1b' in output:
            absent.append('Выведены ANSI-последовательности при отключённом цвете')
            valid = False
        if calls is not None:
            valid = valid and events.splitlines() == calls
        report(name, valid, f'код={rc}; ошибки={absent}; выбрано={picked}; вызовы={events}\n{output}')


child_stub = r'''
menu_invoke() {
    printf 'CALL' >> "$EVENTS"; printf '|%s' "$@" >> "$EVENTS"; printf '\n' >> "$EVENTS"
    MENU_SESSION='' MENU_STATE='' MENU_ORIGIN='' MENU_SITE='' MENU_WEB=''
    return 0
}
'''

# Проверяется настоящий вывод в терминале. Отсутствие цвета по смыслу,
# неверная важность или окраска только заголовка должны приводить к провалу проверок.
pty_case('пояснение об актуальном PHP отображается зелёным', 'CURRENT=8.2.35\n' + child_stub,
         'menu_action --check', forbidden=[AUTO],
         colored=[(32, r'уже установлена|не требуется')])
pty_case('доступная подготовка отображается жёлтым, пока обновление ожидается', child_stub,
         'menu_action --check', colored=[(33, r'подготовк.*обновления')])
for action, pattern in [('--check-site', r'Проверка.*сайта.*пройдена'),
                        ('--setup-update', r'Настройки.*сохранены')]:
    pty_case(action + ': успешный результат отображается зелёным', child_stub,
             'menu_action ' + action, colored=[(32, pattern)])

for setting, pattern in [('BAD_APACHE=1', r'mod_php'),
                         ('RPM_COMMON=8.2.19', r'Пакеты PHP.*не согласованы')]:
    pty_case(setting + ': причина блокировки отображается красным', setting + '\n' + child_stub,
             'menu_action --check', forbidden=[AUTO], colored=[(31, pattern)])

for setting in ['PHP_FAIL=1', 'CURRENT=8.3.36RC1']:
    pty_case(setting + ': пояснение о неизвестном PHP отображается жёлтым', setting + '\n' + child_stub,
             'menu_action --check', forbidden=[AUTO],
             colored=[(33, r'Версия PHP не определена')])

for action, pattern in [('--check-site', r'Проверка сайта отменена'),
                        ('--setup-update', r'Настройка отменена'),
                        ('--update', r'Операция отменена')]:
    pty_case(action + ': отмена отображается жёлтым', child_stub.replace('return 0', 'return 12'),
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
    pty_case(state + ': сводка операции использует цвет по смыслу',
             state_stub.replace('return 0', f'return {rc}'),
             'menu_action --update', colored=[(color, pattern)])

pty_case('префиксы ошибки и предупреждения отображаются красным и жёлтым', child_stub,
         "err color-error; warn color-warning; menu_action --check",
         colored=[(31, 'ОШИБКА: color-error'), (33, 'ВНИМАНИЕ: color-warning')])
pty_case('неудачная операция без метаданных отображается красным',
         child_stub.replace('return 0', 'return 51'), 'menu_action --update',
         colored=[(31, r'Операция остановлена')])

for settings in [{'NO_COLOR': '1'}, {'TERM': 'dumb'}]:
    pty_case(str(settings) + ' отключает цвет в терминале', 'CURRENT=8.2.35\n' + child_stub,
             'err color-error; warn color-warning; menu_action --check',
             env_updates=settings, plain_output=True,
             required=['ОШИБКА: color-error', 'ВНИМАНИЕ: color-warning'])

shell_case('перехваченные сообщения сохраняют потоки и префиксы без ANSI', r'''
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

# Выявляет нарушения связи между настоящим ручным меню, внутренним каналом результата CLI,
# выбором сайта и следующим дочерним процессом. Подменяются только внешние
# поиск и проверка сайта, а также конечный вызов обновления.
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
pty_case('полное меню передаёт выбранный сайт через настоящий канал результата дочернего процесса',
         end_to_end, '', [AUTO], full_script=True, initial_input='1\n5\n2\n',
         calls=['PROBE|8.2.20|' + SITE, 'AUTO|--site|' + SITE],
         required=['Выберите сайт для временной проверки PHP', 'FIXTURE_AUTO_STOP',
                   'Операция остановлена'])

# Работа дочернего процесса подменяется во избежание изменений системы; настоящий выбор определяет
# следующую команду, аргументы и безопасный вариант. Неверный маршрут меняет записанные вызовы.
pty_case('успешная быстрая проверка позволяет перейти к автоматическому обновлению', child_stub,
         'menu_action --check', [AUTO], calls=['CALL|--check', 'CALL|--auto-update'])
pty_case('нулевой код диагностики не разрешает заблокированный профиль', 'BAD_APACHE=1\n' + child_stub,
         'menu_action --check', forbidden=[AUTO], calls=['CALL|--check'], required=['mod_php'])
pty_case('старый PHP позволяет перейти к плану миграции', 'CURRENT=7.4.33\n' + child_stub,
         'menu_action --check', [PLAN], forbidden=[AUTO], calls=['CALL|--check', 'CALL|--plan'])
pty_case('для актуального PHP нет перехода к автоматическому обновлению', 'CURRENT=8.2.35\n' + child_stub,
         'menu_action --check', forbidden=[AUTO], calls=['CALL|--check'])
for action in ['--plan', '--audit --offline', '--setup-update']:
    pty_case(action + ' предлагает явный переход к подготовке', child_stub,
             'menu_action ' + action, [AUTO],
             calls=['CALL|' + action.replace(' ', '|'), 'CALL|--auto-update'])

comparison_stub = child_stub + r'''
bash() {
    [ "$1" = "$SELF" ] || return 99
    shift
    printf 'CALL' >> "$EVENTS"; printf '|%s' "$@" >> "$EVENTS"; printf '\n' >> "$EVENTS"
}
'''
pty_case('после аудита выбор отчётов возвращает к дальнейшим действиям', comparison_stub,
         'menu_action --audit --offline', ['Сравнить.*отчёты'],
         calls=['CALL|--audit|--offline', 'CALL|--compare-menu'])

for action, summary in [('--check-site', 'Проверка сайта отменена'),
                        ('--setup-update', 'Настройка отменена')]:
    cancelled = child_stub.replace('return 0', 'return 12')
    pty_case(action + ': отмена объясняется до выбора дальнейших действий', cancelled,
             'menu_action ' + action, calls=['CALL|' + action], required=[summary])

site_stub = child_stub.replace("MENU_SITE=''", 'MENU_SITE=' + shlex.quote(SITE))
pty_case('продолжение после проверки сайта сохраняет точный дескриптор', site_stub,
         'menu_action --check-site', [AUTO],
         calls=['CALL|--check-site', 'CALL|--auto-update|--site|' + SITE])

site_once = child_stub.replace('    return 0',
                               '    [ "$1" != --check-site ] || MENU_SITE=' + shlex.quote(SITE) + '\n    return 0')
pty_case('просмотр плана сохраняет выбранный сайт для обновления', site_once,
         'menu_action --check-site', [PLAN, AUTO],
         calls=['CALL|--check-site', 'CALL|--plan', 'CALL|--auto-update|--site|' + SITE])

failed_web = site_once.replace('    return 0',
                               '    if [ "$1" = --check-site ]; then MENU_WEB=failed; return 85; fi\n    return 0')
pty_case('неудачная проверка сайта остаётся заблокированной после просмотра плана', failed_web,
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
pty_case('неудачная подготовка не предлагает откат устаревшего сеанса', failed_prepare,
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
pty_case('неудачная предварительная проверка со своим сеансом не предлагает откат', precheck,
         'menu_action --update', forbidden=[ROLLBACK], calls=['CALL|--update'], required=[ORIGINAL])

for state, result in [('completed', 0), ('installation_failed', 62), ('verify_failed', 64)]:
    transaction = saved_session(state) + child_stub.replace(
        "MENU_SESSION='' MENU_STATE=''", f'MENU_SESSION={ORIGINAL} MENU_STATE={state}')
    transaction = transaction.replace('return 0', f'return {result}')
    pty_case('откат собственного обновления после ' + state, transaction,
             'menu_action --auto-update', [ROLLBACK],
             calls=['CALL|--auto-update', 'CALL|--rollback|--session|' + ORIGINAL], required=[ORIGINAL])

rollback = child_stub.replace("MENU_SESSION='' MENU_STATE='' MENU_ORIGIN=''",
                              f'MENU_SESSION={ATTEMPT} MENU_STATE=rollback_failed MENU_ORIGIN={ORIGINAL}')
rollback = rollback.replace('return 0', 'return 72')
pty_case('повтор неудачного отката использует исходный идентификатор обновления', saved_session('verify_failed') + rollback,
         f'menu_action --rollback --session {ORIGINAL}', [ROLLBACK],
         calls=['CALL|--rollback|--session|' + ORIGINAL] * 2, required=[ORIGINAL])

for label, answer, rc in [('Enter', '', 0), ('возврат', '0', 0), ('EOF', 'EOF', 1),
                          ('неверный выбор', 'invalid', 0)]:
    pty_case(label + ' никогда не запускает изменения', child_stub, 'menu_action --check', [answer],
             calls=['CALL|--check'], expected_rc=rc)

shell_case('канал метаданных отключён для обычного CLI', r'''
MENU_RESULT_ENABLED=0
menu_record session 20261108T100000Z-111 3> "$OUTPUT" || exit 1
[ ! -s "$OUTPUT" ]
''')
shell_case('канал метаданных передаёт буквальные значения без вычисления', r'''
MENU_RESULT_ENABLED=1
value='http|site.test|80|/site with spaces/$(touch /root/should-never-exist)'
menu_record site "$value" 3> "$OUTPUT"
[ "$(cat "$OUTPUT")" = "$(printf 'site\t%s' "$value")" ] && [ ! -e /root/should-never-exist ]
''')
shell_case('метаданные дочернего процесса сбрасывают устаревший сеанс до неудачной подготовки', r'''
MENU_SESSION=20261107T080000Z-999 MENU_STATE=completed MENU_ORIGIN=20261107T080000Z-999 MENU_SITE=stale
bash() { return 51; }
menu_invoke --auto-update; rc=$?
[ "$rc" = 51 ] && [ -z "$MENU_SESSION$MENU_STATE$MENU_ORIGIN$MENU_SITE" ]
''')
shell_case('метаданные дочернего процесса разбираются буквально и только из закрытого канала', r'''
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
shell_case('канал результата отклоняет внедрённые многострочные записи', r'''
MENU_RESULT_ENABLED=1
menu_record site $'/site\nsession\t20261107T080000Z-999' 3> "$OUTPUT"
! grep -q '^session' "$OUTPUT"
''')
shell_case('новый сеанс и состояние публикуют собственные метаданные', r'''
MENU_RESULT_ENABLED=1
UPDATER_STATE="$ROOT/state" UPDATER_LOG="$ROOT/logs" WORK_ROOT="$ROOT/work"
exec 3> "$OUTPUT"
session_setup || exit 1
mark_state verify_failed || exit 1
exec 3>&-
grep -Fx "$(printf 'session\t%s' "$SESSION_NAME")" "$OUTPUT" &&
grep -Fx "$(printf 'state\tverify_failed')" "$OUTPUT"
''')
shell_case('состояние определяет исходное обновление для последней попытки отката',
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

# Публичный CLI не должен запрашивать ввод, даже если stdin — терминал или содержит данные.
with tempfile.TemporaryDirectory() as directory:
    php = Path(directory) / 'php'
    php.write_text('#!/bin/sh\nprintf 8.4.1\n')
    php.chmod(0o755)
    result = subprocess.run(['/bin/bash', str(installer), '--check'], input='1\n',
                            capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
    report('обычная проверка CLI не запрашивает дальнейшие действия', result.returncode == 0 and
           'Выберите действие' not in result.stdout and 'Что дальше' not in result.stdout,
           result.stdout + result.stderr)

print(f'{total - failed}/{total} проверок контекстных действий пройдено')
raise SystemExit(bool(failed))
