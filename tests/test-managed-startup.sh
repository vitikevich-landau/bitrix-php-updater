#!/bin/bash
set -eo pipefail
source <(sed '/^# Мутирующие операции:/,$d' "$1")
declare -F _managed_site_validate_httpd_args >/dev/null || { echo 'FAIL: проверка активной конфигурации отсутствует'; exit 1; }
err() { printf 'ОШИБКА: %s\n' "$*" >&2; }
good() { local label="$1"; shift; _managed_site_validate_httpd_args "$@" || exit 1; echo "PASS $label"; }
bad() { local label="$1"; shift; if _managed_site_validate_httpd_args "$@" >/dev/null 2>&1; then echo "FAIL принято: $label"; exit 1; fi; echo "PASS отклонено: $label"; }
good 'параметры по умолчанию'
good 'передний план' -DFOREGROUND
good 'передний план отдельным аргументом' -D FOREGROUND
good 'запуск службы' -k start
good 'явный файл по умолчанию' -f /etc/httpd/conf/httpd.conf
good 'относительный файл по умолчанию' -f conf/httpd.conf
good 'явный корневой каталог по умолчанию' -d /etc/httpd -DFOREGROUND
bad 'другой файл' -f /root/custom-httpd.conf
bad 'другой корневой каталог' -d /srv/apache
bad 'внедрённая директива' -C 'DocumentRoot /srv/other'
bad 'добавленная директива' -c 'ServerName other.example'
bad 'пользовательская константа конфигурации' -DCUSTOM_POOL
bad 'отсутствующий аргумент файла' -f
bad 'неожиданный параметр' -X
echo 'ВСЕ ПРОВЕРКИ ЗАЩИТЫ АКТИВНОЙ КОНФИГУРАЦИИ ПРОЙДЕНЫ'
