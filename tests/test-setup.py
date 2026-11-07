"""Setup tests in isolated /root directories; downloads and website are mocked.

Only the copied test function uses a fixture key hash. No release key is read.
"""
import hashlib
import os
import re
import sys
from pathlib import Path
import pty
import select
import stat
import subprocess
import tempfile
import time

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
for scenario in ('fresh', 'existing_custom_source', 'wrong_key_preserves', 'failed_health',
                 'cancel', 'unsafe_config', 'unsafe_keydir', 'symlink_config', 'symlink_keydir',
                 'failed_save_preserves_pair', 'reuse_pinned_key', 'unsafe_pinned_key', 'corrupt_pinned_key'):
    with tempfile.TemporaryDirectory(dir='/root') as directory:
        home = Path(directory)
        config = home/'update.conf'
        keydir = home/'keys'
        oldkey = keydir/'release-keyring.gpg'
        original = None
        if scenario in ('existing_custom_source','wrong_key_preserves','unsafe_config',
                        'symlink_config','failed_save_preserves_pair', 'reuse_pinned_key', 'unsafe_pinned_key', 'corrupt_pinned_key'):
            keydir.mkdir(mode=0o700, exist_ok=True)
            oldkey.write_bytes(b'previous custom trusted key bytes')
            oldkey.chmod(0o600)
            original = f'SOURCE=https://old.example/release\nKEYRING={oldkey}\nHEALTH_URL=https://site.example/health.php\n'
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
http_check() { [ "$SCENARIO" != failed_health ]; }
safe_download() {
    if [ "$SCENARIO" = wrong_key_preserves ]; then printf 'wrong key' > "$2"; else cp "$FIXTURE_KEY" "$2"; fi
}
mv() {
    local destination
    for destination in "$@"; do :; done
    if [ "$SCENARIO" = failed_save_preserves_pair ] && [ "$destination" = "$CONFIG" ]; then echo fixture-save-failure >&2; return 1; fi
    command mv "$@"
}
setup_auto_update
exit $?
'''
        command=home/'run.sh'
        fixture_file = home/'fixture-key.gpg'
        fixture_file.write_bytes(fixture_key)
        command.write_text(copied+'\n'+stubs,encoding='utf-8')
        inputs='https://site.example/health.php\n'+('CANCEL\n' if scenario=='cancel' else 'СОХРАНИТЬ НАСТРОЙКИ\n')
        if scenario=='existing_custom_source':
            inputs='\nСОХРАНИТЬ НАСТРОЙКИ\n'
        master,slave=pty.openpty()
        child=subprocess.Popen(['/bin/bash',str(command)],stdin=slave,stdout=slave,stderr=slave,
                               env=dict(os.environ,SCENARIO=scenario,CONFIG=str(config),FIXTURE_KEY=str(fixture_file)))
        os.close(slave)
        os.write(master,inputs.encode())
        output=bytearray()
        until=time.monotonic()+5
        while time.monotonic()<until:
            if select.select([master],[],[],.05)[0]:
                try: chunk=os.read(master,65536)
                except OSError: break
                if not chunk: break
                output.extend(chunk)
            elif child.poll() is not None: break
        if child.poll() is None: child.kill()
        code=child.wait()
        os.close(master)
        try:
            if scenario in ('fresh','existing_custom_source','reuse_pinned_key'):
                assert code==0, f'exit {code}'
                data=dict(line.split('=',1) for line in config.read_text().splitlines())
                assert data['SOURCE']==project_source, 'custom source paired with project key'
                assert data['HEALTH_URL']=='https://site.example/health.php'
                savedkey=Path(data['KEYRING'])
                assert hashlib.sha256(savedkey.read_bytes()).hexdigest()==key_hash
                assert stat.S_IMODE(config.stat().st_mode)==0o600
                assert stat.S_IMODE(savedkey.stat().st_mode)==0o600
                assert stat.S_IMODE(keydir.stat().st_mode)==0o700
            else:
                assert code!=0, 'expected refusal'
                expected = {
                    'wrong_key_preserves': 'Публичный ключ не совпадает',
                    'failed_health': 'Сначала настройте закрытый веб-тест',
                    'cancel': 'Операция отменена',
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
