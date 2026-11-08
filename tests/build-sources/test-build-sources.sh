#!/usr/bin/env bash
# Публичная регрессионная проверка: без скачивания, установки и закрытых ключей.
# Использование: BITRIX_TEST_DISPOSABLE=1 bash test-build-sources.sh INSTALLER SRPM82 SRPM83 OUTPUT
# Требуется изолированный контейнер CentOS 7 x86_64 с rpm-build, cpio, GnuPG и xz.
# OUTPUT должен быть доступен для записи, а установщик и SRPM — смонтированы только для чтения.
set -o pipefail
umask 077
export LC_ALL=C
if [[ ${BITRIX_TEST_DISPOSABLE:-} != 1 || ! -f /.dockerenv ]]; then
    echo 'Отказ: запускайте в одноразовом контейнере Docker с BITRIX_TEST_DISPOSABLE=1.' >&2
    exit 2
fi
[[ $# == 4 ]] || { echo 'Использование: test-build-sources.sh INSTALLER SRPM82 SRPM83 OUTPUT' >&2; exit 2; }
installer=$(readlink -f -- "$1") || exit
srpm82=$(readlink -f -- "$2") || exit
srpm83=$(readlink -f -- "$3") || exit
mkdir -p -- "$4" || exit
output=$(readlink -f -- "$4") || exit
[[ -f $installer && -f $srpm82 && -f $srpm83 ]] || exit 2
# Загружаем все определения полного установщика, останавливаясь перед его CLI.
awk '/^# Мутирующие операции:/ {exit} {print}' "$installer" > "$output/library.sh" || exit
source "$output/library.sh"
platform_check || exit
WORK_ROOT="$output/work"
mkdir -p -- "$WORK_ROOT" || exit
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
declare -F set_php_target >/dev/null || fail 'в установщике отсутствует выбор ветки'

# Выявляемый сбой: жёстко заданные php82.spec, имя патча, хеш исходников или ключ подписи GPG.
for branch in 8.2 8.3; do
    if [[ $branch == 8.2 ]]; then version=8.2.35; spec=php82.spec; srpm="$srpm82"; else version=8.3.36; spec=php83.spec; srpm="$srpm83"; fi
    set_php_target "$branch" || fail "не удалось выбрать ветку $branch"
    target="$output/source-$branch"
    source_prepare "$target" "$srpm" > "$output/source-$branch.log" 2>&1 || fail "ошибка настоящего source_prepare для ветки $branch (см. source-$branch.log)"
    [[ -f "$target/topdir" ]] || fail "ветка $branch: этап %prep не завершён"
    [[ $(cat "$target/topdir") == "$target/rpmbuild" ]] || fail "ветка $branch: неверный каталог topdir"
    [[ -s "$target/rpmbuild/SOURCES/php-$version-openssl102-asn1.patch" ]] || fail "ветка $branch: отсутствует файл патча"
    grep -q 'Совместимость с OpenSSL 1.0.2 (EL7)' "$target/rpmbuild/BUILD/php-$version/ext/openssl/xp_ssl.c" || fail "ветка $branch: настоящий этап %prep не применил патч"
    [[ $(rpm -q --qf '%{VERSION}|%{RELEASE}' --specfile "$target/rpmbuild/SPECS/$spec" | head -c 16) == "$version|1.el7.1"* ]] || fail "ветка $branch: неожиданные версия или номер выпуска в спецификации"
    rpm -q --requires --specfile "$target/rpmbuild/SPECS/$spec" > "$target/runtime-requires.txt" || fail "ветка $branch: ошибка запроса к спецификации"
    if [[ $branch == 8.3 ]]; then
        rpmspec -q --buildrequires "$target/rpmbuild/SPECS/$spec" > "$target/build-requires.txt" || fail "ветка $branch: ошибка запроса зависимостей сборки"
        grep -Fx 'unixODBC-devel' "$target/build-requires.txt" >/dev/null || fail 'ветка 8.3: отсутствует зависимость unixODBC для EL7'
        ! grep -Fx 'pkgconfig(odbc)' "$target/build-requires.txt" >/dev/null || fail 'ветка 8.3: сохранена зависимость odbc.pc, недоступная в EL7'
        bash "$(dirname "$0")/check-ffi-el7.sh" "$target/rpmbuild/BUILD/php-$version/ext/ffi/ffi.c" "$target/ffi-compile-proof" > "$target/ffi-compile-proof.log" 2>&1 || fail 'ветка 8.3: сравнения директив FFI не компилируются с glibc из EL7'
    fi
    pass "ветка $branch: настоящее извлечение SRPM, SHA-256, GPG, патч совместимости и %prep"
done

# Выявляемый сбой: доверие любой успешной подписи или проверка только подключа 8.3
# без закреплённого основного ключа. Подмена сначала запускает настоящий GPG, затем заменяет
# поле подписанта на неразрешённое; закрытый ключ и подделка криптографии не используются.
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
    if source_prepare "$target" "$srpm" > "$target.log" 2>&1; then fail "$test_case: принято недопустимое поле GPG"; fi
    [[ ! -f "$target/topdir" && ! -f "$target/prep.log" ]] || fail "$test_case: выполнение дошло до этапа %prep"
    grep -q 'Неожиданный ключ подписи PHP' "$target.log" || fail "$test_case: отказ произошёл по посторонней причине"
    pass "$test_case: недопустимый ключ GPG отклонён до этапа %prep"
done
unset -f gpg

# Выявляемый сбой: распаковка до полной проверки доверия SRPM.
cp -- "$srpm83" "$output/corrupt.src.rpm" || exit
printf 'corruption' >> "$output/corrupt.src.rpm"
set_php_target 8.3 || exit
if source_prepare "$output/corrupt" "$output/corrupt.src.rpm" > "$output/corrupt.log" 2>&1; then fail 'повреждённый SRPM принят'; fi
[[ ! -e "$output/corrupt/source-entries.txt" ]] || fail 'содержимое повреждённого SRPM было просмотрено'
[[ -z $(find "$output/corrupt/rpmbuild/SOURCES" -mindepth 1 -print -quit) ]] || fail 'повреждённый SRPM распакован'
pass 'повреждённый SRPM отклонён до просмотра содержимого или распаковки'

# Выявляемый сбой: выбранная ветка ошибочно принимает SRPM другой ветки.
for branch in 8.2 8.3; do
    set_php_target "$branch" || exit
    if [[ $branch == 8.2 ]]; then srpm="$srpm83"; else srpm="$srpm82"; fi
    if source_prepare "$output/wrong-$branch" "$srpm" > "$output/wrong-$branch.log" 2>&1; then fail "для ветки $branch принят SRPM другой ветки"; fi
    [[ ! -e "$output/wrong-$branch/source-entries.txt" ]] || fail "для ветки $branch просмотрено содержимое SRPM другой ветки"
    pass "ветка $branch: SRPM другой ветки отклонён до распаковки"
done
printf 'Регрессионные проверки исходников завершены. Результаты: %s\n' "$output"
