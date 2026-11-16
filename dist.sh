#!/usr/bin/env bash
# Пересобирает плагины и архивы в build/dist/:
#   retakes-css-server.zip — то, что распаковывается в папку cstrike/ сервера;
#   retakes-css-source.zip — исходники (git archive HEAD);
#   css-port.patch, patches/ — отличия от исходного коммита splewis (без tools/).
# Файлы берутся из коммита HEAD (кроме .smx из build/), поэтому запускать после коммита:
# незакоммиченные правки в архивы не попадут.
# Нужен 7z или zip.
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/build/dist"
BASE=9aae157
cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
    echo "!! есть незакоммиченные изменения: в архивы попадёт только HEAD" >&2
fi

./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
git archive HEAD | tar -x -C "$STAGE"

S="$STAGE/server"
SM="$S/addons/sourcemod"
mkdir -p "$SM/plugins/disabled" "$SM/scripting/include" "$SM/configs" "$S/cfg"
# retakes_allocator — основной аллокатор (решение владельца); остальные лежат в disabled/,
# потому что одновременно должен работать только один аллокатор.
# retakes_autoplant лежит в plugins/, но выключен кваром sm_retakes_autoplant_enabled 0
# (решение владельца). retakes_autodefuse — так же: в plugins/, выключен кваром
# sm_retakes_autodefuse_enabled 0.
# retakes_bothelper лежит в plugins/ и включён (sm_retakes_bothelper_enabled 1): принят
# владельцем после теста на 32-битном сервере Windows. Ему нужен файл из gamedata/.
cp build/retakes.smx build/warmup.smx build/retakes_allocator.smx \
   build/retakes_autoplant.smx build/retakes_autodefuse.smx \
   build/retakes_bothelper.smx "$SM/plugins/"
cp build/retakes_standardallocator.smx build/retakes_pistolallocator.smx \
   build/retakes_sitepicker.smx "$SM/plugins/disabled/"
cp -r "$STAGE/gamedata" "$SM/gamedata"
cp -r "$STAGE/translations" "$SM/translations"
cp -r "$STAGE/configs/retakes" "$SM/configs/retakes"
cp -r "$STAGE/cfg/sourcemod" "$S/cfg/sourcemod"
cp "$STAGE/scripting/include/retakes.inc" "$STAGE/scripting/include/warmup.inc" \
   "$SM/scripting/include/"
cp "$STAGE/README.md" "$S/README_retakes.md"
cp "$STAGE/LICENSE" "$S/LICENSE_retakes"

mkdir -p "$DIST"
rm -rf "$DIST/retakes-css-server.zip" "$DIST/retakes-css-source.zip" \
       "$DIST/css-port.patch" "$DIST/patches"

# Имя архива относительное: 7z для Windows не понимает MSYS-пути вида /d/...
(
    cd "$S"
    if command -v 7z >/dev/null 2>&1; then
        7z a -tzip -bso0 -bsp0 server.zip ./*
    else
        zip -q -r server.zip .
    fi
)
mv "$S/server.zip" "$DIST/retakes-css-server.zip"

git archive --format=zip -o "$DIST/retakes-css-source.zip" HEAD
git diff --binary "$BASE" HEAD -- . ':!tools' > "$DIST/css-port.patch"
git format-patch -q -o "$DIST/patches" "$BASE..HEAD" -- . ':!tools'

echo "== build/dist ($(git rev-parse --short HEAD))"
ls -l "$DIST"
