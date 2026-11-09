#!/usr/bin/env python3
"""Relay orchestration tests using the real installer functions and external stubs.

Run inside a disposable Linux container:
  python -B tests/relay/test_transport.py /repo/install.sh
No connections to production hosts, services, or package installation occur.
"""
import json
import errno
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

INSTALLER = Path(sys.argv.pop(1)).resolve()
PREFIX = INSTALLER.read_text(encoding="utf-8").split("# Мутирующие операции:", 1)[0]
STUB = Path(__file__).with_name("external_stub.py")
GH_URL = "https://github.com/example/file"
RAW_URL = "https://raw.githubusercontent.com/example/file"


def pty_run(command, env, root, password="tests-only-secret", interrupt=""):
    """A real controlling terminal; send a password only after the SSH prompt."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(command[0], command, env)
    chunks = []
    deadline = time.monotonic() + 12
    password_sent = False
    interrupted = False
    status = None
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            chunks.append(chunk)
        if not password_sent and b"FAKE RELAY PASSWORD:" in b"".join(chunks):
            if interrupt == "cancel-auth":
                os.killpg(pid, signal.SIGINT)
            else:
                os.write(fd, password.encode() + b"\n")
            password_sent = True
        trace = root / "trace.jsonl"
        if interrupt.startswith("signal") and not interrupted and trace.exists() and 'holding-download' in trace.read_text():
            selected = {"signal": signal.SIGTERM, "signal-int": signal.SIGINT, "signal-hup": signal.SIGHUP}[interrupt]
            os.killpg(pid, selected)
            interrupted = True
        if status is None:
            found, value = os.waitpid(pid, os.WNOHANG)
            if found:
                # The operation runs in a subshell. Drain its PTY while its EXIT
                # cleanup completes, even if the outer test shell exited first.
                status = value
    else:
        os.killpg(pid, signal.SIGKILL)
    if status is None:
        _, status = os.waitpid(pid, 0)
    os.close(fd)
    return os.waitstatus_to_exitcode(status), b"".join(chunks).decode("utf-8", "replace")


class Result:
    def __init__(self, root, code, output):
        self.code, self.output = code, output
        trace = root / "trace.jsonl"
        self.trace = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
        self.files = {path.name: path.read_bytes() for path in root.glob("result*") if path.is_file()}
        self.active = (root / "active-ssh").exists()
        context = root / "context"
        self.context = context.read_text().strip() if context.exists() else ""
        self.context_exists = Path(self.context).exists() if self.context else False
        self.mode = (root / "mode").read_text().strip() if (root / "mode").exists() else ""
        after = root / "proxies-after"
        self.proxies_after = after.read_text() if after.exists() else ""

    def events(self, tool, phase=None):
        return [event for event in self.trace if event["tool"] == tool
                and (phase is None or event.get("phase") == phase)]


class DownloadTransport(unittest.TestCase):
    def run_case(self, scenario="fallback", body=None, tty=True, args=(), password="tests-only-secret"):
        if body is None:
            body = 'download_transport "' + GH_URL + '" "$TESTROOT/result"'
        with tempfile.TemporaryDirectory(prefix="relay-tests-") as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            for name in ("curl", "ssh", "ssh-keygen", "ssh-keyscan", "ss"):
                (root / "bin" / name).symlink_to(STUB)
            library = root / "library.sh"
            library.write_text(PREFIX, encoding="utf-8")
            script = root / "run.sh"
            script.write_text('''
source "$LIBRARY"
operation() {
    printf '%s\\n' "$RELAY_STATE" > "$TESTROOT/context"
    stat -c '%a' "$RELAY_STATE" > "$TESTROOT/mode"
''' + body + '''
}
with_download_context operation "$@"
result=$?
printf '%s|%s|%s\\n' "${https_proxy:-}" "${ALL_PROXY:-}" "${NO_PROXY:-}" > "$TESTROOT/proxies-after"
exit "$result"
''', encoding="utf-8")
            env = {**os.environ, "LIBRARY": str(library), "TESTROOT": str(root),
                   "SCENARIO": scenario, "PATH": str(root / "bin") + ":" + os.environ["PATH"],
                   "https_proxy": "http://existing-proxy.example:3128", "ALL_PROXY": "",
                   "NO_PROXY": "*", "TMPDIR": str(root)}
            command = ["bash", str(script), *args]
            if tty:
                code, output = pty_run(command, env, root, password=password, interrupt=scenario)
            else:
                process = subprocess.run(command, text=True, capture_output=True, env=env, timeout=12)
                code, output = process.returncode, process.stdout + process.stderr
            return Result(root, code, output)

    def assert_clean(self, result):
        self.assertFalse(result.active, result.output)
        self.assertFalse(result.context_exists, result.output)
        if result.context:
            self.assertEqual(result.mode, "700")
        self.assertNotIn("tests-only-secret", result.output)
        self.assertNotIn("tests-only-secret", json.dumps(result.trace))

    def test_direct_download_succeeds_without_ssh(self):
        with tempfile.TemporaryDirectory(prefix="relay-tests-") as temporary:
            root = Path(temporary)
            library = root / "library.sh"
            library.write_text(PREFIX, encoding="utf-8")
            script = root / "run.sh"
            script.write_text(r'''
source "$LIBRARY"
curl() {
    local output=''
    while (($#)); do
        case "$1" in --output|-o) output=$2; shift 2 ;; *) shift ;; esac
    done
    printf 'downloaded bytes\n' > "$output"
    printf '200'
}
ssh() { printf 'Unexpected SSH\n' >> "$TESTROOT/ssh-called"; return 99; }
operation() { download_transport 'https://github.com/example/file' "$TESTROOT/result"; }
with_download_context operation
''', encoding="utf-8")
            result = subprocess.run(["bash", str(script)], text=True, capture_output=True,
                                    env={**os.environ, "LIBRARY": str(library), "TESTROOT": str(root)},
                                    timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "result").read_text(), "downloaded bytes\n")
            self.assertFalse((root / "ssh-called").exists())

    def test_fallback_prompts_once_and_reuses_tunnel_in_sibling_subshells(self):
        result = self.run_case(body='''
(download_transport "''' + GH_URL + '''" "$TESTROOT/result1") || return
(download_transport "''' + RAW_URL + '''" "$TESTROOT/result2")
''')
        self.assertEqual(result.code, 0, result.output)
        self.assertEqual(result.files, {"result1": b"downloaded bytes\n", "result2": b"downloaded bytes\n"})
        self.assertEqual(len(result.events("ssh", "start")), 1, result.trace)
        self.assertEqual(result.output.count("FAKE RELAY PASSWORD:"), 1, result.output)
        self.assertEqual(len(result.events("ssh", "stop")), 1, result.trace)
        proxied = [event for event in result.events("curl") if event["proxy"]]
        self.assertEqual(len(proxied), 2, result.trace)
        for event in proxied:
            self.assertIn("--socks5-hostname", event["args"])
            i = event["args"].index("--noproxy")
            self.assertEqual(event["args"][i + 1], "")
        self.assertEqual(result.proxies_after, "http://existing-proxy.example:3128||*\n")
        self.assert_clean(result)

    def test_github_http403_can_use_relay(self):
        result = self.run_case("http403")
        self.assertEqual(result.code, 0, result.output)
        self.assertEqual(result.files["result"], b"downloaded bytes\n")
        self.assert_clean(result)

    def test_late_fallback_inside_redirected_manifest_loop_uses_controlling_terminal(self):
        result = self.run_case("late-fallback", body='''
download_transport 'https://github.com/example/direct-first' "$TESTROOT/result1" || return
printf '%s\\n' 'https://github.com/example/second' > "$TESTROOT/inventory"
while IFS= read -r asset; do
    (download_transport "$asset" "$TESTROOT/result2") || return
done < "$TESTROOT/inventory"
''')
        self.assertEqual(result.code, 0, result.output)
        self.assertEqual(result.files, {"result1": b"downloaded bytes\n", "result2": b"downloaded bytes\n"})
        self.assertEqual(len(result.events("ssh", "start")), 1, result.trace)
        self.assertEqual(result.output.count("FAKE RELAY PASSWORD:"), 1, result.output)
        self.assert_clean(result)

    def test_http404_does_not_prompt_or_connect_relay(self):
        result = self.run_case("http404")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertFalse(result.events("ssh", "start"), result.trace)
        self.assert_clean(result)

    def test_local_write_error_does_not_prompt_or_connect_relay(self):
        result = self.run_case("write-error")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertFalse(result.events("ssh", "start"), result.trace)
        self.assert_clean(result)

    def test_no_terminal_does_not_start_ssh(self):
        result = self.run_case(tty=False)
        self.assertNotEqual(result.code, 0, result.output)
        self.assertFalse(result.events("ssh", "start"), result.trace)
        self.assert_clean(result)

    def test_unattended_with_terminal_does_not_start_ssh(self):
        result = self.run_case(args=("--unattended",))
        self.assertNotEqual(result.code, 0, result.output)
        self.assertFalse(result.events("ssh", "start"), result.trace)
        self.assert_clean(result)

    def test_wrong_fingerprint_prevents_password_authentication(self):
        result = self.run_case("wrong-key")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertTrue(result.events("ssh-keygen"), result.trace)
        self.assertFalse(result.events("ssh", "start"), result.trace)
        self.assert_clean(result)

    def test_failed_key_scan_prevents_password_authentication(self):
        result = self.run_case("scan-fail")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertFalse(result.events("ssh", "start"), result.trace)
        self.assert_clean(result)

    def test_bad_password_does_not_issue_proxied_download(self):
        result = self.run_case("bad-password", password="wrong-password")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(len(result.events("ssh", "start")), 1, result.trace)
        self.assertFalse([event for event in result.events("curl") if event["proxy"]], result.trace)
        self.assert_clean(result)

    def test_relay_download_failure_closes_tunnel(self):
        result = self.run_case("proxy-fail")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(len(result.events("ssh", "stop")), 1, result.trace)
        self.assert_clean(result)

    def test_term_during_download_closes_tunnel(self):
        result = self.run_case("signal")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(len(result.events("ssh", "stop")), 1, result.trace)
        self.assert_clean(result)

    def test_ctrl_c_during_download_closes_tunnel(self):
        result = self.run_case("signal-int")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(len(result.events("ssh", "stop")), 1, result.trace)
        self.assert_clean(result)

    def test_hangup_during_download_closes_tunnel(self):
        result = self.run_case("signal-hup")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(len(result.events("ssh", "stop")), 1, result.trace)
        self.assert_clean(result)

    def test_cancelling_password_prompt_does_not_leave_a_tunnel(self):
        result = self.run_case("cancel-auth")
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(len(result.events("ssh", "start")), 1, result.trace)
        self.assertFalse([event for event in result.events("curl") if event["proxy"]], result.trace)
        self.assert_clean(result)

    def test_ssh_does_not_inherit_menu_channel_or_update_lock(self):
        result = self.run_case(body='''
exec 3> "$TESTROOT/menu-channel"
exec 9> "$TESTROOT/update-lock"
download_transport "''' + GH_URL + '''" "$TESTROOT/result"
''')
        self.assertEqual(result.code, 0, result.output)
        startup = result.events("ssh", "start")
        self.assertEqual(len(startup), 1, result.trace)
        for path in startup[0]["descriptors"]:
            self.assertFalse(path.endswith(("/menu-channel", "/update-lock")), path)
        self.assert_clean(result)

    def test_active_relay_does_not_proxy_other_hosts(self):
        result = self.run_case(body='''
download_transport "''' + GH_URL + '''" "$TESTROOT/result1" || return
download_transport 'https://rpms.remirepo.net/SRPMS/file' "$TESTROOT/result2"
''')
        self.assertEqual(result.code, 0, result.output)
        remi = [event for event in result.events("curl") if "remirepo.net" in event["url"]]
        self.assertEqual(len(remi), 1, result.trace)
        self.assertEqual(remi[0]["proxy"], "")
        self.assert_clean(result)

    def test_lookalike_and_credential_hosts_do_not_use_relay(self):
        for url in ("https://github.com.evil.example/file", "https://raw.githubusercontent.com.evil/file",
                    "https://user@github.com/file", "https://example.com/file"):
            with self.subTest(url=url):
                result = self.run_case(body='download_transport "' + url + '" "$TESTROOT/result"')
                self.assertNotEqual(result.code, 0, result.output)
                self.assertFalse(result.events("ssh", "start"), result.trace)
                self.assert_clean(result)

    def test_safe_download_publishes_only_completed_bytes(self):
        result = self.run_case(body='safe_download "' + GH_URL + '" "$TESTROOT/result"')
        self.assertEqual(result.code, 0, result.output)
        self.assertEqual(result.files, {"result": b"downloaded bytes\n"})
        self.assert_clean(result)

    def test_empty_download_does_not_replace_existing_file(self):
        result = self.run_case("empty", body='''
printf 'previous content\\n' > "$TESTROOT/result"
safe_download "''' + GH_URL + '''" "$TESTROOT/result"
''')
        self.assertNotEqual(result.code, 0, result.output)
        self.assertEqual(result.files["result"], b"previous content\n")
        self.assert_clean(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
