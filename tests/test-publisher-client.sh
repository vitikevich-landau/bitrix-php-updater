#!/usr/bin/env bash
set -eo pipefail
# Запускать только внутри одноразового контейнера, описанного в README.md.
# Метаданные RPM, сайт и конечная транзакция установки подменены.
# Подписи издателя, проверка каталогов и выбор пакетов настоящие.
installer="$(readlink -f -- "${1:?Использование: test-publisher-client.sh INSTALLER}")"
test -f "$installer"
grep -q '^# Мутирующие операции:' "$installer"
source <(sed '/^# Мутирующие операции:/,$d' "$installer")
case_root="$(mktemp -d /root/auto-test.XXXXXXXX)"
trap 'rm -rf -- "$case_root"' EXIT
cd "$case_root"
mkdir -m 700 signing work new-input old-input
export GNUPGHOME="$case_root/signing"
gpg --batch --gen-key <<'KEY' >/dev/null 2>&1
Key-Type: RSA
Key-Length: 2048
Name-Real: Isolated Fixture
Name-Email: fixture@invalid.test
Expire-Date: 0
%no-protection
%commit
KEY
gpg --export > keyring.gpg
chmod 600 keyring.gpg
UPDATER_STATE="$case_root/state"
WORK_ROOT="$UPDATER_STATE/work"
test_branch="${2:-8.2}"
case "$test_branch" in
    8.2) initial_version=8.2.20 target_version=8.2.35 ;;
    8.3) initial_version=8.3.8 target_version=8.3.36 ;;
    *) echo 'Поддерживаются только тестовые ветки 8.2 и 8.3'; exit 2 ;;
esac
set_php_target "$test_branch"
old_version="$initial_version"
rpm() {
    local file
    for file in "$@"; do :; done
    case "$1" in
      -qp)
        if [[ "$*" == *SOURCEPACKAGE* ]]; then printf '(none)'; else cat -- "$file"; fi ;;
      -K) return 0 ;;
      *) echo "Неожиданный вызов RPM $*" >&2; return 99 ;;
    esac
}
export -f rpm
for name in php php-cli php-common; do
    record="$name|(none)|$old_version|1.el7|x86_64"
    printf '%s\n' "$record" >> installed
    printf '%s\n' "$record" > "old-input/$name-$old_version-1.el7.x86_64.rpm"
    printf '%s\n' "$name|(none)|$target_version|1.el7|x86_64" > "new-input/$name-$target_version-1.el7.x86_64.rpm"
