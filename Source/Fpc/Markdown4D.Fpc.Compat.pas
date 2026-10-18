unit Markdown4D.Fpc.Compat;

// ============================================================================
//  Free Pascal compatibility layer for the neutral Markdown4D units.
//
//  The neutral code (Source/Core, Source/Layout) is written against the Delphi
//  10.3+ RTL.  A handful of that RTL's declarations have no FPC counterpart, or
//  have a counterpart whose compiled-in string model differs from the one the
//  neutral code assumes.  This unit supplies the missing or corrected pieces.
//
//  It is only pulled in by the FPC port (Source/Fpc of the build tree); the
//  Delphi build is unaffected.  The port appends `Markdown4D.Fpc.Compat` to the
//  interface `uses` clause of every neutral unit, last, so that anything it
//  declares shadows the RTL's version (a later unit in a `uses` clause has
//  precedence).
//
//  Contents:
//    * TStringBuilder  - see below.
//    * TFunc / TProc / TPredicate - generics the Delphi RTL declares in
//      System.SysUtils but FPC does not have at all.
//    * GetAlphaColorValues - the RTL's callback takes an AnsiString because the
//      RTL itself is built with the one-byte string model; the neutral code
//      passes a UnicodeString callback.
// ============================================================================

{$I ../Markdown4D.Fpc.inc}

interface

{$IFDEF FPC}

uses
  SysUtils;

type
  // FPC's SysUtils.CHAR is one byte at the time the RTL is compiled, so its
  // `TStringBuilder = TUnicodeStringBuilder` alias is frozen to the ANSI
  // builder no matter what string model the consumer selects.  Re-exporting the
  // alias here, in a unit compiled under DELPHIUNICODE, restores Delphi's
  // semantics: `TStringBuilder` is the Unicode builder, so `Append(char)`,
  // `ToString` and `Trim(array of Char)` all carry the two-byte model the
  // neutral code expects.
  TStringBuilder = TUnicodeStringBuilder;

  // Delphi declares these in System.SysUtils; FPC has no equivalent at all.
  // The parameter is passed by value rather than as `const` because the neutral
  // lambdas are written `function(Index: Integer): Double`, and FPC requires the
  // modifiers to match exactly when an anonymous method is assigned to a method
  // reference.
  TFunc<TResult> = reference to function: TResult;
  TFunc<T1, TResult> = reference to function(Arg1: T1): TResult;
  TFunc<T1, T2, TResult> = reference to function(Arg1: T1; Arg2: T2): TResult;
  TProc = reference to procedure;
  TProc<T1> = reference to procedure(Arg1: T1);
  TProc<T1, T2> = reference to procedure(Arg1: T1; Arg2: T2);
  TPredicate<T> = reference to function(Arg: T): Boolean;

  // System.UIConsts.GetAlphaColorValues takes TGetStrProc, whose AnsiString
  // parameter is fixed by the RTL build, while the neutral callback works in
  // UnicodeString.  This mirror takes the Unicode form.
  TMarkdownFpcStringProc = procedure(const S: string) of object;

  // FPC's System.Hash.THashBobJenkins.GetHashValue takes its data as `var`, so
  // hashing a read-only field (`Key.Font.Size` where `Key` is `const`) is a
  // compile error.  Delphi's takes `const` (or a pointer).  Re-declaring the
  // record with the Delphi signatures and forwarding to the RTL through its
  // pointer overload restores the neutral code unchanged.
  THashBobJenkins = record
    class function GetHashValue(const aData: string): Integer; overload; static;
    class function GetHashValue(const aData; aLength, aInitialValue: Integer): Integer; overload; static;
  end;

// Enumerate the RTL's web colour table through a UnicodeString callback.
procedure GetAlphaColorValues(Proc: TMarkdownFpcStringProc);

// Delphi's `System.MemoryBarrier` is a compiler intrinsic FPC does not declare.
// FPC has the narrower `ReadWriteBarrier`, which is the closest equivalent for
// the publish/consume pattern the neutral code uses it for.
procedure MemoryBarrier;

// GFM's tag filter escapes the `<` that opens a disallowed HTML tag (title,
// textarea, style, xmp, iframe, noembed, noframes, script, plaintext).  The
// neutral source states it as one regex with a lookahead, which consumes
// nothing:
//
//   <(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|plaintext)[\s/>])
//
// FPC's regex engine (bare `regexpr`, the engine behind vcl-compat's
// System.RegularExpressions) does not honour that lookahead: it consumes the
// tag it was only meant to inspect, so
// `<xmp> is disallowed.  <XMP> is also disallowed.` comes out as
// `&lt;x&lt;XMP> is also disallowed.`  This scanning routine produces the
// regex's output without one, so the ported call site behaves the same.
function FilterDisallowedTags(const Literal: string): string;

{$ENDIF}

