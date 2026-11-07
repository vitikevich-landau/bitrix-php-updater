#!/bin/bash
set -eo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/fixture-common.sh" "$@"
for fixture in /root/managed-probe-test /var/www/rc9-probe-site /var/www/rc9-probe-site-renamed-by-test /etc/httpd/conf.d/zz-rc9-probe.conf; do
    if [ -e "$fixture" ] || [ -L "$fixture" ]; then echo "Refusing to overwrite an existing fixture path: $fixture" >&2; exit 2; fi
done
UPDATER_STATE=/root/managed-probe-test/state
mkdir -p /root/managed-probe-test
chmod 0700 /root/managed-probe-test
MANAGED_SITE='http|probe.example|80|/var/www/rc9-probe-site'
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
expect_failure() { if "$@"; then fail "unexpected success: $*"; fi; }
validate_managed_site "$MANAGED_SITE" || fail 'valid descriptor'
for descriptor in 'http|probe.example|0|/var/www/rc9-probe-site' 'ftp|probe.example|80|/var/www/rc9-probe-site' 'http|bad;host|80|/var/www/rc9-probe-site' 'http|probe.example|80|/var/www/../html' 'http|probe.example|80|/' 'http|probe.example|80|/var/www/rc9-probe-site|' $'http|probe.example|80|/var/www/\nhtml'; do
    expect_failure validate_managed_site "$descriptor"
done
pass 'descriptor validation'
mkdir -m 0700 /root/managed-probe-test/descriptors
managed_site_save /root/managed-probe-test/descriptors/site
MANAGED_SITE=''
managed_site_load /root/managed-probe-test/descriptors/site
[ "$MANAGED_SITE" = 'http|probe.example|80|/var/www/rc9-probe-site' ] || fail 'descriptor round trip'
chmod 0666 /root/managed-probe-test/descriptors/site
expect_failure managed_site_load /root/managed-probe-test/descriptors/site
chmod 0600 /root/managed-probe-test/descriptors/site
pass 'protected descriptor persistence'
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
managed_http_check "$expected" || fail 'real Apache check'
if find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'left public probe after success'; fi
pass 'real Apache token guard and success cleanup'
expect_failure managed_http_check 8.2.99
if find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'left public probe after mismatch'; fi
pass 'version failure cleanup'
source "$TEST_SUITE_DIR/test-curl-wrapper.sh"
TEST_CONTROL=/root/managed-probe-test/control
mkdir -m 0700 "$TEST_CONTROL"
export token='inherited fixture token'
managed_http_check "$expected" || fail 'guard transport inspection'
[ -e "$TEST_CONTROL/auth-inspected" ] || fail 'auth request never reached'
[ ! -e "$TEST_CONTROL/secret-leaked" ] && [ ! -e "$TEST_CONTROL/secret-in-env" ] && [ ! -e "$TEST_CONTROL/wrong-token-accepted" ] && [ ! -e "$TEST_CONTROL/xff-accepted" ] || fail 'secret or auth check'
[ "$token" = 'inherited fixture token' ] || fail 'caller environment value changed'
pass 'wrong token and forged XFF denied; no secret in PHP, curl argv or inherited environment'
assert_no_probe() {
    # The driver parent can exit before its signalled child finishes EXIT cleanup.
    for attempt in {1..100}; do
        if ! find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep -q . &&
           ! find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 | grep -q .; then break; fi
        sleep .05
    done
    if find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'left public probe'; fi
    if find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 | grep .; then fail 'left private lease'; fi
}
for TEST_MODE in timeout static cache redirect wrong_body; do
    printf '0\n' > "$TEST_CONTROL/count"
    expect_failure managed_http_check "$expected" > "$TEST_CONTROL/$TEST_MODE.log" 2>&1
    case "$TEST_MODE" in
        timeout) grep -q 'Не удалось выполнить временную' "$TEST_CONTROL/$TEST_MODE.log" || fail 'wrong timeout failure' ;;
        static|cache) grep -q 'не закрыта' "$TEST_CONTROL/$TEST_MODE.log" || fail 'wrong access failure' ;;
        *) grep -q 'не подтвердила версию' "$TEST_CONTROL/$TEST_MODE.log" || fail 'wrong response failure' ;;
    esac
    assert_no_probe
    pass "$TEST_MODE failure and cleanup"
