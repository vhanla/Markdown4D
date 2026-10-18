#!/bin/bash
# Generate the Free Pascal source tree, and the Lazarus package that wraps it,
# from the Delphi sources.  Nothing here is checked in: `build/fpc` is produced
# on demand and `packages/markdown4d_lcl.lpk` is rewritten to match it.
#
#   makefpc.sh [output-tree]
#
#   build/fpc/            the ported units, laid out like Source/
#     Core/ Layout/       transformed from the Delphi sources
#     Fpc/                RTL shims
#     Lcl/                the hand-written LCL viewer/editor layer
#     Fonts/              the bundled formula font
#
# Environment overrides: FPC, FPC_UNITS (see porttree.py --rtl), ROUNDS.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$ROOT/build/fpc}"
ROUNDS="${ROUNDS:-8}"

if [ -z "${FPC:-}" ] && [ -x "$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc" ]; then
  FPC="$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc"
fi

ARGS=(--src "$ROOT/Source" --out "$OUT" --rounds "$ROUNDS")
if [ -n "${FPC:-}" ]; then
  ARGS+=(--fpc "$FPC")
fi
if [ -n "${FPC_UNITS:-}" ]; then
  ARGS+=(--rtl "$FPC_UNITS")
fi

python3 "$HERE/porttree.py" "${ARGS[@]}"
python3 "$HERE/makelpkg.py" --tree "$OUT" --out "$ROOT/packages/markdown4d_lcl.lpk"

echo
echo "LCL units and examples can now be built with:"
echo "  $HERE/lclbuild.sh $OUT $OUT/Lcl/Examples/Markdown4DLclViewer.pas"
