#!/usr/bin/env bash
# Собирает все плагины из scripting/*.sp в build/*.smx.
# Компилятор и include-файлы лежат в tools/ (SourcePawn 1.12, тот же, что в SourceMod 1.12).
# Использование:  ./build.sh            — собрать всё
#                 ./build.sh retakes    — собрать один плагин
# Компилятор выбирается автоматически:
#   Linux                       — tools/spcomp
#   Windows (Git Bash/MSYS2)    — tools/spcomp64.exe, если нет — tools/spcomp.exe
# Переопределить можно переменной окружения SPCOMP=/путь/к/spcomp.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"

if [ -z "${SPCOMP:-}" ]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            if [ -f "$ROOT/tools/spcomp64.exe" ]; then
                SPCOMP="$ROOT/tools/spcomp64.exe"
            else
                SPCOMP="$ROOT/tools/spcomp.exe"
            fi
            ;;
        *)
            SPCOMP="$ROOT/tools/spcomp"
            ;;
    esac
fi
if [ ! -f "$SPCOMP" ]; then
    echo "!! компилятор не найден: $SPCOMP" >&2
    exit 2
fi
# Абсолютный путь: ниже делаем cd в scripting/.
SPCOMP="$(cd "$(dirname "$SPCOMP")" && pwd)/$(basename "$SPCOMP")"

mkdir -p "$OUT"

if [ $# -gt 0 ]; then
    plugins=("$@")
else
    plugins=()
    for f in "$ROOT"/scripting/*.sp; do plugins+=("$(basename "$f" .sp)"); done
fi

fail=0
cd "$ROOT/scripting"
for p in "${plugins[@]}"; do
    echo "== $p"
    rm -f "$OUT/$p.smx"
    # Пути относительные (от scripting/): Windows-компилятор не понимает MSYS-пути вида /d/...
    # tr убирает \r из вывода Windows-компилятора.
    "$SPCOMP" -i../tools/include -iinclude "$p.sp" -o"../build/$p.smx" 2>&1 \
        | tr -d '\r' \
        | grep -v '^SourcePawn Compiler\|^Copyright (c)\|^$'
    if [ ! -f "$OUT/$p.smx" ]; then
        echo "!! $p: FAILED"
        fail=1
    fi
done
exit $fail
