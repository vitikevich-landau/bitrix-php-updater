#!/bin/bash
set -o pipefail
control_path="$1"
expected="$3"
source "$(dirname -- "${BASH_SOURCE[0]}")/fixture-common.sh" "$2"
source "$TEST_SUITE_DIR/test-curl-wrapper.sh"
UPDATER_STATE=/root/managed-probe-test/state
MANAGED_SITE='http|probe.example|80|/var/www/rc9-probe-site'
TEST_CONTROL="$control_path"
TEST_MODE=block
managed_http_check "$expected"
