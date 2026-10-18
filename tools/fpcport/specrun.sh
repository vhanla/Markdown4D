#!/bin/bash
# Compile specrun.pas against a ported build tree and run the JSON spec corpora.
#
#   specrun.sh <build-tree> [<specs-dir>] [extra fpc args...]
#
# specrun.pas is a self-contained console program: it only needs the ported
# Core/Layout units plus the RTL/FCL (fpjson), so unlike lclbuild.sh it does not
# add the Lazarus search paths.  The layout is discovered from the usual
# fpcupdeluxe locations; set FPC / FPC_UNITS to point somewhere else.
set -u

FPC="${FPC:-$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc}"
FPC_UNITS="${FPC_UNITS:-$HOME/fpcupdeluxe/fpc/units/x86_64-linux}"

TREE="${1:?usage: specrun.sh <build-tree> [<specs-dir>] [fpc args]}"
shift 1
SPECS="Tests/specs"
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  SPECS="$1"
  shift 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${TREE}/.fpcbuild/specout"
mkdir -p "$OUT"

# `fv` (Free Vision) ships units that collide with the RTL's; see lclbuild.sh.
RTL_SKIP='/(fv)$'
FUS=""
for d in "$FPC_UNITS"/*/; do
  d="${d%/}"
  if [[ "$d" =~ $RTL_SKIP ]]; then
    continue
  fi
  FUS="$FUS -Fu$d"
done

"$FPC" -n -viwn -vn -vw -Se2000 \
  -FU"$OUT" -Fi"$OUT" -FE"$OUT" \
  $FUS \
  -Fu"$TREE" -Fu"$TREE/Core" -Fu"$TREE/Layout" -Fu"$TREE/Fpc" \
  "$HERE/specrun.pas" "$@" || exit 1

exec "$OUT/specrun" "$SPECS"
