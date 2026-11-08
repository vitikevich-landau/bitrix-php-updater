#!/usr/bin/env bash
# Compile the actual three FFI directive comparisons against EL7 glibc headers.
set -o pipefail
[[ $# == 2 ]] || exit 2
sourcefile="$1"
output="$2"
comparisons=$(grep -E 'strncmp\(.*"(#define|FFI_SCOPE|FFI_LIB)"' "$sourcefile") || exit
[[ $(printf '%s\n' "$comparisons" | wc -l) == 3 ]] || exit 1
{
    printf '#include <string.h>\n#define ZEND_STRL(s) (s), (sizeof(s) - 1)\n'
    printf 'int main(void) { const char *code_pos = "#define FFI_SCOPE", *p = code_pos;\n'
    printf '%s\n' "$comparisons" | sed -e 's/^[[:space:]}]*\(else \)\?if (/    /' -e 's/) {$/;/'
    printf 'return 0; }\n'
} > "$output.c"
gcc -O2 -Werror=implicit-function-declaration -c "$output.c" -o "$output.o"
