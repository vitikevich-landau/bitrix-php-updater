#!/usr/bin/env bash
# Bitrix Server Master 1.0.0-rc11 — диагностика и обновление PHP 8.2.35 / 8.3.36.
set -o pipefail
umask 077
export LC_ALL=C
MASTER_VERSION='1.0.0-rc11'
MANAGED_SITE=''
MENU_RESULT_ENABLED=0
PY_RELEASE='3.11.18'
PY_BUILD='20261026'
PY_ARTIFACT='cpython-3.11.18+20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz'
PY_SHA256='17c4978a36c496dc53c08899ef8dad1ad2734f6325f08d6033a1e66419e0af26'
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_BUILD}/${PY_ARTIFACT}"
SELF="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

help_ru() { update_help; }

# Private, opt-in channel to the interactive parent. Never parse human output or
# source these records; ordinary CLI invocations cannot enable it via environment.
menu_record() {
    [ "$MENU_RESULT_ENABLED" = 1 ] || return 0
    case "$1" in site|session|state|origin|web) ;; *) return 0 ;; esac
    case "$2" in *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;; esac
    { printf '%s\t%s\n' "$1" "$2" >&3; } 2>/dev/null || true
}

normalize_confirmation() {
    local answer="$1" letters
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    answer="${answer,,}"
    # При LC_ALL=C Bash меняет регистр только ASCII. Русские буквы заменяем явно.
    for letters in А:а Б:б В:в Г:г Д:д Е:е Ё:ё Ж:ж З:з И:и Й:й К:к Л:л М:м \
                   Н:н О:о П:п Р:р С:с Т:т У:у Ф:ф Х:х Ц:ц Ч:ч Ш:ш Щ:щ \
                   Ъ:ъ Ы:ы Ь:ь Э:э Ю:ю Я:я; do
        answer="${answer//${letters%:*}/${letters#*:}}"
    done
    printf '%s' "$answer"
}

confirm_action() {
    local label="$1" phrase="${2:-}" input normalized expected=''
    if [ -n "$phrase" ]; then
        expected="$(normalize_confirmation "$phrase")"
        printf 'Можно также ввести «%s» без учёта регистра.\n' "$phrase"
    fi
    while :; do
        printf '%s [y/N, да/нет]\n> ' "$label"
        if ! IFS= read -r input; then
            printf '\n'
            return 1
        fi
        normalized="$(normalize_confirmation "$input")"
        case "$normalized" in
            y|yes|да) return 0 ;;
            n|no|нет|'') return 1 ;;
        esac
        if [ -n "$expected" ] && [ "$normalized" = "$expected" ]; then
            return 0
        fi
        echo 'Введите y/yes/да для согласия или n/no/нет для отказа. Enter — отказ.'
    done
}

python_is_ok() {
    local c="$1"
    [ -n "$c" ] && [ -x "$c" ] || return 1
    "$c" -B -c 'import sys; sys.exit(0 if (3,8) <= sys.version_info[:2] < (4,0) else 1)' >/dev/null 2>&1
}

python_path() {
    local base candidate
    if [ "$(id -u)" = '0' ]; then
        base='/opt/bitrix-server-master'
    else
        base="${HOME:-/tmp}/.local/share/bitrix-server-master"
    fi
    candidate="$base/runtime-${PY_RELEASE}/bin/python3"
    if python_is_ok "$candidate"; then printf '%s' "$candidate"; return 0; fi
    for candidate in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
        if command -v "$candidate" >/dev/null 2>&1; then
            local found
            found="$(command -v "$candidate")"
            if python_is_ok "$found"; then printf '%s' "$found"; return 0; fi
        fi
    done
    return 1
}

bootstrap_python() {
    local archive="$1" base parent target tmp url result available_kb
    if [ ! -t 0 ]; then
        err 'установка Python требует интерактивного подтверждения в SSH.'
        return 5
    fi
    if [ "$(uname -s)" != 'Linux' ] || [ "$(uname -m)" != 'x86_64' ]; then
        err 'изолированный Python поддержан пока только для Linux x86_64.'
        return 5
    fi
    if ! command -v sha256sum >/dev/null || ! command -v tar >/dev/null || ! command -v mktemp >/dev/null; then
        err 'необходимы sha256sum, tar и mktemp.'
        return 5
    fi
    if [ "$(id -u)" = '0' ]; then
        base='/opt/bitrix-server-master'
    else
        base="${HOME:-/tmp}/.local/share/bitrix-server-master"
    fi
    target="$base/runtime-${PY_RELEASE}"
    if python_is_ok "$target/bin/python3"; then
        status_line ok "Изолированный Python уже установлен: $target/bin/python3"
        return 0
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        err "каталог уже существует, но Python не работает: $target"
        echo 'Автоматически чужие файлы не перезаписываем.' >&2
        return 5
    fi
    echo
    echo 'Предлагается установить отдельный Python 3.11.18.'
    echo "Место установки: $target"
    echo "Источник: ${archive:-$PY_URL}"
    echo "Ожидаемый SHA-256: $PY_SHA256"
    echo 'Системный /usr/bin/python, yum, PHP, Apache и конфигурации не изменяются.'
    echo 'Будет создан отдельный каталог и временные файлы для проверки архива.'
    if ! confirm_action 'Подтвердить установку?'; then
        status_line warning 'Отменено. Изменений нет.'
        return 4
    fi
    parent="$(dirname "$base")"
    if ! mkdir -p -- "$base"; then
        err "не удалось создать $base"
        return 5
    fi
    available_kb="$(df -Pk "$base" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$available_kb" ] && [ "$available_kb" -lt 300000 ] 2>/dev/null; then
        err 'для безопасной подготовки Python нужно минимум 300 МиБ свободно.'
        return 5
    fi
    tmp="$(mktemp -d "$base/.python-stage.XXXXXXXX")" || return 5
    if [ -n "$archive" ]; then
        if [ ! -f "$archive" ] || [ -L "$archive" ]; then
            err 'локальный архив не найден или является символической ссылкой.'
            rm -rf -- "$tmp"
            return 5
        fi
        if ! cp -- "$archive" "$tmp/archive.tar.gz"; then
            err 'не удалось скопировать локальный архив.'
            rm -rf -- "$tmp"
            return 5
        fi
    else
        if ! command -v curl >/dev/null 2>&1; then
            err 'curl отсутствует. Используйте --python-archive.'
            rm -rf -- "$tmp"
            return 5
        fi
        echo 'Скачивание Python по HTTPS (без -k / --insecure)...'
        if ! curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
                  --connect-timeout 12 --max-time 240 --output "$tmp/archive.tar.gz" "$PY_URL"; then
            err 'скачивание не удалось. Системные пакеты не тронуты.'
            rm -rf -- "$tmp"
            return 5
        fi
    fi
    if ! printf '%s  %s\n' "$PY_SHA256" "$tmp/archive.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
        err 'SHA-256 архива не совпал с закреплённым значением. Распаковка запрещена.'
        rm -rf -- "$tmp"
        return 5
    fi
    status_line ok 'Контрольная сумма совпала. Проверяю содержимое архива...'
    if ! tar -tzf "$tmp/archive.tar.gz" >"$tmp/entries" 2>/dev/null; then
        err 'неверный формат архива.'
        rm -rf -- "$tmp"
        return 5
    fi
    # Блокируем абсолютные пути и выход за пределы python/. Проверяем каждый компонент.
    if awk '/^\// || /(^|\/)\.\.($|\/)/ || !/^python\// {bad=1} END{exit bad}' "$tmp/entries"; then
        :
    else
        err 'архив содержит небезопасные пути.'
        rm -rf -- "$tmp"
        return 5
    fi
    if ! tar --no-same-owner --no-same-permissions -xzf "$tmp/archive.tar.gz" -C "$tmp"; then
        err 'не удалось распаковать архив.'
        rm -rf -- "$tmp"
        return 5
    fi
    if ! python_is_ok "$tmp/python/bin/python3"; then
        err 'проверка нового Python не прошла (возможно несовместимая ОС).'
        rm -rf -- "$tmp"
        return 5
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        err 'целевой каталог появился во время операции.'
        rm -rf -- "$tmp"
        return 5
    fi
    if ! mv -- "$tmp/python" "$target"; then
        err 'не удалось завершить развёртывание.'
        rm -rf -- "$tmp"
        return 5
    fi
    rm -rf -- "$tmp"
    status_line ok "Готово: $target/bin/python3"
    echo 'Системный Python и пакеты ОС не изменялись.'
    return 0
}

# Отдельный строго ограниченный диагностический режим для серверов без Python 3.
# Ничего не устанавливает; не опрашивает сетевые ресурсы.
fallback_diagnose() {
    local json=0 report='' check=0 offline=0 args=("$@") x osname= arch= phpv= bitrix= apache= nginx= droot= mem= hostname_local
    local os_id os_major first_version route
    for ((x=0;x<${#args[@]};x++)); do
        case "${args[x]}" in
            --json) json=1 ;;
            --report)
                report='AUTO'
                if [ $((x+1)) -lt ${#args[@]} ] && [[ "${args[x+1]}" != -* ]]; then
                    report="${args[x+1]}"; ((x++))
                fi ;;
            --report=*) report="${args[x]#*=}" ;;
            --check-updates) check=1 ;;
            --offline) offline=1 ;;
            --compare|--url) echo 'Без Python 3 этот режим недоступен. Используйте --bootstrap-python.' >&2; return 6 ;;
        esac
    done
    osname="$(sed -n '/^PRETTY_NAME=/{s/^PRETTY_NAME=//;s/^"//;s/"$//;p;q;}' /etc/os-release 2>/dev/null)"
    [ -n "$osname" ] || osname="$(uname -s)"
    arch="$(uname -m)"
    phpv="$(php -v 2>/dev/null | awk '$1 == "PHP" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+_-]*$/ && !found {print $2; found=1}')" || phpv=''
    [ -n "$phpv" ] || phpv='не обнаружен'
    select_php_target_for_version "$phpv" || true
    route="$(php_version_route "$phpv")"
    apache="$(systemctl is-active httpd 2>/dev/null || true)"
    nginx="$(systemctl is-active nginx 2>/dev/null || true)"
    droot="$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')"
    mem="$(awk '/^MemAvailable:/ {printf "%.0f МиБ", $2/1024}' /proc/meminfo 2>/dev/null)"
    bitrix='не обнаружен'
    [ -d /etc/httpd/bx ] || [ -d /home/bitrix/www/bitrix ] && bitrix='обнаружен (версия не проверена)'
    hostname_local="$(hostname 2>/dev/null || printf 'unknown')"
    # Escapes JSON without requiring Python or jq.
    json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s" | tr -d '\000-\037'; }
    local output
    output="$(printf '{"schema":"bitrix-server-master/fallback-v1","version":"%s","hostname":"%s","os":"%s","architecture":"%s","php_cli":"%s","bitrix":"%s","apache":"%s","nginx":"%s","root_free":"%s","mem_available":"%s","limited":true,"readonly":true,"web_php_confirmed":false,"update_status":"unknown"}' \
      "$MASTER_VERSION" "$(json_escape "$hostname_local")" "$(json_escape "$osname")" "$(json_escape "$arch")" "$(json_escape "$phpv")" "$(json_escape "$bitrix")" "$(json_escape "$apache")" "$(json_escape "$nginx")" "$(json_escape "$droot")" "$(json_escape "$mem")")"
    if [ "$json" -eq 1 ]; then
        printf '%s\n' "$output"
    else
        os_id="$(sed -n '/^ID=/{s/^ID=//;s/"//g;p;q;}' /etc/os-release 2>/dev/null)"
        os_major="$(sed -n '/^VERSION_ID=/{s/^VERSION_ID=//;s/"//g;s/\..*//;p;q;}' /etc/os-release 2>/dev/null)"
        echo '======================================================'
        echo "BITRIX SERVER MASTER $MASTER_VERSION — ОГРАНИЧЕННАЯ ДИАГНОСТИКА"
        echo '======================================================'
        if [ "$route" = unsupported ]; then
            status_line warning "PHP CLI $phpv — обновление этой ветки не поддерживается (только 8.2.x и 8.3.x)"
        elif [ "$route" = older ]; then
            status_line warning "PHP CLI $phpv — для перехода на PHP 8.2 нужен отдельный маршрут (--plan)"
        elif [[ "$phpv" == "$TARGET_PHP" ]]; then
            status_line ok "PHP CLI $phpv — обновление до целевой версии не требуется"
        elif [[ "$phpv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            first_version="$(printf '%s\n' "$phpv" "$TARGET_PHP" | sort -V | head -n 1)"
            if [[ "$first_version" == "$phpv" ]]; then
                status_line warning "PHP CLI $phpv — версия ниже целевой $TARGET_PHP"
            else
                status_line info "PHP CLI $phpv — версия выше целевой $TARGET_PHP"
            fi
        elif [[ "$phpv" == 'не обнаружен' ]]; then
            status_line warning "PHP CLI — версия не определена (цель $TARGET_PHP)"
        else
            status_line warning "PHP CLI $phpv — не удалось сравнить с целевой версией $TARGET_PHP"
        fi
        if [ "$offline" -eq 1 ]; then
            status_line info 'PHP.net — проверка пропущена (--offline)'
        elif [ "$check" -eq 1 ]; then
            status_line info 'PHP.net — проверка недоступна без Python 3.8+'
        else
            status_line info 'PHP.net — проверка не запрошена'
        fi
        status_line warning 'PHP сайта не подтверждён'
        case "$os_id:$os_major" in
            centos:7|centos:8|rhel:7)
                status_line critical "ОС $osname — поддержка завершилась" ;;
            *)
                status_line info "ОС $osname — срок поддержки не определён" ;;
        esac
        if [ "$os_id:$os_major" = centos:7 ] && [[ "$phpv" =~ ^(5|7|8\.[01])\. ]]; then
            status_line info 'Следующий шаг — bash install.sh --plan'
        fi
        status_line info 'Для полного аудита доступен отдельный Python через bash install.sh --bootstrap-python.'
        echo
        echo 'ПОДРОБНОСТИ'
        echo "Сервер:               $hostname_local"
        echo "Архитектура:          $arch"
        echo "BitrixEnv:            $bitrix"
        echo "Apache:               ${apache:-не определено}"
        echo "Nginx:                ${nginx:-не определено}"
        echo "Место на /:           ${droot:-не определено}"
        echo "Доступная память:     ${mem:-не определено}"
        echo 'Рабочая конфигурация и службы не изменены.'
    fi
    if [ -n "$report" ]; then
        if [ "$report" = 'AUTO' ]; then report="./bitrix-audit-$(date -u +%Y%m%d-%H%M%S)-fallback.json"; fi
        if (set -C; printf '%s\n' "$output" > "$report"); then
            echo "Отчёт сохранён: $report" >&2
        else
            echo "Ошибка записи отчёта (файл существует или нет доступа): $report" >&2
            return 3
        fi
    fi
}


# =============================================================================
# Bitrix Server Master — обновление для строго определённого профиля CentOS 7.
# Код Bash не требует Python и никогда не исполняет содержимое сайта.
# =============================================================================
# Доверенная карта целей: клиент не выбирает другую ветку через аргументы.
set_php_target() {
    case "$1" in
        8.2)
            TARGET_PHP='8.2.35'
            TARGET_PHP_SHA='5737b98601fe5ab1b8c5db0c82ed3158acb9283ed3081ffe2faffb9ac81455e6'
            SRC_RPM_SHA256='3e378af07d6beae83e507ba7331fbf70851cd365940a07a69ce6e3fc7fc35c00'
            TARGET_SPEC='php82.spec'
            ;;
        8.3)
            TARGET_PHP='8.3.36'
            TARGET_PHP_SHA='dd54693aa334c5c4d72e9aee96b082c2473750a18a6c1d105789c93a3b1692fd'
            SRC_RPM_SHA256='9a8fbff91b8a79cf82aa2405b70d086e6c313d2575a9d9040866cac7d2d0d87f'
            TARGET_SPEC='php83.spec'
            ;;
        *) err 'Поддерживаются только ветки PHP 8.2 и 8.3.'; return 2 ;;
    esac
    TARGET_BRANCH="$1"
    SRC_RPM_URL="https://rpms.remirepo.net/SRPMS/php-$TARGET_PHP-1.remi.src.rpm"
    PROJECT_RELEASE_URL="https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-$TARGET_PHP-el7-r1"
}
select_php_target_for_version() {
    [[ "$1" =~ ^8\.[23]\.[0-9]+$ ]] || return 20
    set_php_target "${1%.*}"
}
set_php_target 8.2
UPDATER_STATE='/var/lib/bitrix-server-master'
UPDATER_LOG='/var/log/bitrix-server-master'
WORK_ROOT='/var/lib/bitrix-server-master/work'
# Имена только штатных RPM, которые можно обновлять совместно.
CORE_RPM_NAMES='php php-cli php-common php-gd php-ldap php-mbstring php-mysqlnd php-opcache php-pdo php-process php-pspell php-sodium php-xml php-bcmath php-dba php-devel php-embedded php-enchant php-ffi php-fpm php-gmp php-imap php-intl php-litespeed php-odbc php-pdo-dblib php-pdo-firebird php-pgsql php-snmp php-soap php-tidy php-dbg php-debuginfo'

msg() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
console_line() {
    if [[ -t 1 && "${TERM:-}" != dumb && -z "${NO_COLOR:-}" ]]; then
        printf '\033[%sm%s\033[0m\n' "$1" "$2"
    else
        printf '%s\n' "$2"
    fi
}
err() { { printf '\n'; console_line 31 "ОШИБКА: $*"; } >&2; }
warn() { { printf '\n'; console_line 33 "ВНИМАНИЕ: $*"; } >&2; }
status_line() {
    local label color
    case "$1" in
        ok)       label='OK';       color=32 ;;
        warning)  label='ВНИМАНИЕ'; color=33 ;;
        critical) label='КРИТИЧНО'; color=31 ;;
        info)     label='ИНФО';     color=36 ;;
    esac
    console_line "$color" "[$label] $2"
}

require_root() { if [ "$(id -u)" -ne 0 ]; then err 'Для этой операции нужны права root.'; return 10; fi; }
need() { local c; for c in "$@"; do if ! command -v "$c" >/dev/null 2>&1; then err "Не найдена программа: $c"; return 11; fi; done; }
confirm_phrase() {
    local label="$1" phrase="$2"
    if [ ! -t 0 ]; then err "Для действия «$label» нужен интерактивный терминал."; return 12; fi
    echo
    printf '%s\n' "$label"
    if ! confirm_action 'Продолжить?' "$phrase"; then
        status_line warning 'Операция отменена, подтверждение не получено.'
        return 12
    fi
}
platform_check() {
    local ID='' VERSION_ID=''
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    [ "$ID" = centos ] && [[ "$VERSION_ID" =~ ^7(\.[0-9]+)*$ ]] || {
        err "Профиль поддерживает только CentOS 7 (обнаружено: $ID $VERSION_ID)."; return 20;
    }
    [ "$(uname -m)" = x86_64 ] || { err 'Поддерживается только x86_64.'; return 20; }
}

bitrix_env_rpm_guard() {
    local package records version query_rc found=''
    for package in bitrix-env bitrix-env-crm; do
        query_rc=0
        # Маркер сохраняет завершающие переводы строк: пустой второй RPM
        # не должен исчезнуть при подстановке команды. PHP здесь не нужен.
        records="$(rpm -q --qf '%{VERSION}\n' "$package" 2>&1; query_rc=$?; printf '.'; exit "$query_rc")" || query_rc=$?
        records="${records%.}"
        if [ "$query_rc" -ne 0 ]; then
            if [ "$query_rc" -eq 1 ] &&
               { [ "$records" = "package $package is not installed" ] ||
                 [ "$records" = "package $package is not installed"$'\n' ]; }; then
                continue
            fi
            err "Не удалось прочитать RPM окружения $package (код $query_rc)."; return 20
        fi
        version="${records%$'\n'}"
        if [ "$records" != "$version"$'\n' ] || ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            err "Неоднозначные или некорректные метаданные RPM окружения $package."; return 20
        fi
        if [ "${version%%.*}" != 7 ]; then
            err "Обновление BitrixEnv $version не поддерживается; нужен профиль BitrixEnv 7."; return 20
        fi
        if [ -n "$found" ]; then
            err 'Обнаружено несколько RPM окружения BitrixEnv; профиль неоднозначен.'; return 20
        fi
        found="$package"
    done
    # Старые установки без RPM окружения сохраняют прежнюю совместимость.
    return 0
}

profile_check() {
    local cur p_php p_cli apache package_kinds
    platform_check || return
    [ -d /etc/httpd/bx ] || { err 'Конфигурация BitrixEnv /etc/httpd/bx не обнаружена.'; return 20; }
    need rpm php httpd systemctl awk grep sed || return 20
    bitrix_env_rpm_guard || return
    cur="$(php -r 'echo PHP_VERSION;' 2>/dev/null)" || { err 'PHP CLI не отвечает.'; return 20; }
    select_php_target_for_version "$cur" || { err "Обновление поддерживает только ветки PHP 8.2.x и 8.3.x (найдено: $cur). Для старых версий выполните --plan."; return 20; }
    p_php="$(rpm -q --qf '%{VERSION}' php 2>/dev/null)" || { err 'RPM php не установлен.'; return 20; }
    p_cli="$(rpm -q --qf '%{VERSION}' php-cli 2>/dev/null)" || { err 'RPM php-cli не установлен.'; return 20; }
    [[ "$p_php" = "$cur" && "$p_cli" = "$cur" ]] || { err "Версии CLI ($cur) и RPM php/php-cli ($p_php/$p_cli) различаются."; return 20; }
    # Профиль mod_php + prefork. FPM и иные конфигурации пока сознательно блокируются.
    apache="$(httpd -M 2>/dev/null)" || { err 'httpd -M завершился ошибкой.'; return 20; }
    grep -Eq '^[[:space:]]*php_module \(shared\)[[:space:]]*$' <<< "$apache" || {
        err 'mod_php не обнаружен. PHP-FPM пока не поддерживается сценарием установки.'; return 20;
    }
    grep -Eq '^[[:space:]]*mpm_prefork_module \(shared\)[[:space:]]*$' <<< "$apache" || {
        err 'Apache MPM отличается от prefork.'; return 20;
    }
    # Проверяем весь вывод и код возврата rpm; grep -q в конвейере может вызвать SIGPIPE.
    package_kinds="$(rpm -qa --qf '%{NAME}\n' | awk '
        $0 == "php-fpm" { fpm = 1 }
        /^(rh-)?php[0-9][0-9](-|$)/ { scl = 1 }
        END { if (NR == 0) exit 1; print fpm + 0, scl + 0 }
    ')" || { err 'Не удалось прочитать полный список установленных RPM.'; return 20; }
    if [[ "$package_kinds" == '1 '* ]] || systemctl is-active --quiet php-fpm; then
        err 'Обнаружен php-fpm. Автоматическая установка при смешанном PHP-окружении заблокирована.'; return 20
    fi
    if [[ "$package_kinds" == *' 1' ]]; then
        err 'Обнаружены параллельные SCL-пакеты PHP; ручная проверка обязательна.'; return 20
    fi
    PHP_CURRENT="$cur"
    status_line ok "Поддерживаемый профиль: CentOS 7 x86_64, BitrixEnv, Apache prefork/mod_php, PHP $cur"
    return 0
}

available_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4+0}'; }
check_disk() {
    local path="$1" min="$2" av
    av="$(available_mb "$path")"
    [ -n "$av" ] && [ "$av" -ge "$min" ] || { err "Недостаточно места в $path: ${av:-?} МиБ, необходимо не менее $min МиБ."; return 21; }
}

private_session_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a' -- "$1")" = '0:700' ]
}

private_session_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a:%h' -- "$1")" = '0:600:1' ]
}

ensure_session_dir() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        mkdir -m 0700 -- "$1" 2>/dev/null || true
    fi
    private_session_dir "$1" || { err "Небезопасный каталог сессий: $1"; return 22; }
}

session_setup() {
    # Значения из окружения не дают права повторно использовать сессию или пропустить блокировку.
    SESSION_NAME=''
    SESSION_DIR=''
    LOG_FILE=''
    require_root || return
    need flock mkdir date tee stat mktemp mv || return
    ensure_session_dir "$UPDATER_STATE" || return
    if [ -e "$UPDATER_STATE/.lock" ] || [ -L "$UPDATER_STATE/.lock" ]; then
        private_session_file "$UPDATER_STATE/.lock" || { err 'Небезопасный файл блокировки.'; return 22; }
    fi
    exec 9>>"$UPDATER_STATE/.lock" || return
    flock -n 9 || { err 'Другой экземпляр мастера уже выполняет операцию.'; return 22; }
    ensure_session_dir "$UPDATER_STATE/sessions" || return
    ensure_session_dir "$UPDATER_LOG" || return
    ensure_session_dir "$WORK_ROOT" || return
    SESSION_NAME="$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
    SESSION_DIR="$UPDATER_STATE/sessions/$SESSION_NAME"
    mkdir -m 0700 -- "$SESSION_DIR" || return
    LOG_FILE="$UPDATER_LOG/$SESSION_NAME.log"
    (set -o noclobber; : > "$LOG_FILE") || return
    menu_record session "$SESSION_NAME"
    # Журнал не держит блокировку после завершения операции.
    exec > >(tee -a -- "$LOG_FILE" 9>&-) 2>&1
    msg "Сессия $SESSION_NAME. Журнал: $LOG_FILE"
    mark_state started
}

mark_state() {
    local tmp
    tmp="$(mktemp "$SESSION_DIR/.state.XXXXXX")" || return
    if ! { printf '%s\n' "$1" > "$tmp" && mv -f -- "$tmp" "$SESSION_DIR/state"; }; then
        rm -f -- "$tmp"
        err "Не удалось записать состояние сессии: $1"
        return 22
    fi
    menu_record state "$1"
}

show_os_status() {
    local ID='' VERSION_ID='' PRETTY_NAME=''
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    if [[ "$ID" == centos && "$VERSION_ID" =~ ^7(\.[0-9]+)*$ ]]; then
        status_line warning 'ОС: CentOS 7 снята с поддержки.'
    elif [ -n "$ID" ]; then
        status_line info "ОС: ${PRETTY_NAME:-$ID $VERSION_ID}."
    else
        status_line warning 'ОС: не удалось определить версию.'
    fi
}

php_rpm_versions_check() {
    local inventory
    inventory="$(inventory_php_rpms)" || return 2
    awk -F'|' -v version="$1" 'NF != 5 || $3 != version { print $1 " " $3; exit 1 }' <<< "$inventory" >&2
}

target_php_status() {
    local detail rpm_rc=0
    detail="$(php_rpm_versions_check "$TARGET_PHP" 2>&1)" || rpm_rc=$?
    if [ "$rpm_rc" -eq 0 ]; then
        status_line ok "PHP CLI $TARGET_PHP — обновлять до $TARGET_PHP не нужно. Версии основных RPM совпадают."
        return 0
    fi

    status_line info "PHP CLI $TARGET_PHP — обновлять до $TARGET_PHP не нужно."
    if [ "$rpm_rc" -eq 1 ]; then
        status_line critical "RPM отличаются от PHP CLI. Первое расхождение — $detail."
    else
        detail="${detail##*$'\n'}"
        detail="${detail#ОШИБКА: }"
        status_line warning "RPM не подтверждены. ${detail:-Не удалось получить сведения о пакетах.}"
    fi
    return 20
}

php_version_route() {
    local version="$1" major minor patch
    if ! [[ "$version" =~ ^(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.([0-9]{1,3})$ ]]; then
        echo unknown
        return
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    if [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -gt 3 ]; }; then
        echo unsupported
    elif [ "$major" -eq 8 ] && { [ "$minor" -eq 2 ] || [ "$minor" -eq 3 ]; }; then
        set_php_target "$major.$minor" || return
        if [ "$version" = "$TARGET_PHP" ]; then echo target
        elif [ "$((10#$patch))" -ge "${TARGET_PHP##*.}" ]; then echo newer
        else echo patch; fi
    else
        echo older
    fi
}

bitrix_env_release() {
    local package record installed='' installed_name='' version release arch
    for package in bitrix-env bitrix-env-crm; do
        if record="$(rpm -q --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}\n' "$package" 2>/dev/null)"; then
            if [[ -n "$installed_name" || "$record" == *$'\n'* ]]; then
                echo 'BitrixEnv — версия неоднозначна: установлено несколько RPM окружения.'
                return 1
            fi
            installed="$record"
            installed_name="$package"
        elif [ "$record" != "package $package is not installed" ]; then
            echo 'BitrixEnv — не удалось прочитать RPM окружения.'
            return 1
        fi
    done
    if [ -z "$installed_name" ]; then
        echo 'BitrixEnv — RPM bitrix-env и bitrix-env-crm не найдены.'
        return 1
    fi
    if ! [[ "$installed" =~ ^${installed_name}\|([[:alnum:]_.+~^-]+)\|([[:alnum:]_.+~^-]+)\|([[:alnum:]_]+)$ ]]; then
        echo 'BitrixEnv — не удалось распознать метаданные RPM окружения.'
        return 1
    fi
    version="${BASH_REMATCH[1]}"
    release="${BASH_REMATCH[2]}"
    arch="${BASH_REMATCH[3]}"

    # Стабильные сборки из https://repos.1c-bitrix.ru/yum/el/7/x86_64/.
    case "$version-$release.$arch" in
        7.0-[01].el7.centos.noarch|7.1-0.el7.centos.noarch|7.2-[0-2].el7.centos.noarch|\
        7.3-0.el7.centos.noarch|7.3-[0-4].el7.noarch|7.3-1[2-4].el7.noarch|\
        7.4-[0-3].el7.noarch|7.4-1[0-3].el7.noarch|7.5-[0-5].el7.noarch)
            printf '%s.%s|%s|%s-%s-%s.%s\n' "$version" "${release%%.*}" "$installed_name" "$installed_name" "$version" "$release" "$arch"
            ;;
        *)
            printf 'BitrixEnv — стабильный выпуск EL7 не распознан по RPM %s-%s-%s.%s.\n' "$installed_name" "$version" "$release" "$arch"
            return 1 ;;
    esac
}

