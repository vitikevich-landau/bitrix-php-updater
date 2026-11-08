#!/bin/bash
set -eo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/fixture-common.sh" "$@"
for fixture in /root/managed-probe-test /var/www/rc9-probe-site /var/www/rc9-probe-site-renamed-by-test /etc/httpd/conf.d/zz-rc9-probe.conf; do
    if [ -e "$fixture" ] || [ -L "$fixture" ]; then echo "Отказ от перезаписи существующего пути тестовых данных: $fixture" >&2; exit 2; fi
done
UPDATER_STATE=/root/managed-probe-test/state
mkdir -p /root/managed-probe-test
chmod 0700 /root/managed-probe-test
MANAGED_SITE='http|probe.example|80|/var/www/rc9-probe-site'
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
expect_failure() { if "$@"; then fail "неожиданно получен успешный результат: $*"; fi; }
validate_managed_site "$MANAGED_SITE" || fail 'отклонено корректное описание сайта'
for descriptor in 'http|probe.example|0|/var/www/rc9-probe-site' 'ftp|probe.example|80|/var/www/rc9-probe-site' 'http|bad;host|80|/var/www/rc9-probe-site' 'http|probe.example|80|/var/www/../html' 'http|probe.example|80|/' 'http|probe.example|80|/var/www/rc9-probe-site|' $'http|probe.example|80|/var/www/\nhtml'; do
    expect_failure validate_managed_site "$descriptor"
done
pass 'проверка описания сайта'
mkdir -m 0700 /root/managed-probe-test/descriptors
managed_site_save /root/managed-probe-test/descriptors/site
MANAGED_SITE=''
managed_site_load /root/managed-probe-test/descriptors/site
[ "$MANAGED_SITE" = 'http|probe.example|80|/var/www/rc9-probe-site' ] || fail 'описание сайта изменилось после сохранения и загрузки'
chmod 0666 /root/managed-probe-test/descriptors/site
expect_failure managed_site_load /root/managed-probe-test/descriptors/site
chmod 0600 /root/managed-probe-test/descriptors/site
pass 'защищённое сохранение описания сайта'
mkdir -p /var/www/rc9-probe-site
chmod 0755 /var/www/rc9-probe-site
cat > /etc/httpd/conf.d/zz-rc9-probe.conf <<'APACHE'
<VirtualHost *:80>
    ServerName probe.example
    DocumentRoot /var/www/rc9-probe-site
    <Directory /var/www/rc9-probe-site>
        Require all granted
    </Directory>
</VirtualHost>
APACHE
httpd -t
httpd -k start
sleep .2
expected="$(php -r 'echo PHP_VERSION;')"
managed_http_check "$expected" || fail 'ошибка проверки настоящего Apache'
if find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'после успеха осталась публичная проба'; fi
pass 'настоящий Apache: защита токеном и очистка после успеха'
expect_failure managed_http_check 8.2.99
if find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'после несовпадения версий осталась публичная проба'; fi
pass 'очистка при ошибке версии'
source "$TEST_SUITE_DIR/test-curl-wrapper.sh"
TEST_CONTROL=/root/managed-probe-test/control
mkdir -m 0700 "$TEST_CONTROL"
export token='inherited fixture token'
managed_http_check "$expected" || fail 'ошибка проверки защиты при передаче запроса'
[ -e "$TEST_CONTROL/auth-inspected" ] || fail 'запрос с авторизацией не выполнен'
[ ! -e "$TEST_CONTROL/secret-leaked" ] && [ ! -e "$TEST_CONTROL/secret-in-env" ] && [ ! -e "$TEST_CONTROL/wrong-token-accepted" ] && [ ! -e "$TEST_CONTROL/xff-accepted" ] || fail 'ошибка проверки секрета или авторизации'
[ "$token" = 'inherited fixture token' ] || fail 'изменено значение в окружении вызывающего процесса'
pass 'неверный токен и поддельный XFF отклонены; секрет отсутствует в PHP, аргументах curl и унаследованном окружении'
assert_no_probe() {
    # Родительский процесс может завершиться раньше, чем получивший сигнал дочерний процесс закончит очистку EXIT.
    for attempt in {1..100}; do
        if ! find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep -q . &&
           ! find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 | grep -q .; then break; fi
        sleep .05
    done
    if find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'осталась публичная проба'; fi
    if find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 | grep .; then fail 'осталась закрытая запись о пробе'; fi
}
for TEST_MODE in timeout static cache redirect wrong_body; do
    printf '0\n' > "$TEST_CONTROL/count"
    expect_failure managed_http_check "$expected" > "$TEST_CONTROL/$TEST_MODE.log" 2>&1
    case "$TEST_MODE" in
        timeout) grep -q 'Не удалось выполнить временную' "$TEST_CONTROL/$TEST_MODE.log" || fail 'неверная причина отказа при истечении времени ожидания' ;;
        static|cache) grep -q 'не закрыта' "$TEST_CONTROL/$TEST_MODE.log" || fail 'неверная причина отказа при ошибке доступа' ;;
        *) grep -q 'не подтвердила версию' "$TEST_CONTROL/$TEST_MODE.log" || fail 'неверная причина отказа при ошибке ответа' ;;
    esac
    assert_no_probe
    pass "$TEST_MODE: отказ и очистка"
