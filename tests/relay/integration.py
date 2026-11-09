#!/usr/bin/env python3
"""Real SSH/SOCKS integration in one disposable Linux container.

The server and its generated identity exist only on container loopback. Test
credentials are deliberately public fixtures. Only direct curl is replaced with
a connection-failed result; the real installer, SSH client, password terminal,
control socket, SOCKS curl, downloads and cleanup run unchanged.
"""
import errno
import hashlib
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

INSTALLER = Path(sys.argv.pop(1)).resolve()
PREFIX = INSTALLER.read_text(encoding="utf-8").split("# Мутирующие операции:", 1)[0]
PASSWORD = "Rly123"  # Public, disposable fixture; never a production credential.
RAW = "https://raw.githubusercontent.com/vitikevich-landau/bitrix-php-updater/main/release-keyring.gpg"
RELEASE = "https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.3.36-el7-r1/OLD-SHA256SUMS"


def live_process(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][0] != "Z"
    except FileNotFoundError:
        return False


def terminal_run(command, env, password, interrupt=False):
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvpe(command[0], command, env)
    chunks = []
    deadline = time.monotonic() + 150
    sent = 0
    signaled = False
    status = None
    try:
        while time.monotonic() < deadline:
            if select.select([terminal], [], [], 0.05)[0]:
                try:
                    chunk = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            output = b"".join(chunks)
            prompts = output.count(b"password:")
            while sent < prompts:
                os.write(terminal, password.encode() + b"\n")
                sent += 1
            if interrupt and not signaled and b"READY-FOR-TERM" in output:
                os.killpg(pid, signal.SIGTERM)
                signaled = True
            found, value = os.waitpid(pid, os.WNOHANG)
            if found:
                status = value
                break
        else:
            os.killpg(pid, signal.SIGKILL)
            raise AssertionError("PTY timed out: " + b"".join(chunks).decode("utf-8", "replace"))
        if status is None:
            _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), b"".join(chunks).decode("utf-8", "replace"), sent
    finally:
        os.close(terminal)