done
sort -o installed installed
signer="$(gpg --with-colons --fingerprint --list-secret-keys | awk -F: '$1=="fpr"{print $10; exit}')"
bash "$installer" --prepare-release --branch "$test_branch" --new-rpm-dir "$case_root/new-input" --old-rpm-dir "$case_root/old-input" --signer "$signer" --output "$case_root/source"
cmp -s keyring.gpg source/release-keyring.gpg
printf 'PASS клиент использует настоящие каталоги издателя\n'
cp installed initial
printf 'SOURCE=%s/source\nKEYRING=%s/keyring.gpg\nHEALTH_URL=https://fixture.test/health.php\n' "$case_root" "$case_root" > client.conf
chmod 600 client.conf
php() { printf '%s' "$old_version"; }
httpd() { return 0; }
systemctl() { return 0; }
profile_check() { PHP_CURRENT="$old_version"; select_php_target_for_version "$PHP_CURRENT"; }
inventory_php_rpms() { cat "$case_root/installed"; }
http_check() { [ "${WEB_FAIL:-0}" = 0 ]; }
check_disk() { return 0; }
rpm() {
    case "$1" in
      -qp)
        if [[ "$*" == *SOURCEPACKAGE* ]]; then printf '(none)'; else cat -- "${@: -1}"; fi ;;
      -K) return 0 ;;
      *) echo "Неожиданный вызов RPM $*" >&2; return 99 ;;
    esac
}
run_update() {
    if [ "$old_version" = "$TARGET_PHP" ]; then
        printf 'already-current\n' > "$case_root/result"
        return 0
    fi
    [ "$5" = 1 ] && [ -f "$6" ] && cmp -s "$6" "$case_root/installed" || return 99
    local result_root
    result_root="$(mktemp -d "$case_root/update.XXXX")"
    stage_rpm_bundle "$3" "$result_root/old" "$4" &&
    select_rpms "$result_root/old" old "$6" &&
    stage_rpm_bundle "$1" "$result_root/new" "$4" &&
    select_rpms "$result_root/new" new "$6" || return
    printf 'updated\n' > "$case_root/result"
}
expect_failure() {
    local label="$1"; shift
    rm -f "$case_root/result"
    if ( "$@" ) > "$case_root/out" 2>&1; then cat "$case_root/out"; echo "FAIL принято: $label"; exit 1; fi
    [ ! -e "$case_root/result" ] || { echo "FAIL выполнено обновление: $label"; exit 1; }
    local expected=''
    case "$label" in
      unsigned_extra) expected='Посторонний файл в каталоге RPM:' ;;
      absent_required_selected_rpm) expected='Не найден подходящий RPM для php-common (old).' ;;
      missing_backup_flag|missing_unattended) expected='--unattended и --backup-verified нужны вместе.' ;;
      unknown_flag) expected='Параметр --execute недопустим для --auto-update.' ;;
      config_argument) expected='Укажите путь после --config.' ;;
      noninteractive) expected='Для подтверждения установки нужен терминал.' ;;
      writable_config) expected='Нужна конфигурация автоматического обновления в защищённом файле root.' ;;
      duplicate_or_executable_config) expected='В конфигурации есть повтор, пустое значение или управляющий символ.' ;;
      invalid_signature) expected='Не подтверждена подпись каталога RPM доверенным ключом.' ;;
      missing_exact_old) expected='Не удалось получить файл комплекта' ;;
      corrupted_old) expected='Контрольная сумма прежнего RPM не совпала:' ;;
      bad_web_baseline) expected='Исходный веб-PHP не прошёл проверку.' ;;
      signed_unsafe_name) expected='Недопустимая строка в SHA256SUMS.' ;;
      partial_download) expected='fixture-partial-download' ;;
      missing_required_new_module) expected='Не найден подходящий RPM для php-mbstring (new).' ;;
      wrong_new_branch) expected='Не найден подходящий RPM для php (new).' ;;
      *) echo "FAIL неизвестный отрицательный сценарий: $label"; exit 1 ;;
    esac
    grep -Fq -- "$expected" "$case_root/out" || { cat "$case_root/out"; echo "FAIL неверная причина отказа: $label"; exit 1; }
    printf 'PASS отклонено: %s\n' "$label"
}
auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
[ "$(cat result)" = updated ]
printf 'PASS локальная автоматическая подготовка и передача управления существующему установщику\n'

# Подпись OLD покрывает общий архив серверов, а этому узлу нужны только три строки.
extra="php-gd|(none)|$initial_version|1.el7|x86_64"
extra_hash="$(printf '%s\n' "$extra" | sha256sum)"
extra_name="php-gd-${extra_hash%% *}.rpm"
printf '%s\n' "$extra" > "source/$extra_name"
(cd source && sha256sum "$extra_name" >> OLD-SHA256SUMS && gpg --batch --yes --armor --detach-sign --output OLD-SHA256SUMS.asc OLD-SHA256SUMS)
auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
[ "$(cat result)" = updated ]
printf 'PASS отсутствующий посторонний файл подписанного архива OLD\n'
mkdir bundle
cp source/OLD-SHA256SUMS bundle/SHA256SUMS
cp source/OLD-SHA256SUMS.asc bundle/SHA256SUMS.asc
for name in php php-cli php-common; do
    cp source/"$name"-????????????????????????????????????????????????????????????????.rpm bundle/
