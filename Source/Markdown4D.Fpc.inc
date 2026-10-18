// ============================================================================
//  Markdown4D.Fpc.inc
//  Free Pascal / Lazarus compiler contract for the neutral Core and Layout
//  units.
//
//  Include this file immediately AFTER the `unit Name;` (or `program Name;`)
//  clause and BEFORE `interface`:
//
//      unit Markdown4D.Something;
//      {$I ../Markdown4D.Fpc.inc}
//
//      interface
//      ...
//
//  Delphi is unaffected: outside FPC the include only re-states the scoped-enum
//  setting the units already carry.
// ============================================================================

{$IFDEF FPC}

  // --------------------------------------------------------------------------
  //  STRING MODEL -- the decisive setting.
  //
  //  The whole neutral codebase is written against Delphi's UTF-16 model:
  //    * `string` and `Char` are UTF-16 code units, not bytes.
  //    * `Length` and every source offset / column / caret position count
  //      UTF-16 code units.
  //    * surrogate pairs are real: Char.ConvertFromUtf32 is expected to hand
  //      back two Chars (see Markdown4D.Html.Entities.DecodeCodePoint).
  //
  //  Plain MODE DELPHI maps `string` onto AnsiString (UTF-8 on Linux, code
  //  page 0).  That silently changes the meaning of ~1,530 string declarations
  //  and every offset computation in the parser, source map, incremental
  //  parser and editor model -- with no compile error.
  //
  //  DELPHIUNICODE maps `string` onto UnicodeString and restores Delphi
  //  semantics exactly.  Verified against FPC 3.3.1:
  //    Length('a'+#$E9+'b') = 3, SizeOf(S[1]) = 2, StringCodePage(S) = 1200.
  //
  //  CONSEQUENCE -- the LCL boundary must convert explicitly.
  //  An implicit UnicodeString -> AnsiString conversion is NOT UTF-8; it
  //  truncates to Latin-1 and FPC warns "potential data loss".  A string of
  //  'a'+#$E9+'b' crosses the boundary as 61 E9 62, which GTK3/Qt will not
  //  render as intended.  Always use UTF8Encode / UTF8Decode (SysUtils) or the
  //  LazUTF8 helpers at the boundary.  Never let a UnicodeString reach an LCL
  //  API implicitly.
  // --------------------------------------------------------------------------
  {$MODE DELPHIUNICODE}
  {$H+}
  {$DEFINE MARKDOWN4D_UNICODE_STRINGS}

  // Not implied by any mode -- verified: two enums sharing a member name still
  // collide under DELPHIUNICODE unless this is set.  Most neutral units carry
  // their own directive already; this makes the include self-sufficient.
  {$SCOPEDENUMS ON}

  // --------------------------------------------------------------------------
  //  LANGUAGE FEATURES the neutral units actually use.
  //
  //  ADVANCEDRECORDS  - TInlineAtom, TLineOrigin and friends are records with
  //                     methods; several are passed by value into generics.
  //  TYPEHELPERS      - three record helpers are DECLARED by this codebase:
  //                       Markdown4D.Extensions.Alerts  TMarkdownAlertKindHelper
  //                       Markdown4D.Writer.Emphasis    TMarkdownNodeKindHelper
  //                       Markdown4D.Layout.Engine      TMarkdownFontStyleHelper
  //                     FPC only gates the DECLARATION behind this switch;
  //                     consuming RTL helpers (Char.IsLetterOrDigit,
  //                     TCharacter.IsDigit) happens to work either way.
  // --------------------------------------------------------------------------
  {$MODESWITCH ADVANCEDRECORDS}
  {$MODESWITCH TYPEHELPERS}

  // --------------------------------------------------------------------------
  //  SHORT-CIRCUIT -- the neutral units sequence side-effecting calls through
  //  `and`/`or`: a number reader chained in a condition consumes its input in
  //  argument order, and the chemistry arrow table tries its replacements
  //  longest first and stops at the first match.  DELPHI mode already defaults
  //  to this, but a host that compiles with {$B+} would evaluate every operand
  //  and both meanings would change silently, so the contract is stated here.
  // --------------------------------------------------------------------------
  {$B-}

  // --------------------------------------------------------------------------
  //  FPC has no inline declarations: `var X: T;`, `const X = ...;` and
  //  `for var I := ...` inside a statement block are a syntax error, and no
  //  mode switch enables them (verified: there is no m_inline_vars among the
  //  45 modeswitches in FPC 3.3.1; m_default_inline is unrelated).  The
  //  failure is loud rather than silent, so no guard is needed here.
  // --------------------------------------------------------------------------

{$ELSE}

  // Delphi / VCL / FMX build: semantics are already correct.
  {$SCOPEDENUMS ON}
  {$DEFINE MARKDOWN4D_UNICODE_STRINGS}

{$ENDIF}

// ----------------------------------------------------------------------------
//  Runtime-environment markers.  These replace the current implicit assumption
//  that "not FMX" means VCL, which the Vcl/Fmx units rely on.
// ----------------------------------------------------------------------------
{$IFDEF FPC}
  {$DEFINE MARKDOWN4D_FPC}
  {$IFDEF LCL}
    {$DEFINE MARKDOWN4D_LCL}
  {$ENDIF}
  {$IFDEF LINUX}
    {$DEFINE MARKDOWN4D_LINUX}
  {$ENDIF}
{$ENDIF}
{$IFDEF MSWINDOWS}
  {$DEFINE MARKDOWN4D_WINDOWS}
{$ENDIF}
{$IFDEF DARWIN}
  {$DEFINE MARKDOWN4D_MACOS}
{$ENDIF}
