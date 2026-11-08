#!/usr/bin/env bash
# Тестовая подмена: сохраняем все функции установщика, кроме ресурсоёмкого вызова компилятора.
set -o pipefail
[[ ${BITRIX_TEST_DISPOSABLE:-} == 1 && -f /.dockerenv && $# -ge 3 ]] || exit 2
library="$1"
test_state="$2"
shift 2
source "$library"
UPDATER_STATE="$test_state"
UPDATER_LOG="$test_state/log"
WORK_ROOT="$test_state/work"
rpmbuild() {
    if [[ "$1" == -ba ]]; then
        local spec="${@: -1}" top version
        printf '%s\n' "$*" >> "$test_state/compile-boundary.log"
        [[ ${COMPILE_RESULT:-success} == success ]] || return 99
        case "$spec" in
            */SPECS/php82.spec) version=8.2.35 ;;
            */SPECS/php83.spec) version=8.3.36 ;;
            *) return 98 ;;
        esac
        top=${spec%/SPECS/*}
        mkdir -p "$top/RPMS/x86_64" || return
        # Это исключительно тестовая подмена вызова, а не пригодный для установки RPM.
        printf 'ТОЛЬКО ДЛЯ ТЕСТА: подмена компиляции PHP %s\n' "$version" > "$top/RPMS/x86_64/php-$version-1.el7.1.x86_64.rpm"
    else
        command rpmbuild "$@"
    fi
}
updater_dispatch "$@"
