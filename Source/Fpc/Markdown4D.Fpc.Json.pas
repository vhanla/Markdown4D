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
// ============================================================================

{$I ../Markdown4D.Fpc.inc}

interface

{$IFDEF FPC}

uses
  System.JSON;

// Nil when the text is not JSON, never a dangling pointer: the parser is asked
// to raise so a parse failure cannot masquerade as an uninitialised result.
function ParseJsonOrNil(const Text: string): TJSONValue;

{$ENDIF}

implementation

{$IFDEF FPC}

function ParseJsonOrNil(const Text: string): TJSONValue;
begin
  Result := nil;
  try
    Result := TJSONObject.ParseJSONValue(Text, False, True);
  except
    Result := nil;
  end;
end;

{$ENDIF}

end.