legacy_php_profile() {
    local cli="$1" php_path owner rpm_php rpm_cli packages
    if ! [[ "$cli" =~ ^(5\.6|7\.[0-4]|8\.[01])\.[0-9]+$ ]]; then
        echo 'Для исходной версии PHP требуется отдельно проверить совместимость и промежуточные шаги.'
    elif ! [ -d /etc/httpd/bx ]; then
        echo 'Конфигурация BitrixEnv /etc/httpd/bx не обнаружена.'
    elif ! php_path="$(command -v php)" || [[ "$php_path" != /* ]] ||
         ! php_path="$(readlink -f -- "$php_path")" ||
         ! owner="$(rpm -qf --qf '%{NAME}' "$php_path" 2>/dev/null)" || [ "$owner" != php-cli ]; then
        echo 'Запускаемый PHP CLI не подтверждён как файл пакета php-cli.'
    elif ! rpm_php="$(rpm -q --qf '%{VERSION}' php 2>/dev/null)" ||
         ! rpm_cli="$(rpm -q --qf '%{VERSION}' php-cli 2>/dev/null)" ||
         [[ "$rpm_php" != "$cli" || "$rpm_cli" != "$cli" ]]; then
        echo 'Не подтверждено совпадение версий PHP CLI и системных RPM php/php-cli.'
    elif ! packages="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null)" || [ -z "$packages" ]; then
        echo 'Не удалось проверить список установленных RPM.'
    elif grep -qx 'php-fpm' <<< "$packages" || systemctl is-active --quiet php-fpm 2>/dev/null; then
        echo 'Обнаружен PHP-FPM. Сначала проверьте конфигурацию веб-PHP на клоне.'
    elif grep -Eq '^(rh-)?php[0-9][0-9](-|$)' <<< "$packages"; then
        echo 'Обнаружены параллельные пакеты PHP SCL. Сначала проверьте конфигурацию веб-PHP на клоне.'
    else
        return 0
    fi
    return 1
}

show_legacy_php_plan() {
    local cli="$1" bx detail version='' package='' nevra='' route=migrate
    local package_menu='4. Update packages on host' php_menu='8. Update PHP and MySQL' menu_step=5 php_target=''
    if [[ "$cli" =~ ^[[:alnum:]_.+~-]+$ ]]; then
        status_line info "PHP CLI — $cli."
    else
        status_line warning 'Версия PHP CLI не определена.'
    fi
    show_os_status
    status_line info "Архитектура — $(uname -m 2>/dev/null || echo 'не определена')."
    if bx="$(bitrix_env_release)"; then
        IFS='|' read -r version package nevra <<< "$bx"
        status_line info "BitrixEnv $version (RPM $nevra)."
    else
        status_line warning "$bx"
    fi
    if ! detail="$(platform_check 2>&1)"; then
        detail="${detail##*$'\n'}"
        status_line warning "${detail#ОШИБКА: }"
    elif [ -n "$version" ]; then
        if detail="$(legacy_php_profile "$cli")"; then
            case "$version" in
                7.5.[3-5]) route=menu ;;
                7.*) route=environment ;;
            esac
        else
            route=compatibility
            status_line warning "$detail"
        fi
    fi

    status_line info 'Для подробного локального инвентаря можно выполнить bash install.sh --audit --offline.'
    cat <<'EOF'
1. Сделайте снимок ВМ или резервную копию всего сервера и БД, проверьте восстановление и воспроизведите окружение на клоне.
2. Сверьте версии PHP CLI и сайта, ядра и модулей Битрикса, БД, расширений и кодировку.
EOF
    if [[ "$route" == migrate || "$route" == compatibility ]]; then
        echo '3. На клоне подберите совместимые промежуточные версии ядра, модулей и PHP. Проверьте устаревшие API, пользовательский код и доступность нужных расширений на каждом этапе.'
        if [ "$route" = compatibility ]; then
            echo '4. Если совместимость и полный набор пакетов подтверждены, после промежуточного этапа повторите bash install.sh --plan. Если рабочую цепочку подтвердить не удалось, подготовьте перенос на поддерживаемое BitrixVM/BitrixEnv.'
        else
            echo '4. Подготовьте перенос на поддерживаемое BitrixVM/BitrixEnv. Проверьте сайт, фоновые задачи, БД и способ возврата перед переключением трафика.'
        fi
        return
    fi
    cat <<'EOF'
3. На клоне установите доступные для текущего PHP обновления ядра Битрикса, модулей и сторонних решений из Marketplace. Оцените совместимость пользовательского кода и расширений со следующей веткой PHP.
   Подготовка к PHP 8 описана в курсе Bitrix https://dev.1c-bitrix.ru/learning/course/?COURSE_ID=48&LESSON_ID=9685
4. Проверьте штатный Apache/mod_php, подписи, наличие RPM и разрешимость всех зависимостей для выбранной версии и промежуточных шагов. Проверьте репозитории ОС, Bitrix, Remi и прочие источники, нужные вашей конфигурации. Публичные репозитории Remi для EL7 закрыты. При отсутствии проверенного полного набора пакетов выберите перенос на поддерживаемое окружение.
EOF
    if [ "$package" = bitrix-env-crm ]; then
        package_menu='2. Update packages on host'
        php_menu='6. Update PHP and MySQL'
    fi
    status_line info 'Эти действия выполняет администратор на клоне через штатное меню BitrixEnv.'
    echo '   Войдите на сервер управления пулом как root и запустите bash /root/menu.sh.'
    echo '   Для отдельного сервера это меню запускается на самом клоне.'
    if [ "$route" = environment ]; then
        cat <<EOF
5. Сначала проверьте маршрут обновления самого BitrixEnv до выпуска 7.5.3–7.5.5. Где это предусмотрено инструкцией для вашего выпуска, используйте 1. Manage servers in the pool → $package_menu → имя нужного хоста → bitrix. Сверьте название пункта в своём меню, уточните состав пакетов и опробуйте задачу на клоне.
   Для перехода на 7.5.0 действовала отдельная процедура из-за обновления Ansible. Если ваш маршрут проходит через 7.5.0 или требует обновления Ansible, сверьтесь с примечанием поставщика до запуска задачи пула https://dev.1c-bitrix.ru/community/forums/forum32/topic138822/
6. Дождитесь завершения задачи в Background pool tasks → View running tasks и проверьте результат по журналу в /opt/webdir/temp. После успешного обновления окружения перезагрузите обновлённый узел клона, дождитесь запуска служб, проверьте сайт и выполните bash install.sh --plan.
   Меню описано в курсе Bitrix https://dev.1c-bitrix.ru/learning/course/?COURSE_ID=37&LESSON_ID=8825
EOF
    else
        if [[ "$version" == 7.5.3 && "$cli" == 8.1.* ]]; then
            echo '5. Для BitrixEnv 7.5.3 с PHP 8.1 пункт Upgrade PHP может отсутствовать. В 7.5.4 это исправлено. Проверьте на клоне обновление окружения до 7.5.4–7.5.5, затем повторите bash install.sh --plan.'
            menu_step=6
        fi
        case "$cli" in
            7.4.*) php_target=8.0 ;;
            8.0.*) php_target=8.1 ;;
            8.1.*) php_target=8.2 ;;
        esac
        if [ -n "$php_target" ]; then
            printf '%s. После проверки зависимостей выберите только следующий этап PHP %s на клоне.\n' "$menu_step" "$php_target"
            echo "   1. Manage servers in the pool → $php_menu → имя нужного хоста → Upgrade PHP → PHP $php_target. Сверьте названия пунктов в своём меню."
        else
            printf '%s. Для исходного PHP подтвердите на клоне совместимую промежуточную ветку. В меню Upgrade PHP выберите эту ветку и проверьте результат перед следующим переходом.\n' "$menu_step"
        fi
        if [ "$version" = 7.5.5 ]; then
            case "$cli" in
                7.4.*) echo '   Цепочка на клоне 7.4 → 8.0 → 8.1 → 8.2, с отдельной проверкой сайта после каждого этапа.' ;;
                8.0.*) echo '   Цепочка на клоне 8.0 → 8.1 → 8.2, с отдельной проверкой сайта после каждого этапа.' ;;
                8.1.*) echo '   В 7.5.5 предусмотрен переход 8.1 → 8.2.' ;;
            esac
        fi
        printf '%s. ' "$((menu_step + 1))"
        cat <<'EOF'
После каждого этапа дождитесь завершения задачи в Background pool tasks → View running tasks. Проверьте результат по журналу в /opt/webdir/temp. При ошибке устраните её перед следующим этапом.
EOF
        printf '%s. ' "$((menu_step + 2))"
        cat <<'EOF'
Перезагрузите обновлённый узел клона после успешного этапа, дождитесь запуска служб и подтвердите версии PHP CLI, RPM и веб-PHP. Проверьте сайт, админку, формы, интеграции и фоновые задания. Снова проверьте доступные обновления ядра, модулей и решений Маркетплейса для установленного PHP и проверьте сайт после их установки.
EOF
        printf '%s. ' "$((menu_step + 3))"
        cat <<'EOF'
Сохраните проверенное состояние клона. Выполните bash install.sh --check и --plan для следующего этапа. На PHP 8.2.x мастер проверит возможность установки патча 8.2.35.
   Примечания к выпускам Bitrix https://dev.1c-bitrix.ru/learning/course/?CHAPTER_ID=011219&COURSE_ID=37
   Меню описано в курсе Bitrix https://dev.1c-bitrix.ru/learning/course/?COURSE_ID=37&LESSON_ID=8831
EOF
    fi
    echo 'Этот маршрут основан на архивной документации. Доступность пакетов на узле предстоит проверить.'
    echo 'Архив Remi EL7 https://rpms.remirepo.net/enterprise/7/'
}

quick_check() {
    local url='' cli='' route detail rpm_rc=0 web_rc=0 next_action=''
    if [ "$#" -gt 0 ]; then
        if [[ "$#" -ne 2 || "$1" != --url || -z "$2" || "$2" == --* ]]; then
            err 'Использование: bash install.sh --check [--url URL]'
            return 2
        fi
        url="$2"
        health_url_parts "$url" >/dev/null || return
    fi

    printf 'BITRIX SERVER MASTER %s — быстрая проверка\n' "$MASTER_VERSION"
    cli="$(php -r 'echo PHP_VERSION;' 2>/dev/null)" || cli=''
    select_php_target_for_version "$cli" || true
    route="$(php_version_route "$cli")"
    case "$route" in
        unknown)
            if [[ "$cli" =~ ^[[:alnum:]_.+~-]+$ ]]; then
                status_line warning "PHP CLI $cli. Требуется проверка происхождения и совместимости версии."
            else
                status_line critical "PHP CLI недоступен или версия не определена. Целевая версия: $TARGET_PHP."
            fi
            cli=''
            next_action='--plan'
            ;;
        older)
            status_line warning "PHP CLI $cli. Для перехода на PHP 8.2 нужен отдельный маршрут."
            next_action='--plan'
            ;;
        unsupported) status_line warning "PHP CLI $cli. Обновление этой ветки не поддерживается; доступны только 8.2.x и 8.3.x." ;;
        newer) status_line ok "PHP CLI $cli. Понижение до $TARGET_PHP не предусмотрено." ;;
        target) target_php_status || next_action='--audit --offline' ;;
        patch)
            if ! detail="$(profile_check 2>&1)"; then
                detail="${detail##*$'\n'}"
                detail="${detail#ОШИБКА: }"
                status_line warning "PHP CLI $cli. Автоматическое обновление недоступно. $detail"
                next_action='--audit --offline'
            else
                detail="$(php_rpm_versions_check "$cli" 2>&1)" || rpm_rc=$?
                if [ "$rpm_rc" -eq 0 ]; then
                    status_line warning "PHP CLI $cli. На этом профиле можно подготовить обновление до $TARGET_PHP."
                    next_action='--plan'
                elif [ "$rpm_rc" -eq 1 ]; then
                    status_line critical "Автоматическое обновление недоступно. RPM отличаются от PHP CLI $cli. Первое расхождение — $detail."
                    next_action='--audit --offline'
                else
                    detail="${detail##*$'\n'}"
                    detail="${detail#ОШИБКА: }"
                    status_line warning "Автоматическое обновление недоступно. RPM не подтверждены. $detail"
                    next_action='--audit --offline'
                fi
            fi
            ;;
    esac

    if [ -z "$url" ]; then
        status_line warning 'Веб-PHP не проверялся. Автоматическая временная проверка: bash install.sh --check-site (от root).'
    elif [ -z "$cli" ]; then
        status_line warning 'Сайт: веб-PHP не проверен. Не определена ожидаемая версия PHP.'
        web_rc=63
    elif http_check "$url" "$cli" >/dev/null 2>&1; then
        status_line ok "Сайт: веб-PHP $cli (apache2handler) подтверждён, HTTP 200."
    else
        web_rc=$?
        status_line critical "Сайт: веб-PHP не подтверждён для версии $cli."
        if [ "$route" != older ]; then next_action='--audit --offline'; fi
    fi

    show_os_status

    if [ -n "$next_action" ]; then
        status_line info "Следующий шаг: bash install.sh $next_action"
    fi
    return "$web_rc"
}

show_plan() {
    local cli route detail='' profile_rc=20
    printf 'BITRIX SERVER MASTER %s — план обновления\n' "$MASTER_VERSION"
    cli="$(php -r 'echo PHP_VERSION;' 2>/dev/null)" || cli=''
    select_php_target_for_version "$cli" || true
    route="$(php_version_route "$cli")"
    status_line warning 'Веб-PHP не проверялся. Автоматическая временная проверка: bash install.sh --check-site (от root).'
    if [[ "$cli" =~ ^8\.[23]\.[0-9]+$ ]]; then
        if detail="$(profile_check 2>&1)"; then
            profile_rc=0
            console_line 32 "$detail"
        else
            profile_rc=$?
            detail="${detail##*$'\n'}"
            status_line warning "${detail#ОШИБКА: }"
        fi
    fi
    case "$route" in
        unsupported)
            status_line warning "Обновление PHP $cli не поддерживается. Мастер устанавливает патчи только внутри веток 8.2 и 8.3."
            show_os_status
            return 20 ;;
        target)
            if [ "$profile_rc" -eq 0 ]; then target_php_status || profile_rc=$?; else target_php_status || true; fi
            show_os_status
            return "$profile_rc" ;;
        newer)
            status_line ok "Понижение PHP $cli до $TARGET_PHP не предусмотрено."
            show_os_status
            return "$profile_rc" ;;
    esac
    if [ "$route" != patch ]; then
        show_legacy_php_plan "$cli"
        return 20
    fi
    if [ "$profile_rc" -ne 0 ]; then
        status_line warning "Подготовка патча $TARGET_PHP доступна только для подтверждённого профиля."
        if [[ "$detail" == *'httpd -M'* ]]; then
            status_line info 'Если httpd -M не удалось выполнить из-за прав, повторите проверку с доступом на чтение конфигурации Apache, при необходимости от root.'
        fi
        status_line info 'Следующий шаг: bash install.sh --audit --offline'
        return "$profile_rc"
    fi
    if ! php_rpm_versions_check "$cli"; then
        status_line warning 'Версии основных RPM и PHP CLI не совпадают или не подтверждены.'
        status_line info 'Следующий шаг: bash install.sh --audit --offline'
        return 20
    fi
    status_line info "План обновления: PHP $cli → $TARGET_PHP (ветка $TARGET_BRANCH)."
    cat <<'EOF'
1. Проверьте резервную копию или снимок ВМ и доступ к консоли гипервизора.
2. На клоне от root выполните --check-site и выберите сайт для временной проверки.
3. Запустите --auto-update (при необходимости --site ИМЯ): мастер настроит выпуск
   и ключ, проверит подписи, скачает новые RPM и точный прежний комплект для отката.
4. Подтвердите проверенный снимок и установку. Проверьте админку и функции сайта.
5. Выполните откат по ID исходной сессии и подтвердите работу прежнего PHP и сайта.
6. Согласуйте окно обслуживания и повторите проверенную процедуру.
Если точного старого RPM нет в выпуске, владелец должен добавить его в подписанный архив.
CentOS 7 снята с поддержки. Обновление PHP не восстанавливает поддержку ОС.
EOF
}

safe_download() {
    local url="$1" path="$2"
    need curl || return
    msg "Скачивание: $url"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
         --retry 2 --connect-timeout 15 --max-time 600 --output "$path.part" "$url" || return 30
    [ -s "$path.part" ] || { err 'Скачан пустой файл.'; return 30; }
    mv -f -- "$path.part" "$path"
}

# Генерируем маленькое проверенное исправление OpenSSL 1.0.2 через diff.
make_openssl_patch() {
    local tarball="$1" dest="$2" temp src orig edited linecount
    need tar awk diff patch || return
    temp="$(mktemp -d "$WORK_ROOT/openssl-fix.XXXXXXXX")" || return
    if ! tar -xJf "$tarball" -C "$temp" "php-$TARGET_PHP/ext/openssl/xp_ssl.c"; then
        err 'Не удалось извлечь ext/openssl/xp_ssl.c'; rm -rf "$temp"; return 30
    fi
    src="$temp/php-$TARGET_PHP/ext/openssl/xp_ssl.c"
    orig="$temp/orig.c"; edited="$temp/edited.c"
    cp "$src" "$orig"
    linecount="$(grep -c '^#include <openssl/dh.h>' "$orig")"
    [ "$linecount" = 1 ] || { err 'В исходнике нет ожидаемой точки вставки патча.'; rm -rf "$temp"; return 30; }
    awk '
    { print }
    /^#include <openssl\/dh.h>$/ {
      print ""
      print "/* OpenSSL 1.0.2 compatibility (EL7) */"
      print "#if PHP_OPENSSL_API_VERSION < 0x10100"
      print "static const unsigned char *ASN1_STRING_get0_data(const ASN1_STRING *asn1)"
      print "{"
      print "    return M_ASN1_STRING_data(asn1);"
      print "}"
      print "#endif"
    }' "$orig" > "$edited"
    diff -u --label a/ext/openssl/xp_ssl.c --label b/ext/openssl/xp_ssl.c "$orig" "$edited" > "$dest"
    if ! patch --dry-run --fuzz=0 -d "$temp/php-$TARGET_PHP" -p1 < "$dest" >/dev/null 2>&1; then
        err 'Ошибка проверки патча OpenSSL.'; rm -rf "$temp"; return 30
    fi
    rm -rf "$temp"
    msg 'Патч совместимости OpenSSL подготовлен и проверен.'
}

# Replacements for the build/source functions in install.sh.
# Relies on the fixed set_php_target profile map and make_openssl_patch.
make_el7_ffi_patch() {
    local tarball="$1" dest="$2" temp orig edited result
    need tar grep sed diff patch || return
    temp="$(mktemp -d "$WORK_ROOT/ffi-fix.XXXXXXXX")" || return
    if ! tar -xJf "$tarball" -C "$temp" "php-$TARGET_PHP/ext/ffi/ffi.c"; then
        err 'Не удалось извлечь ext/ffi/ffi.c'; rm -rf -- "$temp"; return 30
    fi
    orig="$temp/php-$TARGET_PHP/ext/ffi/ffi.c"
    edited="$temp/edited.c"
    if [ "$(grep -c 'strncmp(.*ZEND_STRL(' "$orig")" != 3 ]; then
        err 'В FFI изменились ожидаемые точки совместимости glibc EL7.'; rm -rf -- "$temp"; return 30
    fi
    sed -e 's/ZEND_STRL("#define")/"#define", sizeof("#define") - 1/' \
        -e 's/ZEND_STRL("FFI_SCOPE")/"FFI_SCOPE", sizeof("FFI_SCOPE") - 1/' \
        -e 's/ZEND_STRL("FFI_LIB")/"FFI_LIB", sizeof("FFI_LIB") - 1/' \
        "$orig" > "$edited" || { rm -rf -- "$temp"; return 30; }
    diff -u --label a/ext/ffi/ffi.c --label b/ext/ffi/ffi.c "$orig" "$edited" > "$dest"
    result=$?
    if [ "$result" != 1 ] || ! patch --dry-run --fuzz=0 -d "$temp/php-$TARGET_PHP" -p1 < "$dest" >/dev/null 2>&1; then
        err 'Ошибка проверки патча FFI для glibc EL7.'; rm -rf -- "$temp"; return 30
    fi
    rm -rf -- "$temp"
    msg 'Патч совместимости FFI с glibc EL7 подготовлен и проверен.'
}

prepare_spec() {
    local root="$1" spec="$1/SPECS/$TARGET_SPEC" new="$1/SPECS/$TARGET_SPEC.modified" anchor
    case "$TARGET_BRANCH" in
        8.2) anchor=302 ;;
        8.3) anchor=49 ;;
        *) err 'Неподдерживаемая ветка исходников PHP.'; return 31 ;;
    esac
    [ -f "$spec" ] || { err "Не найден $TARGET_SPEC в $root/SPECS."; return 31; }
    cp -- "$spec" "$spec.original" || return
    if ! grep -q "^Patch$anchor:" "$spec" || ! grep -q "^%patch -P$anchor " "$spec"; then
        err "Структура spec изменилась: не удалось найти Patch$anchor."; return 31
    fi
    # В 8.3 Patch49 находится вне условного блока tzdata: оба исправления обязательны.
    awk -v anchor="$anchor" -v version="$TARGET_PHP" -v branch="$TARGET_BRANCH" '
    /^Release:[[:space:]]*1%\{\?dist\}/ { sub(/1%\{\?dist\}/, "1%{?dist}.1") }
    /^BuildRequires:[[:space:]]*pkgconfig\(icu-(i18n|io|uc)\)[[:space:]]*>= 74/ { sub(/>= 74/, ">= 73") }
    /^BuildRequires:[[:space:]]*pkgconfig\(odbc\)/ { sub(/pkgconfig\(odbc\)/, "unixODBC-devel") }
    $0 ~ "^Patch" anchor ":" {
        print; print "Patch900: php-" version "-openssl102-asn1.patch"
        if (branch == "8.3") print "Patch901: php-" version "-el7-glibc-strncmp.patch"
        next
    }
    $0 ~ "^%patch -P" anchor " " {
        print; print "%patch -P900 -p1 -b .openssl102"
        if (branch == "8.3") print "%patch -P901 -p1 -b .glibc-strncmp"
        next
    }
    {print}
    ' "$spec" > "$new" || return
    if ! grep -q '^Patch900:' "$new" || ! grep -q '^%patch -P900' "$new" || ! grep -q '>= 73' "$new"; then
        err 'Не удалось корректно модифицировать spec.'; return 31
    fi
    if [ "$TARGET_BRANCH" = 8.3 ] && { ! grep -q '^Patch901:' "$new" || ! grep -q '^%patch -P901 ' "$new"; }; then
        err 'Не удалось добавить обязательный патч FFI для glibc EL7.'; return 31
    fi
    mv -f -- "$new" "$spec" || return
    msg "Спецификация адаптирована: $spec"
}

source_prepare() {
    local dir="$1" src="$2" top keyring sig status fingerprint primary expected_signer expected_primary=''
    case "$TARGET_BRANCH" in
        8.2) expected_signer='E60913E4DF209907D8E30D96659A97C9CF2A795A' ;;
        8.3)
            expected_signer='4B1FC0D9DF92321CED9F615DBEC555E22A143553'
            expected_primary='AFD8691FDAEDF03BDF6E460563F15A9B715376CA'
            ;;
        *) err 'Неподдерживаемая ветка исходников PHP.'; return 30 ;;
    esac
    need rpm2cpio cpio sha256sum rpm rpmbuild gpg tar patch diff readlink || return
    mkdir -p -- "$dir" || return
    dir="$(readlink -f -- "$dir")" || return 30
    top="$dir/rpmbuild"
    mkdir -p -m 0700 "$top/SOURCES" "$top/SPECS" "$top/BUILD" "$top/BUILDROOT" "$top/RPMS" "$top/SRPMS" || return
    if [ -n "$src" ]; then
        [ -f "$src" ] && [ ! -L "$src" ] || { err 'Указанный SRPM не существует или является символической ссылкой.'; return 30; }
        cp -- "$src" "$dir/remi.src.rpm" || return
    else
        safe_download "$SRC_RPM_URL" "$dir/remi.src.rpm" || return
    fi
    # Полный доверенный SRPM включает spec, патчи и публичный keyring.
    if ! (cd -- "$dir" && printf '%s  remi.src.rpm\n' "$SRC_RPM_SHA256" | sha256sum -c -); then
        err 'SHA-256 SRPM не совпал с закреплённым значением Remi. Распаковка запрещена.'; return 30
    fi
    local entries="$dir/source-entries.txt"
    if ! (rpm2cpio "$dir/remi.src.rpm" | cpio -it --quiet) > "$entries" 2>"$dir/source-list-errors.log"; then
        err 'Не удалось прочитать перечень файлов SRPM.'; return 30
    fi
    if ! awk '
      { p=$0; sub(/^\.\//, "", p); if (p !~ /^[[:alnum:]_.+-]+$/ || p == ".." || p == ".") bad=1 }
      END { exit bad }
    ' "$entries"; then
        err 'В SRPM обнаружены недопустимые пути; распаковка отменена.'; return 30
    fi
    if ! (cd "$top/SOURCES" && rpm2cpio "$dir/remi.src.rpm" | cpio -idm --quiet); then
        err 'Не удалось извлечь содержимое SRPM.'; return 30
    fi
    [ -f "$top/SOURCES/$TARGET_SPEC" ] || { err "Не найден $TARGET_SPEC в SRPM."; return 30; }
    cp -- "$top/SOURCES/$TARGET_SPEC" "$top/SPECS/$TARGET_SPEC" || return
    [ -f "$top/SOURCES/php-$TARGET_PHP.tar.xz" ] || { err 'В SRPM отсутствует исходник нужной версии.'; return 30; }
    printf '%s  %s\n' "$TARGET_PHP_SHA" "$top/SOURCES/php-$TARGET_PHP.tar.xz" | sha256sum -c - || {
        err 'Контрольная сумма исходников PHP не совпала.'; return 30;
    }
    sig="$top/SOURCES/php-$TARGET_PHP.tar.xz.asc"
    keyring="$top/SOURCES/php-keyring.gpg"
    [ -f "$sig" ] && [ -f "$keyring" ] || { err 'Не найдены подпись PHP и keyring.'; return 30; }
    mkdir -m 0700 "$dir/gnupg" || return
    # EL7 GnuPG может пропустить другие ключи общего PHP keyring.
    # Проверенная подпись и точные отпечатки ниже остаются обязательными.
    gpg --homedir "$dir/gnupg" --batch --quiet --import "$keyring" > "$dir/source-keyring-import.log" 2>&1 ||
        warn "GPG завершил импорт с замечаниями. См. $dir/source-keyring-import.log"
    status="$(gpg --homedir "$dir/gnupg" --batch --status-fd 1 --verify "$sig" "$top/SOURCES/php-$TARGET_PHP.tar.xz" 2>&1)" || {
        err 'GPG-подпись исходников PHP не подтверждена.'; return 30;
    }
    printf '%s\n' "$status" > "$dir/source-gpg-verification.log" || return
    printf '%s\n' "$status" | grep -q '^\[GNUPG:\] GOODSIG ' || { err 'GPG не подтвердил подпись.'; return 30; }
    fingerprint="$(printf '%s\n' "$status" | awk '/^\[GNUPG:\] VALIDSIG / {print $3; exit}')"
    primary="$(printf '%s\n' "$status" | awk '/^\[GNUPG:\] VALIDSIG / {print $12; exit}')"
    if [ "$fingerprint" != "$expected_signer" ] || { [ -n "$expected_primary" ] && [ "$primary" != "$expected_primary" ]; }; then
        err "Неожиданный ключ подписи PHP: $fingerprint (основной: $primary)."; return 30
    fi
    msg 'SHA-256 и GPG-подпись исходников PHP подтверждены.'
    make_openssl_patch "$top/SOURCES/php-$TARGET_PHP.tar.xz" "$top/SOURCES/php-$TARGET_PHP-openssl102-asn1.patch" || return
    if [ "$TARGET_BRANCH" = 8.3 ]; then
        make_el7_ffi_patch "$top/SOURCES/php-$TARGET_PHP.tar.xz" "$top/SOURCES/php-$TARGET_PHP-el7-glibc-strncmp.patch" || return
    fi
    prepare_spec "$top" || return
    if ! rpmbuild -bp --nodeps --define "_topdir $top" --define 'dist .el7' "$top/SPECS/$TARGET_SPEC" > "$dir/prep.log" 2>&1; then
        err "Ошибка подготовки исходников. См. $dir/prep.log"; tail -n 25 "$dir/prep.log"; return 31
    fi
    msg 'Проверка подготовки исходников RPM (%prep) прошла.'
    printf '%s\n' "$top" > "$dir/topdir"
}

build_rpms() {
    local from_srpm="$1" allow_builder="$2" top missing=0 work
    require_root || return
    platform_check || return
    if [ "${PHP_CURRENT:-}" = "$TARGET_PHP" ]; then
        warn 'PHP уже обновлён, сборка необязательна, но может использоваться для распространения пакетов.'
    fi
    if [ "$allow_builder" -ne 1 ]; then
        warn 'Режим --build предназначен для отдельной копии/строительного сервера.'
        err 'Укажи --builder после запуска на клоне. На рабочем сервере установка зависимостей сборки запрещена.'
        return 40
    fi
    confirm_phrase 'ВНИМАНИЕ: сборка может устанавливать/обновлять многочисленные системные пакеты. Это допускается только НА КЛОНЕ/СБОРОЧНОЙ ВМ.' 'ЭТО КЛОН' || return
    session_setup || return
    check_disk "$WORK_ROOT" 8000 || return
    need yum rpm rpmbuild rpm2cpio cpio gpg patch diff gcc make sha256sum || {
        warn 'Отсутствуют инструменты сборки. Их можно установить только на выделенной сборочной ВМ.'
        confirm_phrase 'Установить инструменты rpm-build, yum-utils, gcc, make, cpio, gnupg2, patch, diffutils, tar, xz на сборочной ВМ?' 'УСТАНОВИТЬ ИНСТРУМЕНТЫ' || return
        yum install -y rpm-build yum-utils gcc make cpio gnupg2 patch diffutils tar xz || return
    }
    work="$WORK_ROOT/build-$SESSION_NAME"
    mkdir -p -m 0700 "$work" || return
    msg 'Извлечение источников и проверка подписей...'
    source_prepare "$work" "$from_srpm" || { mark_state failed_prepare; return 41; }
    top="$work/rpmbuild"
    msg 'Проверка зависимостей сборки...'
    if ! rpmbuild -br --define "_topdir $top" --define 'dist .el7' "$top/SPECS/$TARGET_SPEC" > "$work/buildrequires.log" 2>&1; then
        # -br в старом rpmbuild может не поддерживаться: используем проверку -bp без --nodeps.
        if rpmbuild -bp --define "_topdir $top" --define 'dist .el7' "$top/SPECS/$TARGET_SPEC" > "$work/dependencies-check.log" 2>&1; then
            missing=0
        else
            missing=1
        fi
    else
        # -br может создать SRPM; точный список всё равно проверяем.
        if ! rpmbuild -bp --define "_topdir $top" --define 'dist .el7' "$top/SPECS/$TARGET_SPEC" > "$work/dependencies-check.log" 2>&1; then missing=1; fi
    fi
    if [ "$missing" -eq 1 ]; then
        msg 'Для сборки не хватает зависимостей:'
        tail -n 45 "$work/dependencies-check.log"
        need yum-builddep || { err 'Для зависимостей требуется yum-utils и команда yum-builddep.'; return 42; }
        echo 'Команда yum-builddep может обновить systemd, curl и другие критические пакеты на сборочной ВМ.'
        confirm_phrase 'Разрешить установку build-зависимостей НА КЛОНЕ после предварительного просмотра транзакции?' 'РАЗРЕШАЮ НА КЛОНЕ' || return
        yum-builddep --assumeno "$top/SPECS/$TARGET_SPEC" 2>&1 | tee "$work/builddeps-preview.log" || true
        confirm_phrase 'Транзакция показана выше. Запустить её НА КЛОНЕ?' 'ВЫПОЛНИТЬ НА КЛОНЕ' || return
        yum-builddep -y "$top/SPECS/$TARGET_SPEC" || { err 'Установка build-зависимостей завершилась ошибкой.'; mark_state failed_deps; return 42; }
    fi
    msg 'Компиляция и создание RPM. Подробности: build.log'
    mark_state building
    if ! rpmbuild -ba --define "_topdir $top" --define 'dist .el7' "$top/SPECS/$TARGET_SPEC" > "$work/build.log" 2>&1; then
        err 'Компиляция не прошла, последние строки:'; tail -n 35 "$work/build.log"; mark_state failed_build; return 43
    fi
    if ! ls "$top/RPMS/x86_64/php-$TARGET_PHP"-*.rpm >/dev/null 2>&1; then
        err 'После сборки не найден основной RPM-пакет php.'; mark_state failed_build; return 43
    fi
    # Оператор подписывает этот манифест отдельно доверенным ключом.
    (cd "$top/RPMS/x86_64" && sha256sum -- *.rpm > SHA256SUMS) || { err 'Не создан манифест целостности RPM'; return 43; }
    msg "RPM собраны в $top/RPMS/x86_64"
    printf '%s\n' "$top/RPMS/x86_64" > "$SESSION_DIR/rpm-dir"
    mark_state built
    echo 'Подпиши SHA256SUMS отделённой ASCII-подписью доверенного ключа вне сборочной ВМ.'
    echo 'Передай весь каталог RPM вместе с SHA256SUMS и SHA256SUMS.asc.'
}

# Полная установленная NEVRA нужна для проверки обновления и точного отката.
RPM_RECORD_QF='%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\n'
RPM_RECORD_RE='^([[:alnum:]_.+-]+)\|([0-9]+|\(none\))\|([[:alnum:]_.+~^-]+)\|([[:alnum:]_.+~^-]+)\|([[:alnum:]_]+)$'

check_zipstream_library() {
    local record="$1" files requires path library_found=0
    if ! [[ "$record" =~ $RPM_RECORD_RE && "$record" == *"|noarch" ]]; then
        err 'php-zipstream имеет неожиданный формат RPM. Ожидается архитектура noarch.'
        return 50
    fi
    if ! files="$(rpm -ql -- php-zipstream)" || ! requires="$(rpm -qR -- php-zipstream)"; then
        err 'Не удалось прочитать файлы или зависимости RPM php-zipstream.'
        return 50
    fi
    while IFS= read -r path; do
        case "$path" in
          *.so|*.so.*|*.dll|*.ini)
            err "php-zipstream содержит неожиданный файл $path."; return 50 ;;
          /usr/share/php/zipstream/zipstream.php) library_found=1 ;;
          /usr/share/php/zipstream|/usr/share/doc/php-zipstream-*|/usr/share/licenses/php-zipstream*) ;;
          *)
            err "php-zipstream содержит неожиданный путь $path."; return 50 ;;
        esac
    done <<< "$files"
    if [ "$library_found" -ne 1 ]; then
        err 'В php-zipstream не найден ожидаемый файл PHP-библиотеки.'
        return 50
    fi
    # У стандартного EL7 RPM есть зависимость от php-common и служебные зависимости RPM.
    if ! awk '
        /^php-common([[:space:]]|$)/ { php = 1; next }
        /^rpmlib\([^)]*\)([[:space:]]|$)/ { next }
        { unexpected = 1 }
        END { exit (!php || unexpected) }
    ' <<< "$requires"; then
        err 'php-zipstream имеет неожиданные зависимости. Требуется проверка пакета.'
        return 50
    fi
}