done
printf unsigned > bundle/unsigned.rpm
expect_failure unsigned_extra stage_rpm_bundle "$case_root/bundle" "$case_root/reject-extra" "$case_root/keyring.gpg"
rm bundle/unsigned.rpm
first="$(find bundle -name 'php-common-*.rpm')"
rm "$first"
stage_rpm_bundle "$case_root/bundle" "$case_root/incomplete-staged" "$case_root/keyring.gpg"
expect_failure absent_required_selected_rpm select_rpms "$case_root/incomplete-staged" old "$case_root/initial"
expect_failure missing_backup_flag auto_update_dispatch --config "$case_root/client.conf" --unattended
expect_failure missing_unattended auto_update_dispatch --config "$case_root/client.conf" --backup-verified
expect_failure unknown_flag auto_update_dispatch --execute
expect_failure config_argument auto_update_dispatch --config
expect_failure noninteractive auto_update_dispatch --config "$case_root/client.conf"
chmod 666 client.conf
expect_failure writable_config auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
chmod 600 client.conf
cp client.conf good.conf
printf 'SOURCE=$(touch %s/injected)\n' "$case_root" >> client.conf
expect_failure duplicate_or_executable_config auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
[ ! -e injected ]
cp good.conf client.conf
cp source/OLD-SHA256SUMS.asc old.sig
printf 'bad\n' > source/OLD-SHA256SUMS.asc
expect_failure invalid_signature auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
cp old.sig source/OLD-SHA256SUMS.asc
old_file="$(sed -n '1s/^.*  //p' source/OLD-SHA256SUMS)"
mv "source/$old_file" missing.rpm
expect_failure missing_exact_old auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
mv missing.rpm "source/$old_file"
cp "source/$old_file" clean.rpm
printf 'corruption\n' >> "source/$old_file"
expect_failure corrupted_old auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
cp clean.rpm "source/$old_file"
WEB_FAIL=1 expect_failure bad_web_baseline auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
cp source/NEW-SHA256SUMS new.manifest
printf '%064d  ../escape.rpm\n' 0 >> source/NEW-SHA256SUMS
gpg --batch --yes --armor --detach-sign --output source/NEW-SHA256SUMS.asc source/NEW-SHA256SUMS
expect_failure signed_unsafe_name auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
cp new.manifest source/NEW-SHA256SUMS
gpg --batch --yes --armor --detach-sign --output source/NEW-SHA256SUMS.asc source/NEW-SHA256SUMS
sed "s@^SOURCE=.*@SOURCE=https://release.invalid/tag@" good.conf > client.conf
chmod 600 client.conf
safe_download() {
    if [ -e "$case_root/fail-download" ] && [[ "$1" == *.rpm ]]; then
        echo fixture-partial-download >&2
        printf partial > "$2.part"
        return 30
    fi
    cp -- "$case_root/source/${1##*/}" "$2"
}
touch fail-download
expect_failure partial_download auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
rm fail-download
auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
[ "$(cat result)" = updated ]
printf 'PASS новая попытка HTTPS после частичного скачивания\n'
cp good.conf client.conf
old_version="$target_version"
rm -f keyring.gpg
auto_update_dispatch --config "$case_root/client.conf"
[ "$(cat result)" = already-current ]
printf 'PASS проверка работоспособности целевой версии не требует артефактов\n'


old_version="$initial_version"
cp source/release-keyring.gpg keyring.gpg
chmod 600 keyring.gpg
required="php-mbstring|(none)|$initial_version|1.el7|x86_64"
required_hash="$(printf '%s\n' "$required" | sha256sum)"
required_name="php-mbstring-${required_hash%% *}.rpm"
printf '%s\n' "$required" >> installed
sort -o installed installed
printf '%s\n' "$required" > "source/$required_name"
(cd source && sha256sum "$required_name" >> OLD-SHA256SUMS &&
    gpg --batch --yes --armor --detach-sign --output OLD-SHA256SUMS.asc OLD-SHA256SUMS)
expect_failure missing_required_new_module auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
grep -Fq 'Не найден подходящий RPM для php-mbstring (new).' "$case_root/out"
printf 'PASS отсутствие обязательного модуля NEW блокирует установку после точной подготовки OLD\n'

# Сторонний источник обрабатывается буквально, и даже подписанные RPM другой ветки не могут
# попасть в обновление. Переподписываем временным тестовым ключом этой проверки.
cp initial installed
if [ "$test_branch" = 8.3 ]; then wrong_version=8.2.35; else wrong_version=8.3.36; fi
sed -i "s/$target_version/$wrong_version/" source/php-"$target_version"-1.el7.x86_64.rpm
(cd source && sha256sum php-"$target_version"-1.el7.x86_64.rpm php-cli-"$target_version"-1.el7.x86_64.rpm php-common-"$target_version"-1.el7.x86_64.rpm > NEW-SHA256SUMS &&
    gpg --batch --yes --armor --detach-sign --output NEW-SHA256SUMS.asc NEW-SHA256SUMS)
expect_failure wrong_new_branch auto_update_dispatch --config "$case_root/client.conf" --unattended --backup-verified
printf 'PASS подписанный сторонний выпуск не может изменить ветку PHP\n'
