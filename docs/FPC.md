# Markdown4D on Free Pascal / Lazarus

The library runs on Free Pascal with the LCL: the parser, AST, renderer, writer,
extensions, layout engine, theme and rasterizer are shared unchanged with the
Delphi builds, and an LCL layer replaces the VCL/FMX canvas, controls, fonts and
clipboard.

Nothing about the Delphi side changes. `Source\Core`, `Source\Layout`,
`Source\Vcl` and `Source\Fmx` keep working in Delphi, and the port is additive.

## What is where

| Path | What it is |
|------|-----------|
| `Source\Core`, `Source\Layout` | the shared sources, in Delphi dialect |
| `Source\Markdown4D.Fpc.inc` | the compiler contract every ported unit includes |
| `Source\Fpc` | RTL shims (`System.Net.*`), the compatibility unit, and the FPC include |
| `Source\Lcl` | the LCL layer: painter, viewer, editor, image decoder, FreeType glyph outliner, math font, autoscroll, register unit |
| `Source\Lcl\Examples` | runnable smoke tests for the painter, the viewer and the editor |
| `Examples\Markdown4DStudioLCL`, `Examples\StreamingMarkdownLCL` | the two demos as Lazarus projects |
| `tools\fpcport` | the transformation and build tooling |
| `build\fpc` | the generated FPC tree (**not** checked in) |
| `packages\markdown4d_lcl.lpk` | the Lazarus package (**generated**) |

## Building

```bash
tools/fpcport/makefpc.sh            # build/fpc + packages/markdown4d_lcl.lpk
```

Then either open `packages/markdown4d_lcl.lpk` in the Lazarus IDE and press
*Compile* / *Install*, or build a single unit or example from the command line:

```bash
tools/fpcport/lclbuild.sh build/fpc build/fpc/Lcl/Examples/Markdown4DLclEditor.pas
```

`lclbuild.sh` finds the compiler and the LCL from the usual fpcupdeluxe layout;
`FPC`, `FPC_UNITS`, `LAZARUS_DIR` and `LCL_WIDGETSET` override that. The port is
developed against FPC 3.3.1 and Lazarus trunk (GTK3) on x86-64 Linux; the GTK2
widgetset should work as well but is untested.

Run the examples with an X display (XWayland is fine), for instance:

```bash
build/fpc/Lcl/Examples/Markdown4DLclViewer 760    # optional scroll offset
build/fpc/Lcl/Examples/Markdown4DLclEditor       # optional caret offset
```

`Markdown4DLclRender` and `Markdown4DLclSvg` render offscreen and write a
`.png`-named BMP next to the current directory, useful without a display.

### The LCL examples

`Examples\Markdown4DStudioLCL` and `Examples\StreamingMarkdownLCL` are the
Lazarus counterparts of the VCL/FMX demos. They are self-contained projects:
open the `.lpi` in the IDE and press *Run* (F9), or build them from the command
line against a tree that `makefpc.sh` already produced:

```bash
lazbuild Examples/Markdown4DStudioLCL/Markdown4DStudioLCL.lpi
tools/fpcport/lclbuild.sh build/fpc Examples/StreamingMarkdownLCL/StreamingMarkdownLCL.lpr
```

Both `.lpi` files point at `build/fpc/{Core,Layout,Fpc,Lcl}` and put their units
in `build/fpc/.fpcbuild/lclout`, so switching between the IDE and the scripts
does not rebuild the world. `lclbuild.sh` is the scripted equivalent of the
IDE's *Build*: it is what the port's own LCL examples are built with, and it
takes extra compiler arguments (`-B`, `-gl`) after the project file.

`StreamingMarkdownLCL` reuses the framework-neutral
`Examples\Shared\StreamingMarkdown.Demo.pas` (and its `demo.md`), which is also
what the VCL and FMX samples drive. The Studio does *not* reuse the
`Examples\Shared` shell: that layer is built on VCL-only pieces (actions,
docking-style layout, the table-of-contents tree), so the LCL Studio is
hand-written against the same public components — one `TMarkdownEditor` plus one
`TMarkdownViewer` shared by every tab, with the per-document caret, scroll offset
and preview state kept in a small record per tab. The forms are built in code
rather than loaded from `.lfm` files, which keeps the projects free of binary
resources and reviewable as text.

