unit Markdown4D.Viewer.Shared;

{$SCOPEDENUMS ON}

interface

uses
  System.UITypes,
  Markdown4D.Layout.Interfaces;

type
  TMarkdownViewerShared = class
  public
    class function AlphaOf(const Color: TLayoutColor): Byte;
    class function FontStylesOf(const Font: TMarkdownFontStyle): TFontStyles;
    class function TryResolveGenericFamily(const FamilyName: string; out Resolved: string): Boolean;
    // True when the family name is a monospace one: either the generic
    // 'monospace' or a concrete entry of MonospaceFamilyCandidates.  Painters
    // use it so a missing monospace family is replaced by another monospace
    // family instead of the proportional UI font.
    class function IsMonospaceFamilyName(const FamilyName: string): Boolean;
    class function IsHttpUrl(const Url: string): Boolean;
    // True when the source is resolved against the base URL or the folder the
    // document came from, so a change of either makes it name a different
    // file. A remote address or a rooted path stands on its own.
    class function IsRelativeImageSource(const Source: string): Boolean;
    class function TryResolveImageUrl(const Source, BaseUrl, DocumentFolder: string;
      out Url: string): Boolean; overload;
    class function TryResolveImageUrl(const Source, BaseUrl, DocumentFolder: string;
      const RestrictToDocumentFolder: Boolean; out Url: string): Boolean; overload;
    class function NormalizedLocalPath(const Value: string): string;
    class function IsInsideFolder(const Path, Folder: string): Boolean;
    class procedure RegisterDefaultHighlighters;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Markdown4D.Defines,
  Markdown4D.Layout.Defaults,
  Markdown4D.Highlighter.Interfaces,
  Markdown4D.Highlighter.Pascal,
  Markdown4D.Highlighter.Sql,
  Markdown4D.Highlighter.Json,
  Markdown4D.Highlighter.Xml,
  Markdown4D.Highlighter.Diff,
  Markdown4D.Math.Font;

class function TMarkdownViewerShared.AlphaOf(const Color: TLayoutColor): Byte;
begin
  Result := Color shr 24;
end;

class function TMarkdownViewerShared.FontStylesOf(const Font: TMarkdownFontStyle): TFontStyles;
begin
  Result := [];
  if Font.Bold then
    Include(Result, TFontStyle.fsBold);
  if Font.Italic then
    Include(Result, TFontStyle.fsItalic);
  if Font.Underline then
    Include(Result, TFontStyle.fsUnderline);
  if Font.Strikeout then
    Include(Result, TFontStyle.fsStrikeOut);
end;

class function TMarkdownViewerShared.TryResolveGenericFamily(const FamilyName: string; out Resolved: string): Boolean;
begin
  Result := True;

  if SameText(FamilyName, MonospaceFamilyName) then
    Resolved := MonospaceFallbackFamilyName
  else if SameText(FamilyName, SansSerifFamilyName) then
    Resolved := DefaultFallbackFamilyName
  else if SameText(FamilyName, SerifFamilyName) then
    Resolved := SerifFallbackFamilyName
  else if SameText(FamilyName, MathFamilyName) then
    Resolved := TMarkdownMathFont.ResolvedFamily
  else
  begin
    Resolved := '';
    Result := False;
  end;
end;

class function TMarkdownViewerShared.IsMonospaceFamilyName(const FamilyName: string): Boolean;
begin
  Result := SameText(FamilyName, MonospaceFamilyName);
  if Result then
    Exit;

  for var Candidate in MonospaceFamilyCandidates do
    if SameText(FamilyName, Candidate) then
      Exit(True);
end;

class function TMarkdownViewerShared.IsHttpUrl(const Url: string): Boolean;
begin
  Result := Url.StartsWith(HttpSchemePrefix, True) or Url.StartsWith(HttpsSchemePrefix, True);
end;