class RealSSHRelay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.getuid() != 0 or os.environ.get("BITRIX_DISPOSABLE_TEST") != "1":
            raise RuntimeError("Run only as root inside the documented disposable test container")
        cls.server_directory = tempfile.TemporaryDirectory(prefix="relay-sshd-")
        cls.server = Path(cls.server_directory.name)
        hostkey = cls.server / "hostkey"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(hostkey)], check=True)
        cls.fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(hostkey), "-E", "sha256"], text=True).split()[1]
        hashed = subprocess.check_output(["openssl", "passwd", "-6", "-stdin"], input=PASSWORD + "\n", text=True)
        subprocess.run(["chpasswd", "-e"], input="relay:" + hashed, text=True, check=True)
        config = cls.server / "sshd_config"
        config.write_text(f"""Port 2222
ListenAddress 127.0.0.1
HostKey {hostkey}
PidFile {cls.server}/sshd.pid
AllowUsers relay
PermitRootLogin no
PasswordAuthentication yes
AuthenticationMethods password
PubkeyAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 0
ForceCommand /bin/false
AllowTcpForwarding local
AllowStreamLocalForwarding no
PermitOpen github.com:443 raw.githubusercontent.com:443 release-assets.githubusercontent.com:443
PermitListen none
AllowAgentForwarding no
PermitTTY no
X11Forwarding no
PermitTunnel no
PermitUserRC no
UseDNS no
PerSourcePenalties no
LogLevel VERBOSE
""", encoding="utf-8")
        # Repeated negative tests share one loopback IP; rate penalties are not
        # the subject of this client integration test.
        cls.server_log = open(cls.server / "server.log", "wb")
        cls.daemon = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=cls.server_log, stderr=cls.server_log)
        for _ in range(100):
            if cls.daemon.poll() is not None:
                raise RuntimeError((cls.server / "server.log").read_text())
            try:
                with socket.create_connection(("127.0.0.1", 2222), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Local test sshd did not start")

    @classmethod
    def tearDownClass(cls):
        cls.daemon.terminate()
        cls.daemon.wait(timeout=10)
        cls.server_log.close()
        cls.server_directory.cleanup()

    def run_case(self, *, wrong=False, interrupt=False):
        with tempfile.TemporaryDirectory(prefix="relay-client-") as directory:
            root = Path(directory)
            library = root / "functions.sh"
            library.write_text(PREFIX, encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(r'''
source "$LIBRARY"
RELAY_HOST=127.0.0.1
RELAY_SSH_PORT=2222
RELAY_FINGERPRINT=$FIXTURE_FINGERPRINT
curl() {
    local arg proxied=0
    for arg in "$@"; do
        [ "$arg" != --socks5-hostname ] || proxied=1
    done
    if [ "$proxied" = 0 ]; then
        printf 'direct-blocked\n' >> "$TESTROOT/transports"
        printf '000'
        return 7
    fi
    printf 'socks\n' >> "$TESTROOT/transports"
    command curl "$@"
}
setup_phase() (
    trap 'printf "setup-cleaned\n" > "$TESTROOT/setup-exit"' EXIT
    safe_download "$RAW_URL" "$TESTROOT/keyring"
)
prepare_phase() (
    trap 'printf "prepare-cleaned\n" > "$TESTROOT/prepare-exit"' EXIT
    safe_download "$RELEASE_URL" "$TESTROOT/manifest"
)
operation() {
    printf '%s\n' "$RELAY_STATE" > "$TESTROOT/context"
    setup_phase || return
    command ssh -F /dev/null -S "$RELAY_STATE/control" -O check -p 2222 relay@127.0.0.1 2> "$TESTROOT/master-check" || return
    master_pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' "$TESTROOT/master-check")
    ls -l "/proc/$master_pid/fd" > "$TESTROOT/master-fds"
    if [ "$INTERRUPT" = 1 ]; then
        printf 'READY-FOR-TERM\n'
        while :; do sleep 1; done
    fi
    prepare_phase
}
# Match updater logging and its protected result/lock descriptors. A leaked
# descriptor in background SSH would retain the lock or keep tee alive.
exec 9> "$TESTROOT/update.lock"
flock -n 9 || exit 95
exec 3> "$TESTROOT/menu-channel"
exec > >(tee "$TESTROOT/run.log" 9>&- 3>&-) 2>&1
with_download_context operation
exit $?
''', encoding="utf-8")
            env = {**os.environ, "LIBRARY": str(library), "TESTROOT": str(root),
                   "FIXTURE_FINGERPRINT": self.fingerprint, "RAW_URL": RAW,
                   "RELEASE_URL": RELEASE, "INTERRUPT": "1" if interrupt else "0"}
            code, output, prompts = terminal_run(["bash", str(driver)], env,
                                                  "wrong1" if wrong else PASSWORD, interrupt)
            self.assertNotIn(PASSWORD, output, "Password was echoed into terminal output")
            self.assertNotIn(PASSWORD, (root / "run.log").read_text(), "Password entered updater log")
            context = Path((root / "context").read_text().strip())
            self.assertFalse(context.exists(), f"Relay state leaked: {context}\n{output}")
            self.assertEqual(subprocess.run(["flock", "-n", str(root / "update.lock"), "true"]).returncode, 0,
                             "Background SSH retained updater lock")
            check = root / "master-check"
            if check.exists():
                pid = int(re.search(r"pid=(\d+)", check.read_text()).group(1))
                for _ in range(100):
                    if not live_process(pid):
                        break
                    time.sleep(0.02)
                self.assertFalse(live_process(pid), f"SSH master {pid} survived operation cleanup")
                fds = (root / "master-fds").read_text()
                self.assertNotIn(str(root / "update.lock"), fds)
                self.assertNotIn(str(root / "menu-channel"), fds)
            transports = (root / "transports").read_text().splitlines()
            if wrong:
                self.assertNotEqual(code, 0, output)
                self.assertEqual(prompts, 3, output)
                self.assertEqual(transports, ["direct-blocked"])
                self.assertFalse((root / "keyring").exists())
                self.assertFalse((root / "keyring.part").exists())
            elif interrupt:
                self.assertNotEqual(code, 0, output)
                self.assertEqual(prompts, 1, output)
                self.assertEqual(transports, ["direct-blocked", "socks"])
            else:
                self.assertEqual(code, 0, output)
                self.assertEqual(prompts, 1, output)
                self.assertEqual(transports, ["direct-blocked", "socks", "socks"])
                expected = re.search(r"local expected_key='([0-9a-f]{64})'", PREFIX).group(1)
                self.assertEqual(hashlib.sha256((root / "keyring").read_bytes()).hexdigest(), expected)
                manifest = (root / "manifest").read_text()
                self.assertGreater(len(manifest.splitlines()), 0)
                self.assertTrue(all(re.match(r"^[0-9a-f]{64}  [^/]+\.rpm$", line) for line in manifest.splitlines()), manifest)
                self.assertTrue((root / "setup-exit").exists())
                self.assertTrue((root / "prepare-exit").exists())
                print(f"Verified actual raw key ({(root / 'keyring').stat().st_size} bytes) and release catalog ({(root / 'manifest').stat().st_size} bytes) through one SSH login", flush=True)

    def test_real_ssh_password_socks_downloads_and_cleanup(self):
        self.run_case()

    def test_real_wrong_password_has_no_download_and_no_tunnel(self):
        self.run_case(wrong=True)

    def test_real_term_closes_background_master(self):
        self.run_case(interrupt=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
