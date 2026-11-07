# Sourced only by explicitly opted-in disposable-container tests.
if [ "${BITRIX_DISPOSABLE_TEST:-}" != 1 ]; then
    printf '%s\n' 'Refusing: these tests modify Apache configuration and fixture web roots.' 'Use a disposable CentOS 7 container with BITRIX_DISPOSABLE_TEST=1; never a client server.' >&2
    exit 2
fi
[ "$(id -u)" = 0 ] || { echo 'The disposable fixture requires root inside its container.' >&2; exit 2; }
[ "$#" -eq 1 ] || { echo 'Pass the full installer path as the only argument.' >&2; exit 2; }
INSTALLER="$(readlink -e -- "$1")" || exit 2
[ -f "$INSTALLER" ] || exit 2
[ "$(grep -c '^# Мутирующие операции:' "$INSTALLER")" = 1 ] || { echo 'Installer dispatch boundary not found.' >&2; exit 2; }
TEST_SUITE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
source <(sed '/^# Мутирующие операции:/,$d' "$INSTALLER")
declare -F managed_http_check managed_probe_cleanup_stale >/dev/null || { echo 'Managed probe implementation is missing.' >&2; exit 2; }
