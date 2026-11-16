#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Сборка приложения требует macOS. Тест ядра на Linux: bash test.sh'
    exit 1
fi
if ! xcrun --find clang >/dev/null 2>&1; then
    echo 'Сначала установи инструменты Apple командой: xcode-select --install'
    echo 'После установки повтори запуск. Полный Xcode не нужен.'
    exit 1
fi
BUILD_ARCH="${ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in arm64|x86_64) ;; *) echo 'Поддерживаются arm64 и x86_64'; exit 1;; esac
SDK_DIR="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_DIR="$ROOT_DIR/build"
TEMP_DIR="$(mktemp -d "$ROOT_DIR/.build.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
APP_PATH="$BUILD_DIR/Memory Benchmark.app"
mkdir -p "$BUILD_DIR"
CC=(xcrun --sdk macosx clang -arch "$BUILD_ARCH" -isysroot "$SDK_DIR" -mmacosx-version-min=12.0 -O3 -Wall -Wextra -Werror)
echo "Собираю Memory Benchmark для ${BUILD_ARCH}..."
"${CC[@]}" -std=c11 -c Sources/benchmark.c -o "$TEMP_DIR/benchmark.o"
"${CC[@]}" -fobjc-arc -c Sources/main.m -o "$TEMP_DIR/main.o"
"${CC[@]}" -fobjc-arc -c Sources/report.m -o "$TEMP_DIR/report.o"
mkdir -p "$TEMP_DIR/Memory Benchmark.app/Contents/MacOS" "$TEMP_DIR/Memory Benchmark.app/Contents/Resources"
"${CC[@]}" "$TEMP_DIR/main.o" "$TEMP_DIR/report.o" "$TEMP_DIR/benchmark.o" -framework Cocoa -o "$TEMP_DIR/Memory Benchmark.app/Contents/MacOS/MemoryBenchmark"
cp Resources/Info.plist "$TEMP_DIR/Memory Benchmark.app/Contents/Info.plist"
cp Resources/AppIcon.icns "$TEMP_DIR/Memory Benchmark.app/Contents/Resources/AppIcon.icns"
"${CC[@]}" -std=c11 Sources/cli.c "$TEMP_DIR/benchmark.o" -o "$TEMP_DIR/memory-bench"
"${CC[@]}" -std=c11 -ISources Tests/test_core.c "$TEMP_DIR/benchmark.o" -o "$TEMP_DIR/test_core"
for BINARY in "$TEMP_DIR/memory-bench" "$TEMP_DIR/test_core"; do
    codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$BINARY"
done
codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$TEMP_DIR/Memory Benchmark.app"
codesign --verify --strict --verbose=2 "$TEMP_DIR/Memory Benchmark.app"
if [[ "$BUILD_ARCH" == "$(uname -m)" ]]; then
    echo 'Проверяю измерительное ядро на этом Mac…'
    "$TEMP_DIR/test_core"
fi
# Replace only the generated product after compilation and checks succeed.
if [[ -e "$APP_PATH" ]]; then
    BACKUP_PATH="$BUILD_DIR/Memory Benchmark.previous.$(date +%Y%m%d-%H%M%S).app"
    mv "$APP_PATH" "$BACKUP_PATH"
fi
mv "$TEMP_DIR/Memory Benchmark.app" "$APP_PATH"
cp "$TEMP_DIR/memory-bench" "$BUILD_DIR/memory-bench"
echo "Готово: $APP_PATH"
echo 'Теперь приложение можно перенести в «Программы».'
if [[ "${MB_NO_OPEN:-0}" != 1 ]]; then open "$APP_PATH"; fi

