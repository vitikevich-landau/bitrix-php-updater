#!/usr/bin/env bash
set -euo pipefail
# Запускать в одноразовом контейнере CentOS 7, описанном в tests/README.md.
# Первая проверка использует настоящую базу RPM. Остальные моделируют строки RPM.
installer="$(readlink -f -- "${1:?Использование: test-environment.sh INSTALLER}")"
source <(sed '/^# Мутирующие операции:/,$d' "$installer")
bitrix_env_rpm_guard
printf 'PASS фактическое отсутствие RPM сохраняет совместимость с прежним режимом\n'

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
            printf 'FAIL %s (код %s): %s\n' "$label" "$rc" "$output"; return 1;
        }
    fi
    printf 'PASS %s\n' "$label"
}
check 'единственный Env7' allow '7.5\n' 0
check 'версия Env7 без минорного номера' allow '7\n' 0
check 'явно отсутствующий пакет' allow 'package bitrix-env is not installed\n' 1
check 'Env8 отклоняется' 'не поддерживается' '8.0\n' 0
check 'версия Env9 без минорного номера отклоняется' 'не поддерживается' '9\n' 0
check 'смешанные версии RPM отклоняются' 'метаданные' '7.5\n9.0\n' 0
check 'повторяющийся Env7 отклоняется' 'метаданные' '7.5\n7.5\n' 0
check 'пустой второй RPM отклоняется' 'метаданные' '7.5\n\n' 0
check 'пустая версия при успешном завершении команды отклоняется' 'метаданные' '\n' 0
check 'некорректная версия отклоняется' 'метаданные' '7.5oops\n' 0
check 'вывод без разделителей отклоняется' 'метаданные' '7.59.0' 0
check 'оба пакета окружения отклоняются' 'несколько RPM' '7.5\n' 0 1
check 'сбой базы RPM отклоняется' 'Не удалось прочитать RPM' 'error: rpmdb open failed\n' 1
check 'неожиданный код завершения отклоняется' 'Не удалось прочитать RPM' 'package bitrix-env is not installed\n' 2
