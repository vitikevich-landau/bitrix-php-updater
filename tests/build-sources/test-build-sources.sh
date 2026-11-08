#!/usr/bin/env bash
# Public regression: no downloads, installation, or private keys.
# Usage: BITRIX_TEST_DISPOSABLE=1 bash test-build-sources.sh INSTALLER SRPM82 SRPM83 OUTPUT
# Requires an isolated CentOS 7 x86_64 container with rpm-build, cpio, GnuPG and xz.
# Keep OUTPUT writable and the installer/SRPM mounts read-only.
set -o pipefail
umask 077
export LC_ALL=C
if [[ ${BITRIX_TEST_DISPOSABLE:-} != 1 || ! -f /.dockerenv ]]; then
    echo 'Refusing: run in a disposable Docker container with BITRIX_TEST_DISPOSABLE=1.' >&2
    exit 2
fi
[[ $# == 4 ]] || { echo 'Usage: test-build-sources.sh INSTALLER SRPM82 SRPM83 OUTPUT' >&2; exit 2; }
installer=$(readlink -f -- "$1") || exit
srpm82=$(readlink -f -- "$2") || exit
srpm83=$(readlink -f -- "$3") || exit
mkdir -p -- "$4" || exit
output=$(readlink -f -- "$4") || exit
[[ -f $installer && -f $srpm82 && -f $srpm83 ]] || exit 2
# Load every definition from the complete installer, stopping before its CLI.
awk '/^# Мутирующие операции:/ {exit} {print}' "$installer" > "$output/library.sh" || exit
source "$output/library.sh"
platform_check || exit
WORK_ROOT="$output/work"
mkdir -p -- "$WORK_ROOT" || exit
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
declare -F set_php_target >/dev/null || fail 'installer has no branch selection'

# Break caught: hard-coded php82.spec, patch filename, source hash or GPG signer.
for branch in 8.2 8.3; do
    if [[ $branch == 8.2 ]]; then version=8.2.35; spec=php82.spec; srpm="$srpm82"; else version=8.3.36; spec=php83.spec; srpm="$srpm83"; fi
    set_php_target "$branch" || fail "select $branch"
    target="$output/source-$branch"
    source_prepare "$target" "$srpm" > "$output/source-$branch.log" 2>&1 || fail "real source_prepare $branch (see source-$branch.log)"
    [[ -f "$target/topdir" ]] || fail "$branch did not finish %prep"
    [[ $(cat "$target/topdir") == "$target/rpmbuild" ]] || fail "$branch wrong topdir"
    [[ -s "$target/rpmbuild/SOURCES/php-$version-openssl102-asn1.patch" ]] || fail "$branch patch artifact"
    grep -q 'OpenSSL 1.0.2 compatibility (EL7)' "$target/rpmbuild/BUILD/php-$version/ext/openssl/xp_ssl.c" || fail "$branch patch not applied by real %prep"
    [[ $(rpm -q --qf '%{VERSION}|%{RELEASE}' --specfile "$target/rpmbuild/SPECS/$spec" | head -c 16) == "$version|1.el7.1"* ]] || fail "$branch unexpected spec version/release"
    rpm -q --requires --specfile "$target/rpmbuild/SPECS/$spec" > "$target/runtime-requires.txt" || fail "$branch spec query"
    if [[ $branch == 8.3 ]]; then
        rpmspec -q --buildrequires "$target/rpmbuild/SPECS/$spec" > "$target/build-requires.txt" || fail "$branch build requires"
        grep -Fx 'unixODBC-devel' "$target/build-requires.txt" >/dev/null || fail '8.3 EL7 unixODBC requirement absent'
        ! grep -Fx 'pkgconfig(odbc)' "$target/build-requires.txt" >/dev/null || fail '8.3 retains unavailable EL7 odbc.pc'
        bash "$(dirname "$0")/check-ffi-el7.sh" "$target/rpmbuild/BUILD/php-$version/ext/ffi/ffi.c" "$target/ffi-compile-proof" > "$target/ffi-compile-proof.log" 2>&1 || fail '8.3 FFI directive comparisons do not compile with EL7 glibc'
    fi
    pass "$branch real SRPM extraction, SHA-256, GPG, compatibility patch and %prep"
done

# Break caught: trusting any successful signature, or checking only an 8.3 subkey
# without its pinned primary key. The boundary runs real GPG before substituting
# an unapproved signer field; no private key or forged cryptography is involved.
gpg() {
    if [[ " $* " == *' --verify '* ]]; then
        local verified
        verified="$(command gpg "$@")" || return
        printf '%s\n' "$verified" | awk -v field="$invalid_gpg_field" '
            /^\[GNUPG:\] VALIDSIG / { if (field == "signer") $3="0000000000000000000000000000000000000000"; else $12="0000000000000000000000000000000000000000" }
            {print}
        '
    else
        command gpg "$@"
    fi
}
for test_case in 8.2:signer 8.3:signer 8.3:primary; do
    branch=${test_case%:*}
    invalid_gpg_field=${test_case#*:}
    set_php_target "$branch" || exit
    if [[ $branch == 8.2 ]]; then srpm="$srpm82"; else srpm="$srpm83"; fi
    target="$output/gpg-$branch-$invalid_gpg_field"
    if source_prepare "$target" "$srpm" > "$target.log" 2>&1; then fail "$test_case unapproved GPG field accepted"; fi
    [[ ! -f "$target/topdir" && ! -f "$target/prep.log" ]] || fail "$test_case reached %prep"
    grep -q 'Неожиданный ключ подписи PHP' "$target.log" || fail "$test_case failed for unrelated reason"
    pass "$test_case rejects unapproved GPG identity before %prep"
done
unset -f gpg

# Break caught: extraction before the full SRPM trust check.
cp -- "$srpm83" "$output/corrupt.src.rpm" || exit
printf 'corruption' >> "$output/corrupt.src.rpm"
set_php_target 8.3 || exit
if source_prepare "$output/corrupt" "$output/corrupt.src.rpm" > "$output/corrupt.log" 2>&1; then fail 'corrupt SRPM accepted'; fi
[[ ! -e "$output/corrupt/source-entries.txt" ]] || fail 'corrupt SRPM payload was inspected'
[[ -z $(find "$output/corrupt/rpmbuild/SOURCES" -mindepth 1 -print -quit) ]] || fail 'corrupt SRPM extracted'
pass 'corrupt SRPM refused before payload inspection or extraction'

# Break caught: selected branch accidentally accepting another branch SRPM.
for branch in 8.2 8.3; do
    set_php_target "$branch" || exit
    if [[ $branch == 8.2 ]]; then srpm="$srpm83"; else srpm="$srpm82"; fi
    if source_prepare "$output/wrong-$branch" "$srpm" > "$output/wrong-$branch.log" 2>&1; then fail "wrong SRPM branch accepted for $branch"; fi
    [[ ! -e "$output/wrong-$branch/source-entries.txt" ]] || fail "wrong branch payload inspected for $branch"
    pass "$branch refuses other branch SRPM before extraction"
done
printf 'Source regressions complete. Evidence: %s\n' "$output"