What the Studio shows, all on the shared components:

* the live preview with native charts, mermaid diagrams and formulas (the
  demo registers `TChartBlockOverride` and `TMermaidBlockOverride` exactly like
  the VCL and FMX samples);
* `Ctrl+F` find bar with match count and highlighting, `Escape` to close;
* the view modes `Ctrl+1` (editor only), `Ctrl+2` (split) and `Ctrl+3` (preview
  only), also on the *View* menu;
* zen mode on `F11` (and *View > Zen mode*), which hides the menus and toolbar;
* a light/dark theme toggle on *View > Theme* and on the *Theme* toolbar button,
  which switches `TMarkdownViewer.ThemePreset` / `TMarkdownEditor.ThemePreset`;
* the table of contents, word/character counts, zoom and the HTML export.

### The corpus runner

`tools\fpcport\specrun.sh` compiles `tools\fpcport\specrun.pas` — a small console
program, no LCL — against a built tree and runs it over the JSON corpora in
`Tests\specs`:

```bash
tools/fpcport/specrun.sh build/fpc                 # every corpus
tools/fpcport/specrun.sh build/fpc Tests/specs     # explicit path
```

It renders each CommonMark, GFM and math example with `TMarkdown.ToUnsafeHtml`
and compares the HTML with the corpus, then checks the chart and mermaid corpora
the way the Delphi suites do (a `detected` case must expose a model through the
extension-data channel the pipeline fills while it walks the document, and the
corpus counts must match). Every corpus is reported and the exit code is
non-zero when anything failed, so it works as a gate.

### `cthreads` is required on Unix

The image downloader runs on `TTask`, which links the RTL thread pool. On Unix
that pool crashes while the units initialize unless `cthreads` is the very first
unit of the program:

```pascal
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, ...
```

## How the port is produced

`fpcport.py` rewrites one unit:

* **hoisting** — FPC has no inline `var`/`const`/`for var`. Every inline
  declaration is moved into the routine's declaration section, and loop
  variables are declared. Types cannot be inferred, so the tool guesses from the
  expression and the compiler is asked to correct the guesses.
* **namespace mapping** — `System.SysUtils` becomes `SysUtils` under FPC, and the
  compatibility unit and `{$I ../Markdown4D.Fpc.inc}` are introduced, each wrapped
  in `{$IFDEF FPC}` so the same file still compiles in Delphi.
* **call-site retargeting** — the handful of places where an RTL behaviour
  differs in a way the port cannot paper over by declaring a symbol are rewritten
  to a routine in `Source\Fpc`: `TJSONObject.ParseJSONValue(X)` becomes
  `ParseJsonOrNil(X)`, `X.AsInt64` becomes `JsonAsInt64(X)` and
  `FTagFilterRegex.Replace(X, EscapedLessThan)` becomes
  `FilterDisallowedTags(X)`. All three rewrites are unconditional, all three
  compile in Delphi too, and all three are *checked*: if a call site stops
  matching, the transformation fails loudly instead of silently leaving the RTL
  behaviour in place. See *Compiler and vcl-compat divergences* below for what
  each one repairs.

`porttree.py` runs that over the whole tree, compiles every unit in one pass and
feeds FPC's diagnostics back in, round after round, until the tree is clean. A
diagnostic such as `got "TLineOrigin" expected "LongInt"` names exactly the type
a hoisted declaration needs, so the correction is mechanical.

Those corrections are **knowledge, not build output**: they live in
`tools/fpcport/overrides.json`, checked in and keyed by unit folder and file
name rather than by the build directory (see `override_key` in `fixloop.py`).
That is what makes a build from a fresh clone deterministic — it converges in a
single round. A successful run publishes anything new it learned back into that
file.

The LCL units are **hand-written Free Pascal**, not generated, and are copied
into the tree as they are. Only their inline declarations had to be hoisted,
which `lclport.py` did once:

```bash
python3 tools/fpcport/lclport.py --tree build/fpc Source/Lcl/Markdown4D.Lcl.Editor.pas
```

`makelpkg.py` writes the Lazarus package from the tree, so the unit list cannot
drift from the sources.

### Changing a shared unit

Edit `Source\Core` or `Source\Layout` as usual, then re-run `makefpc.sh`. Two
wrinkles:

