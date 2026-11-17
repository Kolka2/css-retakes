#!/usr/bin/env bash
# Rebuilds the plugins and the archives in build/dist/:
#   retakes-css-server.zip - what gets unpacked into the cstrike/ folder of a server;
#   retakes-css-source.zip - the sources (git archive HEAD);
#   css-port.patch, patches/ - the differences from the base commit of splewis.
# The files are taken from the HEAD commit (except the .smx from build/), so run it after
# a commit: uncommitted changes do not get into the archives.
# Needs 7z or zip.
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/build/dist"
BASE=9aae157
cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
    echo "!! there are uncommitted changes: the archives only get HEAD" >&2
fi

./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
git archive HEAD | tar -x -C "$STAGE"

S="$STAGE/server"
SM="$S/addons/sourcemod"
mkdir -p "$SM/plugins/disabled" "$SM/scripting/include" "$SM/configs" "$S/cfg"
# retakes_allocator is the main allocator; the other ones go to disabled/, because only
# one allocator may run at a time.
# retakes_autoplant and retakes_autodefuse are in plugins/, but switched off by their
# cvars (sm_retakes_autoplant_enabled 0, sm_retakes_autodefuse_enabled 0).
# retakes_bothelper is in plugins/ and switched on (sm_retakes_bothelper_enabled 1); it
# was tested on a 32-bit Windows server and needs its file from gamedata/.
# The warmup plugin (warmup.smx) lives in the css-plugins repository and is not packed here.
cp build/retakes.smx build/retakes_allocator.smx \
   build/retakes_autoplant.smx build/retakes_autodefuse.smx \
   build/retakes_bothelper.smx "$SM/plugins/"
cp build/retakes_standardallocator.smx build/retakes_pistolallocator.smx \
   build/retakes_sitepicker.smx "$SM/plugins/disabled/"
cp -r "$STAGE/gamedata" "$SM/gamedata"
cp -r "$STAGE/translations" "$SM/translations"
cp -r "$STAGE/configs/retakes" "$SM/configs/retakes"
cp -r "$STAGE/cfg/sourcemod" "$S/cfg/sourcemod"
cp "$STAGE/scripting/include/retakes.inc" "$SM/scripting/include/"
cp "$STAGE/README.md" "$S/README_retakes.md"
cp "$STAGE/README.ru.md" "$S/README_retakes.ru.md"
cp "$STAGE/LICENSE" "$S/LICENSE_retakes"

mkdir -p "$DIST"
rm -rf "$DIST/retakes-css-server.zip" "$DIST/retakes-css-source.zip" \
       "$DIST/css-port.patch" "$DIST/patches"

# The archive name is relative: 7z for Windows does not understand MSYS paths like /d/...
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
