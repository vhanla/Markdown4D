unit Markdown4D.Fpc.Json;

// ============================================================================
//  Free Pascal compatibility layer for System.JSON.
//
//  vcl-compat's TJSONParser.Parse catches the scanner's exception and, unless
//  the caller set the RaiseExc option, lets the routine return without ever
//  assigning the function result.  The pointer that reaches the caller is
//  whatever the stack slot happened to hold -- not nil -- so the neutral
//  `if not (Root is TJSONObject) then Root.Free` faults.  Delphi's
//  TJSONObject.ParseJSONValue returns nil in the same situation.
//
//  This unit restores that contract.  The port rewrites the neutral call sites
//  (`TJSONObject.ParseJSONValue(Text)` in the chart extension and the theme
//  reader) into `ParseJsonOrNil(Text)`, and appends this unit to their
//  implementation `uses` clause.
//
//  vcl-compat's TJSONNumber.GetAsInt64 reads the number's text with the 32-bit
//  StrToInt wherever Char is one byte, so any value above High(Integer) raises
//  EConvertError where Delphi's 64-bit AsInt64 reads it.  An ARGB color with an
//  opaque alpha is exactly such a value, and the theme writes every color as
//  one (`TJSONNumber.Create(Int64(Color))`), so reloading a saved theme -- which
//  is what a zoom step does, through `TMarkdownTheme.Scaled` -- failed.  The
//  port retargets the `AsInt64` reads at `JsonAsInt64`.
// ============================================================================

{$I ../Markdown4D.Fpc.inc}

interface

{$IFDEF FPC}

uses
  System.JSON;

// Nil when the text is not JSON, never a dangling pointer: the parser is asked
// to raise so a parse failure cannot masquerade as an uninitialised result.
function ParseJsonOrNil(const Text: string): TJSONValue;

// The number's own text, read at full width: vcl-compat's `AsInt64` goes
// through the 32-bit StrToInt on platforms where Char is one byte.
function JsonAsInt64(const Number: TJSONNumber): Int64;

{$ENDIF}

implementation

{$IFDEF FPC}

uses
  SysUtils;

function ParseJsonOrNil(const Text: string): TJSONValue;
begin
  Result := nil;
  try
    Result := TJSONObject.ParseJSONValue(Text, False, True);
  except
    Result := nil;
  end;
end;

function JsonAsInt64(const Number: TJSONNumber): Int64;
begin
  Result := StrToInt64(Number.Value);
end;

{$ENDIF}

end.
