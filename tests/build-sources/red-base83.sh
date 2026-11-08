#!/usr/bin/env bash
# Исторический тест, выявляющий ошибку в rc9: полные определения и явно заданный утверждённый профиль 8.3.
set -o pipefail
[[ ${BITRIX_TEST_DISPOSABLE:-} == 1 && -f /.dockerenv && $# == 3 ]] || exit 2
mkdir -p "$3" || exit
awk '/^# Мутирующие операции:/ {exit} {print}' "$1" > "$3/library.sh"
source "$3/library.sh"
TARGET_BRANCH=8.3
TARGET_PHP=8.3.36
TARGET_PHP_SHA=dd54693aa334c5c4d72e9aee96b082c2473750a18a6c1d105789c93a3b1692fd
SRC_RPM_SHA256=9a8fbff91b8a79cf82aa2405b70d086e6c313d2575a9d9040866cac7d2d0d87f
TARGET_SPEC=php83.spec
WORK_ROOT="$3/work"
mkdir -p "$WORK_ROOT"
source_prepare "$3/source" "$2"
