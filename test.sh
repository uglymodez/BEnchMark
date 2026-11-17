#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"
mkdir -p work
TEST_DIR="$(mktemp -d "$ROOT_DIR/work/test.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT
COMPILER="${CC:-cc}"
FLAGS=(-std=c11 -O3 -Wall -Wextra -Werror -ISources)
if [[ "${SANITIZE:-0}" == 1 ]]; then FLAGS+=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer); fi
"$COMPILER" "${FLAGS[@]}" Sources/benchmark.c Tests/test_core.c -lm -pthread -o "$TEST_DIR/test_core"
"$COMPILER" "${FLAGS[@]}" Tests/test_blocks.c -lm -pthread -o "$TEST_DIR/test_blocks"
"$COMPILER" "${FLAGS[@]}" Tests/test_chain.c -lm -pthread -o "$TEST_DIR/test_chain"
"$COMPILER" "${FLAGS[@]}" Sources/benchmark.c Sources/cli.c -lm -pthread -o "$TEST_DIR/memory-bench"
if [[ "$(uname -s)" == Darwin ]]; then
    "$COMPILER" "${FLAGS[@]}" -c Sources/benchmark.c -o "$TEST_DIR/benchmark.o"
    "$COMPILER" -O2 -Wall -Wextra -Werror -fobjc-arc -ISources Sources/report.m Tests/test_report.m "$TEST_DIR/benchmark.o" -framework Foundation -o "$TEST_DIR/test_report"
    for BINARY in "$TEST_DIR/test_core" "$TEST_DIR/test_blocks" "$TEST_DIR/test_chain" "$TEST_DIR/memory-bench" "$TEST_DIR/test_report"; do
        codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$BINARY"
    done
    "$TEST_DIR/test_report"
fi
"$TEST_DIR/test_core"
"$TEST_DIR/test_chain"
"$TEST_DIR/test_blocks"
python3 Tests/test_cli.py "$TEST_DIR/memory-bench"