inventory_php_rpms() {
    local inventory record name
    local -A core=()
    inventory="$(rpm -qa --qf "$RPM_RECORD_QF")" || {
        err 'Не удалось получить полную инвентаризацию RPM.'; return 50;
    }
    while IFS= read -r record; do
        name="${record%%|*}"
        case " $CORE_RPM_NAMES " in
            *" $name "*)
                if ! [[ "$record" =~ $RPM_RECORD_RE && "${BASH_REMATCH[5]}" = x86_64 ]]; then
                    err "Некорректная запись установленного PHP RPM: $record"; return 50
                fi
                if [ -n "${core[$name]:-}" ]; then
                    err "Установлено несколько RPM с именем $name."; return 50
                fi
                core["$name"]="$record"
                continue ;;
        esac
        case "$name" in
            php-zipstream) check_zipstream_library "$record" || return 50 ;;
            php-pecl-*|php-pear*|php-composer*|phpMyAdmin*|php-phpunit*) ;;
            php|php-*|php[0-9][0-9]-php|php[0-9][0-9]-php-*)
                err "Обнаружен нестандартный PHP RPM ($name). Требуется ручная проверка."; return 50 ;;
        esac
    done <<< "$inventory"
    for name in php php-cli php-common; do
        [ -n "${core[$name]:-}" ] || { err "Не установлен обязательный RPM $name."; return 50; }
    done
    printf '%s\n' "${core[@]}" | sort
}

verify_rpm_catalog() (
    local directory="$1" keyring="$2" line name verify grep_rc=0
    local manifest_pattern='[0-9a-fA-F]{64} [ *](\./)?[a-zA-Z0-9][a-zA-Z0-9_.+-]*\.rpm'
    local -A names=()
    need gpgv sha256sum grep head cp mkdir rm stat || return
    for name in SHA256SUMS SHA256SUMS.asc; do
        if ! [[ -f "$directory/$name" && ! -L "$directory/$name" ]] ||
           [ "$(stat -c %s -- "$directory/$name")" -gt 8388608 ]; then
            err "Некорректный файл подписанного каталога $name."; return 50
        fi
    done
    [[ -f "$keyring" && ! -L "$keyring" ]] || return 50
    verify="$(mktemp -d "$directory/.verification.XXXXXXXX")" || return 50
    trap 'rm -rf -- "$verify"' EXIT
    if ! cp -P -- "$keyring" "$verify/public.gpg" ||
       ! [[ -f "$verify/public.gpg" && ! -L "$verify/public.gpg" ]] ||
       ! head -n 1 -- "$directory/SHA256SUMS.asc" | grep -aEx -- $'-----BEGIN PGP SIGNATURE-----\r?' >/dev/null ||
       ! gpgv --homedir "$verify" --keyring "$verify/public.gpg" "$directory/SHA256SUMS.asc" "$directory/SHA256SUMS"; then
        err 'Не подтверждена подпись каталога RPM доверенным ключом.'; return 50
    fi
    grep -aExv -- "$manifest_pattern" "$directory/SHA256SUMS" >/dev/null || grep_rc=$?
    if [ "$grep_rc" -ne 1 ]; then
        err 'Недопустимая строка в SHA256SUMS.'; return 50
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        name="${line:66}"; name="${name#./}"
        if [ -n "${names[$name]:-}" ]; then
            err "Повтор имени в SHA256SUMS: $name"; return 50
        fi
        names["$name"]=1
    done < "$directory/SHA256SUMS"
    [ "${#names[@]}" -gt 0 ] || { err 'Подписанный каталог RPM пуст.'; return 50; }
)

load_auto_config() {
    local config="$1" line key value
    local -A seen=()
    AUTO_SOURCE='' AUTO_KEYRING='' AUTO_HEALTH_URL='' AUTO_SITE=''
    if ! config="$(trusted_rpm_keyring "$config")" || [ "$(stat -c %s -- "$config")" -gt 16384 ]; then
        err 'Нужна конфигурация автоматического обновления в защищённом файле root. Выполните настройку через меню.'; return 80
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        if [[ "$line" != *=* ]]; then
            err 'Конфигурация должна содержать строки SOURCE=, KEYRING= и HEALTH_URL=.'; return 80
        fi
        key="${line%%=*}"; value="${line#*=}"
        if ! [[ "$key" =~ ^(SOURCE|KEYRING|HEALTH_URL|SITE)$ ]]; then
            err "Неизвестное поле конфигурации: $key"; return 80
        fi
        if [ -z "$key" ] || [ -n "${seen[$key]:-}" ] || [ -z "$value" ] || [[ "$value" =~ [[:cntrl:]] ]]; then
            err 'В конфигурации есть повтор, пустое значение или управляющий символ.'; return 80
        fi
        case "$key" in
            SOURCE) AUTO_SOURCE="$value" ;;
            KEYRING) AUTO_KEYRING="$value" ;;
            HEALTH_URL) AUTO_HEALTH_URL="$value" ;;
            SITE) AUTO_SITE="$value" ;;
            *) err "Неизвестное поле конфигурации: $key"; return 80 ;;
        esac
        seen["$key"]=1
    done < "$config"
    if [[ -z "$AUTO_SOURCE" || "$AUTO_KEYRING" != /* || -z "$AUTO_HEALTH_URL" ]]; then
        err 'Заполните SOURCE, абсолютный путь KEYRING и HEALTH_URL.'; return 80
    fi
    while [[ "$AUTO_SOURCE" == */ && "$AUTO_SOURCE" != / ]]; do AUTO_SOURCE="${AUTO_SOURCE%/}"; done
    if ! [[ "$AUTO_SOURCE" == /* || "$AUTO_SOURCE" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?(/[a-zA-Z0-9_./~%+@=-]*)?$ ]]; then
        err 'SOURCE должен быть абсолютным путём или HTTPS-адресом каталога без учётных данных и параметров.'; return 80
    fi
    # Только точные адреса выпусков проекта переносятся на выбранную ветку.
    # Пользовательский источник сохраняется буквально и проверяется как обычно.
    case "$AUTO_SOURCE" in
        https://github.com/vitikevich-landau/bitrix-php82-updater/releases/download/php-8.2.35-el7-r1|\
        https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.2.35-el7-r1|\
        https://github.com/vitikevich-landau/bitrix-php-updater/releases/download/php-8.3.36-el7-r1)
            AUTO_SOURCE="$PROJECT_RELEASE_URL" ;;
    esac
    if [ -n "$AUTO_SITE" ]; then validate_managed_site "$AUTO_SITE" || return 80; fi
    if [ "$AUTO_HEALTH_URL" != auto ]; then health_url_parts "$AUTO_HEALTH_URL" >/dev/null || return 80; fi
}

fetch_auto_asset() {
    local source="$1" name="$2" destination="$3" path
    if [[ "$source" == https://* ]]; then
        safe_download "$source/$name" "$destination" || return 81
    else
        path="$source/$name"
        if ! [[ -f "$path" && ! -L "$path" ]] ||
           ! cp -P -- "$path" "$destination.part" ||
           ! [[ -f "$destination.part" && ! -L "$destination.part" && -s "$destination.part" ]] ||
           ! mv -- "$destination.part" "$destination"; then
            err "Не удалось получить файл комплекта $name."; return 81
        fi
    fi
}

prepare_auto_catalog() {
    local source="$1" kind="$2" directory="$3" keyring="$4"
    mkdir -m 0700 -- "$directory" || return 81
    fetch_auto_asset "$source" "$kind-SHA256SUMS" "$directory/SHA256SUMS" &&
    fetch_auto_asset "$source" "$kind-SHA256SUMS.asc" "$directory/SHA256SUMS.asc" &&
    verify_rpm_catalog "$directory" "$keyring"
}

run_auto_update() (
    local config="$1" unattended="$2" selector="${3:-}" work='' record identity name line digest current
    local -A old_hashes=()
    require_root || return
    need rpm php httpd systemctl curl awk sort grep cmp cp chmod stat mktemp || return
    if ! profile_check; then
        status_line info 'Следующий шаг — bash install.sh --plan'; return 20
    fi
    current="$PHP_CURRENT"
    load_auto_config "$config" || return
    MANAGED_SITE=''
    if [ -n "$selector" ]; then AUTO_HEALTH_URL=auto; fi
    if [ "$AUTO_HEALTH_URL" = auto ]; then
        select_managed_site "${selector:-$AUTO_SITE}" "$unattended" || return
    fi
    health_target_validate "$AUTO_HEALTH_URL" || return 80
    if [ "$current" = "$TARGET_PHP" ]; then
        run_update '' "$AUTO_HEALTH_URL" '' '' "$unattended"; return
    fi
    if [[ ! "${current##*.}" =~ ^[0-9]{1,3}$ ]] || [ "${current##*.}" -ge "${TARGET_PHP##*.}" ]; then
        err "Для PHP $current обновление до $TARGET_PHP не требуется."; return 20
    fi
    if [ "$unattended" = 0 ] && [ ! -t 0 ]; then
        err 'Для подтверждения установки нужен терминал. Для заранее согласованного запуска нужны --unattended и --backup-verified.'; return 12
    fi
    need gpgv sha256sum || return
    AUTO_KEYRING="$(trusted_rpm_keyring "$AUTO_KEYRING")" || {
        err 'Доверенный keyring недоступен или имеет небезопасные права.'; return 80
    }
    ensure_session_dir "$UPDATER_STATE" && ensure_session_dir "$WORK_ROOT" || return
    check_disk "$WORK_ROOT" 1024 || return
    work="$(mktemp -d "$WORK_ROOT/auto-prepare.XXXXXXXX")" || return 81
    trap 'rm -rf -- "$work"' EXIT
    if ! inventory_php_rpms > "$work/inventory" ||
       ! awk -F'|' -v version="$current" 'NF != 5 || $3 != version { exit 1 }' "$work/inventory"; then
        err 'Исходный комплект RPM PHP не согласован с версией CLI.'; return 80
    fi
    if ! http_check "$AUTO_HEALTH_URL" "$current"; then
        menu_record web failed
        err 'Исходный веб-PHP не прошёл проверку. Исправьте маршрут проверки или сайт перед обновлением.'; return 80
    fi
    menu_record web ok
    cp -P -- "$AUTO_KEYRING" "$work/public.gpg" && chmod 0600 -- "$work/public.gpg" || return 81
    msg 'Проверка подписанных каталогов новых и прежних RPM...'
    prepare_auto_catalog "$AUTO_SOURCE" OLD "$work/old" "$work/public.gpg" &&
    prepare_auto_catalog "$AUTO_SOURCE" NEW "$work/new" "$work/public.gpg" || return 81
    while IFS= read -r line || [ -n "$line" ]; do
        name="${line:66}"; name="${name#./}"
        old_hashes["$name"]="${line:0:64}"
    done < "$work/old/SHA256SUMS"
    while IFS= read -r record; do
        identity="$(printf '%s\n' "$record" | sha256sum)" || return 81
        name="${record%%|*}-${identity%% *}.rpm"
        digest="${old_hashes[$name]:-}"
        if [ -z "$digest" ]; then
            err "В подписанном архиве отсутствует точный прежний RPM: $record"; return 81
        fi
        fetch_auto_asset "$AUTO_SOURCE" "$name" "$work/old/$name" || return 81
        if ! (cd -- "$work/old" && printf '%s  %s\n' "$digest" "$name" | sha256sum --status -c -); then
            err "Контрольная сумма прежнего RPM не совпала: $name"; return 81
        fi
    done < "$work/inventory"
    while IFS= read -r line || [ -n "$line" ]; do
        name="${line:66}"; name="${name#./}"; digest="${line:0:64}"
        fetch_auto_asset "$AUTO_SOURCE" "$name" "$work/new/$name" || return 81
        if ! (cd -- "$work/new" && printf '%s  %s\n' "$digest" "$name" | sha256sum --status -c -); then
            err "Контрольная сумма нового RPM не совпала: $name"; return 81
        fi
    done < "$work/new/SHA256SUMS"
    select_rpms "$work/old" old "$work/inventory" &&
    select_rpms "$work/new" new "$work/inventory" || return 81
    status_line ok 'Комплекты проверены. Переходим к проверкам и установке PHP.'
    run_update "$work/new" "$AUTO_HEALTH_URL" "$work/old" "$work/public.gpg" "$unattended" "$work/inventory"
)

auto_update_dispatch() {
    local config='/etc/bitrix-php-update.conf' unattended=0 backup_verified=0 use_default=1 selector=''
    local -a setup_options=()
    MANAGED_SITE=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --config)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
                    err 'Укажите путь после --config.'; return 2
                fi
                config="$2"; use_default=0; shift 2 ;;
            --site)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
                    err 'Укажите имя сайта или DocumentRoot после --site.'; return 2
                fi
                selector="$2"; shift 2 ;;
            --unattended) unattended=1; shift ;;
            --backup-verified) backup_verified=1; shift ;;
            *) err "Параметр $1 недопустим для --auto-update."; return 2 ;;
        esac
    done
    if [ "$unattended" != "$backup_verified" ]; then
        err 'Для обновления без запросов параметры --unattended и --backup-verified нужны вместе.'; return 2
    fi
    if [ "$use_default" = 1 ] && [ ! -e "$config" ] && [ ! -L "$config" ]; then
        [ -z "$selector" ] || setup_options+=(--site "$selector")
        [ "$unattended" = 0 ] || setup_options+=(--unattended)
        setup_auto_update "${setup_options[@]}" || return
        # Setup saved the exact vhost record, including an interactive choice.
        # Reusing a hostname or DocumentRoot selector could ask the same question twice.
        selector=''
    fi
    run_auto_update "$config" "$unattended" "$selector"
}

# Проверяем подпись и хеши копий в новом закрытом каталоге сессии.
stage_rpm_bundle() (
    local source="$1" dest="$2" keyring="$3" name path line digest copied=0
    local rpm_filename='[a-zA-Z0-9][a-zA-Z0-9_.+-]*\.rpm'
    local -A listed=()
    need gpgv sha256sum grep head cp mkdir rm || return
    while [[ "$source" == */ && "$source" != / ]]; do source="${source%/}"; done
    if ! [[ -d "$source" && ! -L "$source" && -f "$keyring" && ! -L "$keyring" ]]; then
        err 'Требуются каталог RPM и доверенный файл ключей без символических ссылок.'; return 50
    fi
    [[ "$dest" == /* ]] || dest="$PWD/$dest"
    umask 077
    mkdir -m 0700 -- "$dest" || return 50
    trap '[ "$?" -eq 0 ] || rm -rf -- "$dest"' EXIT
    for name in SHA256SUMS SHA256SUMS.asc; do
        path="$source/$name"
        listed["$name"]=1
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then continue; fi
        if ! [[ -f "$path" && ! -L "$path" ]] || ! cp -P -- "$path" "$dest/$name" ||
            ! [[ -f "$dest/$name" && ! -L "$dest/$name" ]]; then
            err "В каталоге RPM требуется обычный файл $name."; return 50
        fi
    done
    verify_rpm_catalog "$dest" "$keyring" || return 50
    while IFS= read -r line || [ -n "$line" ]; do
        digest="${line:0:64}"
        name="${line:66}"
        name="${name#./}"
        if [ -n "${listed[$name]:-}" ]; then
            err "Повтор имени в SHA256SUMS: $name"; return 50
        fi
        path="$source/$name"
        listed["$name"]=1
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then continue; fi
        if ! [[ -f "$path" && ! -L "$path" ]] || ! cp -P -- "$path" "$dest/$name" ||
            ! [[ -f "$dest/$name" && ! -L "$dest/$name" ]]; then
            err "В каталоге RPM требуется обычный файл $name."; return 50
        fi
        if ! (cd -- "$dest" && printf '%s  %s\n' "$digest" "$name" | sha256sum --status -c -); then
            err "Контрольная сумма RPM не совпала: $name"; return 50
        fi
        copied=$((copied + 1))
    done < "$dest/SHA256SUMS"
    if [ "$copied" -eq 0 ]; then
        err 'В каталоге нет RPM из подписанного манифеста.'; return 50
    fi
    shopt -s nullglob dotglob
    for path in "$source"/*; do
        name="${path##*/}"
        if ! [[ -f "$path" && ! -L "$path" ]] ||
            ! [[ "$name" = SHA256SUMS || "$name" = SHA256SUMS.asc ||
                ( "$name" =~ ^$rpm_filename$ && -n "${listed[$name]:-}" ) ]]; then
            err "Посторонний файл в каталоге RPM: $path"; return 50
        fi
    done
)

