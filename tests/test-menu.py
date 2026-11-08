"""Регрессионные проверки меню в PTY: все переданные Bash действия перехватываются."""
import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile
import time

installer = pathlib.Path(sys.argv[1]).resolve(strict=True)
cases = [
    ('выбор по умолчанию открывает проверки и запускает быструю проверку', '\n\n0\n0\n', ['Проверки и диагностика', 'CALL|--check'], []),
    ('план во вложенном меню', '1\n2\n0\n0\n', ['CALL|--plan'], ['CALL|--check']),
    ('полный аудит без сети', '1\n3\n0\n0\n', ['CALL|--audit|--offline'], []),
    ('аудит с сетью', '1\n4\n0\n0\n', ['CALL|--audit'], ['CALL|--audit|--offline']),
    ('автоматическая временная проверка сайта', '1\n5\n0\n0\n',
     ['CALL|--check-site'], ['CALL|--check|--url']),
    ('Enter в меню обновлений по умолчанию открывает план', '2\n\n0\n0\n', ['CALL|--plan'], ['CALL|--build', 'CALL|--update', 'CALL|--auto-update', 'CALL|--setup-update', 'CALL|--prepare-release']),
    ('сборка требует явного выбора', '2\n4\n0\n0\n', ['CALL|--build|--builder'], []),
    ('сборка 8.3 требует явного выбора', '2\n7\n0\n0\n', ['CALL|--build|--builder|--branch|8.3'], []),
    ('отсутствие нового набора отменяет установку', '2\n5\n\n0\n0\n', ['Установка отменена'], ['CALL|--update']),
    ('обновление получает точные выбранные параметры', '2\n5\n/root/new rpms\n/root/old rpms\n/root/public.gpg\nhttps://site.test/health.php\n0\n0\n',
     ['CALL|--update|--rpm-dir|/root/new rpms|--rollback-dir|/root/old rpms|--rpm-keyring|/root/public.gpg|--url|https://site.test/health.php'], []),
    ('восстановление по умолчанию показывает состояние', '3\n\n0\n0\n', ['CALL|--status'], ['CALL|--rollback']),
    ('пустой идентификатор отменяет откат', '3\n2\n\n0\n0\n', ['Откат отменён'], ['CALL|--rollback']),
    ('идентификатор отката выбран', '3\n2\n20261107T100000Z-123\n0\n0\n', ['CALL|--rollback|--session|20261107T100000Z-123'], []),
    ('необязательный изолированный Python', '1\n7\n0\n0\n', ['CALL|--bootstrap-python'], []),
    ('сравнение отчётов из меню проверок', '1\n8\n0\n0\n', ['CALL|--compare-menu'], ['CALL|--audit', 'CALL|--update']),
    ('справка из главного меню', '4\n0\n', ['CALL|--help'], []),
    ('отсутствие старого набора отменяет установку', '2\n5\n/root/new\n\n0\n0\n', ['Установка отменена'], ['CALL|--update']),
    ('отсутствие ключа отменяет установку', '2\n5\n/root/new\n/root/old\n\n0\n0\n', ['Установка отменена'], ['CALL|--update']),
    ('пустой URL обновления запускает автоматическую проверку сайта', '2\n5\n/root/new\n/root/old\n/root/key\n\n0\n0\n',
     ['CALL|--update|--rpm-dir|/root/new|--rollback-dir|/root/old|--rpm-keyring|/root/key'], ['|--url', 'Установка отменена']),
    ('автоматическое обновление выбрано явно', '2\n2\n0\n0\n', ['CALL|--auto-update'], ['CALL|--build']),
    ('однократная настройка клиента', '2\n3\n0\n0\n', ['CALL|--setup-update'], ['CALL|--update']),
    ('подготовка выпуска получает точные параметры', '2\n6\n/root/new rpms\n/root/old rpms\n0123456789ABCDEF\n/root/release dir\n0\n0\n',
     ['CALL|--prepare-release|--new-rpm-dir|/root/new rpms|--old-rpm-dir|/root/old rpms|--signer|0123456789ABCDEF|--output|/root/release dir'], []),
    ('пустой каталог новых пакетов отменяет подготовку', '2\n6\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('выпуск 8.3 получает точные параметры', '2\n8\n/root/new\n/root/old\n0123456789ABCDEF\n/root/release83\n0\n0\n',
     ['CALL|--prepare-release|--new-rpm-dir|/root/new|--old-rpm-dir|/root/old|--signer|0123456789ABCDEF|--output|/root/release83|--branch|8.3'], []),
    ('пустой каталог старых пакетов отменяет подготовку', '2\n6\n/root/new\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('пустой ключ подписи отменяет подготовку', '2\n6\n/root/new\n/root/old\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('пустой выходной каталог отменяет подготовку', '2\n6\n/root/new\n/root/old\n0123456789ABCDEF\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('EOF при подготовке отменяет её', '2\n6\n/root/new\n', ['Подготовка'], ['CALL|--prepare-release']),
    ('неверный пункт меню', 'x\n0\n', ['Неизвестный пункт'], ['CALL|']),
    ('EOF во вложенном меню завершает меню', '1\n', ['Проверки и диагностика'], ['CALL|']),
]
with tempfile.TemporaryDirectory() as directory:
    env_file = pathlib.Path(directory) / 'env.sh'
    env_file.write_text("""bash() {
    shift
    if [ "${1:-}" = --menu-action ]; then shift; fi
    printf 'CALL'
    printf '|%s' "$@"
    printf '\\n'
}
""")
    env = dict(os.environ, BASH_ENV=str(env_file), TERM='xterm')
    failed = 0
    for name, inputs, expected, forbidden in cases:
        # Обёрнутые дочерние действия имеют безопасное продолжение [0] перед тем же
        # нумерованным ручным подменю. Лишний ввод безвреден для инструментов без обёртки.
        if inputs.endswith('0\n0\n'):
            inputs += '0\n'
        master, slave = pty.openpty()
        child = subprocess.Popen(['/bin/bash', str(installer)], stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        os.write(master, inputs.encode())
        if name.startswith('EOF'):
            os.write(master, b'\x04')
        result = bytearray()
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if select.select([master], [], [], .05)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                result.extend(chunk)
            elif child.poll() is not None:
                break
        if child.poll() is None:
            child.kill()
        returncode = child.wait()
        os.close(master)
        output = result.decode(errors='replace')
        valid = returncode == 0 and all(x in output for x in expected) and not any(x in output for x in forbidden)
        print(('PASS ' if valid else 'FAIL ') + name)
        if not valid:
            failed += 1
            print('код завершения', returncode)
            print(output[-2500:])
    sys.exit(bool(failed))
