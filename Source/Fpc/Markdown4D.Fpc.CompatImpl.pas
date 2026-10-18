unit Markdown4D.Fpc.CompatImpl;

// ============================================================================
//  Free Pascal compatibility layer, implementation-clause edition.
//
//  `Markdown4D.Fpc.Compat` is injected into every ported unit's *interface*
//  `uses` clause.  The implementation clause, however, is searched before the
//  interface one, so a unit listed there shadows the RTL units the
//  implementation itself pulls in (`System.Hash` for THashBobJenkins,
//  `System.UIConsts` for GetAlphaColorValues).  This unit is that second
//  injection point.
//
//  It deliberately re-exports only the *non-generic* shadows from Compat.
//  Re-declaring the generic `TFunc`/`TProc`/`TPredicate` here would give the
//  interface and the implementation two distinct instantiations of the same
//  generic type name, and any method whose interface signature mentions one
//  would no longer match its implementation header.  The generics are left to
//  Compat and stay visible through the `uses` below.
//
//  A unit may not appear in both clauses, which is why this has to be a
//  separate unit rather than a second listing of Compat.
// ============================================================================

{$I ../Markdown4D.Fpc.inc}

interface

{$IFDEF FPC}

uses
  SysUtils,
  Markdown4D.Fpc.Compat;

type
  // Non-generic shadows that mirror their Compat declarations.  They are
  // re-stated here (rather than only inherited through `uses`) so they are
  // direct declarations of the implementation clause and therefore win over
  // the RTL's differently-built versions.
  TStringBuilder = TUnicodeStringBuilder;
  TMarkdownFpcStringProc = Markdown4D.Fpc.Compat.TMarkdownFpcStringProc;
  THashBobJenkins = Markdown4D.Fpc.Compat.THashBobJenkins;

  // Unicode case mapping.
  //
  // FPC's TStringHelper.ToLower/ToUpper (and their ...Invariant twins) are
  // built on SysUtils.LowerCase/UpperCase, which know only ASCII.  Delphi's
  // cover the whole Unicode range, and the neutral code relies on that: the
  // CommonMark link-reference folding has to match a Greek `[A-G-W]`
  // definition against its lowercase reference, and the capital sharp S
  // against a plain `SS` definition.  With FPC's own methods those
  // references silently stop resolving.
  //
  // The helper DERIVES from the RTL's, so every other string method
  // (Replace, Trim, Split, Contains, ...) is still the RTL's own; only the
  // four case methods change, and they go through the widestring manager's
  // Unicode tables, exactly like WideUpperCase/WideLowerCase do.
  TMarkdownFpcStringHelper = type helper(TUnicodeStringHelper) for UnicodeString
    function ToLower: UnicodeString;
    function ToUpper: UnicodeString;
    function ToLowerInvariant: UnicodeString;
    function ToUpperInvariant: UnicodeString;
  end;

procedure GetAlphaColorValues(Proc: TMarkdownFpcStringProc);

{$ENDIF}

implementation

{$IFDEF FPC}

procedure GetAlphaColorValues(Proc: TMarkdownFpcStringProc);
begin
  Markdown4D.Fpc.Compat.GetAlphaColorValues(Proc);
end;

// The widestring manager performs the mapping; the WideString round-trip is
// what reaches its Unicode tables through the RTL's public entry points.
function MappedUnicodeCase(const Value: UnicodeString;
  const Upper: Boolean): UnicodeString;
var
  Wide: WideString;
begin
  Wide := Value;
  if Upper then
    Result := WideUpperCase(Wide)
  else
    Result := WideLowerCase(Wide);
end;

function TMarkdownFpcStringHelper.ToLower: UnicodeString;
begin
  Result := MappedUnicodeCase(Self, False);
end;

function TMarkdownFpcStringHelper.ToUpper: UnicodeString;
begin
  Result := MappedUnicodeCase(Self, True);
end;

function TMarkdownFpcStringHelper.ToLowerInvariant: UnicodeString;
begin
  Result := MappedUnicodeCase(Self, False);
end;

function TMarkdownFpcStringHelper.ToUpperInvariant: UnicodeString;
begin
  Result := MappedUnicodeCase(Self, True);
end;

{$ENDIF}

end.