# Выбор по снимку, без запросов к текущему состоянию RPM.
select_rpms() {
    local rpm_dir="$1" mode="$2" inventory="$3" path record name version release arch source_package
    local el7_release='(^|\.)el7([._+~^-]|$)'
    local -A expected=() matches=()
    local -a names=() selected=()
    SELECTED_RPMS=()
    if ! [[ -d "$rpm_dir" && ! -L "$rpm_dir" && -f "$inventory" && ! -L "$inventory" &&
        ( "$mode" = new || "$mode" = old ) ]]; then
        err 'Нужны подготовленные RPM, снимок пакетов и режим new или old.'; return 50
    fi
    while IFS= read -r record || [ -n "$record" ]; do
        if ! [[ "$record" =~ $RPM_RECORD_RE && "${BASH_REMATCH[5]}" = x86_64 ]]; then
            err "Некорректная запись в снимке RPM: $record"; return 50
        fi
        name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[3]}"
        if [ "${version%.*}" != "$TARGET_BRANCH" ]; then
            err "Ветка PHP в снимке RPM не совпадает с выбранной $TARGET_BRANCH: $record"; return 50
        fi
        if ! [[ " $CORE_RPM_NAMES " == *" $name "* ]] || [ -n "${expected[$name]:-}" ]; then
            err "Недопустимый или повторный пакет в снимке RPM: $name"; return 50
        fi
        expected["$name"]="$record"
        names+=("$name")
    done < "$inventory"
    for name in php php-cli php-common; do
        [ -n "${expected[$name]:-}" ] || { err "В снимке отсутствует обязательный RPM $name."; return 50; }
    done
    for path in "$rpm_dir"/*.rpm; do
        if ! [[ -f "$path" && ! -L "$path" ]]; then
            err "В подготовленном каталоге требуется обычный RPM: $path"; return 50
        fi
        record="$(rpm -qp --nosignature --qf "$RPM_RECORD_QF" -- "$path")" || return 50
        if ! [[ "$record" =~ $RPM_RECORD_RE ]]; then
            err "Не удалось прочитать NEVRA пакета: $path"; return 50
        fi
        name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[3]}"
        release="${BASH_REMATCH[4]}"
        arch="${BASH_REMATCH[5]}"
        [ -n "${expected[$name]:-}" ] || continue
        case "$mode" in
            new) [ "$version" = "$TARGET_PHP" ] || continue ;;
            old) [ "$record" = "${expected[$name]}" ] || continue ;;
        esac
        if ! [[ "$arch" = x86_64 && "$release" =~ $el7_release ]]; then
            err "Неподдерживаемая архитектура или release: $record"; return 50
        fi
        # На RPM 4.11 исходный пакет может также иметь ARCH=x86_64.
        source_package="$(rpm -qp --nosignature --qf '%{SOURCEPACKAGE}' -- "$path")" || return 50
        if [ "$source_package" != '(none)' ]; then
            err "Исходный RPM нельзя использовать как бинарный пакет: $path"; return 50
        fi
        rpm -K --nosignature -- "$path" >/dev/null || {
            err "RPM не прошёл проверку целостности: $path"; return 50;
        }
        if [ -n "${matches[$name]:-}" ]; then
            err "Найдено несколько подходящих RPM для $name."; return 50
        fi
        matches["$name"]="$path"
    done
    for name in "${names[@]}"; do
        if [ -z "${matches[$name]:-}" ]; then
            err "Не найден подходящий RPM для $name ($mode)."; return 50
        fi
        selected+=("${matches[$name]}")
    done
    SELECTED_RPMS=("${selected[@]}")
    printf 'Пакеты для %s (%s)\n' "$mode" "${#SELECTED_RPMS[@]}"
    printf '  %s\n' "${SELECTED_RPMS[@]}"
}

backup_configs() {
    local dir="$1" mode="$2" roots=() p
    local -a php_flags=(-d display_startup_errors=1 -d display_errors=stderr)
    for p in /etc/php.ini /etc/php.d /etc/httpd/conf /etc/httpd/conf.d /etc/httpd/conf.modules.d /etc/httpd/bx /etc/httpd/bx-scale /etc/nginx; do
        if [ -e "$p" ] || [ -L "$p" ]; then roots+=("${p#/}"); fi
    done
    [ "${#roots[@]}" -gt 0 ] || { err 'Не найдено конфигурационных файлов для сохранения.'; return 60; }
    if ! tar -C / -czpf "$dir/configuration.tar.gz" -- "${roots[@]}" 2>"$dir/tar-warnings.log"; then
        rm -f -- "$dir/configuration.tar.gz"
        return 60
    fi
    if [ "$mode" = baseline ]; then
        if ! php "${php_flags[@]}" -m > "$dir/php-modules-before.txt" 2>"$dir/php-modules-errors-before.txt" ||
           ! php "${php_flags[@]}" -v > "$dir/php-before.txt" 2>>"$dir/php-modules-errors-before.txt" ||
           ! grep -Fxq '[PHP Modules]' "$dir/php-modules-before.txt" ||
           [ -s "$dir/php-modules-errors-before.txt" ]; then
            err 'Не удалось получить исходный список модулей PHP без ошибок.'
            cat "$dir/php-modules-errors-before.txt"
            return 60
        fi
        httpd -t > "$dir/httpd-before.txt" 2>&1 || { err 'Apache содержит ошибку ещё до обновления.'; return 60; }
    fi
    msg "Архив конфигураций сохранён: $dir/configuration.tar.gz"
}

# Проверяет синтаксис URL без запроса. Выводит имя узла и порт через пробел.
health_url_parts() {
    local url="$1" scheme host port path
    local pattern="^(https?)://([A-Za-z0-9.-]+)(:([1-9][0-9]{0,4}))?(/[A-Za-z0-9._~/%+!$&'()*+,;=:@-]+)$"
    local dns_label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    local dns_last='[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    if [[ ! "$url" =~ $pattern ]]; then
        err 'Укажите HTTP(S)-адрес защищённого веб-теста с путём, без учётных данных, запроса или фрагмента.'
        return 63
    fi
    scheme="${BASH_REMATCH[1]}"
    host="${BASH_REMATCH[2]}"
    port="${BASH_REMATCH[4]}"
    path="${BASH_REMATCH[5]}"
    # Числовые псевдонимы и внешние IP могут обходить кеш DNS curl.
    if [ "$host" != '127.0.0.1' ] && { [ "${#host}" -gt 253 ] || [[ ! "$host" =~ ^($dns_label\.)*$dns_last$ ]]; }; then
        err 'В адресе веб-теста допустимо DNS-имя или 127.0.0.1.'; return 63
    fi
    if [[ "$path" == *%* ]]; then
        local encoded="$path"
        while [[ "$encoded" == *%* ]]; do
            encoded="${encoded#*%}"
            [[ "$encoded" =~ ^[[:xdigit:]]{2} ]] || { err 'Некорректное кодирование пути веб-теста.'; return 63; }
            encoded="${encoded:2}"
        done
    fi
    if [ -z "$port" ]; then
        case "$scheme" in https) port=443;; http) port=80;; esac
    elif [ "$port" -gt 65535 ]; then
        err 'Порт веб-теста должен быть от 1 до 65535.'; return 63
    fi
    printf '%s %s\n' "$host" "$port"
}

health_target_validate() {
    if [ "$1" = auto ]; then
        validate_managed_site "${MANAGED_SITE:-}"
    else
        health_url_parts "$1" >/dev/null
    fi
}

http_check() (
    local url="$1" expected="$2" address host port response marker
    if [ "$url" = auto ]; then managed_http_check "$expected"; return; fi
    address="$(health_url_parts "$url")" || return
    [[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err 'Не задана ожидаемая версия веб-PHP.'; return 63; }
    need curl head cmp mktemp || return
    read -r host port <<< "$address"
    response="$(mktemp)" || { err 'Не удалось создать файл для проверки HTTP.'; return 63; }
    trap 'rm -f -- "$response"' EXIT
    # Запрос идёт на локальный Apache с исходными Host и SNI. Ограничиваем
    # поток также без Content-Length: старый curl ограничивает только известный размер.
    if ! curl -q --silent --show-error --globoff --proto '=http,https' \
              --connect-timeout 5 --max-time 20 --noproxy '*' --resolve "$host:$port:127.0.0.1" \
              --max-filesize 4096 --write-out '\n%{http_code}\n%{remote_ip}\n%{remote_port}\n' \
              -- "$url" | head -c 4096 > "$response"; then
        err 'Не удалось выполнить локальную HTTP-проверку.'; return 63
    fi
    marker="BITRIX_MASTER_OK $expected apache2handler"
    if ! cmp -s "$response" <(printf '%s\n200\n127.0.0.1\n%s\n' "$marker" "$port") &&
       ! cmp -s "$response" <(printf '%s\n\n200\n127.0.0.1\n%s\n' "$marker" "$port"); then
        err "Веб-тест должен вернуть HTTP 200 и единственную строку «$marker» с локального порта $port."
        return 63
    fi
    status_line ok "Веб-PHP $expected (apache2handler) подтверждён на $url, HTTP 200."
)

verify_after() {
    local dir="$1" url="$2" expected="$3" baseline="${4-}" oldm version rc=0
    local php_errors="$dir/php-modules-errors-after.txt"
    local php_modules="$dir/php-modules-after.txt"
    local -a php_flags=(-d display_startup_errors=1 -d display_errors=stderr)
    if [ "$#" -lt 4 ] && [ -e "$dir/php-modules-before.txt" ]; then
        baseline="$dir/php-modules-before.txt"
    fi
    [[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err 'Не задана ожидаемая версия PHP CLI.'; return 1; }
    msg 'Контроль: CLI PHP'
    php "${php_flags[@]}" -v 2>"$php_errors" || rc=1
    if ! version="$(php "${php_flags[@]}" -r 'echo PHP_VERSION;' 2>>"$php_errors")" ||
       [ "$version" != "$expected" ]; then
        err "PHP CLI не совпадает с ожидаемой версией $expected."; rc=1
    fi
    msg 'Контроль: модули PHP'
    if ! php "${php_flags[@]}" -m >"$php_modules" 2>>"$php_errors" ||
       ! grep -Fxq '[PHP Modules]' "$php_modules"; then
        err 'Не удалось получить список модулей PHP CLI.'; rc=1
    fi
    if [ -s "$php_errors" ]; then
        err 'При запуске PHP CLI были ошибки:'; cat -- "$php_errors"; rc=1
    fi
    if [ -n "$baseline" ]; then
        if [ ! -f "$baseline" ] || [ ! -r "$baseline" ]; then
            err "Недоступен исходный список модулей PHP: $baseline"; rc=1
        else
            # Пропускаем только служебные заголовки и пустые строки.
            while IFS= read -r oldm || [ -n "$oldm" ]; do
                case "$oldm" in ''|'[PHP Modules]'|'[Zend Modules]') continue;; esac
                if ! grep -Fxiq -- "$oldm" "$php_modules"; then
                    err "Пропал модуль: $oldm"; rc=1
                fi
            done < "$baseline" || rc=1
        fi
    fi
    msg 'Контроль: конфигурация и служба Apache'
    httpd -t || rc=1
    systemctl is-active --quiet httpd || { err 'Apache не запущен.'; rc=1; }
    http_check "$url" "$expected" || rc=1
    return "$rc"
}

apache_health_diagnostics() {
    local dir="$1" log
    {
        printf '=== systemctl status httpd ===\n'
        if command -v systemctl >/dev/null && command -v timeout >/dev/null; then
            timeout 8s systemctl status httpd --no-pager --full 2>&1 | head -c 16384 || true
        fi
        printf '\n=== journalctl -u httpd ===\n'
        if command -v journalctl >/dev/null && command -v timeout >/dev/null; then
            timeout 8s journalctl -u httpd -n 60 --no-pager 2>&1 | head -c 32768 || true
        fi
        for log in /var/log/httpd/error_log /var/log/httpd/error.log; do
            if [ -f "$log" ] && [ -r "$log" ]; then
                printf '\n=== %s ===\n' "$log"
                tail -c 32768 -- "$log" | tail -n 60 || true
            fi
        done
    } > "$dir/apache-health-failure.log" || return 0
    msg "Журналы Apache: $dir/apache-health-failure.log"
}

resolve_rpm_dir() {
    local p="$1"
    if [ -n "$p" ]; then printf '%s' "$p"; return; fi
    if [ -d /root/rpmbuild/RPMS/x86_64 ]; then printf '%s' '/root/rpmbuild/RPMS/x86_64'; return; fi
    if [ -d "$WORK_ROOT/packages/x86_64" ]; then printf '%s' "$WORK_ROOT/packages/x86_64"; return; fi
    printf ''
}

rpm_core_snapshot() {
    # При восстановлении php/php-cli/php-common могут временно отсутствовать.
    rpm -qa --qf "$RPM_RECORD_QF" |
        awk -F'|' -v names="$CORE_RPM_NAMES" 'BEGIN { n = split(names, items, " "); for (i = 1; i <= n; i++) core[items[i]] = 1 } $1 in core' |
        sort
}

update_recovery_hint() {
    err "Для восстановления используйте --rollback --session $SESSION_NAME или проверенный снимок."
    printf 'Архив конфигураций для ручной проверки: %s/configuration.tar.gz\n' "$SESSION_DIR"
}

check_external_rpm_obsoletes() {
    local installed obsoletes package name
    [ "$#" -gt 0 ] || return 0
    installed="$(rpm -qa --qf '%{NAME}\n')" || return 1
    for package in "$@"; do
        obsoletes="$(rpm -qp --nosignature --qf '[%{OBSOLETENAME}\n]' -- "$package")" || return 1
        while IFS= read -r name; do
            if [ -n "$name" ] && [[ " $CORE_RPM_NAMES " != *" $name "* ]] &&
               grep -Fxq -- "$name" <<< "$installed"; then
                err "RPM $package может удалить $name, которого нет в плане восстановления."
                return 1
            fi
        done <<< "$obsoletes"
    done
}

trusted_rpm_keyring() {
    local supplied="$1" path parent metadata owner mode
    [[ "$supplied" == /* && ! -L "$supplied" ]] || return 1
    path="$(readlink -e -- "$supplied")" || return 1
    [ -f "$path" ] && [ -s "$path" ] || return 1
    parent="$path"
    while :; do
        metadata="$(stat -c '%u:%a' -- "$parent")" || return 1
        IFS=: read -r owner mode <<< "$metadata"
        [[ "$owner" = 0 && "$mode" =~ ^[0-7]{1,4}$ ]] || return 1
        (( (8#$mode & 022) == 0 )) || return 1
        [ "$parent" != / ] || break
        parent="$(dirname -- "$parent")" || return 1
    done
    printf '%s\n' "$path"
}

run_update() {
    local rpmdir="$1" url="$2" rollback_dir="$3" keyring="$4" unattended="${5:-0}" expected_inventory="${6:-}" current dir file
    local -a update_rpms rollback_rpms
    require_root || return
    need rpm php httpd systemctl curl tar awk sort grep cmp cp chmod sync || return
    health_target_validate "$url" || return 61
    session_setup || return
    dir="$SESSION_DIR"
    if [ "$url" = auto ] && ! managed_site_save "$dir/site-probe"; then
        err 'Не удалось сохранить описание сайта для проверки после отката.'
        mark_state precheck_failed
        return 61
    fi
    profile_check || { mark_state precheck_failed; return 61; }
    if [ "$PHP_CURRENT" = "$TARGET_PHP" ]; then
        if ! inventory_php_rpms > "$dir/rpm-recheck.txt" ||
           ! awk -F'|' -v version="$TARGET_PHP" 'NF != 5 || $3 != version { exit 1 }' "$dir/rpm-recheck.txt"; then
            err 'Версия CLI целевая, но установленный набор RPM PHP не согласован.'
            mark_state precheck_failed
            return 61
        fi
        if ! verify_after "$dir" "$url" "$TARGET_PHP" ''; then
            mark_state precheck_failed
            apache_health_diagnostics "$dir"
            return 61
        fi
        mark_state already_current || return
        status_line ok "PHP $TARGET_PHP уже установлен, CLI и сайт прошли проверку."
        return 0
    fi
    current="$PHP_CURRENT"
    if [[ ! "${current##*.}" =~ ^[0-9]{1,3}$ ]] || [ "${current##*.}" -ge "${TARGET_PHP##*.}" ]; then
        err "Исходная версия PHP $current не поддерживает обновление до $TARGET_PHP."
        mark_state precheck_failed
        return 61
    fi
    if [ -z "$rpmdir" ] || [ -z "$rollback_dir" ] || ! keyring="$(trusted_rpm_keyring "$keyring")"; then
        err 'Нужны каталоги новых и прежних подписанных RPM. Доверенный keyring укажите абсолютным путём в каталоге root без прав записи для группы и остальных.'
        mark_state precheck_failed
        return 61
    fi
    check_disk "$UPDATER_STATE" 300 || return 61
    check_disk /var/lib 300 || return 61
    inventory_php_rpms > "$dir/rpm-before.txt" || { mark_state precheck_failed; return 61; }
    if [ -n "$expected_inventory" ] && ! cmp -s "$expected_inventory" "$dir/rpm-before.txt"; then
        err 'Состав PHP RPM изменился во время подготовки. Повторите --auto-update.'
        mark_state precheck_failed
        return 61
    fi
    if ! cp --no-dereference -- "$keyring" "$dir/trusted-keyring.gpg" ||
       [ ! -f "$dir/trusted-keyring.gpg" ] || [ -L "$dir/trusted-keyring.gpg" ] ||
       ! chmod 0600 -- "$dir/trusted-keyring.gpg" || ! private_session_file "$dir/trusted-keyring.gpg"; then
        err 'Не удалось сохранить закрытую копию доверенного кольца ключей.'
        mark_state precheck_failed
        return 61
    fi
    if ! stage_rpm_bundle "$rollback_dir" "$dir/rpm-rollback" "$dir/trusted-keyring.gpg" ||
       ! select_rpms "$dir/rpm-rollback" old "$dir/rpm-before.txt"; then
        err 'Нужен полный подписанный набор прежних RPM с точным совпадением NEVRA.'
        mark_state precheck_failed
        return 61
    fi
    rollback_rpms=("${SELECTED_RPMS[@]}")
    if ! stage_rpm_bundle "$rpmdir" "$dir/rpm-update" "$dir/trusted-keyring.gpg" ||
       ! select_rpms "$dir/rpm-update" new "$dir/rpm-before.txt"; then
        mark_state precheck_failed
        return 61
    fi
    update_rpms=("${SELECTED_RPMS[@]}")
    for file in "${update_rpms[@]}"; do
        rpm -qp --nosignature --qf "$RPM_RECORD_QF" -- "$file" || { mark_state precheck_failed; return 61; }
    done > "$dir/rpm-target.txt.unsorted"
    sort "$dir/rpm-target.txt.unsorted" > "$dir/rpm-target.txt" || return 61
    rm -f -- "$dir/rpm-target.txt.unsorted"
    printf '%s\n' "$current" > "$dir/php-version-before.txt" || return 61
    printf '%s\n' "$url" > "$dir/url" || return 61

    msg "План: PHP $current -> $TARGET_PHP. Проверяем сайт $url"
    cat "$dir/rpm-target.txt"
    if ! check_external_rpm_obsoletes "${update_rpms[@]}" "${rollback_rpms[@]}" ||
       ! rpm -Uvh --oldpackage --replacepkgs --test "${rollback_rpms[@]}" ||
       ! rpm -Uvh --test "${update_rpms[@]}"; then
        err 'Предварительная проверка RPM-транзакции не прошла.'
        mark_state install_test_failed
        return 61
    fi
    if [ "$unattended" = 1 ]; then
        msg 'Резервная копия и запуск обновления подтверждены параметрами --backup-verified и --unattended.'
    else
        confirm_phrase 'Подтвердите существование актуального, проверенного снимка ВМ или полной резервной копии сервера.' 'СНИМОК ПРОВЕРЕН' || return
        confirm_phrase 'Установить указанные пакеты и перезапустить Apache? Сайт может быть временно недоступен.' 'ОБНОВИТЬ PHP' || return
    fi
    if ! backup_configs "$dir" baseline; then
        mark_state backup_failed
        return 62
    fi
    if ! systemctl is-active --quiet httpd || ! http_check "$url" "$current"; then
        err 'Сайт или служба Apache не прошли проверку перед установкой.'
        mark_state precheck_failed
        return 62
    fi
    if ! inventory_php_rpms > "$dir/rpm-recheck.txt" ||
       ! cmp -s "$dir/rpm-before.txt" "$dir/rpm-recheck.txt"; then
        err 'Состав или версии RPM PHP изменились после предварительной проверки.'
        mark_state precheck_failed
        return 62
    fi
    if ! check_external_rpm_obsoletes "${update_rpms[@]}" "${rollback_rpms[@]}" ||
       ! rpm -Uvh --test "${update_rpms[@]}"; then
        mark_state install_test_failed
        return 62
    fi
    mark_state installing && sync || return 62
    if ! rpm -Uvh "${update_rpms[@]}"; then
        mark_state installation_failed
        err 'RPM-транзакция завершилась ошибкой.'
        update_recovery_hint
        return 62
    fi
    mark_state installed || { update_recovery_hint; return 62; }
    if ! rpm_core_snapshot > "$dir/rpm-after.txt" ||
       ! cmp -s "$dir/rpm-target.txt" "$dir/rpm-after.txt"; then
        mark_state verify_failed
        err 'Установленные RPM не совпадают с согласованным набором.'
        update_recovery_hint
        return 64
    fi
    if ! httpd -t; then
        mark_state apache_config_failed
        err 'Проверка конфигурации Apache после установки завершилась ошибкой.'
        apache_health_diagnostics "$dir"
        update_recovery_hint
        return 63
    fi
    msg 'Перезапуск Apache для загрузки обновлённого mod_php...'
    if ! systemctl restart httpd; then
        mark_state restart_failed
        apache_health_diagnostics "$dir"
        update_recovery_hint
        return 63
    fi
    mark_state verifying || { update_recovery_hint; return 64; }
    if ! verify_after "$dir" "$url" "$TARGET_PHP" "$dir/php-modules-before.txt"; then
        mark_state verify_failed
        apache_health_diagnostics "$dir"
        update_recovery_hint
        return 64
    fi
    mark_state completed || return
    status_line ok "PHP $TARGET_PHP установлен. Apache и сайт прошли проверки."
    printf 'Сессия обновления: %s\nАрхив конфигураций: %s/configuration.tar.gz\n' "$SESSION_NAME" "$dir"
    echo 'Проверьте админку Битрикса и ключевые функции сайта вручную.'
}

plan_rpm_rollback() {
    # Допустимы пропуск пакета и по одной точной записи из обоих наборов.
    awk -F'|' -v branch="$TARGET_BRANCH" '
        FILENAME == ARGV[1] {
            split($3, version, ".")
            if (NF != 5 || version[1] "." version[2] != branch) { invalid = 1; exit 1 }
            if ($1 in old) { invalid = 1; exit 1 }
            names[++n] = $1
            old[$1] = $0
            next
        }
        FILENAME == ARGV[2] {
            split($3, version, ".")
            if (NF != 5 || version[1] "." version[2] != branch) { invalid = 1; exit 1 }
            if (!($1 in old) || ($1 in target)) { invalid = 1; exit 1 }
            target[$1] = $0
            next
        }
        {
            if (!($1 in old) || seen[$0]++ || ($0 != old[$1] && $0 != target[$1])) {
                print "Непредусмотренная запись RPM: " $0 > "/dev/stderr"
                invalid = 1
                exit 1
            }
            count[$1]++
        }
        END {
            if (invalid) exit 1
            for (i = 1; i <= n; i++) {
                name = names[i]
                if (!(name in target)) exit 1
                if (count[name] == 2) print "replace"
                else if (seen[old[name]]) print "keep"
                else print "restore"
            }
        }
    ' "$1" "$2" "$3"
}

# A receipt on the original session survives interrupted recovery processes.
record_rollback_rpm_state() {
    local source="$1" state="$2" tmp
    tmp="$(mktemp "$source/.rollback-rpm-state.XXXXXXXX")" || return 1
    if ! { printf '%s\n' "$state" > "$tmp" && mv -f -- "$tmp" "$source/rollback-rpm-state"; }; then
        rm -f -- "$tmp"
        return 1
    fi
}

rollback_rpm_uncertain() {
    local source="$1" id="$2" original_state="$3" receipt="$1/rollback-rpm-state" attempt state
    if [ -e "$receipt" ] || [ -L "$receipt" ]; then
        if ! private_session_file "$receipt"; then
            err 'Небезопасная запись состояния восстановления RPM.'
            return 2
        fi
        case "$(cat -- "$receipt")" in
            pending) return 0 ;;
            complete) return 1 ;;
            *) err 'Неизвестное состояние восстановления RPM.'; return 2 ;;
        esac
    fi
    case "$original_state" in installing|installation_failed) return 0 ;; esac
    # Older releases did not write a receipt. An earlier incomplete RPM stage
    # requires one conservative repair even if another old attempt later succeeded.
    for attempt in "$UPDATER_STATE"/sessions/*; do
        private_session_dir "$attempt" || continue
        private_session_file "$attempt/rollback-of" || continue
        [ "$(cat -- "$attempt/rollback-of")" = "$id" ] || continue
        if ! private_session_file "$attempt/state"; then
            err 'В истории отката нет пригодного состояния сессии.'
            return 2
        fi
        state="$(cat -- "$attempt/state")" || return 2
        case "$state" in
            rolling_back|rollback_failed) return 0 ;;
            rollback_verify_failed)
                if ! private_session_file "$attempt/rpm-after.txt" ||
                   ! cmp -s "$source/rpm-before.txt" "$attempt/rpm-after.txt"; then
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

run_rollback() {
    local id="$1" url="$2" unattended="${3:-0}" source dir old_php original_url state file action i=0 uncertainty_rc=0
    local -a rollback_rpms=() rollback_flags=(--oldpackage)
    require_root || return
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || { err 'Укажите идентификатор сессии обновления через --session.'; return 71; }
    menu_record origin "$id"
    need rpm httpd systemctl curl tar awk sort grep cmp sync || return
    session_setup || return
    dir="$SESSION_DIR"
    source="$UPDATER_STATE/sessions/$id"
    printf '%s\n' "$id" > "$dir/rollback-of" || return 71
    platform_check || { mark_state rollback_precheck_failed; return 71; }
    bitrix_env_rpm_guard || { mark_state rollback_precheck_failed; return 71; }

    if ! private_session_dir "$source" || ! private_session_dir "$source/rpm-rollback"; then
        err "Защищённая сессия обновления $id не найдена."
        mark_state rollback_precheck_failed
        return 71
    fi
    for file in state rpm-before.txt rpm-target.txt php-version-before.txt php-modules-before.txt configuration.tar.gz trusted-keyring.gpg; do
        if ! private_session_file "$source/$file" || [ ! -s "$source/$file" ]; then
            err "В сессии $id нет пригодного файла восстановления: $file"
            mark_state rollback_precheck_failed
            return 71
        fi
    done
    state="$(cat "$source/state")" || return 71
    case "$state" in
        installing|installation_failed|installed|apache_config_failed|restart_failed|verifying|verify_failed|completed) ;;
        *) err "Состояние «$state» не допускает отката RPM."; mark_state rollback_precheck_failed; return 71 ;;
    esac
    old_php="$(cat "$source/php-version-before.txt")" || return 71
    if ! select_php_target_for_version "$old_php"; then
        err 'В сессии не указана поддерживаемая исходная версия PHP.'
        mark_state rollback_precheck_failed
        return 71
    fi
    MANAGED_SITE=''
    if [ -z "$url" ] && { [ -e "$source/site-probe" ] || [ -L "$source/site-probe" ]; }; then
        if ! managed_site_load "$source/site-probe"; then
            err 'В сессии повреждено или небезопасно описание сайта.'
            mark_state rollback_precheck_failed
            return 71
        fi
        url=auto
    elif [ -z "$url" ]; then
        if ! private_session_file "$source/url" || [ ! -s "$source/url" ]; then
            err 'В сессии нет защищённой цели проверки сайта.'
            mark_state rollback_precheck_failed
            return 71
        fi
        original_url="$(cat "$source/url")" || return 71
        url="$original_url"
    fi
    if ! health_target_validate "$url"; then
        err 'В сессии не указана корректная версия PHP или цель проверки сайта.'
        mark_state rollback_precheck_failed
        return 71
    fi
    printf '%s\n' "$url" > "$dir/url" || return 71
    if [ "$url" = auto ]; then managed_site_save "$dir/site-probe" || return 71; fi
    if ! rpm_core_snapshot > "$dir/rpm-before.txt" ||
       ! plan_rpm_rollback "$source/rpm-before.txt" "$source/rpm-target.txt" "$dir/rpm-before.txt" > "$dir/rpm-rollback-plan.txt"; then
        err 'Состав RPM не соответствует этому обновлению. Проверьте состояние сервера перед восстановлением.'
        mark_state rollback_precheck_failed
        return 71
    fi
    if ! stage_rpm_bundle "$source/rpm-rollback" "$dir/rpm-rollback" "$source/trusted-keyring.gpg" ||
       ! select_rpms "$dir/rpm-rollback" old "$source/rpm-before.txt"; then
        err 'Подписанный набор старых RPM из сессии не прошёл повторную проверку.'
        mark_state rollback_precheck_failed
        return 71
    fi
    rollback_rpm_uncertain "$source" "$id" "$state" || uncertainty_rc=$?
    if [ "$uncertainty_rc" -gt 1 ]; then
        mark_state rollback_precheck_failed
        return 71
    fi
    if [ "$uncertainty_rc" -eq 0 ]; then
        # Interrupted install/recovery may leave old headers with uncertain files or scriptlets.
        rollback_rpms=("${SELECTED_RPMS[@]}")
        rollback_flags=(--oldpackage --replacepkgs)
        msg 'Предыдущая RPM-транзакция не подтверждена. Восстанавливаем весь прежний набор RPM.'
    else
        while IFS= read -r action; do
            if [ "$action" != keep ]; then
                rollback_rpms+=("${SELECTED_RPMS[$i]}")
            fi
            if [ "$action" = replace ]; then
                rollback_flags=(--oldpackage --replacepkgs)
            fi
            i=$((i + 1))
        done < "$dir/rpm-rollback-plan.txt"
    fi

    msg "Восстановление сессии $id до PHP $old_php. Проверяем сайт $url"
    printf 'Исходный архив конфигураций: %s/configuration.tar.gz\n' "$source"
    if [ "$unattended" = 1 ]; then
        msg 'Откат указанной сессии подтверждён параметром --unattended.'
    else
        confirm_phrase 'Восстановить прежние пакеты PHP и перезапустить Apache? Архив конфигураций предназначен для ручного восстановления.' 'ОТКАТИТЬ PHP' || return
    fi
    backup_configs "$dir" archive-only || warn 'Текущие конфигурации не удалось сохранить. Исходный архив остаётся доступен.'
    if ! rpm_core_snapshot > "$dir/rpm-recheck.txt" ||
       ! cmp -s "$dir/rpm-before.txt" "$dir/rpm-recheck.txt"; then
        err 'Состав RPM изменился после предварительной проверки. Повторите откат.'
        mark_state rollback_precheck_failed
        return 71
    fi
    if [ "${#rollback_rpms[@]}" -gt 0 ] && ! rpm -Uvh "${rollback_flags[@]}" --test "${rollback_rpms[@]}"; then
        err 'Предварительная проверка транзакции отката не прошла.'
        mark_state rollback_test_failed
        return 71
    fi
    if ! check_external_rpm_obsoletes "${rollback_rpms[@]}"; then
        mark_state rollback_test_failed
        return 71
    fi
    if ! record_rollback_rpm_state "$source" pending || ! mark_state rolling_back || ! sync; then
        err 'Не удалось записать состояние перед транзакцией отката.'
        return 72
    fi
    if [ "${#rollback_rpms[@]}" -gt 0 ]; then
        if ! rpm -Uvh "${rollback_flags[@]}" "${rollback_rpms[@]}"; then
            err "Ошибка транзакции отката. После диагностики повторите --rollback --session $id."
            mark_state rollback_failed
            return 72
        fi
    else
        msg 'Исходный набор RPM уже установлен. Проверяем возможность перезапуска Apache.'
    fi
    if ! rpm_core_snapshot > "$dir/rpm-after.txt" ||
       ! cmp -s "$source/rpm-before.txt" "$dir/rpm-after.txt"; then
        err 'Состав RPM после отката не совпадает с исходным набором.'
        mark_state rollback_verify_failed
        return 72
    fi
    if ! record_rollback_rpm_state "$source" complete || ! sync; then
        err 'RPM восстановлены, но подтверждение этапа не сохранено. Повторите откат по исходной сессии.'
        mark_state rollback_verify_failed
        return 72
    fi
    if ! httpd -t; then
        err "Конфигурация Apache требует исправления. Сравните с архивом сессии $id и повторите откат."
        mark_state rollback_apache_config_failed
        apache_health_diagnostics "$dir"
        return 72
    fi
    if ! systemctl restart httpd; then
        err 'Не удалось перезапустить Apache после восстановления RPM.'
        mark_state rollback_restart_failed
        apache_health_diagnostics "$dir"
        return 72
    fi
    if ! verify_after "$dir" "$url" "$old_php" "$source/php-modules-before.txt"; then
        err 'После восстановления RPM проверка PHP, Apache или сайта не пройдена.'
        mark_state rollback_verify_failed
        apache_health_diagnostics "$dir"
        return 72
    fi
    mark_state rollback_completed || return
    status_line ok "Набор RPM из сессии $id восстановлен. PHP $old_php, Apache и сайт прошли проверки."
}

# Без привилегий показывает последнюю сессию и её состояние.
show_status() {
    local last
    if [ -d "$UPDATER_STATE" ] && [ ! -x "$UPDATER_STATE" ]; then
        err 'Для просмотра закрытых сессий запустите --status от root.'
        return 10
    fi
    if [ ! -d "$UPDATER_STATE/sessions" ]; then
        echo 'Сессии обновления пока не обнаружены.'; return 0
    fi
    last="$(ls -1dt "$UPDATER_STATE/sessions"/* 2>/dev/null | head -1)"
    if [ -z "$last" ]; then echo 'Сессии не найдены.'; return 0; fi
    echo "Последняя сессия: $last"
    echo -n 'Состояние: '; cat "$last/state" 2>/dev/null || echo 'неизвестно'
    menu_state_text "$(cat "$last/state" 2>/dev/null)"
    if [ -r "$last/rollback-of" ]; then
        printf 'Исходная сессия обновления: '
        cat -- "$last/rollback-of"
    fi
    echo 'Информация о сессии хранится в каталоге с правами root.'
    if private_session_dir "$last" && private_session_file "$last/state"; then
        menu_record session "${last##*/}"
        menu_record state "$(cat -- "$last/state")"
        if private_session_file "$last/rollback-of"; then
            menu_record origin "$(cat -- "$last/rollback-of")"
        fi
    fi
}

update_help() {
    cat <<'EOF'
BITRIX SERVER MASTER 1.0.0-rc11 — диагностика и обновление PHP 8.2 / 8.3

Проверка и отчёт
  bash install.sh --check
  bash install.sh --check-site
  bash install.sh --check-site --site site.ru
  bash install.sh --check --url https://site.ru/_php_health.php
  bash install.sh --audit
  bash install.sh --audit --offline --report ./audit-full.json
  bash install.sh --audit --json
  bash install.sh --compare-menu

--check проверяет целевую версию PHP без Python и доступа к интернету.
С --url он проверяет настроенный локальный маршрут веб-PHP.
--check-site от root находит сайт Apache, создаёт временный закрытый PHP-тест,
проверяет веб-PHP и удаляет тест. При нескольких сайтах предложит выбрать.
Без терминала укажите --site с именем сайта или абсолютным DocumentRoot.
Это проверка PHP/расширений через Apache; nginx, БД и функции Битрикса
проверяйте отдельно. --check и --audit временные тесты не создают.
--audit собирает данные, сверяет патч PHP с PHP.net и сохраняет JSON.
В меню 1 → 8 можно выбрать сохранённые отчёты по номерам и сравнить их.
--plan показывает цепочку перехода на PHP 8.2 для обнаруженного BitrixEnv.
Переходы между ветками администратор запускает через меню /root/menu.sh.
На подходящем PHP 8.2.x он показывает патч до 8.2.35, на 8.3.x — до 8.3.36.
Ветка определяется автоматически; переходов между ветками и понижения нет.
PHP 8.4+ и обновление BitrixEnv 9 не поддерживаются.
Цвета используются в терминале. NO_COLOR=1 отключает цвета.

Подробные команды
  bash install.sh --diagnose --full --offline
  bash install.sh --diagnose --json --report
  bash install.sh --compare OLD.json NEW.json
  bash install.sh --plan

Сборка на отдельном клоне ВМ
  bash install.sh --build --builder
  bash install.sh --build --builder --srpm /path/php-8.2.35-1.remi.src.rpm
  bash install.sh --build --builder --branch 8.3 --srpm /path/php-8.3.36-1.remi.src.rpm

Подготовка выпуска на доверенной машине подписи
  bash install.sh --prepare-release --new-rpm-dir /path/NEW_RPMS --old-rpm-dir /path/OLD_RPMS \
       --signer FULL_RSA_FINGERPRINT --output /path/NEW_RELEASE
Для выпуска PHP 8.3 добавьте --branch 8.3. По умолчанию выбрана 8.2.
--branch разрешён только для --build и --prepare-release.

Автоматическая загрузка и установка из выпуска проекта
  bash install.sh --setup-update
  bash install.sh --auto-update
  bash install.sh --auto-update --unattended --backup-verified
  bash install.sh --auto-update --config /root/client-update.conf
  bash install.sh --auto-update --site site.ru
При первом запуске --auto-update сам настраивает выпуск, закреплённый ключ
и автоматическую проверку сайта. Готовить PHP-файл или URL вручную не нужно.
--setup-update повторяет настройку; для выбора сайта можно добавить --site.
Поддерживаются прежние конфигурации с HEALTH_URL=http(s)://... .

Установка из готовых подписанных комплектов RPM
  bash install.sh --update --rpm-dir /path/NEW_RPMS --rollback-dir /path/OLD_RPMS \
       --rpm-keyring /root/rpm-signing.gpg [--site site.ru]

В каждом каталоге нужны SHA256SUMS и SHA256SUMS.asc. Сайт проверяется временным
автоматическим тестом. Расширенный режим --url https://site.ru/_php_health.php
использует существующий закрытый тест: HTTP 200 и единственная строка
BITRIX_MASTER_OK <версия PHP> apache2handler.
Для запуска без запросов добавьте --unattended --backup-verified только после
проверки актуального снимка ВМ или полной резервной копии сервера.

Откат из сохранённых RPM конкретной сессии обновления
  bash install.sh --rollback --session YYYYMMDDTHHMMSSZ-PID
  bash install.sh --status

Добавьте --unattended, чтобы подтвердить откат указанной сессии без запроса.
Откат использует сохранённое описание сайта и создаёт тест после восстановления.
Для смены маршрута проверки можно явно указать --url URL существующего теста.

Прочее
  bash install.sh --bootstrap-python
  bash install.sh --version

Профиль установки — CentOS 7 x86_64, Apache prefork + mod_php,
BitrixEnv 7, пакетный PHP 8.2.x или 8.3.x. Цели — PHP 8.2.35 / 8.3.36.
Первый прогон — на клоне.
EOF
}

# Prepare release assets on a trusted build/signing machine.
prepare_release() (
    local new_dir="$1" old_dir="$2" signer="$3" output="$4"
    local parent base work='' lock='' tool verify_tool key_info key_fpr key_algorithm
    local kind input source original staged record name ver release arch target digest file
    local source_package count
    local -A names=() old_records=()
    need rpm sha256sum awk sort cmp cp mv mkdir mktemp rm rmdir dirname readlink || return
    tool="$(command -v gpg || command -v gpg2)" || { err 'Нужен GnuPG на машине подписи.'; return 50; }
    verify_tool="$(command -v gpgv || command -v gpgv2)" || { err 'Нужен gpgv на машине подписи.'; return 50; }
    if ! [[ "$signer" =~ ^[[:xdigit:]]{40}$ ]]; then
        err 'Укажите полный 40-символьный отпечаток основного RSA-ключа подписи.'
        return 2
    fi
    signer="${signer^^}"
    if ! key_info="$("$tool" --with-colons --fingerprint --list-secret-keys "$signer" 2>/dev/null)"; then
        err 'Закрытый ключ подписи не найден в текущем GnuPG.'
        return 50
    fi
    key_fpr="$(awk -F: '$1=="sec" { primary=1; next } primary && $1=="fpr" { print $10; exit }' <<< "$key_info")"
    key_algorithm="$(awk -F: '$1=="sec" { print $4; exit }' <<< "$key_info")"
    if [[ "$key_fpr" != "$signer" || "$key_algorithm" != 1 ]]; then
        err 'Нужен точный отпечаток основного RSA-ключа. Его закрытая часть остаётся на машине подписи.'
        return 50
    fi
    if ! [[ -d "$new_dir" && ! -L "$new_dir" && -d "$old_dir" && ! -L "$old_dir" ]]; then
        err 'Укажите обычные каталоги доверенных новых и исходных RPM.'
        return 50
    fi
    new_dir="$(readlink -f -- "$new_dir")" && old_dir="$(readlink -f -- "$old_dir")" || return 50
    output="${output%/}"
    base="${output##*/}"
    if ! [[ "$base" =~ ^[[:alnum:]_][[:alnum:]_.+-]*$ ]]; then
        err 'Укажите имя нового каталога выпуска.'
        return 2
    fi
    parent="$(dirname -- "$output")"
    parent="$(readlink -f -- "$parent")" || return 50
    [ -d "$parent" ] || { err 'Родительский каталог выпуска должен существовать.'; return 50; }
    output="$parent/$base"
    if [[ "$output" = "$new_dir" || "$output" = "$old_dir" || "$output" = "$new_dir/"* || "$output" = "$old_dir/"* ]]; then
        err 'Каталог выпуска должен находиться вне исходных каталогов RPM.'
        return 50
    fi
    if [ -e "$output" ] || [ -L "$output" ]; then
        err 'Каталог выпуска уже существует. Укажите новое имя.'
        return 50
    fi
    lock="$parent/.$base.publish-lock"
    mkdir -m 0700 -- "$lock" || { err 'Подготовка этого выпуска уже выполняется или остался её каталог блокировки.'; return 50; }
    trap '[ -z "$work" ] || rm -rf -- "$work"; rmdir -- "$lock"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    work="$(mktemp -d "$parent/.$base.XXXXXXXX")" || return 50
    umask 077
    shopt -s nullglob dotglob
    for kind in NEW OLD; do
        input="$new_dir"
        [ "$kind" = NEW ] || input="$old_dir"
        count=0
        : > "$work/$kind-SHA256SUMS" || return 50
        for source in "$input"/*; do
            original="${source##*/}"
            case "$original" in SHA256SUMS|SHA256SUMS.asc) continue ;; esac
            if ! [[ -f "$source" && ! -L "$source" && "$original" =~ ^[[:alnum:]][[:alnum:]_.+-]*\.rpm$ ]]; then
                err "В исходном каталоге найден посторонний файл или ссылка — $source"
                return 50
            fi
            staged="$work/.rpm-input"
            rm -f -- "$staged" || return 50
            cp -P -- "$source" "$staged" || return 50
            [ -f "$staged" ] && [ ! -L "$staged" ] || return 50
            record="$(rpm -qp --nosignature --qf "$RPM_RECORD_QF" -- "$staged")" || return 50
            if ! [[ "$record" =~ $RPM_RECORD_RE ]]; then
                err "Не удалось прочитать точные метаданные RPM — $source"
                return 50
            fi
            name="${BASH_REMATCH[1]}"
            ver="${BASH_REMATCH[3]}"
            release="${BASH_REMATCH[4]}"
            arch="${BASH_REMATCH[5]}"
            if ! [[ " $CORE_RPM_NAMES " == *" $name "* && "$arch" = x86_64 &&
                    "$ver" =~ ^8\.[23]\.[0-9]+$ && "${ver%.*}" = "$TARGET_BRANCH" && "$release" =~ (^|\.)el7([._+~^-]|$) ]]; then
                err "Неподходящий пакет для выпуска EL7 PHP $TARGET_BRANCH — $record"
                return 50
            fi
            source_package="$(rpm -qp --nosignature --qf '%{SOURCEPACKAGE}' -- "$staged")" || return 50
            if [ "$source_package" != '(none)' ] || ! rpm -K --nosignature -- "$staged" >/dev/null; then
                err "Нужен целый бинарный RPM — $source"
                return 50
            fi
            if [ "$kind" = NEW ]; then
                if [ "$ver" != "$TARGET_PHP" ] || [ -n "${names[$name]:-}" ]; then
                    err "Новый комплект должен содержать по одному RPM $TARGET_PHP для каждого имени — $name"
                    return 50
                fi
                target="$original"
                names["$name"]=1
            else
                digest="$(printf '%s\n' "$record" | sha256sum)"
                target="$name-${digest%% *}.rpm"
                if [ -n "${old_records[$record]:-}" ]; then
                    if ! cmp -s "$staged" "$work/$target"; then
                        err "Одинаковая NEVRA имеет разное содержимое — $record"
                        return 50
                    fi
                    continue
                fi
                old_records["$record"]=1
            fi
            if [ -e "$work/$target" ]; then
                err "Совпали имена файлов выпуска — $target"
                return 50
            fi
            mv -- "$staged" "$work/$target" || return 50
            (cd -- "$work" && sha256sum -- "$target") >> "$work/$kind-SHA256SUMS" || return 50
            count=$((count + 1))
        done
        [ "$count" -gt 0 ] || { err "Комплект $kind пуст."; return 50; }
        sort -o "$work/$kind-SHA256SUMS" "$work/$kind-SHA256SUMS" || return 50
    done
    rm -f -- "$work/.rpm-input" || return 50
    for name in php php-cli php-common; do
        [ -n "${names[$name]:-}" ] || { err "В новом комплекте отсутствует $name."; return 50; }
    done
    msg "Подписываем подготовленные каталоги ключом $signer."
    msg 'Подпись подтверждает ваше доверие происхождению входных RPM.'
    for kind in NEW OLD; do
        "$tool" --armor --digest-algo SHA256 --local-user "$signer!" \
            --detach-sign --output "$work/$kind-SHA256SUMS.asc" "$work/$kind-SHA256SUMS" || return 50
    done
    "$tool" --export "$signer" > "$work/release-keyring.gpg" || return 50
    [ -s "$work/release-keyring.gpg" ] || return 50
    mkdir -m 0700 -- "$work/.verify" || return 50
    for kind in NEW OLD; do
        "$verify_tool" --homedir "$work/.verify" --keyring "$work/release-keyring.gpg" \
            "$work/$kind-SHA256SUMS.asc" "$work/$kind-SHA256SUMS" || return 50
    done
    rm -rf -- "$work/.verify" || return 50
    mv -Tn -- "$work" "$output" || return 50
    if [ -d "$work" ]; then
        err 'Каталог назначения появился во время подготовки. Выпуск сохранён не был.'
        return 50
    fi
    work=''
    msg "Выпуск подготовлен — $output"
    printf 'Публичный ключ подписи — %s\n' "$signer"
)

