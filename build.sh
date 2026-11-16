#!/usr/bin/env bash
# Compiles every plugin from scripting/*.sp into build/*.smx.
# The compiler and the include files are expected in tools/ (SourcePawn 1.12, the one that
# ships with SourceMod 1.12); see "Building" in README.md.
# Usage:  ./build.sh            - build everything
#         ./build.sh retakes    - build one plugin
# The compiler is picked automatically:
#   Linux                       - tools/spcomp
#   Windows (Git Bash/MSYS2)    - tools/spcomp64.exe, or tools/spcomp.exe if it is missing
# Override it with the SPCOMP=/path/to/spcomp environment variable.
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
    echo "!! compiler not found: $SPCOMP (see \"Building\" in README.md)" >&2
    exit 2
fi
# Absolute path: the script changes into scripting/ below.
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
    # The paths are relative (to scripting/): the Windows compiler does not understand
    # MSYS paths like /d/...
    # tr strips \r from the output of the Windows compiler.
    "$SPCOMP" -i../tools/include -iinclude "$p.sp" -o"../build/$p.smx" 2>&1 \
        | tr -d '\r' \
        | grep -v '^SourcePawn Compiler\|^Copyright (c)\|^$'
    if [ ! -f "$OUT/$p.smx" ]; then
        echo "!! $p: FAILED"
        fail=1
    fi
done
exit $fail
