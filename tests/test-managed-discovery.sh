#!/bin/bash
set -eo pipefail
installer="$1"
source <(sed '/^# Мутирующие операции:/,$d' "$installer")
declare -F discover_managed_sites >/dev/null || { echo 'FAIL: discovery feature is absent'; exit 1; }
work="$(mktemp -d /root/discovery-test.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/s1" "$work/s2" "$work/quoted root"
fixture="$work/config"
err() { printf 'ERROR: %s\n' "$*" >&2; }
need() { return 0; }
require_root() { return 0; }
httpd() {
    case "$*" in
      -M) printf 'Loaded Modules:\n info_module (shared)\n' ;;
      '-t -D DUMP_CONFIG') cat "$fixture"; [ "${broken:-0}" = 0 ] ;;
      *) echo "unexpected httpd invocation: $*" >&2; return 99 ;;
    esac
}
ok() {
    local want="$1" label="$2"
    discover_managed_sites > "$work/out" 2> "$work/err" || { cat "$work/err"; echo "FAIL $label discovery"; exit 1; }
    [ "$(printf '%s\n' "${MANAGED_SITE_CANDIDATES[@]}")" = "$want" ] || { printf 'FAIL %s\nWant: %s\nGot: %s\n' "$label" "$want" "${MANAGED_SITE_CANDIDATES[*]}"; exit 1; }
    echo "PASS $label"
}
bad() {
    local label="$1"
    if discover_managed_sites > "$work/out" 2> "$work/err"; then echo "FAIL accepted $label"; exit 1; fi
    [ "${#MANAGED_SITE_CANDIDATES[@]}" = 0 ] || { echo "FAIL stale candidates: $label"; exit 1; }
    ! grep -q 'SECRET_MARKER' "$work/out" "$work/err" || { echo 'FAIL config dump leaked'; exit 1; }
    echo "PASS rejected $label"
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
ok "http|localhost|8888|$work/s1" 'main server on Bitrix loopback port'
select_managed_site '' 1 >/dev/null
[ "$MANAGED_SITE" = "http|localhost|8888|$work/s1" ]
echo 'PASS sole site selected without interaction'
cat > "$fixture" <<EOF
Listen 80
DocumentRoot "$work/s1"
EOF
ok "http|127.0.0.1|80|$work/s1" 'main without explicit hostname'
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
http|second.example|8888|$work/s2" 'separate vhosts and quoted root'
select_managed_site second.example 1 >/dev/null
[ "$MANAGED_SITE" = "http|second.example|8888|$work/s2" ]
select_managed_site "$work/quoted root" 1 >/dev/null
[ "$MANAGED_SITE" = "http|first.example|8888|$work/quoted root" ]
select_managed_site www.first.example 1 >/dev/null
[ "$MANAGED_SITE" = "http|first.example|8888|$work/quoted root" ]
echo 'PASS selectors by hostname, root and alias'
if select_managed_site '' 1 > "$work/out" 2> "$work/err"; then echo 'FAIL ambiguous unattended selection'; exit 1; fi
grep -q -- '--site' "$work/err"
if select_managed_site '' 0 </dev/null > "$work/out" 2> "$work/err"; then echo 'FAIL ambiguous pipe selection'; exit 1; fi
if select_managed_site missing.example 1 >/dev/null 2> "$work/err"; then echo 'FAIL nonexistent selector'; exit 1; fi
echo 'PASS ambiguity and unknown selector rejected'
cat > "$fixture" <<EOF
Listen 127.0.0.1:8443 https
<VirtualHost *:8443>
 ServerName https://secure.example:443
 DocumentRoot "$work/s1"
 SSLEngine On
</VirtualHost>
EOF
ok "https|secure.example|8443|$work/s1" 'SSL and public ServerName port use local endpoint port'
cat > "$fixture" <<EOF
Listen localhost:8888
<VirtualHost localhost:8888 *:8888>
 ServerName first.example
 DocumentRoot "$work/s1"
</VirtualHost>
EOF
ok "http|first.example|8888|$work/s1" 'duplicate addresses of same vhost collapsed'
cat > "$fixture" <<EOF
Listen 80
DocumentRoot "$work/s1"
<VirtualHost *:80>
 ServerName inherited.example
</VirtualHost>
EOF
ok "http|inherited.example|80|$work/s1" 'inherited main DocumentRoot'
cat > "$fixture" <<EOF
Listen 80
ServerName 'quoted.example'
DocumentRoot '$work/quoted root'
EOF
ok "http|quoted.example|80|$work/quoted root" 'single-quoted Apache scalar values'
cat > "$fixture" <<EOF
Listen 192.0.2.5:80
<VirtualHost 192.0.2.5:80>
 ServerName external.example
 DocumentRoot "$work/s1"
</VirtualHost>
EOF
bad 'external-only listener and vhost'
cat > "$fixture" <<EOF
Listen [::1]:80
DocumentRoot "$work/s1"
EOF
bad 'IPv6-only listener unsupported by IPv4 probe'
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
bad 'conditional DocumentRoot'
cat > "$fixture" <<EOF
Listen 80
VirtualDocumentRoot $work/%0
DocumentRoot "$work/s1"
EOF
bad 'dynamic document roots'
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
bad 'duplicate hostname on same endpoint'
cat > "$fixture" <<EOF
Listen 80
ServerName first.example
DocumentRoot "$work/missing"
EOF
bad 'nonexistent document root'
cat > "$fixture" <<EOF
Listen 80
DocumentRoot "$work/s1"
SetEnv SECRET_KEY SECRET_MARKER
EOF
broken=1
bad 'httpd syntax failure must not expose partial dump'
broken=0
printf 'SetEnv SECRET_KEY SECRET_MARKER\n' > "$fixture"
bad 'empty or unavailable config dump'
echo 'ALL DISCOVERY FIXTURES PASSED'