prepare_release_dispatch() {
    local new_dir='' old_dir='' signer='' output='' option branch=8.2
    while [ "$#" -gt 0 ]; do
        option="$1"
        if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
            err "У параметра $option нет значения."
            return 2
        fi
        case "$option" in
            --branch) branch="$2" ;;
            --new-rpm-dir) new_dir="$2" ;;
            --old-rpm-dir) old_dir="$2" ;;
            --signer) signer="$2" ;;
            --output) output="$2" ;;
            *) err "Параметр $option недопустим для --prepare-release."; return 2 ;;
        esac
        shift 2
    done
    if [[ -z "$new_dir" || -z "$old_dir" || -z "$signer" || -z "$output" ]]; then
        err 'Укажите --new-rpm-dir, --old-rpm-dir, --signer и --output.'
        return 2
    fi
    set_php_target "$branch" || return
    prepare_release "$new_dir" "$old_dir" "$signer" "$output"
}


updater_dispatch() {
    local mode="$1" rpmdir='' olddir='' keyring='' srpm='' url='' session='' builder=0 selector=''
    local unattended=0 backup_verified=0 branch=8.2
    MANAGED_SITE=''
    shift
    while [ "$#" -gt 0 ]; do
        case "$mode:$1" in
          --build:--builder)
            builder=1
            shift
            continue ;;
          --update:--unattended|--rollback:--unattended)
            unattended=1
            shift ;;
          --update:--backup-verified)
            backup_verified=1
            shift ;;
          --update:--build-on-host)
            err 'Сборка отделена от установки. Используйте --build --builder на клоне и подпишите комплект RPM.'
            return 2 ;;
          --rollback:--rpm-dir)
            err 'Откат привязан к записанной сессии. Используйте --rollback --session ID.'
            return 2 ;;
          --build:--branch|--build:--srpm|--update:--rpm-dir|--update:--rollback-dir|--update:--rpm-keyring|--update:--url|--update:--site|--rollback:--session|--rollback:--url)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
                err "У параметра $1 нет значения."
                return 2
            fi
            case "$1" in
              --branch) branch="$2" ;;
              --rpm-dir) rpmdir="$2" ;;
              --rollback-dir) olddir="$2" ;;
              --rpm-keyring) keyring="$2" ;;
              --srpm) srpm="$2" ;;
              --url) url="$2" ;;
              --site) selector="$2" ;;
              --session) session="$2" ;;
            esac
            shift 2 ;;
          *)
            err "Параметр $1 недопустим для $mode."
            return 2 ;;
        esac
    done
    case "$mode" in
       --plan) show_plan ;;
       --build) set_php_target "$branch" && build_rpms "$srpm" "$builder" ;;
       --update)
           if [ "$unattended" != "$backup_verified" ]; then
               err 'Для обновления без запросов параметры --unattended и --backup-verified нужны вместе.'
               return 2
           fi
           if [ -n "$selector" ] && [ -n "$url" ]; then
               err 'Для --update выберите --site или --url, а не оба параметра.'; return 2
           fi
           if [ -z "$url" ] || [ "$url" = auto ]; then
               require_root || return
               select_managed_site "$selector" "$unattended" || return
               url=auto
           fi
           run_update "$(resolve_rpm_dir "$rpmdir")" "$url" "$olddir" "$keyring" "$unattended" ;;
       --rollback)
           if [ -z "$session" ]; then
               err 'Укажите --session ID исходного обновления.'
               return 2
           fi
           run_rollback "$session" "$url" "$unattended" ;;
       --status) show_status ;;
    esac
}

# Подменю используют те же команды и проверки, что и запуск с флагами.
menu_update_readiness() {
    local route detail
    NEXT_STATUS=unknown NEXT_REASON='' NEXT_VERSION='' NEXT_TARGET=''
    NEXT_VERSION="$(php -r 'echo PHP_VERSION;' 2>/dev/null)" || NEXT_VERSION=''
    if select_php_target_for_version "$NEXT_VERSION"; then NEXT_TARGET="$TARGET_PHP"; fi
    route="$(php_version_route "$NEXT_VERSION")"
    case "$route" in
        older) NEXT_STATUS=legacy; NEXT_REASON='Сначала нужен переход через штатное меню BitrixEnv.'; return ;;
        unsupported) NEXT_STATUS=unsupported; NEXT_REASON='Эта ветка PHP не поддерживается мастером.'; return ;;
        newer) NEXT_STATUS=newer; NEXT_REASON='PHP новее цели этого выпуска; понижение не требуется.'; return ;;
        unknown) NEXT_REASON='Версия PHP не определена. Выполните подробную диагностику.'; return ;;
    esac
    if ! detail="$(profile_check 2>&1)"; then
        NEXT_STATUS=blocked
        [ "$(id -u)" = 0 ] || NEXT_STATUS=needs_root
        NEXT_REASON="${detail##*$'\n'}"; NEXT_REASON="${NEXT_REASON#ОШИБКА: }"
    elif ! detail="$(php_rpm_versions_check "$NEXT_VERSION" 2>&1)"; then
        NEXT_STATUS=blocked
        NEXT_REASON="Пакеты PHP не согласованы или не подтверждены: ${detail##*$'\n'}"
    elif [ "$route" = target ]; then
        NEXT_STATUS=current; NEXT_REASON="Цель этого выпуска уже установлена. Обновление PHP до $NEXT_TARGET не требуется."
    elif [ "$(id -u)" != 0 ]; then
        NEXT_STATUS=needs_root; NEXT_REASON='Для подготовки обновления нужны права root.'
    else
        NEXT_STATUS=ready; NEXT_REASON='Профиль подходит. Можно начать подготовку обновления.'
    fi
}

menu_invoke() {
    local scratch="${MENU_RESULT_DIR:-}" own=0 rc=0 key value
    MENU_SESSION='' MENU_STATE='' MENU_ORIGIN='' MENU_SITE='' MENU_WEB=''
    if [ -z "$scratch" ]; then
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/bitrix-menu.XXXXXXXX")" || return 1
        own=1
    fi
    bash "$SELF" --menu-action "$@" 3>"$scratch/result" || rc=$?
    while IFS=$'\t' read -r key value; do
        case "$value" in *$'\t'*|*$'\r'*) continue ;; esac
        case "$key" in
            site) MENU_SITE="$value" ;;
            session) [[ "$value" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] && MENU_SESSION="$value" ;;
            origin) [[ "$value" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] && MENU_ORIGIN="$value" ;;
            state) [[ "$value" =~ ^[a-z_]+$ ]] && MENU_STATE="$value" ;;
            web) case "$value" in ok|failed) MENU_WEB="$value" ;; esac ;;
        esac
    done < "$scratch/result"
    if [ "$own" = 1 ]; then rm -f -- "$scratch/result"; rmdir -- "$scratch"; fi
    return "$rc"
}

menu_can_rollback() {
    local source
    [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || return 1
    source="$UPDATER_STATE/sessions/$1"
    private_session_dir "$source" && private_session_file "$source/state" || return 1
    case "$(cat -- "$source/state")" in
        installing|installation_failed|installed|apache_config_failed|restart_failed|verifying|verify_failed|completed) return 0 ;;
    esac
    return 1
}

menu_state_text() {
    case "$1" in
        started) status_line warning 'Подготовка операции' ;;
        precheck_failed|install_test_failed|backup_failed) status_line critical 'Подготовка остановлена до установки PHP' ;;
        installing) status_line warning 'Установка была начата; требуется проверка состояния пакетов' ;;
        installation_failed) status_line critical 'Установка завершилась ошибкой; требуется проверка состояния пакетов' ;;
        installed|verifying) status_line warning 'Пакеты изменены; проверка результата ещё не завершена' ;;
        apache_config_failed|restart_failed|verify_failed) status_line critical 'Пакеты изменены; проверка результата не завершена успешно' ;;
        completed) status_line ok 'Обновление завершено, автоматические проверки пройдены' ;;
        already_current) status_line ok 'Обновление не требуется, установленный PHP проверен' ;;
        rollback_completed) status_line ok 'Откат завершён, автоматические проверки пройдены' ;;
        rollback_precheck_failed|rollback_test_failed) status_line critical 'Подготовка отката остановлена' ;;
        rolling_back) status_line warning 'Восстановление ещё не завершено; проверьте журнал' ;;
        rollback_failed|rollback_verify_failed|rollback_apache_config_failed|rollback_restart_failed) status_line critical 'Восстановление не завершено; проверьте журнал' ;;
        *) status_line warning 'Состояние не подтверждено; проверьте сведения об операции' ;;
    esac
}

menu_session_details() {
    local id="$1" dir log
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || return 1
    dir="$UPDATER_STATE/sessions/$id"; log="$UPDATER_LOG/$id.log"
    private_session_dir "$dir" && private_session_file "$dir/state" || {
        status_line warning 'Сведения об этой операции недоступны. Нужны права root.'; return 1;
    }
    printf '\nОперация: %s\nКаталог: %s\n' "$id" "$dir"
    menu_state_text "$(cat -- "$dir/state")"
    if private_session_file "$dir/rollback-of"; then
        printf 'Исходное обновление: '; cat -- "$dir/rollback-of"
    fi
    if private_session_file "$log"; then
        printf '\nПоследние 50 строк журнала %s:\n' "$log"
        tail -n 50 -- "$log"
    else
        printf 'Журнал недоступен: %s\n' "$log"
    fi
}

menu_option() { MENU_OPTIONS+=("$1"); MENU_LABELS+=("$2"); }

menu_next_actions() {
    local action="$1" rc="$2" choice i recovery="${MENU_ORIGIN:-$MENU_SESSION}" operation=0 retry=0
    MENU_OPTIONS=() MENU_LABELS=() MENU_NEXT=''
    printf '\n'
    status_line info 'Что дальше'
    case "$action:$rc" in
        --check-site:12) status_line warning 'Проверка сайта отменена; веб-PHP этой проверкой не подтверждён.' ;;
        --setup-update:12) status_line warning 'Настройка отменена; новые настройки не сохранены.' ;;
        --check-site:0) status_line ok 'Проверка PHP сайта пройдена.' ;;
        --setup-update:0) status_line ok 'Настройки автоматического обновления сохранены.' ;;
        --check-site:*) status_line critical 'Проверка сайта не завершена. Причина указана выше.' ;;
        --setup-update:*) status_line critical 'Настройка не завершена. Устраните указанную выше причину и повторите её.' ;;
    esac
    case "$action" in
        --auto-update|--update|--rollback|--status)
            operation=1
            if [ "$rc" = 12 ]; then
                status_line warning 'Операция отменена. Для запуска потребуется новый явный выбор.'
            elif [ -n "$MENU_STATE" ]; then
                menu_state_text "$MENU_STATE"
            elif [ "$rc" != 0 ]; then
                status_line critical 'Операция остановлена. Причина указана выше; сначала устраните её.'
            else
                echo 'Сведения об операции показаны выше.'
            fi
            [ -z "$MENU_SESSION" ] || printf 'Сессия: %s\n' "$MENU_SESSION"
            [ -z "$MENU_ORIGIN" ] || printf 'Исходное обновление: %s\n' "$MENU_ORIGIN"
            case "$MENU_STATE" in
                completed|already_current|rollback_completed)
                    status_line warning 'Проверьте вручную сайт, админку Битрикса, формы и основные функции.' ;;
            esac
            if [ -n "$MENU_SESSION" ]; then menu_option details 'Показать сведения и журнал этой операции'; fi
            if [ "$MENU_STATE" != rollback_completed ] && menu_can_rollback "$recovery"; then
                MENU_RECOVERY_ID="$recovery"
                if [ -n "$MENU_ORIGIN" ]; then
                    menu_option rollback 'Повторить откат исходного обновления'
                else
                    menu_option rollback 'Откатить это обновление'
                fi
            fi
            case "$action:$MENU_STATE" in
                --auto-update:|--auto-update:started|--auto-update:precheck_failed|--auto-update:install_test_failed|--auto-update:backup_failed)
                    [ "$rc" = 0 ] || retry=1 ;;
            esac
            ;;
    esac
    if [ "$operation" = 0 ] || [ "$retry" = 1 ]; then
        menu_update_readiness
        [ -z "$NEXT_VERSION" ] || printf 'Текущий PHP: %s\n' "$NEXT_VERSION"
        [ -z "$NEXT_TARGET" ] || printf 'Цель этого выпуска: %s\n' "$NEXT_TARGET"
        case "$NEXT_STATUS" in
            current|newer) status_line ok "$NEXT_REASON" ;;
            blocked) status_line critical "$NEXT_REASON" ;;
            *) status_line warning "$NEXT_REASON" ;;
        esac
        if [ "$NEXT_STATUS" = ready ] && [ "${MENU_WEB_BLOCKED:-0}" != 1 ]; then
            echo 'Проверки сайта, пакетов и возможности отката выполняются при подготовке.'
            echo 'Заранее подготовьте проверенную резервную копию или снимок ВМ.'
            echo 'Отдельно подтвердите резервную копию, затем — обновление с перезапуском Apache.'
            if [ "$retry" = 1 ]; then
                menu_option auto 'Повторить подготовку автоматического обновления после исправления причины'
            else
                menu_option auto 'Подготовить автоматическое обновление PHP'
            fi
        elif [ "$NEXT_STATUS" = needs_root ]; then
            status_line warning 'Запустите мастер от root и повторите проверку; дополнительные права из меню не выдаются.'
        fi
        if [ "${MENU_WEB_BLOCKED:-0}" = 1 ]; then
            status_line critical 'PHP сайта ещё не подтверждён. Сначала устраните причину и повторите проверку сайта.'
        fi
        if [ "$NEXT_STATUS" = legacy ]; then
            menu_option plan 'Посмотреть план перехода через BitrixEnv'
        elif [ "$NEXT_STATUS" != unknown ] && [ "$NEXT_STATUS" != unsupported ]; then
            menu_option site 'Проверить PHP сайта'
            if [ -n "${MENU_CONTEXT_SITE:-}" ] || [ "${MENU_WEB_BLOCKED:-0}" = 1 ]; then
                menu_option choose_site 'Выбрать другой сайт и проверить PHP'
            fi
            menu_option plan 'Посмотреть план для этого сервера'
        fi
        menu_option check 'Повторить быструю проверку'
        menu_option audit 'Подробная диагностика с отчётом без сети'
        if [ "$action" = --setup-update ] || [ "$retry" = 1 ]; then
            menu_option setup 'Повторить настройку источника и сайта'
        fi
    else
        menu_option check 'Выполнить быструю проверку'
        menu_option site 'Проверить PHP сайта'
    fi
    [ "$action" != --audit ] || menu_option compare 'Сравнить сохранённые отчёты — до и после'
    while :; do
        echo
        for i in "${!MENU_OPTIONS[@]}"; do printf ' %s. %s\n' "$((i+1))" "${MENU_LABELS[$i]}"; done
        echo ' 0. Назад в ручное меню (Enter)'
        printf '\n Выберите действие [0]: '
        IFS= read -r choice || return 1
        case "$choice" in ''|0) return 0 ;; esac
        if ! [[ "$choice" =~ ^[1-9][0-9]?$ ]] || [ "$choice" -gt "${#MENU_OPTIONS[@]}" ]; then
            echo 'Неизвестный пункт. Выберите номер из списка.'; continue
        fi
        MENU_NEXT="${MENU_OPTIONS[$((10#$choice-1))]}"
        if [ "$MENU_NEXT" = details ]; then menu_session_details "$MENU_SESSION"; MENU_NEXT=''; continue; fi
        if [ "$MENU_NEXT" = compare ]; then bash "$SELF" --compare-menu; MENU_NEXT=''; continue; fi
        return 0
    done
}

menu_action() (
    local action rc
    local -a args=("$@")
    local MENU_CONTEXT_SITE='' MENU_WEB_BLOCKED=0 MENU_RESULT_DIR
    [ -t 0 ] || { bash "$SELF" "$@"; return $?; }
    MENU_RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitrix-menu.XXXXXXXX")" || return 1
    trap 'rm -f -- "$MENU_RESULT_DIR/result"; rmdir -- "$MENU_RESULT_DIR"' EXIT
    while :; do
        action="${args[0]}"; rc=0
        menu_invoke "${args[@]}" || rc=$?
        [ -z "$MENU_SITE" ] || MENU_CONTEXT_SITE="$MENU_SITE"
        case "$MENU_WEB" in ok) MENU_WEB_BLOCKED=0 ;; failed) MENU_WEB_BLOCKED=1 ;; esac
        menu_next_actions "$action" "$rc" || return 1
        case "$MENU_NEXT" in
            '') return 0 ;;
            auto) args=(--auto-update) ;;
            check) args=(--check) ;;
            plan) args=(--plan) ;;
            audit) args=(--audit --offline) ;;
            site) args=(--check-site) ;;
            choose_site) MENU_CONTEXT_SITE=''; args=(--check-site) ;;
            setup) MENU_CONTEXT_SITE=''; args=(--setup-update) ;;
            rollback) args=(--rollback --session "$MENU_RECOVERY_ID") ;;
        esac
        case "$MENU_NEXT" in
            auto|site) [ -z "$MENU_CONTEXT_SITE" ] || args+=(--site "$MENU_CONTEXT_SITE") ;;
        esac
    done
)

menu_checks() {
    local choice
    while :; do
        echo
        status_line info 'Проверки и диагностика'
        echo ' 1. Быстрый чек PHP (по умолчанию)'
        echo ' 2. Что делать дальше — план обновления'
        echo ' 3. Полный аудит с отчётом без сети'
        echo ' 4. Полный аудит с проверкой PHP.net через интернет'
        echo ' 5. Проверить PHP сайта автоматически — временный закрытый тест'
        echo ' 6. Подробная диагностика на экране без сети'
        echo ' 7. Подготовить отдельный Python для полного аудита'
        echo ' 8. Сравнить сохранённые отчёты — до и после'
        echo ' 0. Назад'
        printf '\n Выберите действие [1]: '
        IFS= read -r choice || return 1
        case "$choice" in
          1|'') menu_action --check || return 1 ;;
          2) menu_action --plan || return 1 ;;
          3) menu_action --audit --offline || return 1 ;;
          4) menu_action --audit || return 1 ;;
          5) menu_action --check-site || return 1 ;;
          6) menu_action --diagnose --full --offline || return 1 ;;
          7) bash "$SELF" --bootstrap-python ;;
          8) bash "$SELF" --compare-menu ;;
          0) return 0 ;;
          *) echo 'Неизвестный пункт меню.' ;;
        esac
    done
}

menu_install_rpms() {
    local rpm_path old_path keyring site
    echo 'Установка из заранее подготовленных подписанных комплектов.'
    echo 'Enter в поле каталога или ключа отменяет установку.'
    printf 'Каталог новых RPM: '
    IFS= read -r rpm_path || return 1
    if [ -z "$rpm_path" ]; then echo 'Установка отменена.'; return 0; fi
    printf 'Каталог точных старых RPM для отката: '
    IFS= read -r old_path || return 1
    if [ -z "$old_path" ]; then echo 'Установка отменена.'; return 0; fi
    printf 'Абсолютный путь к доверенному публичному keyring: '
    IFS= read -r keyring || return 1
    if [ -z "$keyring" ]; then echo 'Установка отменена.'; return 0; fi
    printf 'Закрытый URL проверки (Enter — автоматический временный тест): '
    IFS= read -r site || return 1
    if [ -n "$site" ]; then
        menu_action --update --rpm-dir "$rpm_path" --rollback-dir "$old_path" --rpm-keyring "$keyring" --url "$site" || return 1
    else
        menu_action --update --rpm-dir "$rpm_path" --rollback-dir "$old_path" --rpm-keyring "$keyring" || return 1
    fi
    return 0
}

menu_prepare_release() {
    local new_path old_path signer output_path branch="${1:-8.2}"
    local -a branch_args=()
    [ "$branch" = 8.2 ] || branch_args=(--branch "$branch")
    echo "Подготовка и подпись выпуска PHP $branch на доверенной сборочной машине."
    echo 'В любом поле Enter отменяет подготовку.'
    printf 'Каталог новых RPM: '
    IFS= read -r new_path || return 1
    if [ -z "$new_path" ]; then echo 'Подготовка выпуска отменена.'; return 0; fi
    printf 'Каталог точных старых RPM для отката: '
    IFS= read -r old_path || return 1
    if [ -z "$old_path" ]; then echo 'Подготовка выпуска отменена.'; return 0; fi
    printf 'Полный отпечаток ключа подписи: '
    IFS= read -r signer || return 1
    if [ -z "$signer" ]; then echo 'Подготовка выпуска отменена.'; return 0; fi
    printf 'Каталог для подготовленного выпуска: '
    IFS= read -r output_path || return 1
    if [ -z "$output_path" ]; then echo 'Подготовка выпуска отменена.'; return 0; fi
    bash "$SELF" --prepare-release --new-rpm-dir "$new_path" --old-rpm-dir "$old_path" --signer "$signer" --output "$output_path" "${branch_args[@]}"
    return 0
}

menu_update() {
    local choice
    while :; do
        echo
        status_line info 'Подготовка и обновление PHP'
        echo ' 1. Посмотреть план для этого сервера (по умолчанию)'
        echo ' 2. Автоматическое обновление PHP — настройка и проверки включены'
        echo ' 3. Настройки источника и сайта — повторить настройку'
        echo ' 4. Собрать RPM PHP 8.2 на отдельной сборочной ВМ'
        echo ' 5. Установить подписанные RPM вручную — расширенный режим'
        echo ' 6. Подписать выпуск PHP 8.2 на доверенной сборочной машине'
        echo ' 7. Собрать RPM PHP 8.3 на отдельной сборочной ВМ'
        echo ' 8. Подписать выпуск PHP 8.3 на доверенной сборочной машине'
        echo ' 0. Назад'
        printf '\n Выберите действие [1]: '
        IFS= read -r choice || return 1
        case "$choice" in
          1|'') menu_action --plan || return 1 ;;
          2) menu_action --auto-update || return 1 ;;
          3) menu_action --setup-update || return 1 ;;
          4) bash "$SELF" --build --builder ;;
          5) menu_install_rpms || return 1 ;;
          6) menu_prepare_release || return 1 ;;
          7) bash "$SELF" --build --builder --branch 8.3 ;;
          8) menu_prepare_release 8.3 || return 1 ;;
          0) return 0 ;;
          *) echo 'Неизвестный пункт меню.' ;;
        esac
    done
}

menu_recovery() {
    local choice session
    while :; do
        echo
        status_line info 'Откат и состояние операции'
        echo ' 1. Состояние последней операции (по умолчанию)'
        echo ' 2. Откатить обновление по ID исходной сессии'
        echo ' 0. Назад'
        printf '\n Выберите действие [1]: '
        IFS= read -r choice || return 1
        case "$choice" in
          1|'') menu_action --status || return 1 ;;
          2)
             printf 'ID исходной сессии обновления (Enter — отмена): '
             IFS= read -r session || return 1
             if [ -z "$session" ]; then
                 echo 'Откат отменён.'
             else
                 menu_action --rollback --session "$session" || return 1
             fi ;;
          0) return 0 ;;
          *) echo 'Неизвестный пункт меню.' ;;
        esac
    done
}

full_menu() {
    local choice
    while :; do
        echo
        echo '=================================================================='
        echo " BITRIX SERVER MASTER $MASTER_VERSION"
        echo ' Диагностика и обновление PHP на старом BitrixEnv'
        echo '=================================================================='
        echo ' 1. Проверки и диагностика (по умолчанию)'
        echo ' 2. Подготовка и обновление PHP'
        echo ' 3. Откат и состояние операции'
        echo ' 4. Справка по командам'
        echo ' 0. Выход'
        printf '\n Выберите раздел [1]: '
        IFS= read -r choice || return 0
        case "$choice" in
          1|'') menu_checks || return 0 ;;
          2) menu_update || return 0 ;;
          3) menu_recovery || return 0 ;;
          4) bash "$SELF" --help ;;
          0) return 0 ;;
          *) echo 'Неизвестный пункт меню.' ;;
        esac
    done
}

check_site_dispatch() {
    local selector='' cli='' unattended=0 rc=0
    MANAGED_SITE=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --site)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
                    err 'Укажите имя сайта или DocumentRoot после --site.'; return 2
                fi
                selector="$2"; shift 2 ;;
            *) err "Параметр $1 недопустим для --check-site."; return 2 ;;
        esac
    done
    require_root || return
    need php httpd curl || return
    [ -t 0 ] || unattended=1
    select_managed_site "$selector" "$unattended" || return
    cli="$(php -r 'echo PHP_VERSION;' 2>/dev/null)" || { err 'Не удалось определить версию PHP CLI.'; return 63; }
    http_check auto "$cli" || rc=$?
    if [ "$rc" = 0 ]; then menu_record web ok; else menu_record web failed; fi
    return "$rc"
}

setup_auto_update() (
    local config='/etc/bitrix-php-update.conf' keydir='/etc/bitrix-php-update' temp='' config_temp='' cli='' keyfile=''
    local selector='' unattended=0
    local source=''
    local key_url='https://raw.githubusercontent.com/vitikevich-landau/bitrix-php-updater/main/release-keyring.gpg'
    local expected_key='7f07067817dfb211bb503e8f5a8e7c0a4b73d2e26154e9b07091548d1dcfb91c'
    require_root || return
    MANAGED_SITE=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --site)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
                    err 'Укажите имя сайта или DocumentRoot после --site.'; return 2
                fi
                selector="$2"; shift 2 ;;
            --unattended) unattended=1; shift ;;
            *) err "Параметр $1 недопустим для --setup-update."; return 2 ;;
        esac
    done
    [ -t 0 ] || unattended=1
    profile_check || return
    source="$PROJECT_RELEASE_URL"
    need curl sha256sum mktemp mv chmod gpgv dirname || return
    if [ -e "$config" ] || [ -L "$config" ]; then
        load_auto_config "$config" || return
        if [ "$unattended" = 1 ]; then selector="${selector:-$AUTO_SITE}"; fi
    fi
    echo 'Настройка подключает общий выпуск проекта и его закреплённый ключ.'
    printf 'Источник комплектов — %s\n' "$source"
    select_managed_site "$selector" "$unattended" || return
    health_target_validate auto || return
    cli="$(php -r 'echo PHP_VERSION;' 2>/dev/null)" || return 61
    http_check auto "$cli" || { menu_record web failed; err 'Автоматическая проверка сайта не пройдена. Настройки не сохранены.'; return 61; }
    menu_record web ok
    status_line ok "Проверка сайта пройдена для PHP $cli."
    if [ -e "$keydir" ] || [ -L "$keydir" ]; then
        private_session_dir "$keydir" || { err 'Каталог /etc/bitrix-php-update должен принадлежать root с правами 0700.'; return 61; }
    else
        mkdir -m 0700 -- "$keydir" || return 61
    fi
    temp="$(mktemp -d "$keydir/.setup.XXXXXXXX")" || return 61
    trap 'rm -rf -- "$temp"; [ -z "$config_temp" ] || rm -f -- "$config_temp"' EXIT
    safe_download "$key_url" "$temp/release-keyring.gpg" || return
    printf '%s  %s\n' "$expected_key" "$temp/release-keyring.gpg" | sha256sum --status -c - || {
        err 'Публичный ключ не совпадает с закреплённой контрольной суммой этого выпуска.'; return 61;
    }
    chmod 0600 -- "$temp/release-keyring.gpg" || return
    keyfile="$keydir/release-$expected_key.gpg"
    if [ -e "$keyfile" ] || [ -L "$keyfile" ]; then
        private_session_file "$keyfile" || { err 'Небезопасный файл публичного ключа.'; return 61; }
        printf '%s  %s\n' "$expected_key" "$keyfile" | sha256sum --status -c - || {
            err 'Сохранённый ключ выпуска повреждён. Проверьте каталог публичных ключей.'; return 61;
        }
    else
        mv -- "$temp/release-keyring.gpg" "$keyfile" || return
    fi
    config_temp="$(mktemp "$(dirname -- "$config")/.bitrix-php-update.XXXXXXXX")" || return
    printf 'SOURCE=%s\nKEYRING=%s\nHEALTH_URL=auto\nSITE=%s\n' "$source" "$keyfile" "$MANAGED_SITE" > "$config_temp" || return
    chmod 0600 -- "$config_temp" || return
    mv -f -- "$config_temp" "$config" || return
    status_line ok 'Настройки сохранены. Для обновления запустите bash install.sh --auto-update.'
)

# Список строится из активного дерева Apache, а не из glob всех *.conf.
MANAGED_SITE_CANDIDATES=()
MANAGED_SITE_LABELS=()
MANAGED_SITE_ALIASES=()
MANAGED_SITE=''

_managed_site_validate_httpd_args() {
    local value
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -DFOREGROUND|-kstart) shift ;;
            -D)
                [ "$#" -ge 2 ] && [ "$2" = FOREGROUND ] || return 83
                shift 2 ;;
            -k)
                [ "$#" -ge 2 ] && [ "$2" = start ] || return 83
                shift 2 ;;
            -f|-d)
                [ "$#" -ge 2 ] || return 83
                value="$2"
                if [ "$1" = -f ]; then
                    [[ "$value" = /etc/httpd/conf/httpd.conf || "$value" = conf/httpd.conf || "$value" = ./conf/httpd.conf ]] || return 83
                else
                    [[ "$value" = /etc/httpd || "$value" = /etc/httpd/ ]] || return 83
                fi
                shift 2 ;;
            -f*)
                value="${1#-f}"
                [[ "$value" = /etc/httpd/conf/httpd.conf || "$value" = conf/httpd.conf || "$value" = ./conf/httpd.conf ]] || return 83
                shift ;;
            -d*)
                value="${1#-d}"
                [[ "$value" = /etc/httpd || "$value" = /etc/httpd/ ]] || return 83
                shift ;;
            *) return 83 ;;
        esac
    done
}

