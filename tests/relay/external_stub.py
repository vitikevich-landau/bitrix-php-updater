#!/usr/bin/env python3
"""Network/process boundary substitutes, used only by isolated relay tests."""
import json
import os
from pathlib import Path
import signal
import socket
import sys
import termios
import time

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["TESTROOT"])
scenario = os.environ["SCENARIO"]


def value(*flags):
    for index, arg in enumerate(args):
        for flag in flags:
            if arg == flag and index + 1 < len(args):
                return args[index + 1]
            if arg.startswith(flag + "="):
                return arg[len(flag) + 1:]
    return ""


def record(**extra):
    with (root / "trace.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps({"tool": tool, "args": args, **extra}) + "\n")


if tool == "curl":
    url = next((arg for arg in reversed(args) if arg.startswith("https://")), "")
    output = value("--output", "-o")
    writeout = value("--write-out", "-w")
    proxy = value("--socks5-hostname", "--proxy", "-x")
    record(url=url, proxy=proxy, proxies={key: os.environ.get(key) for key in
           ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "no_proxy")})
    code, status = 0, "200"
    if scenario == "http404":
        code, status = 22, "404"
    elif scenario == "write-error":
        code, status = 23, "200"
    elif not proxy and scenario not in ("direct", "empty") and "remirepo.net" not in url and not (scenario == "late-fallback" and url.endswith("/direct-first")):
        code, status = (22, "403") if scenario == "http403" else (7, "000")
    elif proxy and scenario == "proxy-fail":
        code, status = 56, "000"
    if output:
        Path(output).write_bytes(b"" if scenario == "empty" else
                                 b"downloaded bytes\n" if code == 0 else b"partial download\n")
    if proxy and scenario.startswith("signal"):
        record(phase="holding-download")
        time.sleep(30)
    sys.stdout.write(writeout.replace("%{http_code}", status).replace("\\n", "\n"))
    sys.exit(code)

if tool == "ssh-keyscan":
    record()
    if scenario == "scan-fail":
        sys.exit(1)
    print("[31.130.132.194]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRlc3RmaXh0dXJl")
    sys.exit(0)

if tool == "ssh-keygen":
    record()
    fingerprint = ("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" if scenario == "wrong-key"
                   else "DXlwUOYrx9brdSSIW72VQL4CGvS/5G8onnqri6LBflg")
    print("256 SHA256:" + fingerprint + " fixture (ED25519)")
    sys.exit(0)

if tool == "ss":
    record()
    sys.exit(0)

if tool == "ssh":
    control = value("-S")
    command = value("-O")
    active = root / "active-ssh"
    if command == "check":
        record(phase="check")
        sys.exit(0 if active.exists() else 255)
    if command == "exit":
        record(phase="stop")
        active.unlink(missing_ok=True)
        if control:
            Path(control).unlink(missing_ok=True)
        sys.exit(0)
    descriptors = []
    for fd in Path("/proc/self/fd").iterdir():
        try:
            descriptors.append(os.readlink(fd))
        except FileNotFoundError:
            pass
    record(phase="start", descriptors=descriptors)
    tty = os.open("/dev/tty", os.O_RDWR)
    old = termios.tcgetattr(tty)
    hidden = termios.tcgetattr(tty)
    hidden[3] &= ~termios.ECHO
    termios.tcsetattr(tty, termios.TCSANOW, hidden)
    try:
        os.write(tty, b"FAKE RELAY PASSWORD: ")
        password = os.read(tty, 256).decode().rstrip("\r\n")
    finally:
        termios.tcsetattr(tty, termios.TCSANOW, old)
        os.write(tty, b"\n")
        os.close(tty)
    if password != "tests-only-secret" or scenario == "bad-password":
        sys.exit(255)
    if not control:
        print("Expected explicit SSH control socket", file=sys.stderr)
        sys.exit(99)
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(control)
    sock.close()
    active.write_text("running\n")
    record(phase="authenticated", forward=value("-D"))
    sys.exit(0)

raise SystemExit("Unexpected external tool " + tool)