* `porttree.py` keeps pristine copies of each unit under
  `build/fpc/.fpcbuild/pristine/` and only creates them once, because
  transforming an already-transformed file would compound the rewrites. Delete
  the stale copy (`rm build/fpc/.fpcbuild/pristine/Layout/Markdown4D.Something.pas`)
  after editing a source, or delete `build/fpc` entirely.
* `Makefile`-style fixes that the transformer cannot make belong in the shared
  source when they are correct for Delphi too. Four such fixes are already in
  `Source\Layout`, all commented in place: two argument-evaluation-order claims
  in `Markdown4D.Image.Svg.Path.pas` (FPC evaluates arguments right to left), the
  miter-join loop in `Markdown4D.Image.Rasterizer.pas` (`for X in [1, -1]` is a
  *set* to FPC, so `-1` wraps to `255`), the inline anonymous record type in
  `Markdown4D.Image.Svg.Native.pas` (named now, because FPC cannot hoist a loop
  variable out of an inline record type), and the hasher result type in
  `Markdown4D.Layout.MeasureCache.pas` (`Generics.Defaults` declares `Integer` in
  Delphi and `UInt32` in FPC, so the declared spelling is guarded).

## Platform substitutions

| Delphi / VCL | LCL port |
|--------------|----------|
| `TCanvas`, `TColor`, `TFont` metrics | `TCanvas` plus a `TLazIntfImage` the painter composites through, so the premultiplied BGRA of the rasterizer keeps its per-pixel alpha |
| window style `WS_VSCROLL` + `SetScrollInfo`/`WM_VSCROLL` | `TScrollingWinControl` with its own `VertScrollBar` (`Range`/`Page`/`Position` + `UpdateScrollbars`), `AutoScroll` off so the widgetset cannot recompute the range |
| native scroll blit | the control renders its visible slice at `OriginY` and blits the buffer back at the scroll offset where the canvas itself is what the widgetset scrolls (GTK's `GtkLayout`, because its origin is the top of the content) and at 0 where it is not (Qt and Win32 keep the canvas origin at the top of the visible slice); `ScrollBy` is overridden to just invalidate |
| Win32 caret (`CreateCaret`/`SetCaretPos`) | `LCLIntf`'s caret, backed by the widgetset; `CF_UNICODETEXT` and `EClipboardException` become `Clipboard.AsText` with `UTF8Encode`/`UTF8Decode` |
| `KeyPress(var Key: Char)` | `UTF8KeyPress(var UTF8Key: TUTF8Char)`, so a whole codepoint arrives before the one-byte fallback path |
| `AddFontMemResourceEx` | the bundled OTF is unpacked to a temp file and registered with fontconfig, which is what Pango resolves through; the resource is embedded with `{$R '../Fonts/STIXTwoMath.res'}` |
| GDI glyph outliner | FreeType (lazarus `freetype` package), unhinted, with TrueType quadratics flattened at the same density |
| `ScrollBarTheme`, `TCustomStyleEngine` style hooks | dropped: the widgetset paints its own scrollbars |
| `GetSystemMetrics(SM_CXDOUBLECLK)` / `GetDoubleClickTime` | used when the platform answers, otherwise `Mouse.DragThreshold` and a 500 ms fallback |
| `WM_CAPTURECHANGED` | no reliable LCL equivalent; autoscroll stops on mouse-up and on focus loss |
| autoscroll cursors | no-ops on Linux, which has no `SetCursorPos`-style lock |

Strings stay UTF-16 code units throughout the shared code, exactly as in
Delphi; conversion happens only at the LCL boundary.

## Compiler and vcl-compat divergences

Four FPC behaviours would change the *output* rather than fail to compile, and
one fails at run time. They are all repaired in `Source\Fpc`, so `Source\Core`
and `Source\Layout` stay untouched:

| Divergence | Symptom | Fix |
|------------|---------|-----|
| No widestring manager is installed by default, so `TEncoding.UTF8.GetBytes`/`UTF8Encode` degrade to one byte per UTF-16 code unit | every non-ASCII link destination is percent-encoded wrong (`/f%F6%F6` instead of `/f%C3%B6%C3%B6`); the CommonMark corpus catches two examples | `Markdown4D.Fpc.Compat` links `fpwidestring`, the pure-Pascal manager Lazarus itself uses, next to `fpmonitor` |
| `TStringHelper.ToLower`/`ToUpper` (and the `...Invariant` pair) are built on `SysUtils.LowerCase`/`UpperCase`, which only know ASCII | Greek and sharp-S link labels stop matching their references (two more corpus examples) | `Markdown4D.Fpc.CompatImpl` declares a string helper that *derives* from the RTL's and replaces only those four methods, mapping through the manager's Unicode tables |
| vcl-compat's `TJSONParser.Parse` returns an **unassigned** result for invalid JSON unless the `RaiseExc` option is set | `TJSONObject.ParseJSONValue` hands back a garbage pointer where Delphi returns `nil`, and `Root.Free` then crashes | `Markdown4D.Fpc.Json.ParseJsonOrNil` parses with `RaiseExc` and turns the exception into `nil`; the transformer retargets the call sites |
| vcl-compat's `TJSONNumber.GetAsInt64` parses the number's text with the **32-bit** `StrToInt` wherever `Char` is one byte | a value above `High(Integer)` cannot be read back, and every opaque ARGB color is one: scaling the theme — what a zoom step does, through `SaveToJson`/`LoadFromJson` — dies with `"4280230696" is an invalid integer` | `Markdown4D.Fpc.Json.JsonAsInt64` reads the number's own text with `StrToInt64`; the transformer retargets the `AsInt64` reads |
| FPC's regex engine (bare `regexpr`, behind vcl-compat's `System.RegularExpressions`) does not honour a bare lookahead, so the GFM tag-filter pattern consumes the tag it should only inspect | `<xmp> is disallowed.  <XMP> is...` collapses to `&lt;x&lt;XMP> is...`; the GFM corpus catches it | `Markdown4D.Fpc.Compat.FilterDisallowedTags` performs the same scan without a regex; the transformer retargets the call site |