done
TEST_MODE=normal
date() {
    if [ "${1:-}" = +%s ]; then printf '%s\n' "$(( $(command date +%s) - 200 ))"; else command date "$@"; fi
}
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/expired.log" 2>&1
grep -q 'не подтвердила версию' "$TEST_CONTROL/expired.log" || fail 'неверная причина отказа по истечении срока действия'
unset -f date
assert_no_probe
pass 'доступ после истечения срока действия запрещён'
TEST_MODE=parent_rename
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/parent-rename.log" 2>&1
[ "$(cat /var/www/rc9-probe-site/replacement)" = 'replacement site' ] || fail 'подменный сайт изменён'
if find /var/www/rc9-probe-site-renamed-by-test -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'очистка через закреплённый родительский каталог оставила пробу'; fi
rm /var/www/rc9-probe-site/replacement
rmdir /var/www/rc9-probe-site
mv /var/www/rc9-probe-site-renamed-by-test /var/www/rc9-probe-site
assert_no_probe
pass 'очистка через закреплённый переименованный родительский каталог не затрагивает подменный сайт'
TEST_MODE=cleanup_failure
printf '0\n' > "$TEST_CONTROL/count"
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/cleanup-failure.log" 2>&1
grep -q 'Не удалось безопасно удалить' "$TEST_CONTROL/cleanup-failure.log" || fail 'ошибка очистки не отражена в сообщении'
lease="$(find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 -type d | head -1)"
probe_name="$(cat "$lease/name")"
[ -f "/var/www/rc9-probe-site/$probe_name/probe.php" ] || fail 'изменённая проба удалена при ошибке очистки'
cp "$lease/payload.php" "/var/www/rc9-probe-site/$probe_name/probe.php"
managed_probe_cleanup_stale || fail 'не удалось удалить изменённую пробу после восстановления её содержимого'
assert_no_probe
pass 'ошибка очистки меняет успешный результат HTTP-проверки на отказ'
TEST_MODE=normal
start_blocked_probe() {
    rm -f "$TEST_CONTROL/blocking"
    setsid bash "$TEST_SUITE_DIR/signal-driver.sh" "$TEST_CONTROL" "$INSTALLER" "$expected" > "$TEST_CONTROL/driver.log" 2>&1 &
    driver_pid=$!
    for attempt in {1..200}; do [ ! -e "$TEST_CONTROL/blocking" ] || break; sleep .05; done
    [ -e "$TEST_CONTROL/blocking" ] || fail 'проба не дошла до блокирующего вызова транспорта'
}
for signal in TERM HUP; do
    start_blocked_probe
    managed_probe_cleanup_stale || fail 'очистка должна пропускать запись о работающей пробе'
    [ "$(find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | wc -l)" -eq 1 ] || fail 'работающая проба удалена'
    kill -"$signal" -- "-$driver_pid"
    wait "$driver_pid" && fail 'сигнал не завершил управляющий процесс с ошибкой'
    assert_no_probe
    pass "$signal: очистка и сохранение записи о работающей пробе"
