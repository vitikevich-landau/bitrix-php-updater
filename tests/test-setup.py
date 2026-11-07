"""Noninteractive setup tests in isolated /root directories.

Discovery, downloads and the HTTP probe are boundary doubles. Only the copied
test function uses a fixture key hash. No release key is read.
"""
import hashlib
import os
import pty
import re
import sys
from pathlib import Path
import stat
import subprocess
import tempfile

installer = Path(sys.argv[1]).resolve(strict=True).read_text(encoding='utf-8')
marker = '# Мутирующие операции:'
assert marker in installer, 'installer dispatch marker not found'
prefix = installer.split(marker, 1)[0]
assert 'setup_auto_update() (' in prefix, 'setup function not found'
setup_function = prefix.split('setup_auto_update() (', 1)[1]
project_source = re.search(r"local source='([^']+)'", setup_function).group(1)
original_key_hash = re.search(r"local expected_key='([0-9a-f]{64})'", setup_function).group(1)
fixture_key = b'isolated setup key fixture; never a real signing key\n'
key_hash = hashlib.sha256(fixture_key).hexdigest()
prefix = prefix.replace("expected_key='" + original_key_hash + "'", "expected_key='" + key_hash + "'", 1)
failures = 0
site_record = 'http|site.example|80|/var/www/site'
other_record = 'http|other.example|80|/var/www/other'
for scenario in ('fresh', 'explicit_site', 'existing_saved_site', 'interactive_existing_site', 'existing_custom_source',
                 'wrong_key_preserves', 'failed_health', 'ambiguous_sites', 'selection_cancelled',
                 'unsafe_config', 'unsafe_keydir', 'symlink_config', 'symlink_keydir',
                 'failed_save_preserves_pair', 'reuse_pinned_key', 'unsafe_pinned_key', 'corrupt_pinned_key'):
    with tempfile.TemporaryDirectory(dir='/root') as directory:
        home = Path(directory)
        config = home/'update.conf'
        keydir = home/'keys'
        oldkey = keydir/'release-keyring.gpg'
        original = None
        if scenario in ('existing_custom_source','existing_saved_site','interactive_existing_site','wrong_key_preserves','unsafe_config',
                        'symlink_config','failed_save_preserves_pair', 'reuse_pinned_key', 'unsafe_pinned_key', 'corrupt_pinned_key'):
            keydir.mkdir(mode=0o700, exist_ok=True)
            oldkey.write_bytes(b'previous custom trusted key bytes')
            oldkey.chmod(0o600)
            original = f'SOURCE=https://old.example/release\nKEYRING={oldkey}\nHEALTH_URL=https://site.example/health.php\n'
            if scenario in ('existing_saved_site','interactive_existing_site'):
                original = f'SOURCE=https://old.example/release\nKEYRING={oldkey}\nHEALTH_URL=auto\nSITE={other_record}\n'
            config.write_text(original)
            config.chmod(0o600)
        if scenario in ('reuse_pinned_key', 'unsafe_pinned_key', 'corrupt_pinned_key'):
            keydir.mkdir(mode=0o700, exist_ok=True)
            pinned=keydir/f'release-{key_hash}.gpg'
            pinned.write_bytes(fixture_key)
            pinned.chmod(0o600)
            if scenario=='unsafe_pinned_key':
                pinned.chmod(0o666)
            if scenario=='corrupt_pinned_key':
                pinned.write_bytes(b'wrong pinned key')
        if scenario == 'unsafe_config':
            config.chmod(0o666)
        if scenario == 'unsafe_keydir':
            keydir.mkdir(mode=0o777)
            keydir.chmod(0o777)
        if scenario == 'symlink_config':
            dest=home/'real.conf'
            config.rename(dest)
            config.symlink_to(dest)
        if scenario == 'symlink_keydir':
            real=home/'realkeys'
            real.mkdir(mode=0o700)
            keydir.symlink_to(real)
        copied=prefix.replace("config='/etc/bitrix-php-update.conf'", f"config='{config}'").replace("keydir='/etc/bitrix-php-update'", f"keydir='{keydir}'")
        stubs=r'''
profile_check() { return 0; }
need() { return 0; }
php() { printf '8.2.20'; }
validate_managed_site() {
    [[ "$1" = 'http|site.example|80|/var/www/site' || "$1" = 'http|other.example|80|/var/www/other' ]]
}
select_managed_site() {
    printf '%s\n%s\n' "$1" "$2" > "$SELECTION"
    case "$SCENARIO" in
        ambiguous_sites) echo fixture-ambiguous-use-site >&2; return 65 ;;
        selection_cancelled) echo fixture-site-selection-cancelled >&2; return 130 ;;
    esac
    case "$1" in
        ''|'http|site.example|80|/var/www/site') MANAGED_SITE='http|site.example|80|/var/www/site' ;;
        other.example|'http|other.example|80|/var/www/other') MANAGED_SITE='http|other.example|80|/var/www/other' ;;
        *) echo unexpected-site-selector >&2; return 65 ;;
    esac
}
http_check() {
    [ "$1" = auto ] && [ "$2" = 8.2.20 ] && validate_managed_site "$MANAGED_SITE" || return 1
    printf '%s\n' "$MANAGED_SITE" > "$PROBE"
    [ "$SCENARIO" != failed_health ]
}
safe_download() {
    if [ "$SCENARIO" = wrong_key_preserves ]; then printf 'wrong key' > "$2"; else cp "$FIXTURE_KEY" "$2"; fi
}
mv() {
    local destination
    for destination in "$@"; do :; done
    if [ "$SCENARIO" = failed_save_preserves_pair ] && [ "$destination" = "$CONFIG" ]; then echo fixture-save-failure >&2; return 1; fi
    command mv "$@"
}
setup_args=()
[ "$SCENARIO" != explicit_site ] || setup_args=(--site other.example)
setup_auto_update "${setup_args[@]}"
exit $?
'''
        command=home/'run.sh'
        fixture_file = home/'fixture-key.gpg'
        fixture_file.write_bytes(fixture_key)
        command.write_text(copied+'\n'+stubs,encoding='utf-8')
        selection = home/'selection'
        probe = home/'probe'
        master = slave = None
        if scenario == 'interactive_existing_site': master, slave = pty.openpty()
        child=subprocess.run(['/bin/bash',str(command)],stdin=slave if slave is not None else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                             timeout=5, env=dict(os.environ,SCENARIO=scenario,CONFIG=str(config),FIXTURE_KEY=str(fixture_file),
                                                 SELECTION=str(selection),PROBE=str(probe)))
        if master is not None:
            os.close(slave)
            os.close(master)
        output=child.stdout
        code=child.returncode
        try:
            if scenario in ('fresh','explicit_site','existing_saved_site','interactive_existing_site','existing_custom_source','reuse_pinned_key'):
                assert code==0, f'exit {code}'
                data=dict(line.split('=',1) for line in config.read_text().splitlines())
                assert data['SOURCE']==project_source, 'custom source paired with project key'
                assert data['HEALTH_URL']=='auto'
                expected_site = other_record if scenario in ('explicit_site','existing_saved_site') else site_record
                assert data['SITE']==expected_site
                assert probe.read_text().strip()==expected_site, 'saved site differs from checked site'
                selection_lines=selection.read_text().splitlines()
                assert selection_lines[1]==('0' if scenario=='interactive_existing_site' else '1'), 'wrong selection mode'
                if scenario=='interactive_existing_site': assert selection_lines[0]=='', 'interactive setup reused previous site'
                if scenario=='explicit_site': assert selection_lines[0]=='other.example'
                if scenario=='existing_saved_site': assert selection_lines[0]==other_record
                savedkey=Path(data['KEYRING'])
                assert hashlib.sha256(savedkey.read_bytes()).hexdigest()==key_hash
                assert stat.S_IMODE(config.stat().st_mode)==0o600
                assert stat.S_IMODE(savedkey.stat().st_mode)==0o600
                assert stat.S_IMODE(keydir.stat().st_mode)==0o700
            else:
                assert code!=0, 'expected refusal'
                expected = {
                    'wrong_key_preserves': 'Публичный ключ не совпадает',
                    'failed_health': 'Автоматическая проверка сайта не пройдена',
                    'ambiguous_sites': 'fixture-ambiguous-use-site',
                    'selection_cancelled': 'fixture-site-selection-cancelled',
                    'unsafe_config': 'Нужна конфигурация автоматического обновления в защищённом файле root',
                    'unsafe_keydir': 'Каталог /etc/bitrix-php-update должен принадлежать root',
                    'symlink_config': 'Нужна конфигурация автоматического обновления в защищённом файле root',
                    'symlink_keydir': 'Каталог /etc/bitrix-php-update должен принадлежать root',
                    'failed_save_preserves_pair': 'fixture-save-failure',
                    'unsafe_pinned_key': 'Небезопасный файл публичного ключа',
                    'corrupt_pinned_key': 'Сохранённый ключ выпуска повреждён',
                }[scenario]
                assert expected in output.decode(errors='replace'), 'wrong rejection branch: ' + expected
                if original:
                    assert config.read_text()==original, 'existing config changed on failed setup'
                    assert oldkey.read_bytes()==b'previous custom trusted key bytes', 'existing trusted key changed on failed setup'
                else:
                    assert not config.exists(), 'configuration created on refusal'
            print('PASS',scenario)
        except AssertionError as error:
            failures+=1
            print('FAIL',scenario, str(error))
            print(output.decode(errors='replace')[-1400:])
raise SystemExit(bool(failures))
