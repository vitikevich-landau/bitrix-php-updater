#!/bin/bash
set -eo pipefail
installer="$1"
source <(sed '/^# Мутирующие операции:/,$d' "$installer")
declare -F discover_managed_sites >/dev/null || { echo 'FAIL: функция поиска отсутствует'; exit 1; }
work="$(mktemp -d /root/discovery-test.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/s1" "$work/s2" "$work/quoted root"
fixture="$work/config"
err() { printf 'ОШИБКА: %s\n' "$*" >&2; }
need() { return 0; }
require_root() { return 0; }
httpd() {
    case "$*" in
      -M) printf 'Loaded Modules:\n info_module (shared)\n' ;;
      '-t -D DUMP_CONFIG') cat "$fixture"; [ "${broken:-0}" = 0 ] ;;
      *) echo "неожиданный вызов httpd: $*" >&2; return 99 ;;
    esac
}
ok() {
    local want="$1" label="$2"
    discover_managed_sites > "$work/out" 2> "$work/err" || { cat "$work/err"; echo "FAIL $label: поиск"; exit 1; }
    [ "$(printf '%s\n' "${MANAGED_SITE_CANDIDATES[@]}")" = "$want" ] || { printf 'FAIL %s\nОжидалось: %s\nПолучено: %s\n' "$label" "$want" "${MANAGED_SITE_CANDIDATES[*]}"; exit 1; }
    echo "PASS $label"
}
bad() {
    local label="$1"
    if discover_managed_sites > "$work/out" 2> "$work/err"; then echo "FAIL принято: $label"; exit 1; fi
    [ "${#MANAGED_SITE_CANDIDATES[@]}" = 0 ] || { echo "FAIL устаревшие кандидаты: $label"; exit 1; }
    ! grep -q 'SECRET_MARKER' "$work/out" "$work/err" || { echo 'FAIL раскрыт дамп конфигурации'; exit 1; }
    echo "PASS отклонено: $label"
}
cat > "$fixture" <<EOF
# In file: /etc/httpd/bx/conf/default.conf
Listen 127.0.0.1:8888
ServerName localhost
DocumentRoot "$work/s1"
<Directory "$work/s1">
  Require all granted
</Directory>
EOF
ok "http|localhost|8888|$work/s1" 'основной сервер на локальном порту Битрикс'
select_managed_site '' 1 >/dev/null
[ "$MANAGED_SITE" = "http|localhost|8888|$work/s1" ]
echo 'PASS единственный сайт выбран без диалога'
cat > "$fixture" <<EOF
Listen 80
DocumentRoot "$work/s1"
EOF
ok "http|127.0.0.1|80|$work/s1" 'основной сервер без явного имени узла'
cat > "$fixture" <<EOF
Listen 127.0.0.1:8888
<VirtualHost *:8888>
  ServerName first.example
  ServerAlias www.first.example alias.example
  DocumentRoot "$work/quoted root"
</VirtualHost>
<VirtualHost 127.0.0.1:8888>
  ServerName second.example
  DocumentRoot "$work/s2"
</VirtualHost>
EOF
ok "http|first.example|8888|$work/quoted root
http|second.example|8888|$work/s2" 'раздельные виртуальные узлы и корневой каталог в кавычках'
select_managed_site second.example 1 >/dev/null
[ "$MANAGED_SITE" = "http|second.example|8888|$work/s2" ]
select_managed_site "$work/quoted root" 1 >/dev/null
[ "$MANAGED_SITE" = "http|first.example|8888|$work/quoted root" ]
select_managed_site www.first.example 1 >/dev/null
[ "$MANAGED_SITE" = "http|first.example|8888|$work/quoted root" ]
echo 'PASS выбор по имени узла, корневому каталогу и псевдониму'
if select_managed_site '' 1 > "$work/out" 2> "$work/err"; then echo 'FAIL неоднозначный выбор без диалога'; exit 1; fi
grep -q -- '--site' "$work/err"
if select_managed_site '' 0 </dev/null > "$work/out" 2> "$work/err"; then echo 'FAIL неоднозначный выбор при вводе через канал'; exit 1; fi
if select_managed_site missing.example 1 >/dev/null 2> "$work/err"; then echo 'FAIL отсутствующий вариант выбора'; exit 1; fi
echo 'PASS неоднозначность и неизвестный вариант выбора отклонены'
cat > "$fixture" <<EOF
Listen 127.0.0.1:8443 https
<VirtualHost *:8443>
 ServerName https://secure.example:443
 DocumentRoot "$work/s1"
 SSLEngine On
</VirtualHost>
EOF
ok "https|secure.example|8443|$work/s1" 'SSL и публичный порт ServerName используют локальный порт подключения'
cat > "$fixture" <<EOF
Listen localhost:8888
<VirtualHost localhost:8888 *:8888>
 ServerName first.example
 DocumentRoot "$work/s1"
</VirtualHost>
EOF
ok "http|first.example|8888|$work/s1" 'повторяющиеся адреса одного виртуального узла объединяются'
cat > "$fixture" <<EOF
Listen 80
DocumentRoot "$work/s1"
<VirtualHost *:80>
 ServerName inherited.example
</VirtualHost>
EOF
ok "http|inherited.example|80|$work/s1" 'унаследованный основной DocumentRoot'
cat > "$fixture" <<EOF
Listen 80
ServerName 'quoted.example'
DocumentRoot '$work/quoted root'
EOF
ok "http|quoted.example|80|$work/quoted root" 'скалярные значения Apache в одинарных кавычках'
cat > "$fixture" <<EOF
Listen 192.0.2.5:80
<VirtualHost 192.0.2.5:80>
 ServerName external.example
 DocumentRoot "$work/s1"
</VirtualHost>
EOF
bad 'слушатель и виртуальный узел только с внешним адресом'
cat > "$fixture" <<EOF
Listen [::1]:80
DocumentRoot "$work/s1"
EOF
bad 'слушатель только IPv6 не поддерживается IPv4-пробой'
cat > "$fixture" <<EOF
Listen 80
<VirtualHost *:80>
 ServerName first.example
 DocumentRoot "$work/s1"
 <If "true">
   DocumentRoot "$work/s2"
 </If>
</VirtualHost>
EOF
bad 'условный DocumentRoot'
cat > "$fixture" <<EOF
Listen 80
VirtualDocumentRoot $work/%0
DocumentRoot "$work/s1"
EOF
bad 'динамические корневые каталоги сайтов'
cat > "$fixture" <<EOF
Listen 80
<VirtualHost *:80>
 ServerName first.example
 DocumentRoot "$work/s1"
</VirtualHost>
<VirtualHost *:80>
 ServerName first.example
 DocumentRoot "$work/s2"
</VirtualHost>
EOF
bad 'повторяющееся имя узла на одном адресе подключения'
cat > "$fixture" <<EOF
Listen 80
ServerName first.example
DocumentRoot "$work/missing"
EOF
bad 'несуществующий корневой каталог сайта'
cat > "$fixture" <<EOF
Listen 80
DocumentRoot "$work/s1"
SetEnv SECRET_KEY SECRET_MARKER
EOF
broken=1
bad 'ошибка синтаксиса httpd не должна раскрывать частичный дамп'
broken=0
printf 'SetEnv SECRET_KEY SECRET_MARKER\n' > "$fixture"
bad 'пустой или недоступный дамп конфигурации'
echo 'ВСЕ ПРОВЕРКИ ПОИСКА ПРОЙДЕНЫ'