done
python "$TEST_SUITE_DIR/test-int.py" "$TEST_SUITE_DIR" "$INSTALLER" "$expected"
start_blocked_probe
kill -KILL -- "-$driver_pid"
wait "$driver_pid" && fail 'SIGKILL не остановил управляющий процесс'
managed_probe_cleanup_stale || fail 'ошибка очистки оставшихся файлов после SIGKILL'
assert_no_probe
pass 'очистка записи о пробе после SIGKILL при следующем запуске'
start_blocked_probe
kill -KILL -- "-$driver_pid"
wait "$driver_pid" && fail 'SIGKILL не остановил управляющий процесс'
lease="$(find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 -type d | head -1)"
probe_name="$(cat "$lease/name")"
printf '\n// изменено другим администратором\n' >> "/var/www/rc9-probe-site/$probe_name/probe.php"
expect_failure managed_probe_cleanup_stale > "$TEST_CONTROL/changed.log" 2>&1
grep -q 'изменена или недоступна' "$TEST_CONTROL/changed.log" || fail 'неверная причина отказа при изменённом файле'
[ -f "/var/www/rc9-probe-site/$probe_name/probe.php" ] || fail 'изменённый файл удалён'
cp "$lease/payload.php" "/var/www/rc9-probe-site/$probe_name/probe.php"
managed_probe_cleanup_stale || fail 'ошибка очистки после восстановления ожидаемого файла'
assert_no_probe
pass 'изменённый файл сохранён'
start_blocked_probe
kill -KILL -- "-$driver_pid"
wait "$driver_pid" && fail 'SIGKILL не остановил управляющий процесс'
lease="$(find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 -type d | head -1)"
probe_name="$(cat "$lease/name")"
printf 'unrelated private file\n' > "$TEST_CONTROL/important"
rm -- "/var/www/rc9-probe-site/$probe_name/probe.php"
ln -s "$TEST_CONTROL/important" "/var/www/rc9-probe-site/$probe_name/probe.php"
expect_failure managed_probe_cleanup_stale > "$TEST_CONTROL/symlink.log" 2>&1
[ "$(cat "$TEST_CONTROL/important")" = 'unrelated private file' ] || fail 'посторонний файл изменён'
[ -L "/var/www/rc9-probe-site/$probe_name/probe.php" ] || fail 'подменная символическая ссылка удалена'
rm -- "/var/www/rc9-probe-site/$probe_name/probe.php"
rmdir -- "/var/www/rc9-probe-site/$probe_name"
managed_probe_cleanup_stale || fail 'ошибка очистки при отсутствующем публичном файле'
assert_no_probe
pass 'подменная символическая ссылка сохранена, посторонний файл не изменён'
ln -s /var/www/rc9-probe-site /root/managed-probe-test/site-link
MANAGED_SITE='http|probe.example|80|/root/managed-probe-test/site-link'
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/root-symlink.log" 2>&1
grep -q 'Каталог выбранного сайта изменился' "$TEST_CONTROL/root-symlink.log" || fail 'неверная причина отказа при символической ссылке на каталог сайта'
assert_no_probe
pass 'неканонический путь к корневому каталогу сайта отклонён'
MANAGED_SITE='http|probe.example|80|/var/www/rc9-probe-site'
mkdir() {
    local final
    for final in "$@"; do :; done
    if [[ "${final##*/}" == bitrix-master-probe-* ]]; then
        command mkdir -m 0700 -- "$final"
        printf '%s\n' "${final##*/}" > "$TEST_CONTROL/collision"
        return 1
    fi
    command mkdir "$@"
}
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/collision.log" 2>&1
unset -f mkdir
collision="$(cat "$TEST_CONTROL/collision")"
[ -d "/var/www/rc9-probe-site/$collision" ] || fail 'каталог с совпавшим именем и неподтверждённой принадлежностью удалён'
rmdir -- "/var/www/rc9-probe-site/$collision"
managed_probe_cleanup_stale || fail 'ошибка очистки после удаления владельцем каталога с совпавшим именем'
assert_no_probe
pass 'каталог с совпавшим именем и неподтверждённой принадлежностью сохранён'
selinuxenabled() { return 0; }
chcon() { return 1; }
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/selinux.log" 2>&1
unset -f selinuxenabled chcon
grep -q 'SELinux-контекст' "$TEST_CONTROL/selinux.log" || fail 'неверная причина отказа при ошибке SELinux'
assert_no_probe
pass 'очистка при ошибке подготовки SELinux'
printf 'ВСЕ ПРОВЕРКИ ВРЕМЕННОЙ ПРОБЫ ПРОЙДЕНЫ\n'
