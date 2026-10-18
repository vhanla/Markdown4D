#!/bin/bash
# Compile an LCL-side unit, or one of the example programs, against a ported
# build tree.
#
#   lclbuild.sh <build-tree> <source.pas> [extra fpc args...]
#
# The Core/Layout units in <build-tree> are the transformer's output (see
# porttree.py); the LCL units under Source/Lcl are hand-written Free Pascal and
# are compiled as-is, so this script only has to add the Lazarus LCL search
# paths on top of the ordinary RTL ones.
#
# The layout is discovered from the usual fpcupdeluxe install locations; set
# FPC / FPC_UNITS / LAZARUS_DIR / LCL_WIDGETSET to point somewhere else.
set -u

FPC="${FPC:-$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc}"
LAZ="${LAZARUS_DIR:-$HOME/fpcupdeluxe/lazarus}"
FPC_UNITS="${FPC_UNITS:-$HOME/fpcupdeluxe/fpc/units/x86_64-linux}"
WIDGETSET="${LCL_WIDGETSET:-gtk3}"
PLATFORM="$(basename "$FPC_UNITS")"

TREE="${1:?usage: lclbuild.sh <build-tree> <source.pas> [fpc args]}"
SRC="${2:?usage: lclbuild.sh <build-tree> <source.pas> [fpc args]}"
shift 2

OUT="${TREE}/.fpcbuild/lclout"
mkdir -p "$OUT"

# `fv` (Free Vision) ships units named `menus`, `dialogs`, `views`, ... that
# collide with LCL's own; leaving it on the path makes FPC recompile LCL units
# from the wrong source and abort.  Everything else stays, including the `gtk2`
# package: the GTK3 widgetset still pulls `glib2` and `gdk2` from it.
RTL_SKIP='/(fv)$'

FUS=""
for d in "$FPC_UNITS"/*/; do
  d="${d%/}"
  if [[ "$d" =~ $RTL_SKIP ]]; then
    continue
  fi
  FUS="$FUS -Fu$d"
done

LCLDIRS=(
  "$LAZ/lcl/units/$PLATFORM"
  "$LAZ/lcl/units/$PLATFORM/$WIDGETSET"
  "$LAZ/components/lazutils/lib/$PLATFORM"
  # FreeType (freetypelaz) backs the glyph outliner that draws SVG text.
  "$LAZ/components/freetype/lib/$PLATFORM"
)

LCLFUS=""
for d in "${LCLDIRS[@]}"; do LCLFUS="$LCLFUS -Fu$d"; done

# A program that lives outside the tree (an example project) keeps its own
# units next to itself, where FPC does not look by default.
SRCDIR="$(cd "$(dirname "$SRC")" && pwd)"

# Frameworks-neutral example units (StreamingMarkdown.Demo) sit in
# Examples/Shared, next to the example projects rather than in the ported tree.
SHARED="$(cd "$SRCDIR/../Shared" 2>/dev/null && pwd || true)"
if [ -n "$SHARED" ] && [ -d "$SHARED" ]; then
  FUS="$FUS -Fu$SHARED"
fi

exec "$FPC" -n -viwn -vn -vw -Se2000 \
  -FU"$OUT" -Fi"$OUT" \
  $FUS $LCLFUS \
  -Fu"$TREE" -Fu"$TREE/Core" -Fu"$TREE/Layout" -Fu"$TREE/Fpc" -Fu"$TREE/Lcl" \
  -Fu"$SRCDIR" \
  "$SRC" "$@"
