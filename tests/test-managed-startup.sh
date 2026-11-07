#!/bin/bash
set -eo pipefail
source <(sed '/^# Мутирующие операции:/,$d' "$1")
declare -F _managed_site_validate_httpd_args >/dev/null || { echo 'FAIL: running-config guard is absent'; exit 1; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
good() { local label="$1"; shift; _managed_site_validate_httpd_args "$@" || exit 1; echo "PASS $label"; }
bad() { local label="$1"; shift; if _managed_site_validate_httpd_args "$@" >/dev/null 2>&1; then echo "FAIL accepted $label"; exit 1; fi; echo "PASS rejected $label"; }
good defaults
good foreground -DFOREGROUND
good separate-foreground -D FOREGROUND
good daemon-start -k start
good explicit-default-file -f /etc/httpd/conf/httpd.conf
good relative-default-file -f conf/httpd.conf
good explicit-default-root -d /etc/httpd -DFOREGROUND
bad alternate-file -f /root/custom-httpd.conf
bad alternate-root -d /srv/apache
bad injected-directive -C 'DocumentRoot /srv/other'
bad appended-directive -c 'ServerName other.example'
bad custom-config-define -DCUSTOM_POOL
bad missing-file-argument -f
bad unexpected-option -X
echo 'ALL RUNNING-CONFIG GUARD FIXTURES PASSED'
