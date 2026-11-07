#!/bin/bash
set -o pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/fixture-common.sh" "$@"
for fixture in /root/rc9-race-state /root/rc9-race-victim /root/rc9-race-target /root/rc9-race-http-started /root/rc9-race-log /var/www/rc9-race-site; do
    if [ -e "$fixture" ] || [ -L "$fixture" ]; then echo "Refusing to overwrite an existing fixture path: $fixture" >&2; exit 2; fi
done
command -v runuser >/dev/null && [ "$(id -u nobody)" = 99 ] || { echo 'The fixture requires the CentOS nobody account (UID99) and runuser.' >&2; exit 2; }
failures=0
for race_mode in attacker_directory root_symlink root_private_directory root_nonempty_directory; do
    UPDATER_STATE=/root/rc9-race-state
    MANAGED_SITE='http|probe.example|80|/var/www/rc9-race-site'
    command mkdir -m 0755 /var/www/rc9-race-site
    chown 99:99 /var/www/rc9-race-site
    command mkdir -m 0700 /root/rc9-race-victim
    printf 'unrelated root data\n' > /root/rc9-race-victim/probe.php
    chmod 0644 /root/rc9-race-victim/probe.php
    command mkdir -m 0700 /var/www/rc9-race-site/private
    printf 'private directory data\n' > /var/www/rc9-race-site/private/secret
    chmod 0644 /var/www/rc9-race-site/private/secret
    mkdir() {
        local last
        for last in "$@"; do :; done
        command mkdir "$@" || return
        if [[ "${last##*/}" == bitrix-master-probe-* ]]; then
            last="/var/www/rc9-race-site/${last##*/}"
            runuser -u nobody -- mv -- "$last" "$last.original"
            case "$race_mode" in
                attacker_directory)
                    runuser -u nobody -- mkdir -m 0755 -- "$last"
                    runuser -u nobody -- ln -s /root/rc9-race-victim/probe.php "$last/probe.php"
                    ;;
                root_symlink)
                    runuser -u nobody -- ln -s /root/rc9-race-victim "$last"
                    ;;
                root_private_directory)
                    runuser -u nobody -- mv /var/www/rc9-race-site/private "$last"
                    ;;
                root_nonempty_directory)
                    chmod 0755 /var/www/rc9-race-site/private
                    runuser -u nobody -- mv /var/www/rc9-race-site/private "$last"
                    ;;
            esac
            printf '/var/www/rc9-race-site/%s\n' "${last##*/}" > /root/rc9-race-target
        fi
    }
    curl() { touch /root/rc9-race-http-started; return 28; }
    if managed_http_check 8.2.20 > /root/rc9-race-log 2>&1; then
        printf 'FAIL %s unexpectedly succeeded\n' "$race_mode"; failures=$((failures + 1))
    fi
    unset -f mkdir curl
    target="$(cat /root/rc9-race-target)"
    ok=1
    [ -f /root/rc9-race-victim/probe.php ] && [ "$(cat /root/rc9-race-victim/probe.php)" = 'unrelated root data' ] || ok=0
    [ "$(stat -c %a /root/rc9-race-victim)" = 700 ] || ok=0
    [ ! -e /root/rc9-race-http-started ] || ok=0
    case "$race_mode" in
        root_private_directory)
            [ "$(stat -c %a "$target")" = 700 ] && [ "$(cat "$target/secret")" = 'private directory data' ] && [ ! -e "$target/probe.php" ] || ok=0 ;;
        root_nonempty_directory)
            [ "$(cat "$target/secret")" = 'private directory data' ] && [ ! -e "$target/probe.php" ] || ok=0 ;;
    esac
    if [ "$ok" -eq 1 ]; then printf 'PASS %s prewrite refusal preserves unrelated data and permissions\n' "$race_mode";
    else printf 'FAIL %s changed unrelated data/permissions or reached HTTP\n' "$race_mode"; failures=$((failures + 1)); fi
    # Fixed disposable fixture roots, never production website paths.
    rm -rf -- /var/www/rc9-race-site /root/rc9-race-state /root/rc9-race-victim
    rm -f -- /root/rc9-race-target /root/rc9-race-http-started /root/rc9-race-log
done
[ "$failures" -eq 0 ]
