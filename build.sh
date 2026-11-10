#!/usr/bin/env bash
# Собирает все плагины из scripting/*.sp в build/*.smx.
# Компилятор и include-файлы лежат в tools/ (SourcePawn 1.12, тот же, что в SourceMod 1.12).
# Использование:  ./build.sh            — собрать всё
#                 ./build.sh retakes    — собрать один плагин
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SPCOMP="${SPCOMP:-$ROOT/tools/spcomp}"
OUT="$ROOT/build"
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
    "$SPCOMP" -i"$ROOT/tools/include" -i"$ROOT/scripting/include" "$p.sp" -o"$OUT/$p.smx" \
        | grep -v '^SourcePawn Compiler\|^Copyright (c)\|^$'
    if [ ! -f "$OUT/$p.smx" ]; then
        echo "!! $p: FAILED"
        fail=1
    fi
done
exit $fail