_managed_site_check_running() {
    local pidfile='' trusted pid executable arg
    local -a argv=()
    for pidfile in /run/httpd/httpd.pid /var/run/httpd/httpd.pid; do
        if [ -e "$pidfile" ] || [ -L "$pidfile" ]; then break; fi
        pidfile=''
    done
    [ -n "$pidfile" ] || return 0
    if ! declare -F trusted_rpm_keyring >/dev/null ||
       ! trusted="$(trusted_rpm_keyring "$pidfile")" ||
       [ "$(stat -c %s -- "$trusted")" -gt 32 ]; then
        err 'Не удалось проверить защищённый PID-файл Apache.'; return 83
    fi
    pid="$(cat -- "$trusted")" || return 83
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || { err 'Некорректный PID Apache.'; return 83; }
    [ -d "/proc/$pid" ] || return 0
    executable="$(readlink -- "/proc/$pid/exe" 2>/dev/null)" || return 0
    executable="${executable% (deleted)}"
    # PID мог устареть и уже принадлежать другому процессу.
    [ "${executable##*/}" = httpd ] || return 0
    if [ ! -r "/proc/$pid/cmdline" ]; then err 'Недоступны аргументы работающего Apache.'; return 83; fi
    while IFS= read -r -d '' arg; do argv+=("$arg"); done < "/proc/$pid/cmdline"
    [ "${#argv[@]}" -gt 0 ] || { err 'Не удалось проверить запуск Apache.'; return 83; }
    if ! _managed_site_validate_httpd_args "${argv[@]:1}"; then
        err 'Apache запущен с нестандартными параметрами конфигурации. Автоматический поиск сайтов остановлен; используйте явно настроенный URL проверки.'
        return 83
    fi
}