done
TEST_MODE=normal
date() {
    if [ "${1:-}" = +%s ]; then printf '%s\n' "$(( $(command date +%s) - 200 ))"; else command date "$@"; fi
}
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/expired.log" 2>&1
grep -q 'не подтвердила версию' "$TEST_CONTROL/expired.log" || fail 'wrong expiry failure'
unset -f date
assert_no_probe
pass 'expired guard denied'
TEST_MODE=parent_rename
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/parent-rename.log" 2>&1
[ "$(cat /var/www/rc9-probe-site/replacement)" = 'replacement site' ] || fail 'replacement site changed'
if find /var/www/rc9-probe-site-renamed-by-test -maxdepth 1 -name 'bitrix-master-probe-*' | grep .; then fail 'anchored parent cleanup left probe'; fi
rm /var/www/rc9-probe-site/replacement
rmdir /var/www/rc9-probe-site
mv /var/www/rc9-probe-site-renamed-by-test /var/www/rc9-probe-site
assert_no_probe
pass 'renamed parent cleanup anchored without touching replacement site'
TEST_MODE=cleanup_failure
printf '0\n' > "$TEST_CONTROL/count"
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/cleanup-failure.log" 2>&1
grep -q 'Не удалось безопасно удалить' "$TEST_CONTROL/cleanup-failure.log" || fail 'cleanup failure was not reported'
lease="$(find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 -type d | head -1)"
probe_name="$(cat "$lease/name")"
[ -f "/var/www/rc9-probe-site/$probe_name/probe.php" ] || fail 'changed cleanup-failure probe was deleted'
cp "$lease/payload.php" "/var/www/rc9-probe-site/$probe_name/probe.php"
managed_probe_cleanup_stale || fail 'cleanup restored changed probe'
assert_no_probe
pass 'cleanup failure changes successful HTTP outcome to failure'
TEST_MODE=normal
start_blocked_probe() {
    rm -f "$TEST_CONTROL/blocking"
    setsid bash "$TEST_SUITE_DIR/signal-driver.sh" "$TEST_CONTROL" "$INSTALLER" "$expected" > "$TEST_CONTROL/driver.log" 2>&1 &
    driver_pid=$!
    for attempt in {1..200}; do [ ! -e "$TEST_CONTROL/blocking" ] || break; sleep .05; done
    [ -e "$TEST_CONTROL/blocking" ] || fail 'probe did not enter blocking transport'
}
for signal in TERM HUP; do
    start_blocked_probe
    managed_probe_cleanup_stale || fail 'live lease cleanup should skip'
    [ "$(find /var/www/rc9-probe-site -maxdepth 1 -name 'bitrix-master-probe-*' | wc -l)" -eq 1 ] || fail 'live probe was removed'
    kill -"$signal" -- "-$driver_pid"
    wait "$driver_pid" && fail 'signal did not fail driver'
    assert_no_probe
    pass "$signal cleanup and live lease preservation"
done
python "$TEST_SUITE_DIR/test-int.py" "$TEST_SUITE_DIR" "$INSTALLER" "$expected"
start_blocked_probe
kill -KILL -- "-$driver_pid"
wait "$driver_pid" && fail 'SIGKILL did not stop driver'
managed_probe_cleanup_stale || fail 'stale cleanup after SIGKILL'
assert_no_probe
pass 'SIGKILL lease cleanup on next run'
start_blocked_probe
kill -KILL -- "-$driver_pid"
wait "$driver_pid" && fail 'SIGKILL did not stop driver'
lease="$(find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 -type d | head -1)"
probe_name="$(cat "$lease/name")"
printf '\n// changed by another administrator\n' >> "/var/www/rc9-probe-site/$probe_name/probe.php"
expect_failure managed_probe_cleanup_stale > "$TEST_CONTROL/changed.log" 2>&1
grep -q 'изменена или недоступна' "$TEST_CONTROL/changed.log" || fail 'wrong changed-file failure'
[ -f "/var/www/rc9-probe-site/$probe_name/probe.php" ] || fail 'changed file was deleted'
cp "$lease/payload.php" "/var/www/rc9-probe-site/$probe_name/probe.php"
managed_probe_cleanup_stale || fail 'cleanup after restoring expected file'
assert_no_probe
pass 'changed file preserved'
start_blocked_probe
kill -KILL -- "-$driver_pid"
wait "$driver_pid" && fail 'SIGKILL did not stop driver'
lease="$(find "$UPDATER_STATE/probes" -mindepth 1 -maxdepth 1 -type d | head -1)"
probe_name="$(cat "$lease/name")"
printf 'unrelated private file\n' > "$TEST_CONTROL/important"
rm -- "/var/www/rc9-probe-site/$probe_name/probe.php"
ln -s "$TEST_CONTROL/important" "/var/www/rc9-probe-site/$probe_name/probe.php"
expect_failure managed_probe_cleanup_stale > "$TEST_CONTROL/symlink.log" 2>&1
[ "$(cat "$TEST_CONTROL/important")" = 'unrelated private file' ] || fail 'unrelated file modified'
[ -L "/var/www/rc9-probe-site/$probe_name/probe.php" ] || fail 'replacement symlink deleted'
rm -- "/var/www/rc9-probe-site/$probe_name/probe.php"
rmdir -- "/var/www/rc9-probe-site/$probe_name"
managed_probe_cleanup_stale || fail 'cleanup absent public artifact'
assert_no_probe
pass 'symlink replacement preserved and unrelated file untouched'
ln -s /var/www/rc9-probe-site /root/managed-probe-test/site-link
MANAGED_SITE='http|probe.example|80|/root/managed-probe-test/site-link'
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/root-symlink.log" 2>&1
grep -q 'Каталог выбранного сайта изменился' "$TEST_CONTROL/root-symlink.log" || fail 'wrong root symlink failure'
assert_no_probe
pass 'noncanonical document root rejected'
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
[ -d "/var/www/rc9-probe-site/$collision" ] || fail 'unclaimed colliding directory deleted'
rmdir -- "/var/www/rc9-probe-site/$collision"
managed_probe_cleanup_stale || fail 'cleanup after collision removed by owner'
assert_no_probe
pass 'unclaimed directory collision preserved'
selinuxenabled() { return 0; }
chcon() { return 1; }
expect_failure managed_http_check "$expected" > "$TEST_CONTROL/selinux.log" 2>&1
unset -f selinuxenabled chcon
grep -q 'SELinux-контекст' "$TEST_CONTROL/selinux.log" || fail 'wrong SELinux failure'
assert_no_probe
pass 'SELinux preparation failure cleanup'
printf 'ALL PROBE TESTS PASSED\n'
