#!/usr/bin/env bash
set -euo pipefail
# Запускать только внутри одноразового контейнера, описанного в README.md.
# Метаданные RPM подменены; подписи GnuPG и проверки хешей настоящие.
installer="$(readlink -f -- "${1:?Использование: test-publisher.sh INSTALLER}")"
test -f "$installer"
root="$(mktemp -d)"
trap 'rm -rf -- "$root"' EXIT
export GNUPGHOME="$root/gnupg"
mkdir -m700 "$GNUPGHOME" "$root/bin" "$root/new" "$root/old"
cat > "$root/key" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Publisher fixture
Name-Email: publisher@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
gpg --batch --gen-key "$root/key" >/dev/null 2>&1
signer="$(gpg --with-colons --fingerprint --list-secret-keys | awk -F: '$1=="fpr"{print $10;exit}')"
export PATH="$root/bin:$PATH"
cat > "$root/bin/rpm" <<'EOF'
#!/usr/bin/env bash
for file in "$@"; do :; done
if [ "$1" = -K ]; then exit 0; fi
if [[ "$*" == *SOURCEPACKAGE* ]]; then
    if grep -q source "$file"; then echo 1; else echo '(none)'; fi
else
    head -n1 "$file"
fi
EOF
chmod +x "$root/bin/rpm"
for name in php php-cli php-common php-mbstring; do
    printf '%s|(none)|8.2.35|1.el7.custom|x86_64\n' "$name" > "$root/new/$name-8.2.35-1.el7.custom.x86_64.rpm"
    printf '%s|(none)|8.2.20|1.el7.remi|x86_64\n' "$name" > "$root/old/$name-8.2.20-1.el7.remi.x86_64.rpm"
done
run_publish() {
    bash "$installer" --prepare-release --new-rpm-dir "$root/new" --old-rpm-dir "$root/old" --signer "$signer" --output "$1"
}
run_publish "$root/dist" > "$root/out" 2>&1 || { cat "$root/out"; exit 1; }
test -s "$root/dist/release-keyring.gpg"
mkdir -m700 "$root/verify"
for name in NEW OLD; do
    gpgv --homedir "$root/verify" --keyring "$root/dist/release-keyring.gpg" "$root/dist/$name-SHA256SUMS.asc" "$root/dist/$name-SHA256SUMS"
    (cd "$root/dist"; sha256sum --status -c "$name-SHA256SUMS")
done
expected="$(printf 'php|(none)|8.2.20|1.el7.remi|x86_64\n' | sha256sum | cut -d' ' -f1)"
test -f "$root/dist/php-$expected.rpm"
test "$(find "$root/dist" -type f | wc -l)" -eq 13
printf 'PASS настоящие подписи RSA, экспорт открытого ключа, каноническое имя OLD и точный список файлов\n'
if run_publish "$root/dist" > "$root/out" 2>&1; then echo 'выходные данные перезаписаны'; exit 1; fi
grep -Fq 'Каталог выпуска уже существует.' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS существующие выходные данные отклонены\n'
cp "$root/new/php-8.2.35-1.el7.custom.x86_64.rpm" "$root/new/php-other.rpm"
if run_publish "$root/duplicate" > "$root/out" 2>&1; then echo 'принят дубликат'; exit 1; fi
test ! -e "$root/duplicate"
rm "$root/new/php-other.rpm"
grep -Fq 'Новый комплект должен содержать по одному RPM' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS повторяющийся пакет NEW отклонён, выходных данных нет\n'
mv "$root/new/php-common-8.2.35-1.el7.custom.x86_64.rpm" "$root/common"
if run_publish "$root/missing" > "$root/out" 2>&1; then echo 'принято отсутствие основного пакета'; exit 1; fi
mv "$root/common" "$root/new/php-common-8.2.35-1.el7.custom.x86_64.rpm"
grep -Fq 'В новом комплекте отсутствует php-common.' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS отсутствие обязательного пакета NEW отклонено\n'
ln -s "$root/new/php-8.2.35-1.el7.custom.x86_64.rpm" "$root/new/link.rpm"
if run_publish "$root/link" > "$root/out" 2>&1; then echo 'принята символическая ссылка'; exit 1; fi
rm "$root/new/link.rpm"
grep -Fq 'В исходном каталоге найден посторонний файл или ссылка' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS символическая ссылка на RPM отклонена\n'
printf 'source\n' >> "$root/new/php-8.2.35-1.el7.custom.x86_64.rpm"
if run_publish "$root/source" > "$root/out" 2>&1; then echo 'принят SRPM'; exit 1; fi
sed -i '$d' "$root/new/php-8.2.35-1.el7.custom.x86_64.rpm"
grep -Fq 'Нужен целый бинарный RPM' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS RPM с исходниками отклонён\n'
cp "$root/old/php-8.2.20-1.el7.remi.x86_64.rpm" "$root/old/conflict.rpm"
printf 'different payload\n' >> "$root/old/conflict.rpm"
if run_publish "$root/conflict" > "$root/out" 2>&1; then echo 'принято конфликтующее содержимое'; exit 1; fi
rm "$root/old/conflict.rpm"
grep -Fq 'Одинаковая NEVRA имеет разное содержимое' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS конфликтующий артефакт OLD отклонён\n'
if run_publish "$root/old/nested" > "$root/out" 2>&1; then echo 'принят вложенный выходной каталог'; exit 1; fi
grep -Fq 'Каталог выпуска должен находиться вне исходных каталогов RPM.' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS выходной каталог внутри входного отклонён\n'