The first two are invisible in the LCL apps, which get a manager from the
widgetset; they bite console programs and any host that does not install one,
which is why they had to be fixed in the library.

## Known differences

* **Offscreen capture.** `TWinControl.PaintTo` is a no-op on GTK3, so the viewer
  cannot be rendered into a bitmap. The painter can: `Markdown4DLclRender`
  drives `TMarkdownLclPainter` over an offscreen `TBitmap` and writes the
  result. The editor's own `PaintTo(Bitmap)` calls its render path directly and
  is unaffected.
* **BMP, not PNG.** `TBitmap.SaveToFile` writes a BMP whatever the extension
  says, so the examples' `.png` files are BMPs. They are smoke tests, not
  publishing tools.
* **Scrollbar look.** The port does not theme scrollbars; the editor and viewer
  use the widgetset's own.
* **`cthreads`.** See above; omitting it crashes at startup rather than at first
  use.

## What has been verified

* the ported tree compiles clean from a fresh clone (108 units, one round) and
  the Lazarus package compiles and installs (72k lines, no errors);
* the corpus runner passes all **770** cases — 652 CommonMark 0.31.2 examples,
  24 GFM 0.29 examples, 35 math examples, 31 chart cases and 28 mermaid cases —
  with zero failures;
* the two LCL demos build with both `lazbuild` and `lclbuild.sh` and run: the
  streaming window parses and repaints as text arrives, and the Studio renders
  the shared `demo.md` with charts, mermaid flowcharts and sequence diagrams
  laid out natively, with a clean status line;
* the Studio's interactions were exercised on the running LCL build:
  `Ctrl+F` reports the match count and highlights, `Escape` closes the find bar,
  `Ctrl+1`/`Ctrl+2`/`Ctrl+3` switch the view modes, `F11` toggles zen mode both
  ways, *View > Theme* switches to the dark theme (the status line follows) and
  Help > About opens;
* offscreen rendering of a document with headings, lists, tables, quotes, code,
  an SVG image, a chart and inline/display formulas matches the Delphi output;
* the viewer renders and scrolls, including the native SVG image;
* the editor renders with line numbers, fold markers, syntax and match
  highlighting, wraps, scrolls by wheel and by the native scrollbar, keeps the
  caret visible, types (including Tab indent and Ctrl+Z), copies and pastes
  through the clipboard, middle-click autoscrolls, and drives the linked preview
  pane both ways;
* the bundled math font registers through fontconfig and is used for formulas.
