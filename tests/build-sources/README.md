# Build/source regressions

The tests accept a complete installer plus both original SRPMs as arguments. They
contain no workstation paths, downloads, signing keys, or production installs.
Keep `test-build-sources.sh` beside `check-ffi-el7.sh`, and keep
`test-build-dispatch.py` beside `dispatch-entry.sh`.

Run only in a disposable CentOS 7 x86_64 Docker container. Every test requires
`BITRIX_TEST_DISPOSABLE=1` and `/.dockerenv`. Mount the installer and inputs read
only, keep network disabled during the tests, and give each invocation a fresh
writable scratch directory. The container root filesystem can remain read only;
`/tmp` and `/var/tmp` must be writable.

Required source tools: Bash 4.2, RPM 4.11 (`rpm-build`, including `rpmspec`), cpio,
GnuPG 2.0, tar/xz, patch, diffutils, coreutils, awk, grep, sed and GCC with EL7
glibc headers. The dispatch test additionally needs Python 2.7 or Python 3 and
all dependencies in the adapted PHP specs. Its disk-space guard needs at least
8,000 MiB free; a 12 GiB `/tmp` tmpfs satisfies this without reserving all memory.

```bash
export BITRIX_TEST_DISPOSABLE=1
bash tests/build-sources/test-build-sources.sh \
  /input/install.sh /input/php-8.2.35-1.remi.src.rpm \
  /input/php-8.3.36-1.remi.src.rpm /tmp/source-check
python tests/build-sources/test-build-dispatch.py \
  /input/install.sh /input/php-8.2.35-1.remi.src.rpm \
  /input/php-8.3.36-1.remi.src.rpm /tmp/dispatch-check
```

The source test executes real hash checks, SRPM extraction, GPG verification,
patch generation and `%prep` for both branches. It compiles the actual three FFI
directive comparisons with EL7 headers, rejects corrupt/wrong-branch SRPMs before
payload inspection, and checks pinned signing identities. For the identity
negative cases only, a test wrapper runs genuine GPG first, then substitutes a
disallowed signer/primary fingerprint at that boundary.

The dispatch test loads all definitions from the supplied full installer, invokes
its real `updater_dispatch`, and uses real pseudo-terminal confirmation, session
creation, source preparation and dependency checks. Only `rpmbuild -ba` is
replaced. The resulting artifact says `TEST ONLY` and is not an installable RPM.
It tests missing `--builder`, noninteractive invocation, declined confirmation,
unsupported branch, wrong-branch SRPM, explicit 8.3, and default 8.2 behavior.
These tests do not claim a real PHP compilation or runtime update/rollback.

`red-base83.sh` reproduces the historical rc9 failure after supplying the approved
8.3 profile as a standalone fixture. `check-ffi-el7.sh` also runs independently on
an extracted `ext/ffi/ffi.c` to demonstrate the unpatched EL7 compiler failure.
