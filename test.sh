#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"
mkdir -p work
TEST_DIR="$(mktemp -d "$ROOT_DIR/work/test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
cc -std=c11 -O3 -Wall -Wextra -Werror -ISources Sources/benchmark.c Tests/test_core.c -lm -pthread -o "$TEST_DIR/test_core"
if [[ "$(uname -s)" == Darwin ]]; then
    codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$TEST_DIR/test_core"
fi
"$TEST_DIR/test_core"
