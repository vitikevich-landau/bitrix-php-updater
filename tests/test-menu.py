"""PTY menu regression tests: all delegated Bash actions are intercepted."""
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
    ('default enters checks and runs quick check', '\n\n0\n0\n', ['Проверки и диагностика', 'CALL|--check'], []),
    ('nested plan', '1\n2\n0\n0\n', ['CALL|--plan'], ['CALL|--check']),
    ('offline full audit', '1\n3\n0\n0\n', ['CALL|--audit|--offline'], []),
    ('online audit', '1\n4\n0\n0\n', ['CALL|--audit'], ['CALL|--audit|--offline']),
    ('automatic temporary website check', '1\n5\n0\n0\n',
     ['CALL|--check-site'], ['CALL|--check|--url']),
    ('updates enter defaults to plan', '2\n\n0\n0\n', ['CALL|--plan'], ['CALL|--build', 'CALL|--update', 'CALL|--auto-update', 'CALL|--setup-update', 'CALL|--prepare-release']),
    ('builder remains explicit', '2\n4\n0\n0\n', ['CALL|--build|--builder'], []),
    ('8.3 builder is explicit', '2\n7\n0\n0\n', ['CALL|--build|--builder|--branch|8.3'], []),
    ('missing new bundle cancels', '2\n5\n\n0\n0\n', ['Установка отменена'], ['CALL|--update']),
    ('update takes exact chosen inputs', '2\n5\n/root/new rpms\n/root/old rpms\n/root/public.gpg\nhttps://site.test/health.php\n0\n0\n',
     ['CALL|--update|--rpm-dir|/root/new rpms|--rollback-dir|/root/old rpms|--rpm-keyring|/root/public.gpg|--url|https://site.test/health.php'], []),
    ('recovery defaults to status', '3\n\n0\n0\n', ['CALL|--status'], ['CALL|--rollback']),
    ('empty rollback id cancels', '3\n2\n\n0\n0\n', ['Откат отменён'], ['CALL|--rollback']),
    ('rollback id chosen', '3\n2\n20261107T100000Z-123\n0\n0\n', ['CALL|--rollback|--session|20261107T100000Z-123'], []),
    ('optional isolated Python', '1\n7\n0\n0\n', ['CALL|--bootstrap-python'], []),
    ('help from main', '4\n0\n', ['CALL|--help'], []),
    ('missing old bundle cancels', '2\n5\n/root/new\n\n0\n0\n', ['Установка отменена'], ['CALL|--update']),
    ('missing keyring cancels', '2\n5\n/root/new\n/root/old\n\n0\n0\n', ['Установка отменена'], ['CALL|--update']),
    ('empty update URL uses automatic site test', '2\n5\n/root/new\n/root/old\n/root/key\n\n0\n0\n',
     ['CALL|--update|--rpm-dir|/root/new|--rollback-dir|/root/old|--rpm-keyring|/root/key'], ['|--url', 'Установка отменена']),
    ('automatic update selected explicitly', '2\n2\n0\n0\n', ['CALL|--auto-update'], ['CALL|--build']),
    ('one-time client setup', '2\n3\n0\n0\n', ['CALL|--setup-update'], ['CALL|--update']),
    ('prepare release exact inputs', '2\n6\n/root/new rpms\n/root/old rpms\n0123456789ABCDEF\n/root/release dir\n0\n0\n',
     ['CALL|--prepare-release|--new-rpm-dir|/root/new rpms|--old-rpm-dir|/root/old rpms|--signer|0123456789ABCDEF|--output|/root/release dir'], []),
    ('prepare empty new directory cancels', '2\n6\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('8.3 release exact inputs', '2\n8\n/root/new\n/root/old\n0123456789ABCDEF\n/root/release83\n0\n0\n',
     ['CALL|--prepare-release|--new-rpm-dir|/root/new|--old-rpm-dir|/root/old|--signer|0123456789ABCDEF|--output|/root/release83|--branch|8.3'], []),
    ('prepare empty old directory cancels', '2\n6\n/root/new\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('prepare empty signer cancels', '2\n6\n/root/new\n/root/old\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('prepare empty output cancels', '2\n6\n/root/new\n/root/old\n0123456789ABCDEF\n\n0\n0\n', ['Подготовка выпуска отменена'], ['CALL|--prepare-release']),
    ('EOF during prepare cancels', '2\n6\n/root/new\n', ['Подготовка'], ['CALL|--prepare-release']),
    ('invalid menu choice', 'x\n0\n', ['Неизвестный пункт'], ['CALL|']),
    ('EOF in child ends menu', '1\n', ['Проверки и диагностика'], ['CALL|']),
]
with tempfile.TemporaryDirectory() as directory:
    env_file = pathlib.Path(directory) / 'env.sh'
    env_file.write_text("""bash() {
    shift
    printf 'CALL'
    printf '|%s' "$@"
    printf '\\n'
}
""")
    env = dict(os.environ, BASH_ENV=str(env_file), TERM='xterm')
    failed = 0
    for name, inputs, expected, forbidden in cases:
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
            print('returncode', returncode)
            print(output[-2500:])
    sys.exit(bool(failed))