_managed_site_dump_records() (
    local temp modules module bytes
    local -a extra=()
    require_root || return
    need httpd awk mktemp rm stat grep readlink cat || return
    _managed_site_check_running || return
    umask 077
    export LC_ALL=C
    temp="$(mktemp -d /tmp/bitrix-sites.XXXXXXXX)" || return 83
    trap 'rm -rf -- "$temp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    modules="$(httpd -M 2> "$temp/modules-error")" || {
        err 'Apache не смог прочитать конфигурацию. Сначала исправьте ошибки httpd -t.'; return 83;
    }
    if ! grep -Eq '^[[:space:]]*info_module \((shared|static)\)[[:space:]]*$' <<< "$modules"; then
        # Модуль загружается только в отдельный процесс проверки конфигурации.
        # Рабочая служба и её файлы конфигурации не меняются.
        if ! declare -F trusted_rpm_keyring >/dev/null ||
           ! module="$(trusted_rpm_keyring /usr/lib64/httpd/modules/mod_info.so)"; then
            err 'Для поиска сайтов нужен доверенный модуль mod_info Apache.'; return 83
        fi
        extra=(-C "LoadModule info_module $module")
    fi
    if ! httpd -t -D DUMP_CONFIG "${extra[@]}" > "$temp/config" 2> "$temp/config-error"; then
        err 'Apache не смог разобрать конфигурацию сайтов. Выполните httpd -t.'; return 83
    fi
    bytes="$(stat -c %s -- "$temp/config")" || return 83
    if ! [[ "$bytes" =~ ^[0-9]+$ ]] || [ "$bytes" -eq 0 ] || [ "$bytes" -gt 16777216 ]; then
        err 'Не получен ограниченный дамп активной конфигурации Apache.'; return 83
    fi
    # mod_info уже раскрыл Include/IfModule/IfDefine. Неизвестные способы
    # задания корня сайта не интерпретируем как shell/PHP-код.
    if ! awk '
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      function scalar(s) {
        s=trim(s)
        if (s ~ /^"[^"\\]*"$/ || s ~ /^\047[^\047\\]*\047$/) return substr(s,2,length(s)-2)
        if (s !~ /[[:space:]"\\\047]/) return s
        return ""
      }
      function hostname(s, a,n,i) {
        s=tolower(s)
        sub(/^https?:\/\//,"",s)
        sub(/:[0-9]+$/,"",s)
        if (s=="127.0.0.1") return s
        if (length(s)<1 || length(s)>253 || s !~ /^[a-z0-9.-]+$/ || s !~ /[a-z]/) return ""
        n=split(s,a,".")
        for(i=1;i<=n;i++) if (length(a[i])<1 || length(a[i])>63 || a[i] !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) return ""
        if(a[n] !~ /^[a-z]/) return ""
        return s
      }
      function endpoint(s, a,n,p) {
        if (s ~ /^[0-9]+$/) p=s
        else {
          n=split(s,a,":")
          if(n!=2 || a[1] !~ /^(127\.0\.0\.1|0\.0\.0\.0|localhost|\*|_default_)$/) return ""
          p=a[2]
        }
        if(p !~ /^[1-9][0-9]*$/ || length(p)>5 || p+0>65535) return ""
        return p+0
      }
      function emit(v,p, h,r,ssl,k,alias,seenAlias,a,n,i) {
        if(bad[v] || bad[0]) return
        h=names[v]; if(h=="") h=names[0]; if(h=="") h="127.0.0.1"
        h=hostname(h); if(h=="") return
        r=roots[v]; if(r=="") r=roots[0]
        if(r !~ /^\// || r=="/" || r ~ /[|[:cntrl:]]/ || length(r)>4096) return
        ssl=ssls[v]; if(ssl=="") ssl=ssls[0]
        if(ssl!="on" && ssl!="off") return
        k=h ":" p
        if(used[k]++) { fatal=1; return }
        alias=""; seenAlias=" " h " "
        n=split(aliases[v],a," ")
        for(i=1;i<=n;i++) {
          a[i]=hostname(a[i])
          if(a[i]!="" && index(seenAlias," " a[i] " ")==0) { alias=alias (alias==""?"":" ") a[i]; seenAlias=seenAlias a[i] " " }
        }
        if(++count>512) { fatal=1; return }
        print (ssl=="on"?"https":"http") "|" h "|" p "|" r "|" alias
      }
      BEGIN { depth=0; v=0; total=0; ssls[0]="off" }
      {
        line=trim($0)
        if(line=="" || line ~ /^#/) next
        if(line ~ /[[:cntrl:]]/ && line !~ /\t/) { fatal=1; next }
        if(line ~ /^<\//) {
          tag=tolower(line); sub(/^<\//,"",tag); sub(/>$/,"",tag); tag=trim(tag)
          if(depth<1 || stack[depth]!=tag) { fatal=1; next }
          if(tag=="virtualhost") v=0
          delete stack[depth--]; next
        }
        if(line ~ /^</) {
          if(!match(line,/^<([^[:space:]>]+)([[:space:]]+.*)?>$/,m)) { fatal=1; next }
          tag=tolower(m[1]); args=substr(line,length(m[1])+2); sub(/>$/,"",args); args=trim(args)
          if(tag=="virtualhost") {
            if(depth!=0 || ++total>512) { fatal=1; next }
            v=total
            n=split(args,a,/[[:space:]]+/)
            if(n>64) { bad[v]=1; next }
            for(i=1;i<=n;i++) { p=endpoint(a[i]); if(p!="") ports[v SUBSEP p]=1 }
          }
          stack[++depth]=tag; next
        }
        key=line; sub(/[[:space:]].*$/,"",key); args=trim(substr(line,length(key)+1)); key=tolower(key)
        direct=(depth==0 || (v>0 && depth==1 && stack[1]=="virtualhost"))
        if(key=="virtualdocumentroot" || key=="virtualdocumentrootip") { bad[v]=1; next }
        if(key=="listen") {
          if(depth!=0) { fatal=1; next }
          n=split(args,a,/[[:space:]]+/)
          if(n>2 || (n==2 && a[2]!="http" && a[2]!="https")) next
          p=endpoint(a[1]); if(p!="") listens[p]=1
          next
        }
        if(key=="documentroot" || key=="servername" || key=="sslengine") {
          if(!direct) { bad[v]=1; next }
          value=scalar(args)
          if(value=="" || value ~ /[|[:cntrl:]]/) { bad[v]=1; next }
          if(key=="documentroot") roots[v]=value
          else if(key=="servername") names[v]=value
          else { value=tolower(value); if(value!="on" && value!="off") bad[v]=1; else ssls[v]=value }
          next
        }
        if(key=="serveralias" && v>0 && direct) {
          n=split(args,a,/[[:space:]]+/)
          if(n>64) { bad[v]=1; next }
          for(i=1;i<=n;i++) { value=scalar(a[i]); if(value !~ /[*?]/) aliases[v]=aliases[v] " " value }
        }
      }
      END {
        if(depth!=0 || fatal) exit 83
        nports=asorti(listens,orderedports,"@ind_num_asc")
        if(total==0) for(pi=1;pi<=nports;pi++) emit(0,orderedports[pi])
        else for(v=1;v<=total;v++) for(pi=1;pi<=nports;pi++)
          if((v SUBSEP orderedports[pi]) in ports) emit(v,orderedports[pi])
        if(count==0 || fatal) exit 83
      }
    ' "$temp/config"; then
        err 'Не удалось однозначно найти сайты Apache с локальным IPv4-доступом. Проверьте DocumentRoot, Listen и виртуальные хосты.'
        return 83
    fi
)

discover_managed_sites() {
    local records scheme host port root aliases canonical record label
    MANAGED_SITE_CANDIDATES=() MANAGED_SITE_LABELS=() MANAGED_SITE_ALIASES=()
    records="$(_managed_site_dump_records)" || return
    while IFS='|' read -r scheme host port root aliases; do
        [ -n "$scheme" ] || continue
        canonical="$(readlink -e -- "$root" 2>/dev/null)" || {
            err 'Один из корневых каталогов Apache недоступен. Автоматический выбор сайта отменён.'
            MANAGED_SITE_CANDIDATES=() MANAGED_SITE_LABELS=() MANAGED_SITE_ALIASES=(); return 83
        }
        if ! [[ -d "$canonical" && "$canonical" == /* && "$canonical" != / && "$canonical" != *'|'* && ! "$canonical" =~ [[:cntrl:]] ]]; then
            err 'Корневой каталог сайта не подходит для временной проверки.'
            MANAGED_SITE_CANDIDATES=() MANAGED_SITE_LABELS=() MANAGED_SITE_ALIASES=(); return 83
        fi
        record="$scheme|$host|$port|$canonical"
        label="$host:$port — $canonical"
        [ -z "$aliases" ] || label="$label (алиасы: $aliases)"
        MANAGED_SITE_CANDIDATES+=("$record") MANAGED_SITE_LABELS+=("$label") MANAGED_SITE_ALIASES+=("$aliases")
    done <<< "$records"
    [ "${#MANAGED_SITE_CANDIDATES[@]}" -gt 0 ] || { err 'Подходящие сайты не обнаружены.'; return 83; }
}

select_managed_site() {
    local selector="${1:-}" unattended="${2:-0}" i record scheme host port root choice pick
    local -a matches=()
    MANAGED_SITE=''
    [[ "$unattended" = 0 || "$unattended" = 1 ]] || return 2
    discover_managed_sites || return
    if [[ "$selector" == /* && -d "$selector" ]]; then selector="$(readlink -e -- "$selector")" || return 83; fi
    for i in "${!MANAGED_SITE_CANDIDATES[@]}"; do
        record="${MANAGED_SITE_CANDIDATES[$i]}"
        IFS='|' read -r scheme host port root <<< "$record"
        if [ -z "$selector" ] || [ "$selector" = "$record" ] || [ "$selector" = "$root" ] ||
           [ "${selector,,}" = "$host" ] || [[ " ${MANAGED_SITE_ALIASES[$i]} " == *" ${selector,,} "* ]]; then
            matches+=("$i")
        fi
    done
    if [ "${#matches[@]}" -eq 0 ]; then err 'Выбранный сайт не найден в активной конфигурации Apache. Повторите выбор сайта.'; return 83; fi
    if [ "${#matches[@]}" -eq 1 ]; then
        MANAGED_SITE="${MANAGED_SITE_CANDIDATES[${matches[0]}]}"
        menu_record site "$MANAGED_SITE"
        return 0
    fi
    if [ "$unattended" = 1 ] || [ ! -t 0 ]; then
        err 'Найдено несколько сайтов. Укажите --site с доменом, корневым каталогом или точной записью сайта; либо запустите выбор в терминале.'
        return 83
    fi
    echo 'Выберите сайт для временной проверки PHP:'
    for i in "${!matches[@]}"; do printf '  %s) %s\n' "$((i+1))" "${MANAGED_SITE_LABELS[${matches[$i]}]}"; done
    printf 'Номер сайта (пустой ввод — отмена): '
    IFS= read -r choice || return 12
    [ -n "$choice" ] || return 12
    if ! [[ "$choice" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$choice" -gt "${#matches[@]}" ]; then err 'Неверный номер сайта. Повторите команду и выберите пункт из списка.'; return 83; fi
    pick="${matches[$((10#$choice-1))]}"
    MANAGED_SITE="${MANAGED_SITE_CANDIDATES[$pick]}"
    menu_record site "$MANAGED_SITE"
}

# Managed probes are scoped to one HTTP check. Never import state from the environment.
MANAGED_SITE=''

validate_managed_site() {
    local record="$1" scheme host port root extra
    [[ -n "$record" && "${#record}" -le 4095 && ! "$record" =~ [[:cntrl:]] ]] || return 85
    IFS='|' read -r scheme host port root extra <<< "$record"
    [[ "$record" = "$scheme|$host|$port|$root" && "$scheme" =~ ^https?$ &&
       "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 &&
       "$root" = /* && "$root" != / && "$root" != */ && "$root" != *//* &&
       "$root" != */./* && "$root" != */../* && "$root" != */. && "$root" != */.. ]] || return 85
    health_url_parts "$scheme://$host:$port/bitrix-master-probe.php" >/dev/null || return 85
}

managed_site_save() (
    local path="$1" parent temp=''
    validate_managed_site "$MANAGED_SITE" || { err 'Некорректное описание выбранного сайта.'; return 85; }
    [[ "$path" = /* && ! -L "$path" ]] || return 85
    if [ -e "$path" ]; then private_session_file "$path" || return 85; fi
    parent="$(dirname -- "$path")" || return 85
    temp="$(mktemp "$parent/.managed-site.XXXXXXXX")" || return 85
    trap '[ -z "$temp" ] || rm -f -- "$temp"' EXIT
    printf '%s\n' "$MANAGED_SITE" > "$temp" && chmod 0600 -- "$temp" || return 85
    trusted_rpm_keyring "$temp" >/dev/null || return 85
    mv -T -- "$temp" "$path" || return 85
)

managed_site_load() {
    local path="$1" record
    private_session_file "$path" && trusted_rpm_keyring "$path" >/dev/null || return 85
    [ "$(stat -c %s -- "$path")" -le 4096 ] && awk 'END {exit NR != 1}' "$path" || return 85
    record="$(cat -- "$path")" && validate_managed_site "$record" || return 85
    MANAGED_SITE="$record"
}

managed_probe_record() (
    local path="$1" value="$2" temp
    temp="$(mktemp "$(dirname -- "$path")/.record.XXXXXXXX")" || return 85
    trap 'rm -f -- "$temp"' EXIT
    printf '%s\n' "$value" > "$temp" && chmod 0600 -- "$temp" && mv -T -- "$temp" "$path"
)

managed_probe_read_record() {
    local path="$1" value
    private_session_file "$path" && [ "$(stat -c %s -- "$path")" -le 4096 ] || return 85
    awk 'END {exit NR != 1}' "$path" || return 85
    value="$(cat -- "$path")" || return 85
    [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] || return 85
    printf '%s\n' "$value"
}

# Caller holds the lease lock. Open directory descriptors anchor cleanup even if
# a site owner renames the document root or the temporary directory meanwhile.
managed_probe_cleanup_one() (
    local lease="$1" parent_anchor="${2:-}" directory_anchor="${3:-}" MANAGED_SITE=''
    local scheme host port root name parent_id expected_id expected_hash actual file parent_fd='' directory_fd=''
    private_session_dir "$lease" && managed_site_load "$lease/site" || return 85
    IFS='|' read -r scheme host port root <<< "$MANAGED_SITE"
    name="$(managed_probe_read_record "$lease/name")" && [[ "$name" =~ ^bitrix-master-probe-[a-f0-9]{32}$ ]] || return 85
    parent_id="$(managed_probe_read_record "$lease/parent.id")" && [[ "$parent_id" =~ ^[0-9]+:[0-9]+$ ]] || return 85
    expected_hash="$(managed_probe_read_record "$lease/sha256")" && [[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 85
    if [ -z "$parent_anchor" ]; then
        [[ -d "$root" && ! -L "$root" && "$(readlink -e -- "$root")" = "$root" ]] || return 85
        exec {parent_fd}< "$root" || return 85
        parent_anchor="/proc/$BASHPID/fd/$parent_fd"
    fi
    [ "$(stat -Lc '%d:%i' -- "$parent_anchor")" = "$parent_id" ] || return 85
    if [ -z "$directory_anchor" ]; then
        if [ ! -e "$parent_anchor/$name" ] && [ ! -L "$parent_anchor/$name" ]; then
            directory_anchor=''
        else
            [[ -d "$parent_anchor/$name" && ! -L "$parent_anchor/$name" ]] || return 85
            exec {directory_fd}< "$parent_anchor/$name" || return 85
            directory_anchor="/proc/$BASHPID/fd/$directory_fd"
        fi
    fi
    if [ -n "$directory_anchor" ]; then
        actual="$(stat -Lc '%u:%a:%h' -- "$directory_anchor")" || return 85
        [[ "$actual" =~ ^0:(700|755):(1|2)$ ]] || return 85
        # A failed mkdir may have collided with another directory. An unclaimed
        # empty directory is safer to leave than to infer ownership from its name.
        expected_id="$(managed_probe_read_record "$lease/directory.id")" && [[ "$expected_id" =~ ^[0-9]+:[0-9]+$ ]] || return 85
        [ "$(stat -Lc '%d:%i' -- "$directory_anchor")" = "$expected_id" ] || return 85
        file="$directory_anchor/probe.php"
        if [ -e "$file" ] || [ -L "$file" ]; then
            [[ -f "$file" && ! -L "$file" ]] || return 85
            actual="$(stat -c '%u:%a:%h' -- "$file")" || return 85
            [[ "$actual" = 0:600:1 || "$actual" = 0:644:1 ]] || return 85
            if [ -e "$lease/file.id" ]; then
                expected_id="$(managed_probe_read_record "$lease/file.id")" && [[ "$expected_id" =~ ^[0-9]+:[0-9]+$ ]] || return 85
                [ "$(stat -c '%d:%i' -- "$file")" = "$expected_id" ] || return 85
            fi
            actual="$(sha256sum -- "$file")" || return 85
            [ "${actual%% *}" = "$expected_hash" ] || return 85
            rm -f -- "$file" || return 85
        fi
        # Do not recursively delete directories or follow a replacement symlink.
        [[ -d "$parent_anchor/$name" && ! -L "$parent_anchor/$name" ]] || return 85
        [ "$(stat -Lc '%d:%i' -- "$parent_anchor/$name")" = "$(stat -Lc '%d:%i' -- "$directory_anchor")" ] || return 85
        rmdir -- "$parent_anchor/$name" || return 85
    fi
    for name in site name parent.id directory.id file.id sha256 payload.php curl.conf active.lock response; do
        if [ -e "$lease/$name" ] || [ -L "$lease/$name" ]; then
            private_session_file "$lease/$name" || return 85
            rm -f -- "$lease/$name" || return 85
        fi
    done
    # Interrupted atomic metadata writes are private, regular files only.
    for file in "$lease"/.record.*; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        private_session_file "$file" || return 85
        rm -f -- "$file" || return 85
    done
    rmdir -- "$lease" || return 85
)

managed_probe_cleanup_stale() (
    local state="$UPDATER_STATE/probes" lease name lock_fd rc=0
    require_root || return
    if [ ! -e "$state" ] && [ ! -L "$state" ]; then return 0; fi
    private_session_dir "$UPDATER_STATE" && private_session_dir "$state" || return 85
    need flock stat readlink sha256sum awk || return 85
    for lease in "$state"/*; do
        [ -e "$lease" ] || [ -L "$lease" ] || continue
        name="${lease##*/}"
        if ! [[ "$name" =~ ^[a-f0-9]{32}$ ]] || ! private_session_dir "$lease" || ! private_session_file "$lease/active.lock"; then
            err 'Небезопасная запись временной веб-проверки. Автоматическая очистка остановлена.'
            rc=85; continue
        fi
        exec {lock_fd}< "$lease/active.lock" || { rc=85; continue; }
        if flock -n "$lock_fd"; then
            if ! managed_probe_cleanup_one "$lease"; then
                err "Временная веб-проверка изменена или недоступна; файлы сохранены для проверки: $lease"
                rc=85
            fi
        fi
        exec {lock_fd}<&-
    done
    return "$rc"
)

managed_http_check() (
    local expected="$1" scheme host port root state lease='' stage='' parent_fd='' directory_fd='' lease_fd=''
    local parent_anchor='' directory_anchor='' token nonce token_hash expiry name url result expected_hash
    local directory_metadata directory_identity parent_real directory_real selinux_status=1
    local -a directory_entries=()
    # Bash locals inherit export attributes from same-named caller variables.
    # Keep generated credentials out of child environments as well as argv.
    export -n token token_hash
    require_root || return
    validate_managed_site "$MANAGED_SITE" && [[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        err 'Не задан выбранный сайт или ожидаемая версия PHP.'; return 85;
    }
    need curl head cmp mktemp stat readlink sha256sum od tr flock mkdir rmdir rm chmod cp date awk || return 85
    ensure_session_dir "$UPDATER_STATE" || return 85
    state="$UPDATER_STATE/probes"
    ensure_session_dir "$state" && managed_probe_cleanup_stale || return 85
    IFS='|' read -r scheme host port root <<< "$MANAGED_SITE"
    [[ -d "$root" && ! -L "$root" && "$(readlink -e -- "$root")" = "$root" ]] || {
        err 'Каталог выбранного сайта изменился или недоступен.'; return 85;
    }
    managed_probe_exit() {
        local status=$?
        trap - EXIT HUP INT TERM
        if [ -n "$lease" ]; then
            if ! managed_probe_cleanup_one "$lease" "$parent_anchor" "$directory_anchor"; then
                err "Не удалось безопасно удалить временную веб-проверку. Проверьте запись $lease"
                [ "$status" -ne 0 ] || status=85
            fi
        elif [ -n "$stage" ] && private_session_dir "$stage"; then
            # This is a private staging directory; no web file exists yet.
            rm -rf -- "$stage" || { [ "$status" -ne 0 ] || status=85; }
        fi
        exit "$status"
    }
    trap managed_probe_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec {parent_fd}< "$root" || return 85
    parent_anchor="/proc/$BASHPID/fd/$parent_fd"
    token="$(od -v -An -N32 -tx1 /dev/urandom | tr -d ' \n')" || return 85
    nonce="$(od -v -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || return 85
    [[ "$token" =~ ^[a-f0-9]{64}$ && "$nonce" =~ ^[a-f0-9]{32}$ ]] || return 85
    token_hash="$(printf '%s' "$token" | sha256sum)" || return 85
    token_hash="${token_hash%% *}"
    expiry=$(( $(date +%s) + 180 ))
    name="bitrix-master-probe-$nonce"
    url="$scheme://$host:$port/$name/probe.php"
    stage="$(mktemp -d "$state/.stage.XXXXXXXX")" || return 85
    exec {lease_fd}> "$stage/active.lock" || return 85
    flock -n "$lease_fd" || return 85
    managed_site_save "$stage/site" || return 85
    managed_probe_record "$stage/name" "$name" &&
    managed_probe_record "$stage/parent.id" "$(stat -Lc '%d:%i' -- "$parent_anchor")" || return 85
    cat > "$stage/payload.php" <<PHP
<?php
header('Content-Type: text/plain; charset=UTF-8');
header('Cache-Control: private, no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
\$peer = isset(\$_SERVER['REMOTE_ADDR']) ? \$_SERVER['REMOTE_ADDR'] : '';
\$method = isset(\$_SERVER['REQUEST_METHOD']) ? \$_SERVER['REQUEST_METHOD'] : '';
\$secret = isset(\$_SERVER['HTTP_X_BITRIX_MASTER_PROBE']) ? \$_SERVER['HTTP_X_BITRIX_MASTER_PROBE'] : '';
\$allowed = (\$peer === '127.0.0.1' || \$peer === '::1') && \$method === 'GET' && time() <= $expiry;
if (!\$allowed || !is_string(\$secret) || !preg_match('/^[a-f0-9]{64}\$/D', \$secret) || !function_exists('hash')) {
    header('HTTP/1.1 404 Not Found'); exit;
}
\$actual = hash('sha256', \$secret);
\$known = '$token_hash';
\$difference = 0;
for (\$i = 0; \$i < 64; \$i++) { \$difference |= ord(\$actual[\$i]) ^ ord(\$known[\$i]); }
if (\$difference !== 0) { header('HTTP/1.1 404 Not Found'); exit; }
if (PHP_SAPI !== 'apache2handler' || !function_exists('mb_substr') || !extension_loaded('mysqli')) {
    header('HTTP/1.1 503 Service Unavailable'); exit;
}
echo 'BITRIX_MASTER_OK ' . PHP_VERSION . " apache2handler $nonce\n";
PHP
    [ "$?" -eq 0 ] || return 85
    expected_hash="$(sha256sum -- "$stage/payload.php")" || return 85
    managed_probe_record "$stage/sha256" "${expected_hash%% *}" || return 85
    printf 'header = "X-Bitrix-Master-Probe: %s"\n' "$token" > "$stage/curl.conf" || return 85
    chmod 0600 -- "$stage/payload.php" "$stage/curl.conf" "$stage/active.lock" || return 85
    [ ! -e "$state/$nonce" ] && [ ! -L "$state/$nonce" ] || return 85
    mv -T -- "$stage" "$state/$nonce" || return 85
    lease="$state/$nonce"; stage=''
    # The parent belongs to the site owner, who can replace a directory entry
    # after mkdir. Never open, populate, or chmod a replacement blindly.
    # Root0755 is safe from creation: credentials stay in the private lease and
    # probe.php is O_EXCL-created at0600 until its complete guard is ready.
    mkdir -m 0755 -- "$parent_anchor/$name" || return 85
    directory_metadata="$(stat -c '%F:%u:%a:%d:%i' -- "$parent_anchor/$name")" || return 85
    [[ "$directory_metadata" =~ ^directory:0:755:([0-9]+:[0-9]+)$ ]] || {
        err 'Каталог временной проверки подменён; запись файлов отменена.'; return 85;
    }
    directory_identity="${BASH_REMATCH[1]}"
    exec {directory_fd}< "$parent_anchor/$name" || return 85
    directory_anchor="/proc/$BASHPID/fd/$directory_fd"
    [[ ! -L "$parent_anchor/$name" &&
       "$(stat -c '%F:%u:%a:%d:%i' -- "$parent_anchor/$name")" = "$directory_metadata" &&
       "$(stat -Lc '%F:%u:%a:%d:%i' -- "$directory_anchor")" = "$directory_metadata" ]] || {
        err 'Каталог временной проверки изменился при открытии; запись файлов отменена.'; return 85;
    }
    parent_real="$(readlink -e -- "$parent_anchor")" && directory_real="$(readlink -e -- "$directory_anchor")" || return 85
    [ "$directory_real" = "$parent_real/$name" ] || {
        err 'Временный каталог оказался вне выбранного пути сайта.'; return 85;
    }
    shopt -s nullglob dotglob
    directory_entries=("$directory_anchor"/*)
    [ "${#directory_entries[@]}" -eq 0 ] || {
        err 'Временный каталог уже содержит чужие файлы; запись отменена.'; return 85;
    }
    managed_probe_record "$lease/directory.id" "$directory_identity" || return 85
    (set -o noclobber; cat -- "$lease/payload.php" > "$directory_anchor/probe.php") || return 85
    managed_probe_record "$lease/file.id" "$(stat -c '%d:%i' -- "$directory_anchor/probe.php")" || return 85
    chmod 0644 -- "$directory_anchor/probe.php" || return 85
    if command -v selinuxenabled >/dev/null 2>&1; then
        selinux_status=0
        selinuxenabled || selinux_status=$?
        [[ "$selinux_status" = 0 || "$selinux_status" = 1 ]] || {
            err 'Не удалось определить состояние SELinux.'; return 85;
        }
    elif [ -e /sys/fs/selinux/enforce ]; then
        selinux_status=0
    fi
    if [ "$selinux_status" = 0 ]; then
        need chcon || return 85
        # Anchor both reference and targets; never relabel a replaced web path.
        chcon --reference="$parent_anchor/." -- "$directory_anchor/." "$directory_anchor/probe.php" >/dev/null 2>&1 || {
            err 'Не удалось подготовить SELinux-контекст временной проверки.'; return 85;
        }
    fi
    for result in negative authenticated negative; do
        local curl_options=()
        [ "$result" != authenticated ] || curl_options=(--config "$lease/curl.conf")
        if ! curl -q "${curl_options[@]}" --silent --show-error --globoff --proto '=http,https' \
                  --connect-timeout 5 --max-time 20 --noproxy '*' --resolve "$host:$port:127.0.0.1" \
                  --max-filesize 4096 --write-out '\n%{http_code}\n%{remote_ip}\n%{remote_port}\n' \
                  -- "$url" | head -c 4096 > "$lease/response"; then
            err 'Не удалось выполнить временную локальную HTTP-проверку.'; return 85
        fi
        if [ "$result" = authenticated ]; then
            cmp -s "$lease/response" <(printf 'BITRIX_MASTER_OK %s apache2handler %s\n\n200\n127.0.0.1\n%s\n' "$expected" "$nonce" "$port") || {
                err 'Временная проверка не подтвердила версию PHP, mod_php и необходимые расширения.'; return 85;
            }
        else
            cmp -s "$lease/response" <(printf '\n404\n127.0.0.1\n%s\n' "$port") || {
                err 'Временная проверка не закрыта для запроса без секретного ключа; обновление запрещено.'; return 85;
            }
        fi
    done
    status_line ok "Веб-PHP $expected (apache2handler) подтверждён для $host. Временная проверка закрыта и будет удалена."
)

# Мутирующие операции: отдельный обработчик Bash, без зависимости от Python.
if [ "${1:-}" = --menu-action ]; then
    if [ "$#" -lt 2 ] || [ ! -t 0 ] || ! { true >&3; } 2>/dev/null; then
        err 'Внутренний режим меню требует терминал и канал результата.'; exit 2
    fi
    MENU_RESULT_ENABLED=1
    shift
fi
if [ "$#" -eq 0 ] && [ -t 0 ]; then full_menu; exit $?; fi
case "${1:-}" in
  --setup-update)
      shift
      setup_auto_update "$@"
      exit $?
      ;;
  --auto-update)
      shift
      auto_update_dispatch "$@"
      exit $?
      ;;
  --prepare-release)
      shift
      prepare_release_dispatch "$@"
      exit $?
      ;;
  --check)
      shift
      quick_check "$@"
      exit $?
      ;;
  --check-site)
      shift
      check_site_dispatch "$@"
      exit $?
      ;;
  --plan|--build|--update|--rollback|--status)
      action="$1"; shift
      updater_dispatch "$action" "$@"
      exit $?
      ;;
esac

# Обработка режима изолированной установки Python происходит только по явному запросу.
if [ "${1:-}" = '--help' ] || [ "${1:-}" = '-h' ]; then help_ru; exit 0; fi
if [ "${1:-}" = '--version' ]; then printf 'Bitrix Server Master %s\n' "$MASTER_VERSION"; exit 0; fi
if [ "${1:-}" = '--bootstrap-python' ]; then
    shift
    python_archive=''
    if [ "${1:-}" = '--python-archive' ]; then
        if [ -z "${2:-}" ]; then echo 'Укажите путь к архиву.' >&2; exit 2; fi
        python_archive="$2"
        shift 2
    fi
    if [ "$#" -ne 0 ]; then echo 'Лишние аргументы режима --bootstrap-python.' >&2; exit 2; fi
    bootstrap_python "$python_archive"
    exit $?
fi

if [ "${1:-}" = '--audit' ]; then
    shift
    audit_options=("$@")
    while [ "$#" -gt 0 ]; do
        case "$1" in
          --offline|--json) ;;
          --report)
              if [ "$#" -gt 1 ] && [[ "$2" != -* ]]; then
                  if [ -z "$2" ]; then err 'Укажите непустой путь отчёта.'; exit 2; fi
                  shift
              fi
              ;;
          --report=) err 'Укажите непустой путь отчёта.'; exit 2 ;;
          --report=*) ;;
          *) err "Параметр $1 недопустим для --audit. См. --help."; exit 2 ;;
        esac
        shift
    done
    set -- --diagnose --full --check-updates --report "${audit_options[@]}"
fi

py="$(python_path)"
if [ -z "$py" ]; then
    case "${1:-}" in
        --compare|--compare-menu)
            err 'Для сравнения нужен Python 3.8+. В меню 1 → 7 можно подготовить отдельный Python, затем 1 → 3 — сохранить полный отчёт.'
            exit 3 ;;
    esac
    fallback_diagnose "$@"
    exit $?
fi

# Встроенная программа исполняется из stdin: --diagnose не создаёт .py-файлов на диске.
audit_targets="$(set_php_target 8.2; printf '8.2=%s;' "$TARGET_PHP"; set_php_target 8.3; printf '8.3=%s' "$TARGET_PHP")"
# FD 4 сохраняет ввод пользователя: stdin Python занят встроенным кодом.
{
    sed -n '/^__PYTHON_PAYLOAD_START__$/,/^__PYTHON_PAYLOAD_END__$/p' "$SELF" | sed '1d;$d' | BITRIX_MASTER_TARGETS="$audit_targets" BITRIX_MASTER_SCRIPT_DIR="$(dirname -- "$SELF")" "$py" -B - "$@"
} 4<&0
exit $?

# Всё после этой строки — встроенный код Python, внутри heredoc для bash -n.
: <<'__PYTHON_PAYLOAD_END__'
__PYTHON_PAYLOAD_START__
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bitrix Server Master — read-only diagnostics engine (stdlib only)."""
import argparse
import datetime as dt
import glob
import json
import os
import platform
import re
import shutil
import socket
import stat
import subprocess
import sys
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path

VERSION = '1.0.0-rc11'
PHP_EOL = {'5.6': '2018-12-31', '7.0': '2019-01-10', '7.1': '2019-12-01',
           '7.2': '2020-11-30', '7.3': '2021-12-06', '7.4': '2022-11-28',
           '8.0': '2023-11-26', '8.1': '2025-12-31', '8.2': '2026-12-31',
           '8.3': '2027-12-31', '8.4': '2028-12-31', '8.5': '2029-12-31'}
OS_EOL = {'centos:7': '2024-06-30', 'centos:8': '2021-12-31',
          'rhel:7': '2024-06-30', 'almalinux:8': '2029-05-31',
          'almalinux:9': '2032-05-31', 'rocky:8': '2029-05-31',
          'rocky:9': '2032-05-31'}
RISK_PRIORITIES = {'critical': 0, 'warning': 1, 'info': 2}


def run(argv, timeout=6, max_chars=5000, include_stderr=False):
    try:
        cp = subprocess.run(argv, capture_output=True, text=True, errors='replace',
                            timeout=timeout, env={**os.environ, 'LC_ALL': 'C'})
        output = ((cp.stdout or '') + '\n' + (cp.stderr or '')) if include_stderr else (cp.stdout or cp.stderr or '')
        return output.strip()[:max_chars], cp.returncode
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired, OSError):
        return '', 127


def read(path, limit=16384):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return fh.read(limit)
    except (OSError, UnicodeError):
        return ''


def parse_os_release():
    pairs = {}
    for ln in read('/etc/os-release').splitlines():
        if '=' in ln and not ln.lstrip().startswith('#'):
            key, value = ln.split('=', 1)
            pairs[key] = value.strip().strip('"')
    return pairs


def version(text):
    m = re.search(r'\b(\d+)\.(\d+)\.(\d+)\b', text or '')
    return m.group(0) if m else None


def branch(ver):
    return '.'.join(ver.split('.')[:2]) if ver else None


def lifecycle(kind, key):
    today = dt.datetime.now(dt.timezone.utc).date()
    last = (PHP_EOL if kind == 'php' else OS_EOL).get(key)
    if not last:
        return {'status': 'unknown', 'deadline': None, 'note': 'Срок поддержки не задан в этой версии справочника'}
    ended = today > dt.date.fromisoformat(last)
    return {'status': 'ended' if ended else 'supported', 'deadline': last,
            'note': 'Основная или расширенная поддержка завершилась' if ended else 'Указанный срок окончания поддержки ещё не наступил'}


def iso_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def memory():
    result = {}
    for line in read('/proc/meminfo').splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            try:
                result[k] = int(v.strip().split()[0]) // 1024
            except (ValueError, IndexError):
                pass
    return {k: result.get(k) for k in ('MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree')}


def disk(path):
    try:
        st = os.statvfs(path)
        return {'path': path, 'total_gb': round(st.f_blocks * st.f_frsize / (1024**3), 2),
                'available_gb': round(st.f_bavail * st.f_frsize / (1024**3), 2),
                'used_pct': round(100 * (st.f_blocks - st.f_bfree) / max(1, st.f_blocks), 1)}
    except OSError:
        return None


def package_list():
    if not shutil.which('rpm'):
        return [], 'RPM отсутствует'
    raw, rc = run(['rpm', '-qa', '--qf', '%{NAME}|%{VERSION}|%{RELEASE}\n'], timeout=16, max_chars=800000)
    if rc != 0:
        return [], 'Не удалось получить список RPM'
    packages = []
    for line in raw.splitlines():
        parts = line.split('|')
        if len(parts) == 3:
            packages.append({'name': parts[0], 'version': parts[1], 'release': parts[2]})
    # Avoid unbounded output: for safety the collector intentionally stores only relevant packages.
    return packages, None


def php_core_rpms(packages, cli_version, package_error):
    names = ('php', 'php-cli', 'php-common')
    core = [package for package in packages if package['name'] in names]
    result = {'status': 'unknown', 'packages': core, 'missing': [], 'mismatches': [], 'duplicates': []}
    if package_error or not cli_version:
        result['reason'] = package_error or 'Версия PHP CLI не определена'
        return result
    result['missing'] = [name for name in names if not any(p['name'] == name for p in core)]
    result['mismatches'] = [p for p in core if p['version'] != cli_version]
    result['duplicates'] = [name for name in names if sum(p['name'] == name for p in core) > 1]
    result['status'] = ('ambiguous' if result['duplicates'] else
                        'mismatch' if result['mismatches'] else
                        'incomplete' if result['missing'] else 'confirmed')
    return result


def get_packages(all_packages, rx):
    return sorted([p for p in all_packages if re.search(rx, p['name'], re.I)],
                  key=lambda p: p['name'])


def svc(name):
    if not shutil.which('systemctl'):
        return 'недоступно'
    out, rc = run(['systemctl', 'is-active', name], timeout=4)
    if rc == 0:
        return 'active'
    first = out.splitlines()[0].strip() if out else ''
    return first if first in ('inactive', 'failed', 'activating', 'deactivating', 'unknown') else 'unknown'


def web_server():
    apache_bin = shutil.which('httpd') or shutil.which('apache2')
    nginx_bin = shutil.which('nginx')
    apache_ver, _ = run([apache_bin, '-v']) if apache_bin else ('', 127)
    nginx_ver, _ = run([nginx_bin, '-v']) if nginx_bin else ('', 127)
    mpm = None
    phpmod = None
    modules_error = None
    if apache_bin:
        out, rc = run([apache_bin, '-M'], timeout=8)
        if rc == 0:
            m = re.search(r'\b(mpm_\w+_module)\b', out)
            mpm = m.group(1) if m else None
            phpmod = bool(re.search(r'\bphp\d?_module\b', out))
        else:
            modules_error = 'Не удалось прочитать модули Apache (httpd -M)'
    return {
        'apache': {'version': version(apache_ver), 'active': svc('httpd') if apache_bin else 'нет',
                   'mpm': mpm, 'mod_php': phpmod, 'modules_check_error': modules_error},
        'nginx': {'version': version(nginx_ver), 'active': svc('nginx') if nginx_bin else 'нет'},
        'php_fpm': {'active': svc('php-fpm'), 'process_count': process_count('php-fpm')},
        'apache_process_count': (process_count('httpd') or 0) + (process_count('apache2') or 0),
        'apache_worker_limit': apache_worker_limit(),
    }


def process_count(name):
    out, rc = run(['ps', '-C', name, '-o', 'pid='], timeout=4)
    return len(out.splitlines()) if rc == 0 else (0 if rc == 1 else None)


def apache_worker_limit():
    vals = []
    for path in ['/etc/httpd/bx/conf/prefork.conf', '/etc/httpd/bx-scale/conf/prefork.conf',
                 '/etc/httpd/conf.modules.d/00-mpm.conf']:
        data = read(path, 100000)
        m = re.search(r'^\s*MaxRequestWorkers\s+(\d+)', data, re.M | re.I)
        if m:
            vals.append({'file': path, 'value': int(m.group(1))})
    return vals


def php_info():
    loc = shutil.which('php')
    if not loc:
        return {'binary': None, 'version': None, 'modules': [], 'module_errors': [],
                'web_version': None, 'web_version_confirmed': False}
    ver_out, ver_rc = run([loc, '-v'], timeout=8, include_stderr=True)
    mod_out, mod_rc = run([loc, '-m'], timeout=8, include_stderr=True)
    modules = []
    if mod_rc == 0:
        for ln in mod_out.splitlines():
            txt = ln.strip()
            if txt and not txt.startswith('[') and not txt.startswith('PHP Warning') and not txt.startswith('PHP Fatal error') and not txt.startswith('Warning:') and not txt.startswith('Module ') and txt != '':
                modules.append(txt)
    warnings = re.findall(r'PHP (?:Warning|Fatal error):[^\n]+', '\n'.join((ver_out, mod_out)))
    banner = re.search(r'^PHP ([0-9]+\.[0-9]+\.[0-9]+)(?=\s|$)', ver_out, re.M)
    return {'binary': loc, 'version': banner.group(1) if ver_rc == 0 and banner else None,
            'modules': sorted(set(modules), key=str.lower),
            'module_errors': warnings[:10], 'web_version': None,
            'web_version_confirmed': False}


def repos():
    enabled, disabled, invalid = [], [], []
    if not os.path.isdir('/etc/yum.repos.d'):
        return {'enabled': [], 'disabled': [], 'invalid_files': []}
    for path in glob.glob('/etc/yum.repos.d/*.repo')[:200]:
        data = read(path, 150000)
        if not data:
            invalid.append(os.path.basename(path))
            continue
        section = None
        flag = '1'
        for ln in data.splitlines() + ['[__END__]']:
            s = ln.strip()
            if s.startswith('#') or s.startswith(';'):
                continue
            if s.startswith('[') and s.endswith(']'):
                if section and section != '__END__':
                    (enabled if flag == '1' else disabled).append(section)
                section = s[1:-1]
                flag = '1'
            elif section and re.match(r'^enabled\s*=', s, re.I):
                flag = s.split('=', 1)[1].strip()
    return {'enabled': sorted(set(enabled)), 'disabled': sorted(set(disabled)),
            'invalid_files': sorted(set(invalid))}


BITRIX_ENV_RPM_NAMES = ('bitrix-env', 'bitrix-env-crm')
BITRIX_HOME = Path('/home/bitrix')
BITRIX_INVENTORY = Path('/etc/ansible/hosts')
BITRIX_MENU = Path('/root/menu.sh')
BITRIX_VERSION_FILES = (Path('/etc/bitrix-env/version'), Path('/etc/bitrix-env/version.conf'))
BITRIX_POOL_GROUPS = frozenset((
    'bitrix-hosts', 'bitrix-mgmt', 'bitrix-web', 'bitrix-mysql', 'bitrix-push',
    'bitrix-memcached', 'bitrix-sphinx', 'bitrix-searchd', 'bitrix-transformer',
))
AUDIT_NAME = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}')
AUDIT_VERSION = r'[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}'
PHP_METADATA_TOKENS = re.compile(
    r"""//[^\n]*|\#[^\n]*|/\*.*?(?:\*/|\Z)|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|<<<|=>|[A-Za-z0-9_$]+|\S""",
    re.S)


@contextmanager
def audit_parent(path):
    # Hold each directory open so a concurrently replaced symlink cannot redirect a privileged read.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parts = path.parts
    fd = os.open(parts[0], flags)
    try:
        for part in parts[1:-1]:
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd, parts[-1]
    finally:
        os.close(fd)


def audit_error(error):
    if isinstance(error, FileNotFoundError):
        return 'missing'
    if isinstance(error, PermissionError):
        return 'permission_denied'
    return 'unavailable'


def audit_file(path, limit):
    try:
        with audit_parent(path) as (parent, name):
            if not stat.S_ISREG(os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode):
                return '', 'unavailable'
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            with os.fdopen(os.open(name, flags, dir_fd=parent), 'rb') as fh:
                if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                    return '', 'unavailable'
                data = fh.read(limit + 1)
    except OSError as error:
        return '', audit_error(error)
    if len(data) > limit:
        return '', 'limited'
    return data.decode('utf-8-sig', errors='replace'), 'read'


def audit_dirs(path, limit):
    names, count, status = [], 0, 'read'
    try:
        with audit_parent(path) as (parent, name):
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                with os.scandir(fd) as entries:
                    for entry in entries:
                        if count >= limit:
                            status = 'limited'
                            break
                        count += 1
                        if entry.is_dir(follow_symlinks=False):
                            if AUDIT_NAME.fullmatch(entry.name):
                                names.append(entry.name)
                            else:
                                status = 'limited'
                        elif entry.is_symlink():
                            status = 'limited'
            finally:
                os.close(fd)
    except OSError as error:
        status = audit_error(error)
    return sorted(names), count, status


def php_file_version(path, core=False):
    text, status = audit_file(path, 32768)
    if status != 'read':
        return None, status
    php = re.fullmatch(r'\s*<\?(?:php(?=\s))?(.*?)(?:\?>\s*)?', text, re.I | re.S)
    if not php:
        return None, 'unknown'
    tokens = [t for t in PHP_METADATA_TOKENS.findall(php[1])
              if not t.startswith(('//', '#', '/*'))]
    if any(t in ('<<<', "'", '"', '?', '<') for t in tokens):
        return None, 'unknown'
    versions, depth, module_depth = set(), 0, None
    for i, token in enumerate(tokens):
        if core:
            if (token.lower() != 'define' or tokens[i + 1:i + 4] not in
                    (['(', '"SM_VERSION"', ','], ['(', "'SM_VERSION'", ',']) or
                    tokens[i + 5:i + 6] != [')']):
                continue
            value = tokens[i + 4]
        else:
            if token in ('(', '[', '{'):
                depth += 1
                if (token == '[' and tokens[i - 2:i] == ['$arModuleVersion', '='] or
                        token == '(' and tokens[i - 3:i] == ['$arModuleVersion', '=', 'array']):
                    module_depth = depth
            elif token in (')', ']', '}'):
                if depth == module_depth:
                    module_depth = None
                depth -= 1
            if (depth != module_depth or token not in ('"VERSION"', "'VERSION'") or
                    tokens[i - 1] not in (',', '(', '[') or tokens[i + 1:i + 2] != ['=>'] or
                    tokens[i + 3:i + 4] not in ([','], [']'], [')'])):
                continue
            value = tokens[i + 2]
        if re.fullmatch(r"""(["'])(""" + AUDIT_VERSION + r""")\1""", value):
            versions.add(value[1:-1])
    if len(versions) == 1:
        return versions.pop(), 'file_only'
    return None, 'ambiguous' if versions else 'unknown'


def bitrix_rpm_version(package):
    ver, rel = package.get('version'), package.get('release')
    if not isinstance(ver, str) or not isinstance(rel, str):
        return None
    version_match = re.fullmatch(r'[0-9]{1,6}\.[0-9]{1,6}', ver)
    release_match = re.fullmatch(r'([0-9]{1,6})\.el(?:7(?:\.centos)?|9)', rel)
    return version_match[0] + '.' + release_match[1] if version_match and release_match else None


def bitrix_environment(packages, pkg_err):
    packages = sorted((p for p in packages if p['name'] in BITRIX_ENV_RPM_NAMES),
                      key=lambda p: (p['name'], p['version'], p['release']))
    result = {'version': None, 'status': 'unknown', 'source': None, 'packages': packages}
    if packages:
        result['source'] = 'rpm'
        if len(packages) != 1:
            result['status'] = 'ambiguous'
            return result
        ver = bitrix_rpm_version(packages[0])
        if ver and not pkg_err:
            result.update(version=ver, status='confirmed')
        return result

    # Historical marker files can identify a version with lower confidence than RPM.
    evidence = []
    for path in BITRIX_VERSION_FILES:
        data, status = audit_file(path, 4096)
        literal = re.fullmatch(r'\s*(?:VERSION\s*=\s*)?(["\']?)(' + AUDIT_VERSION + r')\1\s*', data)
        if status == 'read' and literal:
            evidence.append((str(path), literal[2]))
    if len({ver for _, ver in evidence}) > 1:
        result.update(status='ambiguous', source='version_files')
    elif evidence:
        result.update(version=evidence[0][1], status='file_only', source=evidence[0][0])
    return result


def bitrix_core(site, allowed_cores):
    core = site / 'bitrix'
    try:
        with audit_parent(core) as (parent, name):
            mode = os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode
            if stat.S_ISLNK(mode):
                # A standard link may share a known site's bitrix directory. Reopen that exact
                # path without following any links, including chains or a changed target.
                target = os.path.normpath(str(site / os.readlink(name, dir_fd=parent)))
                if target not in allowed_cores:
                    return core, {'version': None, 'status': 'unavailable', 'source': None}
                core = Path(target)
    except OSError as error:
        return core, {'version': None, 'status': audit_error(error), 'source': None}

    candidates = (
        (core / 'modules/main/classes/general/version.php', True),
        (core / 'modules/main/install/version.php', False),
    )
    status = 'missing'
    for path, is_core in candidates:
        ver, state = php_file_version(path, core=is_core)
        if ver or state == 'ambiguous':
            return core, {'version': ver, 'status': state, 'source': str(path)}
        if status == 'missing':
            status = state
    return core, {'version': None, 'status': status, 'source': None}


def bitrix_modules(site, core, budget):
    items, examined, statuses = [], 0, {}
    for location, path in (('bitrix/modules', core / 'modules'), ('local/modules', site / 'local/modules')):
        dirs, count, state = audit_dirs(path, min(160, budget - examined))
        examined += count
        for name in dirs:
            ver, result = php_file_version(path / name / 'install/version.php')
            if ver:
                items.append({'name': name, 'location': location, 'version': ver})
            else:
                state = 'limited'
        statuses[location] = state
    states = set(statuses.values())
    if states == {'missing'}:
        status = 'missing'
    elif states <= {'missing', 'read'}:
        status = 'file_only'
    else:
        status = 'limited'
    return {'status': status, 'directories': statuses, 'items': items}, examined


def bitrix_sites():
    default, extras = BITRIX_HOME / 'www', BITRIX_HOME / 'ext_www'
    roots, coverage = [], {}
    try:
        with audit_parent(default) as (parent, name):
            mode = os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode
        coverage['default'] = 'read' if stat.S_ISDIR(mode) else 'unavailable'
        if coverage['default'] == 'read':
            roots.append(default)
    except OSError as error:
        coverage['default'] = audit_error(error)
    names, _, coverage['additional'] = audit_dirs(extras, 48)
    roots.extend(extras / name for name in names)

    allowed = {str(root / 'bitrix') for root in roots}
    items, budget = [], 512
    for root in roots:
        core_path, core = bitrix_core(root, allowed)
        modules, examined = bitrix_modules(root, core_path, budget)
        budget -= examined
        items.append({'root': str(root), 'confidence': 'static_version' if core['version'] else 'filesystem_candidate',
                      'core': core, 'modules': modules})
    states = set(coverage.values())
    status = ('limited' if not states <= {'read', 'missing'} else
              'file_only' if items else 'missing')
    return {'status': status, 'coverage': coverage, 'items': items}


def bitrix_pool():
    text, status = audit_file(BITRIX_INVENTORY, 131072)
    result = {'status': status, 'source': str(BITRIX_INVENTORY), 'hosts': []}
    if status != 'read':
        return result
    group, found, skipped = None, False, False
    hosts, members = {}, set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(('#', ';')):
            continue
        section = re.fullmatch(r'\[([A-Za-z0-9_:-]+)\]\s*(?:[;#].*)?', line)
        if line.startswith('['):
            group = section[1] if section and section[1] in BITRIX_POOL_GROUPS else None
            found = found or group is not None
            continue
        if group:
            host = re.fullmatch(r'([A-Za-z0-9_][A-Za-z0-9_.-]{0,252})(?:\s+(?:[;#].*|\w+=.*))?', line)
            if not host or (host[1] not in hosts and len(hosts) >= 128):
                skipped = True
                continue
            name = host[1]
            roles = hosts.setdefault(name, set())
            if group == 'bitrix-hosts':
                members.add(name)
            else:
                roles.add(group)
    result['hosts'] = [{'name': name, 'roles': sorted(hosts[name])} for name in sorted(members)]
    result['status'] = 'limited' if skipped or hosts.keys() - members else 'file_only' if found else 'unknown'
    return result


def bitrix_menu():
    try:
        with audit_parent(BITRIX_MENU) as (parent, name):
            mode = os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode
        status = ('present' if mode & 0o111 else 'not_executable') if stat.S_ISREG(mode) else 'unavailable'
    except OSError as error:
        status = audit_error(error)
    return {'path': str(BITRIX_MENU), 'status': status}


def bitrix_info(pkgs, full=False, pkg_err=None):
    bitrix_packages = get_packages(pkgs, r'^(bitrix|bx-)|bitrixenv')
    markers = {p: os.path.exists(p) for p in ['/home/bitrix/www/bitrix',
                                               '/etc/httpd/bx', '/etc/nginx/bx',
                                               '/etc/ansible/']}
    environment = bitrix_environment(bitrix_packages, pkg_err)
    sites = bitrix_sites() if full else {'status': 'not_checked', 'items': []}
    pool = bitrix_pool() if full else {'status': 'not_checked', 'hosts': []}
    menu = bitrix_menu() if full else {'status': 'not_checked'}
    return {'detected': (any(markers.values()) or bool(bitrix_packages) or
                         environment['version'] is not None or
                         any(site['core']['version'] for site in sites['items']) or
                         bool(pool['hosts']) or menu['status'] == 'present'),
            'version': environment['version'], 'markers': markers, 'packages': bitrix_packages[:25],
            'environment': environment, 'sites': sites, 'pool': pool, 'menu': menu}


def db_info(pkgs):
    names = get_packages(pkgs, r'^(mysql-community-server|Percona-Server-server|MariaDB-server|mariadb-server|mysql-server)$')
    cli = shutil.which('mysql') or shutil.which('mariadb')
    v, _ = run([cli, '--version']) if cli else ('', 127)
    return {'server_packages': names, 'client_version': version(v),
            'services': {n: svc(n) for n in ('mysqld', 'mariadb')}}


def live_php(branch_str, offline):
    if offline:
        return {'status': 'skipped', 'reason': 'Включён режим --offline'}
    if not branch_str or not re.fullmatch(r'\d+\.\d+', branch_str):
        return {'status': 'unavailable', 'reason': 'Невозможно определить ветку PHP'}
    url = 'https://www.php.net/releases/index.php?json&version=' + branch_str
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'BitrixServerMaster/' + VERSION})
        with urllib.request.urlopen(req, timeout=9) as resp:
            raw = resp.read(20000)
        j = json.loads(raw.decode('utf-8'))
        latest = j.get('version') if isinstance(j, dict) else None
        if not isinstance(latest, str) or not re.fullmatch(r'\d+\.\d+\.\d+', latest) or branch(latest) != branch_str:
            return {'status': 'unavailable', 'reason': 'PHP.net вернул неподходящие данные'}
        return {'status': 'ok', 'version': latest, 'source': url}
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        return {'status': 'unavailable', 'reason': 'Не удалось подтвердить версию по HTTPS на php.net'}


def url_probe(url):
    if not url:
        return None
    from urllib.parse import urlsplit
    invalid = {'url': None, 'status': 'invalid',
               'reason': 'Требуется корректный HTTP(S)-адрес без учётных данных'}
    if re.search(r'[\s\x00-\x1f\x7f\\]', url):
        return invalid
    try:
        parsed = urlsplit(url)
        port = parsed.port
        if (parsed.scheme not in ('http', 'https') or not parsed.hostname or
                parsed.username is not None or parsed.password is not None or port == 0 or
                not re.fullmatch(r'(?:\[[^\[\]]+\]|[^:\[\]@]+)(?::[0-9]+)?', parsed.netloc)):
            return invalid
    except ValueError:
        return invalid
    try:
        req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'BitrixServerMaster/' + VERSION})
        # Redirects may be followed by urllib. This probe is opt-in only.
        with urllib.request.urlopen(req, timeout=7) as resp:
            return {'url': url, 'status': 'ok', 'http_code': resp.status, 'note': 'HEAD; версия веб-PHP не подтверждается'}
    except urllib.error.HTTPError as e:
        return {'url': url, 'status': 'http_error', 'http_code': e.code, 'note': 'HEAD; сайт ответил ошибкой'}
    except (OSError, ValueError, urllib.error.URLError):
        return {'url': url, 'status': 'unavailable', 'reason': 'Нет ответа или ошибка TLS/DNS'}


def report_for(args):
    osrel = parse_os_release()
    ostype = osrel.get('ID', platform.system().lower()).lower()
    os_ver = osrel.get('VERSION_ID', '')
    pkgs, pkg_err = package_list()
    php = php_info()
    core_rpms = php_core_rpms(pkgs, php['version'], pkg_err)
    servers = web_server()
    ram = memory()
    disks = [disk('/')]
    if args.full and os.path.ismount('/home'):
        disks.append(disk('/home'))
    php_life = lifecycle('php', branch(php['version']))
    os_life = lifecycle('os', ostype + ':' + os_ver.split('.')[0])
    update = live_php(branch(php['version']), args.offline) if args.check_updates else {'status': 'not_checked'}
    alerts = []
    def alert(level, code, title, detail):
        alerts.append({'level': level, 'code': code, 'title': title, 'detail': detail})
    if os_life['status'] == 'ended':
        alert('critical', 'OS_EOL', 'Операционная система не поддерживается',
              'Срок поддержки завершился: ' + str(os_life['deadline']) + '. Рекомендуется план миграции ОС.')
    elif os_life['status'] == 'unknown':
        alert('info', 'OS_UNKNOWN', 'Статус поддержки ОС не определён', 'Проверить вручную у производителя дистрибутива.')
    if php['version'] is None:
        alert('warning', 'PHP_UNKNOWN', 'PHP CLI не найден или не отвечает', 'Проверить расположение и способы запуска PHP.')
    elif php_life['status'] == 'ended':
        alert('critical', 'PHP_EOL', 'Ветка PHP больше не поддерживается',
              'Срок поддержки: ' + str(php_life['deadline']) + '. Требуется поддерживаемая ветка PHP.')
    elif php_life['status'] == 'unknown':
        alert('info', 'PHP_SUPPORT_UNKNOWN', 'Статус поддержки PHP не определён', 'Проверить версию и сроки поддержки вручную.')
    if update['status'] == 'ok' and php['version']:
        a = tuple(map(int, php['version'].split('.')))
        b = tuple(map(int, update['version'].split('.')))
        if b > a:
            alert('warning', 'PHP_PATCH', 'Доступно обновление PHP в текущей ветке',
                  f"Установлено {php['version']}, на php.net опубликовано {update['version']}. Проверить совместимость перед обновлением.")
        elif b < a:
            alert('info', 'PHP_AHEAD', 'Локальная версия выше ответа PHP.net', 'Проверить источники и дату публикации пакета.')
    if args.check_updates and update['status'] not in ('ok', 'skipped'):
        alert('info', 'UPDATE_UNCERTAIN', 'Не удалось проверить актуальные обновления PHP',
              'Нельзя делать вывод об актуальности патч-версии без данных из сети.')
    if php['module_errors']:
        alert('critical', 'PHP_MODULE_ERRORS', 'Ошибки загрузки модулей PHP CLI',
              'Проверьте php -m / php -v, найдено: ' + str(len(php['module_errors'])))
    if servers['apache']['modules_check_error']:
        alert('info', 'APACHE_CHECK_UNKNOWN', 'Не удалось прочитать модули Apache',
              'Проверка способа подключения PHP неполная.')
    if servers['apache']['mod_php'] is True and servers['apache']['active'] == 'active':
        alert('info', 'MOD_PHP', 'Обнаружен mod_php',
              'После обновления модулей PHP нужен согласованный полный перезапуск Apache; одного reload может быть недостаточно.')
    if servers['apache']['mod_php'] is None and servers['php_fpm']['active'] != 'active':
        alert('info', 'WEB_PHP_UNCONFIRMED', 'Версия PHP через веб-сервер не установлена',
              'Диагностика не создаёт phpinfo.php и не выполняет PHP-код на сайте.')
    if disks[0] and disks[0]['available_gb'] < 6:
        alert('warning', 'LOW_DISK', 'Мало свободного места на корневом разделе',
              f"Доступно {disks[0]['available_gb']} ГБ. Для сборки может потребоваться больше места.")
    if ram.get('MemAvailable') is not None and ram['MemAvailable'] < 512:
        alert('warning', 'LOW_RAM', 'Мало доступной оперативной памяти',
              'Доступно меньше 512 МиБ; операции сборки/обновления могут быть рискованны.')
    if servers['apache_worker_limit']:
        alert('info', 'APACHE_LIMIT', 'Обнаружены ограничения MaxRequestWorkers',
              'Лимит процессов следует сравнить с реальной нагрузкой и потреблением памяти; автоматически не изменяется.')
    if core_rpms['status'] == 'ambiguous':
        found = ', '.join(p['name'] + ' ' + p['version'] + '-' + p['release']
                          for p in core_rpms['packages'] if p['name'] in core_rpms['duplicates'])
        alert('critical', 'PHP_CORE_RPM_AMBIGUOUS', 'Несколько RPM одного базового пакета PHP',
              found + '. Требуется разбор дублей и согласование пакетов на клоне.')
    elif core_rpms['status'] == 'mismatch':
        found = ', '.join(p['name'] + ' ' + p['version'] for p in core_rpms['mismatches'])
        alert('critical', 'PHP_CORE_RPM_MISMATCH', 'Базовые RPM отличаются от PHP CLI',
              'PHP CLI ' + php['version'] + '. Отличаются ' + found + '.')
    elif core_rpms['status'] == 'incomplete':
        alert('warning', 'PHP_CORE_RPM_INCOMPLETE', 'Неполный базовый комплект RPM PHP',
              'Не найдены ' + ', '.join(core_rpms['missing']) +
              '. Для профиля Apache/mod_php мастеру нужны php, php-cli и php-common.')
    if pkg_err:
        alert('info', 'PKG_UNAVAILABLE', 'Нет полной информации об RPM', pkg_err)
    if args.url and not args.offline:
        probe = url_probe(args.url)
        if probe['status'] not in ('ok',):
            alert('warning', 'WEB_HTTP_ERROR', 'Проверка сайта не завершилась успешно',
                  'Проверьте URL, HTTP-ответ и журналы веб-сервера.')
    else:
        probe = None
    alerts.sort(key=lambda x: (RISK_PRIORITIES[x['level']], x['code']))
    decision = 'uncertain'
    if any(x['level'] == 'critical' for x in alerts):
        decision = 'manual_review'
    elif core_rpms['status'] == 'incomplete':
        decision = 'uncertain'
    elif update['status'] == 'ok' and php['version']:
        installed = tuple(map(int, php['version'].split('.')))
        published = tuple(map(int, update['version'].split('.')))
        if published > installed:
            decision = 'update_available'
        elif published == installed and php_life['status'] == 'supported':
            decision = 'patch_current'
    legacy_php = bool(re.fullmatch(r'(?:[57]\.[0-9]+|8\.[01])', branch(php['version']) or ''))
    el7 = os_ver.split('.')[0] == '7' and ostype in ('centos', 'rhel', 'ol', 'oraclelinux', 'scientific')
    if core_rpms['status'] == 'ambiguous':
        next_step = ('На клоне разберите дубли базовых RPM по журналу пакетных операций и восстановите '
                     'согласованный комплект из доверенного источника. Проверьте сайт и повторите '
                     'bash install.sh --check.')
    elif core_rpms['status'] == 'mismatch':
        next_step = ('На клоне восстановите согласованный комплект php/php-cli/php-common из доверенного источника, '
                     'проверьте сайт и повторите bash install.sh --check.')
    elif core_rpms['status'] == 'incomplete':
        next_step = ('Уточните способ запуска PHP на сервере. Для обновления этим мастером нужен профиль '
                     'Apache/mod_php с пакетами php, php-cli и php-common одной версии. '
                     'Выберите способ обновления для фактического веб-PHP и проверьте его на клоне.')
    else:
        next_step = 'bash install.sh --plan' if args.full and el7 and legacy_php else None
    return {
        'schema': 'bitrix-server-master/diagnostic-v1', 'tool_version': VERSION,
        'timestamp_utc': iso_now(), 'hostname': socket.gethostname(),
        'mode': 'full' if args.full else 'quick' if args.quick else 'standard',
        'readonly': True,
        'system': {'name': osrel.get('PRETTY_NAME', platform.platform()), 'id': ostype,
                   'version': os_ver, 'arch': platform.machine(), 'kernel': platform.release(),
                   'os_lifecycle': os_life, 'root': os.geteuid() == 0 if hasattr(os, 'geteuid') else False},
        'bitrix': bitrix_info(pkgs, args.full, pkg_err), 'php': {**php, 'lifecycle': php_life},
        'web': servers, 'database': db_info(pkgs),
        'resources': {'memory_mib': ram, 'disks': [x for x in disks if x]},
        'rpm': {'installed_count': len(pkgs), 'php_packages': get_packages(pkgs, r'^php(-|$)')[:80],
                'error': pkg_err, 'core_php': core_rpms}, 'repositories': repos() if args.full else {'note': 'Подробности доступны с --full'},
        'update_check': update, 'site_probe': probe,
        'conclusion': {'code': decision, 'automated_update_permitted': False,
                       'message': conclusion_text(decision, os_life, php_life),
                       'next_step': next_step},
        'alerts': alerts,
        'limitations': ['Версия PHP в Apache/PHP-FPM не подтверждается без отдельного защищённого веб-теста.',
                        'Результат не является тестом безопасности и не заменяет резервное копирование.',
                        'Наличие HTTP 200 не доказывает исправность всех функций Битрикса.'] +
                       (['Сайты определяются в /home/bitrix/www и /home/bitrix/ext_www/* по данным файловой системы. '
                         'Активные виртуальные хосты и сайты за пределами этих путей не проверяются.',
                         'Версии ядра и модулей извлекаются из ограниченного набора файлов. Регистрация модулей в БД не проверяется.',
                         'Имена участников пула берутся из группы bitrix-hosts, роли из известных групп локального INI-инвентаря Ansible. '
                         'Доступность хостов не проверяется.']
                        if args.full else [])
    }


def conclusion_text(decision, os_life, php_life):
    if os_life['status'] == 'ended':
        return 'Нужен план миграции устаревшей ОС. Обновление одного PHP не устраняет риски системы.'
    if php_life['status'] == 'ended':
        return 'Требуется переход на поддерживаемую ветку PHP после проверки совместимости.'
    if decision == 'manual_review':
        return 'Обнаружены критические проблемы. Сначала проверьте соответствующие предупреждения.'
    if decision == 'update_available':
        return 'Найдена более новая патч-версия PHP. Обновление возможно только после проверки совместимости.'
    if decision == 'patch_current':
        return 'На момент сетевой проверки PHP.net опубликована та же патч-версия PHP; это не проверка безопасности всего сервера.'
    return 'Для заключения об актуальности PHP нужны дополнительные проверки; система автоматически не изменялась.'


def fmt_bytes_gb(gb):
    return f'{gb:.2f} ГБ' if gb is not None else 'неизвестно'


def print_human(rep):
    color = sys.stdout.isatty() and os.environ.get('TERM') != 'dumb' and not os.environ.get('NO_COLOR')

    def status(level, text, indent=' '):
        label, code = {'ok': ('[OK]', 32), 'warning': ('[ВНИМАНИЕ]', 33),
                       'critical': ('[КРИТИЧНО]', 31), 'info': ('[ИНФО]', 36)}[level]
        line = f'{label} {text}'
        if color:
            line = f'\x1b[{code}m{line}\x1b[0m'
        print(indent + line)

    print('\n' + '=' * 66)
    print(f" BITRIX SERVER MASTER {VERSION} — ДИАГНОСТИКА (ТОЛЬКО ЧТЕНИЕ)")
    print('=' * 66)

    cli_version = rep['php']['version']
    targets = dict(item.split('=', 1) for item in os.environ.get('BITRIX_MASTER_TARGETS', '').split(';') if '=' in item)
    target = targets.get(branch(cli_version), '')
    installed = tuple(map(int, cli_version.split('.'))) if cli_version else None
    pinned = tuple(map(int, target.split('.'))) if re.fullmatch(r'\d+\.\d+\.\d+', target) else None
    core_rpms = rep['rpm']['core_php']
    if rep['php']['module_errors']:
        status('critical', 'PHP CLI' + (f' {cli_version}' if cli_version else '') + ' — ошибки загрузки модулей')
    if not installed:
        status('warning', 'PHP CLI — версия не определена' + (f' (цель {target})' if pinned else ''))
    elif not pinned:
        if installed >= (8, 4, 0):
            status('warning', f'PHP CLI {cli_version} — обновление этой ветки не поддерживается; доступны только 8.2.x и 8.3.x')
        else:
            status('warning', f'PHP CLI {cli_version} — для перехода на PHP 8.2 нужен отдельный маршрут (--plan)')
    elif not rep['php']['module_errors']:
        if installed == pinned:
            level = 'info' if core_rpms['status'] in ('mismatch', 'incomplete', 'ambiguous') else 'ok'
            status(level, f'PHP CLI {cli_version} — обновление до целевой версии не требуется')
        elif installed < pinned:
            status('warning', f'PHP CLI {cli_version} — версия ниже целевой {target}')
        else:
            status('info', f'PHP CLI {cli_version} — версия выше целевой {target}')

    if core_rpms['status'] == 'ambiguous':
        found = ', '.join(p['name'] + ' ' + p['version'] + '-' + p['release']
                          for p in core_rpms['packages'] if p['name'] in core_rpms['duplicates'])
        status('critical', 'Несколько RPM одного базового пакета — ' + found + '.')
    elif core_rpms['status'] == 'mismatch':
        found = ', '.join(p['name'] + ' ' + p['version'] for p in core_rpms['mismatches'])
        status('critical', 'Базовые RPM отличаются от PHP CLI — ' + found + '.')
    elif core_rpms['status'] == 'incomplete':
        status('warning', 'Базовые RPM — не найдены ' + ', '.join(core_rpms['missing']) + '.')
    elif core_rpms['status'] == 'confirmed':
        status('ok', 'RPM php, php-cli и php-common совпадают с PHP CLI ' + cli_version + '.')
    else:
        status('warning', 'Базовые RPM PHP не подтверждены — ' + core_rpms['reason'] + '.')

    update = rep['update_check']
    published = None
    if update['status'] == 'ok':
        latest = update['version']
        published = tuple(map(int, latest.split('.')))
        if installed and published > installed:
            status('warning', f'PHP.net {latest} — опубликован более новый патч в этой ветке')
        elif published == installed:
            status('ok', f'PHP.net {latest} — версия совпадает с PHP CLI')
        else:
            status('info', f'PHP.net {latest} — опубликованная патч-версия ниже PHP CLI')
    elif update['status'] == 'skipped':
        status('info', 'PHP.net — проверка пропущена (--offline)')
    elif update['status'] == 'unavailable':
        status('warning', 'PHP.net — проверка недоступна. ' + update['reason'])
    else:
        status('info', 'PHP.net — проверка не запрошена')

    status('warning', 'PHP сайта не подтверждён. Аудит показывает версию PHP CLI.')
    system = rep['system']
    os_life = system['os_lifecycle']
    if os_life['status'] == 'ended':
        status('critical', f"ОС {system['name']} — поддержка завершилась {os_life['deadline']}")
    elif os_life['status'] == 'supported':
        status('ok', f"ОС {system['name']} — срок поддержки по справочнику до {os_life['deadline']}")
    else:
        status('warning', f"ОС {system['name']} — срок поддержки не определён")

    if core_rpms['status'] in ('mismatch', 'incomplete', 'ambiguous'):
        action = rep['conclusion']['next_step']
    elif rep['conclusion'].get('next_step'):
        action = 'посмотрите маршрут PHP командой ' + rep['conclusion']['next_step'] + '.'
    elif not installed:
        action = 'проверьте наличие и запуск PHP CLI командой php -v.'
    elif rep['php']['module_errors']:
        action = 'проверьте ошибки загрузки модулей командой php -m.'
    elif os_life['status'] == 'ended':
        action = 'запланируйте миграцию на поддерживаемую ОС.'
    elif rep['php']['lifecycle']['status'] == 'ended':
        action = 'проверьте совместимость сайта с поддерживаемой веткой PHP.'
    elif published and published > installed:
        action = 'проверьте совместимость опубликованного патча на клоне сервера.'
    elif pinned and installed < pinned:
        action = f'проверьте совместимость с PHP {target} на клоне сервера.'
    else:
        action = 'подтвердите версию PHP в веб-сервере защищённой проверкой.'
    status('info', 'Следующий шаг — ' + action)

    print('\n ПОДРОБНОСТИ')
    print(' Сервер:          ' + rep['hostname'])
    print(' Дата UTC:        ' + rep['timestamp_utc'])
    print(' Архитектура:     ' + rep['system']['arch'])
    bitrix = rep['bitrix']
    labels = {
        'confirmed': 'подтверждено по RPM', 'ambiguous': 'несколько вариантов версии',
        'file_only': 'по локальным файлам', 'unknown': 'не определено',
        'missing': 'не найдено', 'permission_denied': 'нет прав доступа',
        'unavailable': 'недоступно', 'limited': 'частичные данные',
        'present': 'найден исполняемый файл', 'not_executable': 'нет бита исполнения',
    }
    env = bitrix['environment']
    status_text = labels[env['status']]
    if env['version']:
        status_text = env['version'] + ' (' + status_text + ')'
    elif not bitrix['detected']:
        status_text = 'признаки окружения не найдены'
    print(' BitrixEnv:       ' + status_text)
    if env['packages']:
        rows = [p['name'] + ' ' + p['version'] + '-' + p['release'] for p in env['packages'][:4]]
        extra = f" (ещё {len(env['packages']) - 4})" if len(env['packages']) > 4 else ''
        print(' RPM BitrixEnv:   ' + ', '.join(rows) + extra)
    if rep['mode'] == 'full':
        sites, pool, menu = bitrix['sites'], bitrix['pool'], bitrix['menu']
        print(' Сайты:           ' + labels[sites['status']] + ' (стандартные каталоги)')
        for site in sites['items'][:8]:
            core, modules = site['core'], site['modules']
            version_text = core['version'] or labels[core['status']]
            count = len(modules['items'])
            print(f"   {site['root']} — ядро {version_text}, версий модулей {count} ({labels[modules['status']]})")
        if len(sites['items']) > 8:
            print(f"   Ещё {len(sites['items']) - 8} каталогов в JSON.")
        print(' Пул BitrixVM:    ' + labels[pool['status']])
        for host in pool['hosts'][:8]:
            print('   ' + host['name'] + ' — ' + (', '.join(host['roles']) or 'роль не указана'))
        if len(pool['hosts']) > 8:
            print(f"   Ещё {len(pool['hosts']) - 8} хостов в JSON.")
        print(' Меню BitrixVM:   ' + labels[menu['status']] + ' (' + menu['path'] + ')')
    print(' Apache:          ' + str(rep['web']['apache']['version'] or 'не определён') + ', служба ' + rep['web']['apache']['active'])
    print(' mod_php:         ' + ({True:'да', False:'нет', None:'неизвестно'}[rep['web']['apache']['mod_php']]))
    print(' PHP-FPM:         ' + rep['web']['php_fpm']['active'])
    print(' Nginx:          ' + str(rep['web']['nginx']['version'] or 'не определён') + ', служба ' + rep['web']['nginx']['active'])
    names = rep['database']['server_packages']
    print(' БД, пакеты:      ' + (', '.join(p['name']+' '+p['version'] for p in names) or 'нет данных'))
    mem = rep['resources']['memory_mib']
    print(' ОЗУ:             ' + (str(mem.get('MemTotal'))+' МиБ' if mem.get('MemTotal') else 'неизвестно'))
    print(' Доступно ОЗУ:    ' + (str(mem.get('MemAvailable'))+' МиБ' if mem.get('MemAvailable') is not None else 'неизвестно'))
    print(' Диск /:         ' + ', '.join(fmt_bytes_gb(x['available_gb'])+' доступно' for x in rep['resources']['disks'] if x['path'] == '/'))
    print('\n РЕЗУЛЬТАТЫ ПРОВЕРОК:')
    if not rep['alerts']:
        status('ok', 'Нет предупреждений в рамках выполненных проверок.', '   ')
    for a in rep['alerts']:
        status(a['level'], a['title'], '   ')
        print('     ' + a['detail'])
    print('\n Действия на сервере: никаких обновлений и перезапусков.')
    if rep['site_probe']:
        print(' Проверка URL:', rep['site_probe'])
    print('=' * 66 + '\n')


def safe_write_report(rep, path):
    if path == 'AUTO':
        name = re.sub(r'[^A-Za-z0-9_.-]', '_', rep['hostname'])[:50]
        stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
        path = f'./bitrix-audit-{name}-{stamp}.json'
    path = os.path.abspath(os.path.expanduser(path))
    # Refuse overwrite and symlink targets; use restrictive file mode from creation onward.
    old = os.umask(0o077)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(rep, fh, ensure_ascii=False, indent=2)
            fh.write('\n')
    finally:
        os.umask(old)
    return path


def reported_bitrix_version(report):
    bitrix = report.get('bitrix')
    if not isinstance(bitrix, dict):
        return None
    ver, packages = bitrix.get('version'), bitrix.get('packages')
    if 'environment' in bitrix or not isinstance(packages, list):
        return ver
    # Older reports saved RPM VERSION alone. Reuse their recorded RELEASE for comparison.
    rows = [p for p in packages if isinstance(p, dict) and p.get('name') in BITRIX_ENV_RPM_NAMES]
    if len(rows) == 1 and rows[0].get('version') == ver:
        return bitrix_rpm_version(rows[0]) or ver
    return ver


def report_text(value):
    """Report contents and filenames are data, never terminal escape sequences."""
    text = 'неизвестно' if value is None else str(value)
    return ''.join(c if c.isprintable() else repr(c)[1:-1] for c in text)[:500]


def report_status(level, text):
    label, color = {'ok': ('OK', 32), 'warning': ('ВНИМАНИЕ', 33),
                    'critical': ('КРИТИЧНО', 31), 'info': ('ИНФО', 36)}[level]
    line = '[' + label + '] ' + report_text(text)
    if sys.stdout.isatty() and os.environ.get('TERM') != 'dumb' and not os.environ.get('NO_COLOR'):
        line = f'\x1b[{color}m{line}\x1b[0m'
    print(line)


def report_date(report):
    stamp = report.get('timestamp_utc')
    if not isinstance(stamp, str) or 'T' not in stamp:
        raise ValueError('В отчёте отсутствует корректная дата диагностики.')
    try:
        value = dt.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
        if value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return value.astimezone(dt.timezone.utc)
    except (ValueError, OverflowError) as e:
        raise ValueError('В отчёте некорректная дата диагностики.') from e


def load_report(path):
    # O_NONBLOCK and fstat also cover a regular file replaced by a FIFO during discovery.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as fh:
        meta = os.fstat(fh.fileno())
        limit = 8 * 1024 * 1024
        if not stat.S_ISREG(meta.st_mode) or meta.st_size > limit:
            raise ValueError('Ожидался обычный JSON-файл размером не более 8 МиБ.')
        raw = fh.read(limit + 1)
        if len(raw) > limit:
            raise ValueError('Отчёт превышает 8 МиБ.')
    obj = json.loads(raw.decode('utf-8'))
    if not isinstance(obj, dict) or obj.get('schema') != 'bitrix-server-master/diagnostic-v1':
        raise ValueError('Нужен полный JSON-отчёт Bitrix Server Master: ' + report_text(path))
    if not isinstance(obj.get('hostname'), str) or not obj['hostname'].strip():
        raise ValueError('В отчёте отсутствует имя сервера.')
    report_date(obj)
    if obj.get('mode') not in ('quick', 'standard', 'full'):
        raise ValueError('В отчёте отсутствует режим диагностики.')
    for section, field in [('system', 'name'), ('bitrix', 'version'), ('php', 'version')]:
        data = obj.get(section)
        if not isinstance(data, dict) or field not in data or not isinstance(data[field], (str, type(None))):
            raise ValueError('В отчёте отсутствуют или повреждены данные: ' + section)
    web = obj.get('web')
    if not isinstance(web, dict):
        raise ValueError('В отчёте отсутствуют сведения о веб-сервере.')
    for name in ('apache', 'nginx'):
        data = web.get(name)
        if not isinstance(data, dict) or 'version' not in data or not isinstance(data['version'], (str, type(None))):
            raise ValueError('В отчёте отсутствуют или повреждены данные: ' + name)
    if 'active' not in web['apache'] or not isinstance(web['apache']['active'], (str, bool, type(None))):
        raise ValueError('В отчёте отсутствует состояние службы Apache.')
    alerts = obj.get('alerts')
    if not isinstance(alerts, list) or any(
            not isinstance(a, dict) or not isinstance(a.get('code'), str) or not a['code'] or
            a.get('level') not in ('info', 'warning', 'critical', 'ok') or
            not isinstance(a.get('title', ''), str) or not isinstance(a.get('detail', ''), str)
            for a in alerts):
        raise ValueError('В отчёте повреждён список предупреждений.')
    return obj


def compare_reports(paths, json_out):
    old, new = [load_report(p) for p in paths]
    if old.get('hostname') != new.get('hostname'):
        raise ValueError('Отчёты относятся к разным именам серверов. Сравнение отменено.')
    changes = []
    for label, path in [('ОС', ('system', 'name')), ('BitrixEnv', ('bitrix', 'version')),
                        ('PHP CLI', ('php', 'version')), ('Apache', ('web', 'apache', 'version')),
                        ('Nginx', ('web', 'nginx', 'version')),
                        ('Apache: служба', ('web', 'apache', 'active'))]:
        def get(obj):
            for x in path:
                obj = obj.get(x) if isinstance(obj, dict) else None
            return obj
        if path == ('bitrix', 'version'):
            a, b = reported_bitrix_version(old), reported_bitrix_version(new)
        else:
            a, b = get(old), get(new)
        if a != b:
            changes.append({'component': label, 'before': a, 'after': b})
    a_codes = {x['code'] for x in old.get('alerts', [])}
    b_codes = {x['code'] for x in new.get('alerts', [])}
    result = {'server': new['hostname'], 'before': old['timestamp_utc'],
              'after': new['timestamp_utc'], 'changes': changes,
              'resolved_alerts': sorted(a_codes-b_codes), 'new_alerts': sorted(b_codes-a_codes)}
    if json_out:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print('\nСРАВНЕНИЕ ОТЧЁТОВ:', report_text(result['server']))
        print('ДО:   ', report_text(paths[0]))
        print('ПОСЛЕ:', report_text(paths[1]))
        print('Было:', report_text(result['before']), '| Стало:', report_text(result['after']))
        scope_changed = (old.get('mode') != new.get('mode') or
                         old.get('update_check') != new.get('update_check') or
                         old.get('site_probe') != new.get('site_probe'))
        if scope_changed:
            report_status('warning', 'Условия проверки различаются (режим, проверка обновлений или сайта). '
                          'Исчезновение предупреждения само по себе не доказывает исправление.')
        if report_date(old) >= report_date(new):
            report_status('warning', 'Отчёт «после» не новее отчёта «до». Проверьте порядок файлов.')
        print('\nИзменения версий и служб:')
        if not changes:
            print('Изменений по отслеживаемым полям не найдено.')
        for x in changes:
            report_status('info', '{}: {} → {}'.format(x['component'], report_text(x['before']), report_text(x['after'])))
        old_alerts = {a['code']: a for a in old['alerts']}
        new_alerts = {a['code']: a for a in new['alerts']}
        for heading, codes, source, resolved in [
                ('Больше не отмечены в новом отчёте', a_codes - b_codes, old_alerts, True),
                ('Появились в новом отчёте', b_codes - a_codes, new_alerts, False),
                ('Остались в новом отчёте', a_codes & b_codes, new_alerts, False)]:
            print('\n' + heading + ':')
            if not codes:
                print('  нет')
            for code in sorted(codes):
                alert = source[code]
                level = ('info' if scope_changed else 'ok') if resolved else alert['level']
                report_status(level, alert.get('title') or code)
                if alert.get('detail'):
                    print('  ' + report_text(alert['detail']))
        critical = sum(a['level'] == 'critical' for a in new['alerts'])
        warnings = sum(a['level'] == 'warning' for a in new['alerts'])
        if critical or warnings:
            report_status('critical' if critical else 'warning',
                          f'В отчёте «после»: критических проблем — {critical}, предупреждений — {warnings}. '
                          'Посмотрите причины выше.')
        else:
            report_status('ok', 'В отчёте «после» нет критических проблем и предупреждений.')
        report_status('info', 'Это сравнение сохранённых данных. Текущее состояние сервера и работа сайта заново не проверялись.')
    return 0


def discover_reports(directories):
    reports, seen, skipped = [], set(), 0
    for directory in dict.fromkeys(os.path.abspath(os.path.expanduser(p)) for p in directories):
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    if not entry.name.lower().endswith('.json') or not entry.is_file(follow_symlinks=False):
                        continue
                    try:
                        meta = entry.stat(follow_symlinks=False)
                        identity = (meta.st_dev, meta.st_ino)
                        if identity in seen:
                            continue
                        seen.add(identity)
                        obj = load_report(entry.path)
                        reports.append((entry.path, obj))
                    except (OSError, ValueError, RecursionError):
                        skipped += 1
        except OSError as e:
            report_status('warning', 'Не удалось прочитать каталог: ' + directory + ' — ' + str(e))
    reports.sort(key=lambda item: (report_date(item[1]), item[0]), reverse=True)
    return reports, skipped


def report_choice(terminal, prompt, count):
    while True:
        print(prompt, end='', flush=True)
        value = terminal.readline()
        if not value:
            return None
        value = value.strip()
        if value in ('', '0'):
            return None
        if re.fullmatch(r'[1-9][0-9]{0,5}', value) and int(value) <= count:
            return int(value)
        print('Неизвестный пункт. Выберите номер из списка; Enter или 0 — назад.')


def choose_report(terminal, reports, title):
    print('\n' + title)
    for i, (path, obj) in enumerate(reports, 1):
        php = obj.get('php')
        version = php.get('version') if isinstance(php, dict) else None
        print(' {}. {} UTC | {} | PHP {}'.format(i, report_date(obj).strftime('%d.%m.%Y %H:%M:%S'),
                                               report_text(obj['hostname']), report_text(version)))
        print('    ' + report_text(path))
    answer = report_choice(terminal, 'Номер отчёта [0 — назад]: ', len(reports))
    return reports[answer - 1] if answer else None


def latest_report_pair(reports):
    pairs = {}
    for item in reports:  # Discovery is sorted newest first.
        host = item[1]['hostname']
        group = pairs.setdefault(host, [])
        if not group or (len(group) == 1 and report_date(item[1]) < report_date(group[0][1])):
            group.append(item)
    pairs = {host: group for host, group in pairs.items() if len(group) == 2}
    pair = pairs.get(socket.gethostname())
    if pair is None and len(pairs) == 1:
        pair = next(iter(pairs.values()))
    return (pair[1], pair[0]) if pair else None


def compare_menu(terminal):
    if not terminal.isatty():
        print('Для выбора отчётов нужен терминал.', file=sys.stderr)
        return 2
    directories = [os.getcwd(), os.environ.get('BITRIX_MASTER_SCRIPT_DIR', os.getcwd()), str(Path.home())]
    while True:
        print('\nСРАВНЕНИЕ СОХРАНЁННЫХ ОТЧЁТОВ — ДО И ПОСЛЕ')
        print('Поиск JSON без вложенных папок:')
        for directory in dict.fromkeys(directories):
            print('  ' + report_text(directory))
        reports, skipped = discover_reports(directories)
        print('Найдено полных отчётов:', len(reports))
        if skipped:
            report_status('warning', f'Пропущено неподходящих или повреждённых JSON: {skipped}. '
                          'Сокращённые отчёты без Python не подходят для сравнения.')
        if len(reports) < 2:
            report_status('info', 'Нужны два полных отчёта одного сервера: сохраните аудит до и после работ '
                          'через меню 1 → 3 или выберите папку с прежними отчётами.')
        pair = latest_report_pair(reports)
        print('\n 1. Сравнить два последних отчёта одного сервера' +
              (' — ' + report_text(pair[0][1]['hostname']) if pair else ' (пара пока не определена)'))
        if pair:
            for label, item in zip(('ДО', 'ПОСЛЕ'), pair):
                print('    {}: {} UTC | {}'.format(label, report_date(item[1]).strftime('%d.%m.%Y %H:%M:%S'),
                                                   report_text(os.path.basename(item[0]))))
        print(' 2. Выбрать отчёты «до» и «после» из списка')
        print(' 3. Найти отчёты в другой папке')
        print(' 0. Назад (Enter)')
        answer = report_choice(terminal, 'Выберите действие [0]: ', 3)
        if answer is None:
            return 0
        if answer == 3:
            print('Папка с отчётами (Enter — отмена): ', end='', flush=True)
            directory = terminal.readline()
            if not directory:
                return 0
            directory = directory.strip()
            if directory:
                directory = os.path.abspath(os.path.expanduser(directory))
                if os.path.isdir(directory):
                    directories = [directory]
                else:
                    report_status('warning', 'Каталог не найден: ' + directory)
            continue
        if answer == 1 and not pair:
            report_status('warning', 'Нужны два отчёта одного сервера с разными датами. '
                          'Если серверов несколько, выберите отчёты вручную пунктом 2.')
            continue
        if answer == 2:
            if not reports:
                continue
            before = choose_report(terminal, reports, 'Выберите отчёт ДО работ:')
            if before is None:
                continue
            candidates = [item for item in reports if item[1]['hostname'] == before[1]['hostname'] and
                          report_date(item[1]) > report_date(before[1])]
            if not candidates:
                report_status('warning', 'Более нового отчёта этого сервера нет. Выберите более ранний отчёт ДО '
                              'или сохраните новый аудит через меню 1 → 3.')
                continue
            after = choose_report(terminal, candidates, 'Выберите отчёт ПОСЛЕ работ (тот же сервер, более новая дата):')
            if after is None:
                continue
            pair = (before, after)
        try:
            # Re-read the chosen files: removal or replacement is a recoverable error.
            return compare_reports([item[0] for item in pair], False)
        except (OSError, ValueError, RecursionError) as e:
            report_status('critical', 'Не удалось сравнить отчёты: ' + str(e))


def parse_args(argv):
    parser = argparse.ArgumentParser(prog='bash install.sh', description='Bitrix Server Master 1.0 — русскоязычная безопасная диагностика')
    parser.add_argument('-d', '--diagnose', action='store_true', help='диагностика без изменения системы')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--quick', action='store_true', help='краткая диагностика')
    group.add_argument('--full', action='store_true', help='расширенная диагностика')
    parser.add_argument('--json', action='store_true', help='вывести JSON в stdout')
    parser.add_argument('--report', nargs='?', const='AUTO', metavar='ФАЙЛ', help='сохранить JSON-отчёт (создаёт только указанный файл)')
    parser.add_argument('--check-updates', action='store_true', help='сверить патч-версию PHP с php.net по HTTPS')
    parser.add_argument('--offline', action='store_true', help='не обращаться к сети')
    parser.add_argument('--url', metavar='URL', help='проверить HTTP-ответ указанного сайта HEAD-запросом (оставляет запись в access.log)')
    parser.add_argument('--compare', nargs=2, metavar=('СТАРЫЙ_JSON', 'НОВЫЙ_JSON'), help='сравнить два сохранённых отчёта')
    parser.add_argument('--compare-menu', action='store_true', help='выбрать сохранённые отчёты в меню')
    parser.add_argument('--version', action='version', version='Bitrix Server Master ' + VERSION)
    return parser.parse_args(argv)


def interactive():
    while True:
        print('\nBITRIX SERVER MASTER', VERSION)
        print(' 1. Диагностика сервера')
        print(' 2. Полная диагностика + проверка обновлений PHP')
        print(' 3. Полная диагностика + сохранение отчёта')
        print(' 4. Обновление PHP (показать команды)')
        print(' 0. Выход')
        try:
            answer = input('Ваш выбор: ').strip()
        except (EOFError, KeyboardInterrupt):
            print('\nВыход.'); return 0
        if answer == '0':
            return 0
        if answer == '4':
            print('План: bash install.sh --plan')
            print('Сборка на клоне: bash install.sh --build --builder')
            print('Установка готовых RPM: bash install.sh --help')
            continue
        if answer not in ('1', '2', '3'):
            print('Неизвестный пункт меню.'); continue
        sub = parse_args(['--diagnose'] + (['--full'] if answer in ('2', '3') else []) +
                         (['--check-updates'] if answer == '2' else []) +
                         (['--report'] if answer == '3' else []))
        diagnose(sub)


def diagnose(args):
    rep = report_for(args)
    if args.json:
        print(json.dumps(rep, ensure_ascii=False, indent=2))
    else:
        print_human(rep)
    if args.report:
        try:
            path = safe_write_report(rep, args.report)
            print('Отчёт сохранён:', path, file=sys.stderr if args.json else sys.stdout)
        except OSError as e:
            print('Не удалось сохранить отчёт: ' + str(e), file=sys.stderr)
            return 3
    return 0


def main():
    argv = sys.argv[1:]
    args = parse_args(argv)
    if args.compare_menu:
        with os.fdopen(os.dup(4), 'r', encoding='utf-8') as terminal:
            return compare_menu(terminal)
    if args.compare:
        try:
            return compare_reports(args.compare, args.json)
        except (OSError, ValueError, RecursionError) as e:
            print('Ошибка сравнения: ' + report_text(e), file=sys.stderr)
            return 3
    if argv or args.diagnose:
        return diagnose(args)
    if not sys.stdin.isatty():
        print('Интерактивное меню требует терминал; запускаю диагностику.')
        return diagnose(parse_args(['--diagnose']))
    return interactive()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nОперация прервана пользователем.', file=sys.stderr)
        sys.exit(130)

__PYTHON_PAYLOAD_END__
