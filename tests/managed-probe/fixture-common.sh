# Подключается только тестами одноразового контейнера с явным разрешением запуска.
if [ "${BITRIX_DISPOSABLE_TEST:-}" != 1 ]; then
    printf '%s\n' 'Отказ: эти тесты изменяют конфигурацию Apache и каталоги тестовых сайтов.' 'Используйте одноразовый контейнер CentOS 7 с BITRIX_DISPOSABLE_TEST=1; не запускайте на клиентском сервере.' >&2
    exit 2
fi
[ "$(id -u)" = 0 ] || { echo 'Для одноразового тестового стенда нужны права root внутри контейнера.' >&2; exit 2; }
[ "$#" -eq 1 ] || { echo 'Передайте путь к полному установщику единственным аргументом.' >&2; exit 2; }
INSTALLER="$(readlink -e -- "$1")" || exit 2
[ -f "$INSTALLER" ] || exit 2
[ "$(grep -c '^# Мутирующие операции:' "$INSTALLER")" = 1 ] || { echo 'Граница диспетчера установщика не найдена.' >&2; exit 2; }
TEST_SUITE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
source <(sed '/^# Мутирующие операции:/,$d' "$INSTALLER")
declare -F managed_http_check managed_probe_cleanup_stale >/dev/null || { echo 'Отсутствует реализация временной веб-проверки.' >&2; exit 2; }