cat > "$root/bin/gpg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--detach-sign* && "$*" == *OLD-SHA256SUMS* ]]; then echo 'fixture-second-signature-failure' >&2; exit 1; fi
exec /usr/bin/gpg "$@"
EOF
chmod +x "$root/bin/gpg"
if run_publish "$root/signfail" > "$root/out" 2>&1; then echo 'принята неудачная подпись'; exit 1; fi
test ! -e "$root/signfail"
if compgen -G "$root/.signfail.*" >/dev/null; then echo 'частичные результаты подписи сохранены'; exit 1; fi
rm "$root/bin/gpg"
grep -Fq 'fixture-second-signature-failure' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS сбой второй подписи очищает подготовленные данные и ничего не публикует\n'
printf 'private material\n' > "$root/new/private-key.txt"
if run_publish "$root/unexpected" > "$root/out" 2>&1; then echo 'приняты посторонние входные данные'; exit 1; fi
test ! -e "$root/unexpected"
rm "$root/new/private-key.txt"
grep -Fq 'В исходном каталоге найден посторонний файл или ссылка' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS посторонние входные данные отклонены\n'
saved="$signer"
signer=0000000000000000000000000000000000000000
if run_publish "$root/wrongkey" > "$root/out" 2>&1; then echo 'принят неверный ключ'; exit 1; fi
test ! -e "$root/wrongkey"
signer="$saved"
grep -Fq 'Закрытый ключ подписи не найден' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS недоступный ключ подписи отклонён\n'

# PHP 8.3 — отдельный подписанный выпуск. Старые артефакты должны оставаться в его ветке.
mkdir "$root/new83" "$root/old83"
for name in php php-cli php-common; do
    printf '%s|(none)|8.3.36|1.el7.custom|x86_64\n' "$name" > "$root/new83/$name.rpm"
    printf '%s|(none)|8.3.8|1.el7.remi|x86_64\n' "$name" > "$root/old83/$name.rpm"
done
publish83() {
    bash "$installer" --prepare-release --branch 8.3 --new-rpm-dir "$root/new83" --old-rpm-dir "$1" --signer "$signer" --output "$2"
}
publish83 "$root/old83" "$root/dist83" > "$root/out" 2>&1 || { cat "$root/out"; exit 1; }
for kind in NEW OLD; do
    gpgv --homedir "$root/verify" --keyring "$root/dist83/release-keyring.gpg" "$root/dist83/$kind-SHA256SUMS.asc" "$root/dist83/$kind-SHA256SUMS"
    (cd "$root/dist83"; sha256sum --status -c "$kind-SHA256SUMS")
done
printf 'PASS ветка 8.3 создаёт проверенные каталоги NEW и OLD\n'
if publish83 "$root/old" "$root/crossbranch" > "$root/out" 2>&1; then echo 'принят OLD другой ветки'; exit 1; fi
test ! -e "$root/crossbranch"
grep -Fq 'Неподходящий пакет для выпуска EL7 PHP 8.3' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS ветка 8.3 отклоняет архив OLD от 8.2 до публикации\n'
sed -i s/8.3.36/8.3.35/ "$root/new83/php.rpm"
if publish83 "$root/old83" "$root/wrongpatch" > "$root/out" 2>&1; then echo 'принята неверная версия исправления NEW'; exit 1; fi
test ! -e "$root/wrongpatch"
grep -Fq 'Новый комплект должен содержать по одному RPM 8.3.36' "$root/out" || { cat "$root/out"; exit 1; }
printf 'PASS ветка 8.3 требует точной целевой версии исправления в архиве NEW\n'
