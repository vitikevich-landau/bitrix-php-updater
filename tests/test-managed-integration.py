"""Регрессионные проверки потока управления; внешние операции web/RPM изолированы подменами.

Запускать в Linux от root: python3 test-managed-integration.py /path/install.sh
"""
import hashlib
import os
import pty
from pathlib import Path
import re
import subprocess
import sys
import tempfile

text = Path(sys.argv[1]).read_text(encoding='utf-8')
prefix = text.split('# Мутирующие операции:', 1)[0]
fixture = b'integration fixture public key\n'
digest = hashlib.sha256(fixture).hexdigest()
stubs = r'''
require_root() { return 0; }
need() { return 0; }
profile_check() { PHP_CURRENT="${CURRENT:-8.2.20}"; }
php() { printf '%s' "${CURRENT:-8.2.20}"; }
select_managed_site() {
    printf 'SELECT:%s:%s\n' "$1" "$2" >> "$LOG"
    [ "$1" != ambiguous ] || return 65
    MANAGED_SITE="${1:-http|site.test|80|/var/www/site}"
    [ "$MANAGED_SITE" != other.test ] || MANAGED_SITE='http|other.test|80|/var/www/other'
}
validate_managed_site() { [[ "$1" == http\|*\|80\|/* ]]; }
managed_site_save() { validate_managed_site "$MANAGED_SITE" && printf '%s\n' "$MANAGED_SITE" > "$1" && chmod 0600 "$1"; }
managed_site_load() { MANAGED_SITE="$(cat "$1")" && validate_managed_site "$MANAGED_SITE"; }
managed_http_check() { printf 'PROBE:%s:%s\n' "$1" "$MANAGED_SITE" >> "$LOG"; [ "${FAIL_HEALTH:-0}" = 0 ]; }
safe_download() { cp "$FIXTURE" "$2"; }
session_setup() { SESSION_DIR="$TESTROOT/session"; mkdir -p "$SESSION_DIR"; }
mark_state() { printf '%s\n' "$1" > "$SESSION_DIR/state"; }
'''
cases = {
    'автоматическая конфигурация принимает необязательный дескриптор': r'''
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=auto\nSITE=http|site.test|80|/var/www/site\n' > "$CONFIG"
load_auto_config "$CONFIG" || exit 1
[ "$AUTO_HEALTH_URL" = auto ] && [ "$AUTO_SITE" = 'http|site.test|80|/var/www/site' ]
''',
    'автоматическая конфигурация без сайта откладывает его выбор': r'''
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=auto\n' > "$CONFIG"
load_auto_config "$CONFIG" && [ -z "$AUTO_SITE" ]
''',
    'старая конфигурация продолжает поддерживаться': r'''
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=https://site.test/health.php\n' > "$CONFIG"
load_auto_config "$CONFIG" && [ "$AUTO_HEALTH_URL" = https://site.test/health.php ]
''',
    'автоматическая HTTP-проверка использует управляемую пробу': r'''
MANAGED_SITE='http|site.test|80|/var/www/site'
health_target_validate auto && http_check auto 8.2.20 || exit 1
grep -Fx 'PROBE:8.2.20:http|site.test|80|/var/www/site' "$LOG"
''',
    'автоматическая проверка отклоняет отсутствие дескриптора': r'''
MANAGED_SITE=''
declare -F health_target_validate >/dev/null || exit 1
! health_target_validate auto
''',
    'проверка без изменений отклоняет URL auto': r'''
quick_check --url auto; result=$?
[ "$result" != 0 ] && [ ! -s "$LOG" ]
''',
    'отдельная проверка сайта выбирает и проверяет текущий PHP': r'''
check_site_dispatch --site other.test || exit 1
grep -Fx 'PROBE:8.2.20:http|other.test|80|/var/www/other' "$LOG"
''',
    'ручное обновление по умолчанию использует выбранный сайт автоматической проверки': r'''
run_update() { [ "$2" = auto ] && [ "$MANAGED_SITE" = 'http|other.test|80|/var/www/other' ] && [ "$5" = 1 ]; }
updater_dispatch --update --site other.test --unattended --backup-verified
''',
    'ручной явный URL сохраняет прежний режим': r'''
run_update() { [ "$2" = https://site.test/health.php ] && [ -z "$MANAGED_SITE" ]; }
MANAGED_SITE=stale
updater_dispatch --update --url https://site.test/health.php
''',
    'конфликт сайта и явного URL отклоняется': r'''
run_update() { echo UNEXPECTED >> "$LOG"; }
updater_dispatch --update --site other.test --url https://site.test/health.php; result=$?
[ "$result" = 2 ] && [ ! -s "$LOG" ]
''',
    'отсутствующая конфигурация по умолчанию создаётся без диалога': r'''
setup_auto_update() { printf 'SETUP'; printf ':%s' "$@"; printf '\n'; touch "$CONFIG"; }
run_auto_update() { [ -f "$1" ] && [ "$2" = 1 ] && [ -z "$3" ]; }
auto_update_dispatch --site other.test --unattended --backup-verified
''',
    'первая настройка передаёт обновлению точный сохранённый выбор': r'''
CURRENT=8.2.35
select_managed_site() {
    if grep -q '^SELECT:' "$LOG" && [ "$1" != 'http|other.test|80|/var/www/other' ]; then
        echo UNEXPECTED_REPEATED_PICKER >> "$LOG"; return 65
    fi
    printf 'SELECT:%s:%s\n' "$1" "$2" >> "$LOG"
    MANAGED_SITE='http|other.test|80|/var/www/other'
}
run_update() { [ "$MANAGED_SITE" = 'http|other.test|80|/var/www/other' ]; }
auto_update_dispatch --site ambiguous.test --unattended --backup-verified || exit 1
grep -Fx 'SELECT:http|other.test|80|/var/www/other:1' "$LOG" && ! grep -q UNEXPECTED "$LOG"
''',
    'явно указанная отсутствующая конфигурация не создаётся': r'''
setup_auto_update() { echo UNEXPECTED >> "$LOG"; }
run_auto_update() { load_auto_config "$1"; }
auto_update_dispatch --config "$TESTROOT/missing"; result=$?
[ "$result" != 0 ] && [ ! -s "$LOG" ]
''',
    'автоматический режим выбирает сохранённый сайт даже при актуальной версии': r'''
CURRENT=8.2.35
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=auto\nSITE=http|site.test|80|/var/www/site\n' > "$CONFIG"
run_update() { [ "$2" = auto ] && [ "$MANAGED_SITE" = 'http|site.test|80|/var/www/site' ]; }
run_auto_update "$CONFIG" 1
''',
    'явный выбор в автоматическом режиме задаёт другой сайт': r'''
CURRENT=8.2.35
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=auto\nSITE=http|site.test|80|/var/www/site\n' > "$CONFIG"
run_update() { [ "$2" = auto ] && [ "$MANAGED_SITE" = 'http|other.test|80|/var/www/other' ]; }
run_auto_update "$CONFIG" 1 other.test
''',
    'неоднозначный автоматический выбор предотвращает операции с RPM': r'''
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=auto\n' > "$CONFIG"
inventory_php_rpms() { echo UNEXPECTED >> "$LOG"; }
run_auto_update "$CONFIG" 1 ambiguous; result=$?
[ "$result" != 0 ] && grep -Fx 'SELECT:ambiguous:1' "$LOG" && ! grep -q UNEXPECTED "$LOG"
''',
    'настройка создаёт защищённую автоматическую конфигурацию без ввода': r'''
setup_auto_update --site other.test || exit 1
load_auto_config "$CONFIG" || exit 1
[ "$AUTO_HEALTH_URL" = auto ] && [ "$AUTO_SITE" = 'http|other.test|80|/var/www/other' ] && [ "$(stat -c %a "$CONFIG")" = 600 ]
''',
    'интерактивная настройка выбирает сайт заново': r'''
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=auto\nSITE=http|other.test|80|/var/www/other\n' > "$CONFIG"
setup_auto_update || exit 1
load_auto_config "$CONFIG" || exit 1
[ "$AUTO_SITE" = 'http|site.test|80|/var/www/site' ] && grep -Fx 'SELECT::0' "$LOG"
''',
    'неудачная проба при настройке сохраняет существующую конфигурацию': r'''
printf 'SOURCE=/root/release\nKEYRING=/root/key\nHEALTH_URL=https://site.test/health.php\n' > "$CONFIG"
cp "$CONFIG" "$TESTROOT/previous"
FAIL_HEALTH=1
setup_auto_update --site other.test; result=$?
[ "$result" != 0 ] && grep -q '^PROBE:' "$LOG" && cmp "$CONFIG" "$TESTROOT/previous"
''',
    'обновление уже актуальной версии сохраняет постоянный дескриптор': r'''
CURRENT=8.2.35
MANAGED_SITE='http|site.test|80|/var/www/site'
inventory_php_rpms() { printf 'php|0|8.2.35|1|x86_64\n'; }
verify_after() { [ -f "$1/site-probe" ] && [ "$(cat "$1/site-probe")" = "$MANAGED_SITE" ] && [ "$2" = auto ]; }
run_update '' auto '' '' 1 || exit 1
[ "$(cat "$SESSION_DIR/state")" = already_current ]
''',
}
rollback_common = r'''
UPDATER_STATE="$TESTROOT/state"
id=20261107T100000Z-123
source="$UPDATER_STATE/sessions/$id"
mkdir -p "$source/rpm-rollback"
chmod 0700 "$UPDATER_STATE" "$UPDATER_STATE/sessions" "$source" "$source/rpm-rollback"
for file in rpm-before.txt rpm-target.txt php-modules-before.txt configuration.tar.gz trusted-keyring.gpg; do echo fixture > "$source/$file"; done
echo completed > "$source/state"
echo 8.2.20 > "$source/php-version-before.txt"
echo auto > "$source/url"
echo 'http|site.test|80|/var/www/site' > "$source/site-probe"
chmod 0600 "$source/"*
chmod 0700 "$source/rpm-rollback"
platform_check() { :; }
php() { echo EARLY_PHP >> "$LOG"; return 1; }
rpm() {
    case "${@: -1}" in
        bitrix-env|bitrix-env-crm) printf 'package %s is not installed\n' "${@: -1}"; return 1 ;;
        *) echo UNEXPECTED_RPM >> "$LOG"; return 99 ;;
    esac
}
select_managed_site() { echo EARLY_DISCOVERY >> "$LOG"; return 1; }
rpm_core_snapshot() { echo fixture; }
plan_rpm_rollback() { echo keep; }
stage_rpm_bundle() { :; }
select_rpms() { SELECTED_RPMS=(/fixture.rpm); }
rollback_rpm_uncertain() { return 1; }
backup_configs() { :; }
check_external_rpm_obsoletes() { :; }
sync() { :; }
httpd() { [ -f "$source/rollback-rpm-state" ]; }
systemctl() { [ "$1" = restart ] && touch "$TESTROOT/restarted"; }
verify_after() { [ -f "$TESTROOT/restarted" ] && [ "$2" = "$EXPECTED_URL" ]; }
'''
cases['откат использует дескриптор при неисправном PHP до восстановления'] = rollback_common + r'''
EXPECTED_URL=auto
MANAGED_SITE=stale
run_rollback "$id" '' 1 || exit 1
[ "$MANAGED_SITE" = 'http|site.test|80|/var/www/site' ] && ! grep -q EARLY "$LOG"
'''
cases['восстановление по дескриптору не зависит от устаревшего файла URL'] = rollback_common + r'''
EXPECTED_URL=auto
rm "$source/url"
run_rollback "$id" '' 1
'''
cases['некорректный сохранённый дескриптор предотвращает транзакцию восстановления'] = rollback_common + r'''
EXPECTED_URL=auto
echo invalid > "$source/site-probe"
run_rollback "$id" '' 1; result=$?
[ "$result" = 71 ] && [ ! -e "$source/rollback-rpm-state" ]
'''
cases['явный URL отката заменяет сохранённый дескриптор'] = rollback_common + r'''
EXPECTED_URL=https://override.test/health.php
echo corrupt > "$source/site-probe"
run_rollback "$id" "$EXPECTED_URL" 1
'''
cases['откат в прежнем режиме требует только исходный URL'] = rollback_common + r'''
EXPECTED_URL=https://legacy.test/health.php
rm "$source/site-probe"
echo "$EXPECTED_URL" > "$source/url"
run_rollback "$id" '' 1
'''
failed = 0
for name, body in cases.items():
    with tempfile.TemporaryDirectory(dir='/root') as directory:
        root = Path(directory)
        config = root/'config'
        log = root/'events'
        log.touch()
        key = root/'fixture-key'
        key.write_bytes(fixture)
        script = prefix.replace("config='/etc/bitrix-php-update.conf'", f"config='{config}'").replace("keydir='/etc/bitrix-php-update'", f"keydir='{root}/keys'")
        script = re.sub(r"expected_key='[0-9a-f]{64}'", f"expected_key='{digest}'", script)
        path = root/'run.sh'
        path.write_text(script+'\n'+stubs+'\n'+body, encoding='utf-8')
        master = slave = None
        if name.startswith('интерактивная настройка'):
            master, slave = pty.openpty()
        result = subprocess.run(['/bin/bash', str(path)], stdin=slave if slave is not None else subprocess.DEVNULL, capture_output=True, text=True,
                                env=dict(os.environ, TESTROOT=directory, CONFIG=str(config), LOG=str(log), FIXTURE=str(key)))
        if master is not None:
            os.close(slave)
            os.close(master)
        if result.returncode:
            failed += 1
            print('FAIL', name, result.returncode, result.stdout[-1500:], result.stderr[-1500:], sep='\n')
        else:
            print('PASS', name)
print(f'{len(cases)-failed}/{len(cases)} интеграционных проверок пройдено')
raise SystemExit(bool(failed))
