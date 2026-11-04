#!/bin/bash
# Checks that release tags map to Debian versions apt orders correctly.
set -euo pipefail

cd "$(dirname "$0")/.."
map=.github/scripts/deb-version.sh
fail=0

expect_version() {
    local got
    got="$("$map" "$1")"
    if [[ "$got" != "$2" ]]; then
        echo "FAIL: $1 maps to $got, want $2"
        fail=1
    fi
}

expect_older() {
    if ! dpkg --compare-versions "$("$map" "$1")" lt "$("$map" "$2")"; then
        echo "FAIL: $1 should be older than $2"
        fail=1
    fi
}

expect_rejected() {
    if "$map" "$1" >/dev/null 2>&1; then
        echo "FAIL: $1 should be rejected"
        fail=1
    fi
}

expect_version 1.2.0 1.2.0
expect_version 1.2.0-beta.3 1.2.0~beta.3
expect_version 0.0.0-ci.42 0.0.0~ci.42

expect_older 1.0.0-beta.1 1.0.0
expect_older 1.0.0-beta.9 1.0.0-beta.10
expect_older 1.0.0 1.0.1-beta.1
expect_older 1.0.9 1.0.10

expect_rejected v1.2.0
expect_rejected 1.2
expect_rejected "1.2.0-beta.1;id"

if [[ $fail -ne 0 ]]; then
    exit 1
fi
echo "versions: ok"
