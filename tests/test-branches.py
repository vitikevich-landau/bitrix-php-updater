"""Branch isolation regressions. Run against the full installer in disposable Docker.

OS, RPM metadata and services are boundary doubles; the target selection,
diagnostics, parsers, inventory matching and rollback state machine are real.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

installer = Path(sys.argv[1]).resolve(strict=True)
text = installer.read_text(encoding='utf-8')
prefix = text.split('# Мутирующие операции:', 1)[0]
assert prefix != text
cases = {}

for version, route, target in [('8.2.20', 'patch', '8.2.35'), ('8.2.35', 'target', '8.2.35'),
                               ('8.2.36', 'newer', '8.2.35'), ('8.3.8', 'patch', '8.3.36'),
                               ('8.3.36', 'target', '8.3.36'), ('8.3.37', 'newer', '8.3.36')]:
    cases['route '+version] = f'''
set_php_target {version.rsplit('.', 1)[0]} || exit 1
[ "$(php_version_route {version})" = {route} ] && [ "$TARGET_PHP" = {target} ]
'''
for version, route in [('8.1.33', 'older'), ('7.4.33', 'older'), ('8.4.1', 'unsupported'),
                       ('9.0.0', 'unsupported'), ('8.3.36RC1', 'unknown')]:
    cases['route '+version] = f'[ "$(php_version_route {version})" = {route} ]'
cases['unsupported builder target is refused before build'] = '''
build_rpms() { echo unexpected > "$EVENTS"; }
updater_dispatch --build --builder --branch 8.4; rc=$?
[ "$rc" = 2 ] && [ ! -s "$EVENTS" ]
'''
cases['explicit builder target selects source and specification'] = '''
build_rpms() {
    [ "$TARGET_PHP" = 8.3.36 ] && [ "$TARGET_SPEC" = php83.spec ] &&
    [ "$SRC_RPM_URL" = https://rpms.remirepo.net/SRPMS/php-8.3.36-1.remi.src.rpm ] &&
    [ "$TARGET_PHP_SHA" = dd54693aa334c5c4d72e9aee96b082c2473750a18a6c1d105789c93a3b1692fd ]
}
updater_dispatch --build --builder --branch 8.3
'''
cases['builder default remains 8.2 after previous target selection'] = '''
set_php_target 8.3 || exit 1
build_rpms() { [ "$TARGET_PHP" = 8.2.35 ] && [ "$TARGET_SPEC" = php82.spec ]; }
updater_dispatch --build --builder
'''
cases['client refuses explicit branch override'] = '''
run_update() { echo unexpected > "$EVENTS"; }
updater_dispatch --update --branch 8.3; rc=$?
[ "$rc" = 2 ] && [ ! -s "$EVENTS" ]
'''
profile = r'''
platform_check() { :; }
need() { :; }
php() { printf '%s' "$CURRENT"; }
httpd() { printf ' php_module (shared)\n mpm_prefork_module (shared)\n'; }
systemctl() { return 3; }
rpm() {
    if [ "$1" = -qa ]; then echo php; return; fi
    case "${@: -1}" in
        bitrix-env|bitrix-env-crm)
            if [ "${@: -1}" = bitrix-env-crm ] && [ "${ENV_BOTH:-0}" != 1 ]; then
                printf 'package bitrix-env-crm is not installed\n'; return 1
            elif [ "${ENV_VERSION+set}" = set ]; then
                # Model RPM formatting: a missing newline concatenates duplicate versions.
                if [ "${ENV_RC:-0}" != 0 ]; then
                    printf '%b' "$ENV_VERSION"; return "$ENV_RC"
                elif [[ "$3" == *'\n' ]]; then
                    printf '%b\n' "$ENV_VERSION"
                else
                    printf '%b' "$ENV_VERSION" | tr -d '\n'
                fi
            else
                printf 'package %s is not installed\n' "${@: -1}"; return 1
            fi ;;
        php|php-cli) printf '%s' "$CURRENT" ;;
        *) return 1 ;;
    esac
}
'''
for version in ('8.2.20', '8.3.8', '8.3.36'):
    target = '8.2.35' if version.startswith('8.2.') else '8.3.36'
    cases['real profile selects '+version] = profile + f'''
CURRENT={version}
profile_check || exit 1
[ "$PHP_CURRENT" = {version} ] && [ "$TARGET_PHP" = {target} ]
'''
cases['profile rejects known BitrixEnv 9'] = profile + '''
CURRENT=8.2.20 ENV_VERSION=9.0
profile_check; rc=$?
[ "$rc" = 20 ]
'''
cases['profile rejects unsupported PHP branch'] = profile + '''
CURRENT=8.4.1
profile_check; rc=$?
[ "$rc" = 20 ]
'''
for label, value, rc, both, expected in [
        ('single Env7', '7.5', 0, 0, 0),
        ('bare Env7', '7', 0, 0, 0),
        ('Env8', '8.0', 0, 0, 20),
        ('bare Env9', '9', 0, 0, 20),
        ('mixed same-name versions', '7.5\\n9.0', 0, 0, 20),
        ('duplicate same-name Env7', '7.5\\n7.5', 0, 0, 20),
        ('trailing empty RPM version', '7.5\\n', 0, 0, 20),
        ('both environment packages', '7.5', 0, 1, 20),
        ('successful empty RPM version', '', 0, 0, 20),
        ('malformed RPM version', '7.5oops', 0, 0, 20),
        ('RPM database failure', 'error: rpmdb open failed\\n', 1, 0, 20),
        ('not-installed text with error status', 'package bitrix-env is not installed\\n', 2, 0, 20),
        ('confirmed absent Env RPM', 'package bitrix-env is not installed\\n', 1, 0, 0)]:
    cases['environment guard '+label] = profile + f'''
CURRENT=8.3.8 ENV_VERSION='{value}' ENV_RC={rc} ENV_BOTH={both}
profile_check; rc=$?
[ "$rc" = {expected} ]
'''
diagnostic_stubs = '''
php() { if [ "$1" = -v ]; then echo "PHP $CURRENT (cli)"; else printf '%s' "$CURRENT"; fi; }
profile_check() { PHP_CURRENT="$CURRENT"; }
php_rpm_versions_check() { :; }
show_os_status() { :; }
'''
for name, command in [('quick', 'quick_check'), ('plan', 'show_plan'), ('fallback', 'fallback_diagnose --offline')]:
    cases[name+' treats old 8.3 as needing its own target'] = diagnostic_stubs + f'''
CURRENT=8.3.8
{command} > "$OUTPUT" || exit 1
grep -q 8.3.36 "$OUTPUT" && ! grep -q '8.2.35\|Понижение' "$OUTPUT"
'''
cases['current 8.3 diagnostic does not suggest downgrade'] = diagnostic_stubs + '''
CURRENT=8.3.36
quick_check > "$OUTPUT"
grep -q '8.3.36.*обновлять.*не нужно' "$OUTPUT" && ! grep -q '8.2.35\|Понижение' "$OUTPUT"
'''
cases['unsupported plan does not offer legacy transition'] = diagnostic_stubs + '''
CURRENT=8.4.1
show_legacy_php_plan() { echo unexpected > "$EVENTS"; }
show_plan > "$OUTPUT"; rc=$?
[ "$rc" = 20 ] && [ ! -s "$EVENTS" ] && grep -qi 'не поддерж' "$OUTPUT"
'''
cases['manual current 8.3 verifies health without RPM transaction'] = profile + '''
CURRENT=8.3.36
session_setup() { SESSION_DIR="$ROOT/session"; mkdir -m700 "$SESSION_DIR"; }
mark_state() { echo "$1" > "$SESSION_DIR/state"; }
inventory_php_rpms() {
    for name in php php-cli php-common; do printf '%s|(none)|8.3.36|1.el7.custom|x86_64\\n' "$name"; done
}
verify_after() { [ "$2" = https://site.test/health.php ] && [ "$3" = 8.3.36 ]; }
run_update '' https://site.test/health.php '' '' 1 || exit 1
[ "$(cat "$SESSION_DIR/state")" = already_current ]
'''
cases['automatic current 8.3 maps legacy source before health handoff'] = profile + '''
CURRENT=8.3.36
printf 'SOURCE=https://github.com/vitikevich-landau/bitrix-php82-updater/releases/download/php-8.2.35-el7-r1\\nKEYRING=/root/absent-key\\nHEALTH_URL=https://site.test/health.php\\n' > "$ROOT/config"
run_update() {
    [ "$TARGET_PHP" = 8.3.36 ] && [ "$AUTO_SOURCE" = https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.3.36-el7-r1 ] &&
    [ "$2" = https://site.test/health.php ] && echo health > "$EVENTS"
}
run_auto_update "$ROOT/config" 1 || exit 1
grep -qx health "$EVENTS"
'''
cases['automatic newer 8.3 refuses downgrade before preparation'] = profile + '''
CURRENT=8.3.37
printf 'SOURCE=/root/custom\\nKEYRING=/root/absent-key\\nHEALTH_URL=https://site.test/health.php\\n' > "$ROOT/config"
run_update() { echo unexpected > "$EVENTS"; }
safe_download() { echo unexpected > "$EVENTS"; }
run_auto_update "$ROOT/config" 1; rc=$?
[ "$rc" = 20 ] && [ ! -s "$EVENTS" ]
'''
for source in ('https://github.com/vitikevich-landau/bitrix-php82-updater/releases/download/php-8.2.35-el7-r1',
               'https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.2.35-el7-r1',
               'https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.3.36-el7-r1',
               'https://custom.example/php-8.2.35-el7-r1', '/root/custom-release'):
    expected = source if source.startswith(('https://custom.', '/root/')) else 'https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.3.36-el7-r1'
    cases['configured source '+source] = f'''
set_php_target 8.3 || exit 1
printf 'SOURCE=%s\nKEYRING=/root/key\nHEALTH_URL=https://site.test/health.php\n' '{source}' > "$ROOT/config"
load_auto_config "$ROOT/config" || exit 1
[ "$AUTO_SOURCE" = '{expected}' ]
'''
inventory = '''
for name in php php-cli php-common; do
    printf '%s|(none)|%s|1.el7.remi|x86_64\\n' "$name" "$OLD" >> "$ROOT/inventory"
    printf '%s|(none)|%s|1.el7.custom|x86_64\\n' "$name" "$NEW" > "$ROOT/rpms/$name.rpm"
done
rpm() {
    if [ "$1" = -K ]; then return 0; fi
    if [[ "$*" == *SOURCEPACKAGE* ]]; then echo '(none)'; else cat "${@: -1}"; fi
}
'''
cases['8.3 selection accepts exact target'] = '''
set_php_target 8.3 || exit 1
OLD=8.3.8 NEW=8.3.36
''' + inventory + '''select_rpms "$ROOT/rpms" new "$ROOT/inventory" && [ "${#SELECTED_RPMS[@]}" = 3 ]'''
cases['8.3 refuses wrong new branch before RPM mutation'] = '''
set_php_target 8.3 || exit 1
OLD=8.3.8 NEW=8.2.35
''' + inventory + '''! select_rpms "$ROOT/rpms" new "$ROOT/inventory"'''
cases['old inventory cannot cross selected branch'] = '''
set_php_target 8.3 || exit 1
OLD=8.2.20 NEW=8.2.20
''' + inventory + '''
sed -i s/1.el7.custom/1.el7.remi/ "$ROOT/rpms/"*.rpm
! select_rpms "$ROOT/rpms" old "$ROOT/inventory"
'''
rollback = r'''
require_root() { :; }
need() { :; }
platform_check() { :; }
session_setup() { SESSION_DIR="$ROOT/recovery"; mkdir -m700 "$SESSION_DIR"; }
mark_state() { echo "$1" > "$SESSION_DIR/state"; }
UPDATER_STATE="$ROOT/state"
id=20261107T100000Z-123
source="$UPDATER_STATE/sessions/$id"
mkdir -p -m700 "$source/rpm-rollback"
chmod 0700 "$UPDATER_STATE" "$UPDATER_STATE/sessions" "$source" "$source/rpm-rollback"
echo completed > "$source/state"
echo "$OLD" > "$source/php-version-before.txt"
echo 'https://site.test/health.php' > "$source/url"
for name in php php-cli php-common; do
    printf '%s|(none)|%s|1.el7.remi|x86_64\n' "$name" "$OLD" >> "$source/rpm-before.txt"
    printf '%s|(none)|%s|1.el7.custom|x86_64\n' "$name" "$NEW" >> "$source/rpm-target.txt"
done
for file in php-modules-before.txt configuration.tar.gz trusted-keyring.gpg; do echo fixture > "$source/$file"; done
chmod 0600 "$source/"*
chmod 0700 "$source/rpm-rollback"
php() { echo EARLY_PHP >> "$EVENTS"; return 1; }
rpm() {
    case "${@: -1}" in
        bitrix-env|bitrix-env-crm) printf 'package %s is not installed\n' "${@: -1}"; return 1 ;;
        *) echo UNEXPECTED_RPM >> "$EVENTS"; return 99 ;;
    esac
}
rpm_core_snapshot() { cat "$source/rpm-before.txt"; }
stage_rpm_bundle() { echo STAGE >> "$EVENTS"; }
select_rpms() { SELECTED_RPMS=(php php-cli php-common); }
rollback_rpm_uncertain() { return 1; }
backup_configs() { :; }
check_external_rpm_obsoletes() { :; }
sync() { :; }
httpd() { :; }
systemctl() { :; }
verify_after() { [ "$3" = "$OLD" ]; }
'''
for old, new in [('8.2.20', '8.2.35'), ('8.3.8', '8.3.36')]:
    cases['rollback without PHP '+old] = f'OLD={old} NEW={new}\n' + rollback + f'''
run_rollback "$id" '' 1 || exit 1
[ "$TARGET_PHP" = {new} ] && ! grep -q EARLY_PHP "$EVENTS"
'''
cases['cross branch saved target rejected before rollback staging'] = 'OLD=8.3.8 NEW=8.2.35\n' + rollback + '''
run_rollback "$id" '' 1; rc=$?
[ "$rc" = 71 ] && [ ! -s "$EVENTS" ]
'''
cases['rollback rejects Env9 without invoking broken PHP'] = 'OLD=8.3.8 NEW=8.3.36\n' + rollback + '''
rpm() {
    case "${@: -1}" in
        bitrix-env) printf '9.0\\n' ;;
        bitrix-env-crm) printf 'package bitrix-env-crm is not installed\\n'; return 1 ;;
        *) echo UNEXPECTED_RPM >> "$EVENTS"; return 99 ;;
    esac
}
run_rollback "$id" '' 1; rc=$?
[ "$rc" = 71 ] && [ ! -s "$EVENTS" ] && [ ! -e "$source/rollback-rpm-state" ]
'''

failed = 0
Path('/etc/httpd/bx').mkdir(parents=True, exist_ok=True)
for name, body in cases.items():
    with tempfile.TemporaryDirectory(dir='/root') as directory:
        root = Path(directory)
        (root/'rpms').mkdir()
        (root/'events').touch()
        script = root/'run.sh'
        script.write_text(prefix+'\n'+body, encoding='utf-8')
        result = subprocess.run(['/bin/bash', str(script)], capture_output=True, text=True,
                                env=dict(os.environ, ROOT=directory, EVENTS=str(root/'events'), OUTPUT=str(root/'output')))
        if result.returncode:
            failed += 1
            print('FAIL', name, result.returncode, result.stdout[-2000:], result.stderr[-2000:], sep='\n')
            if (root/'output').exists(): print((root/'output').read_text()[-2000:])
        else:
            print('PASS', name)

# Execute the complete embedded auditor through the public CLI with a fake PHP
# executable. This catches passing the 8.2 target to Python for an 8.3 host.
for version, wanted in [('8.3.8', 'ниже целевой 8.3.36'), ('8.3.36', 'обновление до целевой версии не требуется'),
                        ('8.3.37', 'выше целевой 8.3.36'), ('8.4.1', 'не поддерж')]:
    with tempfile.TemporaryDirectory() as directory:
        php = Path(directory)/'php'
        php.write_text('#!/bin/bash\ncase "$1" in -v) echo "PHP '+version+' (cli)";; -r) echo '+version+';; -m) echo Core;; esac\n')
        php.chmod(0o755)
        result = subprocess.run(['/bin/bash', str(installer), '--diagnose', '--offline'], capture_output=True, text=True,
                                env=dict(os.environ, PATH=directory+':'+os.environ['PATH']))
        if wanted not in result.stdout or ('8.2.35' in result.stdout):
            failed += 1
            print('FAIL embedded audit', version, result.stdout[:2200], result.stderr)
        else:
            print('PASS embedded audit', version)
for version, branch_warning in [('8.1.33', 'отдельный маршрут'), ('8.4.1', 'не поддерживается')]:
    with tempfile.TemporaryDirectory() as directory:
        php = Path(directory)/'php'
        php.write_text('#!/bin/bash\ncase "$1" in -v) echo "PHP '+version+' (cli)"; echo "PHP Warning: fixture module failed" >&2;; -m) echo Core;; esac\n')
        php.chmod(0o755)
        result = subprocess.run(['/bin/bash', str(installer), '--diagnose', '--offline'], capture_output=True, text=True,
                                env=dict(os.environ, PATH=directory+':'+os.environ['PATH']))
        if ('[КРИТИЧНО] PHP CLI '+version+' — ошибки загрузки модулей') not in result.stdout or branch_warning not in result.stdout:
            failed += 1
            print('FAIL module error and branch warning', version, result.stdout[:2200], result.stderr)
        else:
            print('PASS module error and branch warning', version)
print(f'{len(cases)+6-failed}/{len(cases)+6} branch cases passed')
raise SystemExit(bool(failed))
