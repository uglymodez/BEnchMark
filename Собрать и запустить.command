#!/bin/bash
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
bash "$ROOT_DIR/build.sh"
RESULT=$?
if [[ "$RESULT" -ne 0 ]]; then
    echo 'Сборка не завершилась. Причина указана выше.'
fi
if [[ -t 0 ]]; then read -r -p 'Нажми Enter, чтобы закрыть это окно…' _; fi
exit "$RESULT"