// The same rule TryResolveImageUrl applies when it decides whether to combine a
// source with a base: a scheme carries its own destination, and a rooted path
// is already absolute, so neither moves when the base does. An empty source
// names nothing at all.
class function TMarkdownViewerShared.IsRelativeImageSource(const Source: string): Boolean;
begin
  Result := (Source <> '') and not Source.Contains(UrlSchemeSeparator) and
    not TPath.IsPathRooted(Source);
end;

class function TMarkdownViewerShared.TryResolveImageUrl(const Source, BaseUrl, DocumentFolder: string;
  out Url: string): Boolean;
begin
  Result := TryResolveImageUrl(Source, BaseUrl, DocumentFolder, False, Url);
end;

class function TMarkdownViewerShared.TryResolveImageUrl(const Source, BaseUrl, DocumentFolder: string;
  const RestrictToDocumentFolder: Boolean; out Url: string): Boolean;
begin
  Url := Source;
  try
    if Source.Contains(UrlSchemeSeparator) then
    begin
      Result := True;
      Exit;
    end;

    if BaseUrl <> '' then
    begin
      // A base carrying a scheme names a server rather than a folder on this
      // machine, so a folder restriction has nothing to compare against.
      if BaseUrl.Contains(UrlSchemeSeparator) then
      begin
        Url := BaseUrl + Source;
        Result := True;
        Exit;
      end;

      Url := NormalizedLocalPath(TPath.Combine(BaseUrl, Source));
    end
    else
    begin
      const UsesDocumentFolder = (DocumentFolder <> '') and not TPath.IsPathRooted(Source);
      if UsesDocumentFolder then
        Url := NormalizedLocalPath(TPath.Combine(DocumentFolder, Source));
    end;

    const EscapesDocumentFolder = RestrictToDocumentFolder and (DocumentFolder <> '') and
      (not IsInsideFolder(Url, DocumentFolder));
    if EscapesDocumentFolder then
    begin
      Url := '';
      Result := False;
      Exit;
    end;

    Result := True;
  except
    on EArgumentException do
      Result := False;
    on EInOutError do
      Result := False;
  end;
end;

// Compares canonical paths, so neither "..", a doubled separator nor a differing
// case decides the outcome. The separator guard keeps "C:\docs-private" from
// counting as a child of "C:\docs".
class function TMarkdownViewerShared.IsInsideFolder(const Path, Folder: string): Boolean;
begin
  const FullPath = NormalizedLocalPath(Path);
  const Root = IncludeTrailingPathDelimiter(NormalizedLocalPath(Folder));

  Result := FullPath.StartsWith(Root, True);
end;

// Resolves the ".." segments a document can put in an image path, so callers
// compare, cache and open one canonical path instead of several spellings of
// the same file. Relative results are left alone: they carry no root to resolve
// against and would otherwise be bound to the process working directory.
class function TMarkdownViewerShared.NormalizedLocalPath(const Value: string): string;
begin
  if not TPath.IsPathRooted(Value) then
  begin
    Result := Value;
    Exit;
  end;

  Result := TPath.GetFullPath(Value);
end;

class procedure TMarkdownViewerShared.RegisterDefaultHighlighters;
begin
  var Existing: IMarkdownSyntaxHighlighter;

  if not THighlighterRegistry.TryGet(PascalLanguageName, Existing) then
    THighlighterRegistry.Register(PascalLanguageName, TPascalSyntaxHighlighter.Create);

  if not THighlighterRegistry.TryGet(SqlLanguageName, Existing) then
    THighlighterRegistry.Register(SqlLanguageName, TSqlSyntaxHighlighter.Create);

  if not THighlighterRegistry.TryGet(JsonLanguageName, Existing) then
    THighlighterRegistry.Register(JsonLanguageName, TJsonSyntaxHighlighter.Create);

  if not THighlighterRegistry.TryGet(XmlLanguageName, Existing) then
    THighlighterRegistry.Register(XmlLanguageName, TXmlSyntaxHighlighter.Create);

  if not THighlighterRegistry.TryGet(DiffLanguageName, Existing) then
    THighlighterRegistry.Register(DiffLanguageName, TDiffSyntaxHighlighter.Create);
end;

end.