implementation

{$IFDEF FPC}

uses
  System.UIConsts,
  System.Hash,
  // FPC's TMonitor dispatches through System's monitor-manager function table,
  // which stays nil until a unit registers an implementation.  `fpmonitor`
  // (rtl-objpas) does that in its initialization; without it, TMonitor.Enter
  // calls a nil pointer and the whole parser crashes.  Linking it here means
  // every consumer of the port inherits working monitors.
  //
  // `fpwidestring` is linked for the same reason.  Delphi's RTL always knows
  // how to move between UnicodeString and the ANSI/UTF-8 forms; FPC's does
  // that through a "widestring manager" a program has to install, and without
  // one TEncoding.UTF8.GetBytes - and every UTF8Encode - degrades to one byte
  // per UTF-16 code unit.  That silently corrupts every non-ASCII string that
  // crosses the boundary, the percent-encoded link destinations of
  // Markdown4D.Text.Unescape.NormalizeUri among them.  fpwidestring is the
  // pure-Pascal manager Lazarus itself uses.
  fpmonitor,
  fpwidestring;

class function THashBobJenkins.GetHashValue(const aData: string): Integer;
begin
  Result := System.Hash.THashBobJenkins.GetHashValue(aData);
end;

class function THashBobJenkins.GetHashValue(const aData;
  aLength, aInitialValue: Integer): Integer;
begin
  Result := System.Hash.THashBobJenkins.GetHashValue(
    PByte(@aData), aLength, aInitialValue);
end;

type
  // The RTL's callback is an `of object` method pointer, so the adapter that
  // receives its AnsiString must be a method rather than a plain procedure.
  TAlphaColorSink = class
    procedure Sink(const S: AnsiString);
  end;

var
  GAlphaColorProc: TMarkdownFpcStringProc;
  GAlphaColorSink: TAlphaColorSink;

procedure TAlphaColorSink.Sink(const S: AnsiString);
begin
  if Assigned(GAlphaColorProc) then
    GAlphaColorProc(UnicodeString(S));
end;

procedure GetAlphaColorValues(Proc: TMarkdownFpcStringProc);
begin
  GAlphaColorProc := Proc;
  System.UIConsts.GetAlphaColorValues(GAlphaColorSink.Sink);
end;

procedure MemoryBarrier;
begin
  ReadWriteBarrier;
end;

// `\s` in the pattern above is the .NET whitespace class, which reaches past
// ASCII: the ASCII controls NEL is grouped with, plus the Unicode separator
// categories.  The scanner has to accept the same set, or an exotic input would
// be filtered on Delphi and left alone here.
function IsWhitespaceChar(const Ch: Char): Boolean;
begin
  case Ch of
    ' ', #9, #10, #11, #12, #13, #$0085, #$00A0, #$1680, #$2000..#$200A,
    #$2028, #$2029, #$202F, #$205F, #$3000:
      Result := True;
  else
    Result := False;
  end;
end;

function FilterDisallowedTags(const Literal: string): string;
const
  DisallowedTags: array[0..8] of string = (
    'title', 'textarea', 'style', 'xmp', 'iframe', 'noembed', 'noframes',
    'script', 'plaintext');
var
  Builder: TStringBuilder;
  Index: Integer;
  TagStart: Integer;
  AfterTag: Integer;
  Tag: Integer;
  TagName: string;
  IsDisallowed: Boolean;
begin
  Builder := TStringBuilder.Create;
  try
    Index := 1;
    while Index <= Length(Literal) do
    begin
      IsDisallowed := False;

      if Literal[Index] = '<' then
      begin
        TagStart := Index + 1;
        if (TagStart <= Length(Literal)) and (Literal[TagStart] = '/') then
          Inc(TagStart);

        for Tag := Low(DisallowedTags) to High(DisallowedTags) do
        begin
          TagName := DisallowedTags[Tag];
          AfterTag := TagStart + Length(TagName);

          if (AfterTag - 1 > Length(Literal))
            or not SameText(Copy(Literal, TagStart, Length(TagName)), TagName) then
            Continue;

          // The tag name stands alone only when a boundary follows it; the
          // pattern's trailing class is what keeps `<titles>` out.
          if (AfterTag > Length(Literal))
            or IsWhitespaceChar(Literal[AfterTag])
            or (Literal[AfterTag] = '/')
            or (Literal[AfterTag] = '>') then
          begin
            IsDisallowed := True;
            Break;
          end;
        end;
      end;

      if IsDisallowed then
      begin
        Builder.Append('&lt;');
        Inc(Index);
      end
      else
      begin
        Builder.Append(Literal[Index]);
        Inc(Index);
      end;
    end;

    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

initialization
  GAlphaColorSink := TAlphaColorSink.Create;

finalization
  GAlphaColorSink.Free;

{$ENDIF}

end.
