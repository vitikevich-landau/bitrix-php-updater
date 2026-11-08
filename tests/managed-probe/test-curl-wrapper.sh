# Только тестовые сбои транспорта вокруг настоящей реализации curl/Apache.
curl() {
    local config='' next=0 arg url='' count token path code original
    for arg in "$@"; do
        [ "$next" -eq 0 ] || { config="$arg"; next=0; }
        [ "$arg" != --config ] || next=1
        url="$arg"
    done
    printf '%s\n' "$*" >> "$TEST_CONTROL/argv"
    count="$(cat "$TEST_CONTROL/count" 2>/dev/null || echo 0)"; count=$((count + 1))
    printf '%s\n' "$count" > "$TEST_CONTROL/count"
    path="/var/www/rc9-probe-site/${url#*://*/}"
    if [ -n "$config" ]; then
        token="$(sed -n 's/^header = "X-Bitrix-Master-Probe: \([a-f0-9]*\)"$/\1/p' "$config")"
        [[ "$token" =~ ^[a-f0-9]{64}$ ]] || return 99
        if env | grep -Fxq "token=$token"; then touch "$TEST_CONTROL/secret-in-env"; return 99; fi
        if grep -Fq -- "$token" "$path" || [[ "$*" == *"$token"* ]]; then
            touch "$TEST_CONTROL/secret-leaked"; return 99
        fi
        printf 'header = "X-Bitrix-Master-Probe: %064d"\n' 0 > "$TEST_CONTROL/wrong.conf"
        code="$(command curl -q --silent --show-error --noproxy '*' --resolve probe.example:80:127.0.0.1 --config "$TEST_CONTROL/wrong.conf" --write-out '%{http_code}' -- "$url")" || return 99
        [ "$code" = 404 ] || { touch "$TEST_CONTROL/wrong-token-accepted"; return 99; }
        code="$(command curl -q --silent --show-error --noproxy '*' --resolve probe.example:80:127.0.0.1 --header 'X-Forwarded-For: 127.0.0.1' --write-out '%{http_code}' -- "$url")" || return 99
        [ "$code" = 404 ] || { touch "$TEST_CONTROL/xff-accepted"; return 99; }
        touch "$TEST_CONTROL/auth-inspected"
    fi
    case "${TEST_MODE:-normal}" in
        timeout) return 28 ;;
        block) touch "$TEST_CONTROL/blocking"; sleep 30 ;;
        parent_rename)
            mv /var/www/rc9-probe-site /var/www/rc9-probe-site-renamed-by-test
            mkdir /var/www/rc9-probe-site
            printf 'replacement site\n' > /var/www/rc9-probe-site/replacement
            return 28
            ;;
        static) cat -- "$path"; printf '\n200\n127.0.0.1\n80\n'; return 0 ;;
        cache)
            if [ "$count" -eq 2 ]; then command curl "$@" | tee "$TEST_CONTROL/cached"; return "${PIPESTATUS[0]}"; fi
            if [ "$count" -eq 3 ]; then cat "$TEST_CONTROL/cached"; return 0; fi
            ;;
        redirect)
            if [ -n "$config" ]; then printf '\n302\n127.0.0.1\n80\n'; return 0; fi ;;
        wrong_body)
            if [ -n "$config" ]; then printf 'a different site\n\n200\n127.0.0.1\n80\n'; return 0; fi ;;
        cleanup_failure)
            if [ "$count" -eq 3 ]; then
                command curl "$@"
                printf '\n// изменено извне\n' >> "$path"
                return 0
            fi
            ;;
    esac
    command curl "$@"
}
