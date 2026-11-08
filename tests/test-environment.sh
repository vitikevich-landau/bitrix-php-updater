#!/usr/bin/env bash
set -euo pipefail
# Run in the disposable CentOS 7 container documented in tests/README.md.
# The first case uses the real RPM database. Remaining cases model RPM rows.
installer="$(readlink -f -- "${1:?Usage: test-environment.sh INSTALLER}")"
source <(sed '/^# Мутирующие операции:/,$d' "$installer")
bitrix_env_rpm_guard
printf 'PASS actual RPM absence retains legacy compatibility\n'

rpm() {
    [ "$#" = 4 ] && [ "$1" = -q ] && [ "$2" = --qf ] && [ "$3" = '%{VERSION}\n' ] || return 99
    if [ "$4" = bitrix-env-crm ] && [ "$fixture_both" = 0 ]; then
        printf 'package bitrix-env-crm is not installed\n'; return 1
    fi
    printf '%b' "$fixture_records"
    return "$fixture_status"
}
check() {
    local label="$1" expected="$2" output rc=0
    fixture_records="$3" fixture_status="$4" fixture_both="${5:-0}"
    output="$(bitrix_env_rpm_guard 2>&1)" || rc=$?
    if [ "$expected" = allow ]; then
        [ "$rc" = 0 ] || { printf 'FAIL %s: %s\n' "$label" "$output"; return 1; }
    else
        [ "$rc" = 20 ] && [[ "$output" == *"$expected"* ]] || {
            printf 'FAIL %s (status %s): %s\n' "$label" "$rc" "$output"; return 1;
        }
    fi
    printf 'PASS %s\n' "$label"
}
check 'single Env7' allow '7.5\n' 0
check 'bare Env7' allow '7\n' 0
check 'explicit absent package' allow 'package bitrix-env is not installed\n' 1
check 'Env8 rejected' 'не поддерживается' '8.0\n' 0
check 'bare Env9 rejected' 'не поддерживается' '9\n' 0
check 'mixed RPM versions rejected' 'метаданные' '7.5\n9.0\n' 0
check 'duplicate Env7 rejected' 'метаданные' '7.5\n7.5\n' 0
check 'empty second RPM rejected' 'метаданные' '7.5\n\n' 0
check 'successful empty version rejected' 'метаданные' '\n' 0
check 'malformed version rejected' 'метаданные' '7.5oops\n' 0
check 'unseparated output rejected' 'метаданные' '7.59.0' 0
check 'both environment packages rejected' 'несколько RPM' '7.5\n' 0 1
check 'RPM database failure rejected' 'Не удалось прочитать RPM' 'error: rpmdb open failed\n' 1
check 'unexpected status rejected' 'Не удалось прочитать RPM' 'package bitrix-env is not installed\n' 2
