unit Markdown4D.Lcl.Glyphs;

{$I ../Markdown4D.Fpc.inc}

// ============================================================================
//  Markdown4D.Lcl.Glyphs
//
//  FPC/LCL counterpart of Markdown4D.Image.Glyphs.Gdi.  It reads glyph outlines
//  from the fonts installed on the machine and hands them to the neutral SVG
//  engine as plain contours, so an SVG that draws text as paths works without a
//  system text API.
//
//  Where the Windows unit asks GDI for GGO_NATIVE outlines, this one asks
//  fontconfig for the file of the requested family and then reads the curves
//  through FreeType (Lazarus' freetypelaz).  Both produce the same thing: closed
//  contours in pixels at the requested size, laid out left to right from the
//  baseline origin, with Y pointing down the page.
//
//  The unit registers itself; the viewer's SVG renderer picks it up through
//  TMarkdownGlyphSupport.
// ============================================================================

interface

procedure RegisterLclGlyphOutliner;

implementation

uses
  DynLibs,
  SysUtils,
  Classes,
  ctypes,
  Generics.Collections,
  LazFreeType,
  TTTypes,
  EasyLazFreeType,
  libfontconfig,
  Markdown4D.Layout.Interfaces,
  Markdown4D.Image.Glyphs;

type
  // Turns a run of text into contours by reading each glyph's outline from the
  // font file fontconfig picks for the family.
  TLclGlyphOutliner = class
  private
    const
      // Points along a quadratic curve segment; the same density the Windows
      // outliner uses, so both platforms agree on how round a letter looks.
      CurveSegments = 6;
      // FreeType writes outline coordinates in 26.6 fixed point.
      FixedScale = 64.0;
    class var FFiles: TDictionary<string, string>;
    class var FFonts: TDictionary<string, TFreeTypeFont>;
    class var FFontConfigReady: Boolean;
    class procedure EnsureFontConfig;
    class function ResolveFontFile(const FamilyName: string; const Bold, Italic: Boolean): string;
    class function AcquireFont(const FamilyName: string; const PixelSize: Single;
      const Bold, Italic: Boolean): TFreeTypeFont;
    class function NextCodePoint(const Text: string; var Index: Integer): Integer;
    class function AppendGlyph(const Font: TFreeTypeFont; const CodePoint: Integer;
      const Pen: Single; var Contours: TArray<TArray<TLayoutPointF>>; out Advance: Single): Boolean;
    class procedure AppendOutline(const Outline: TT_Outline; const Pen: Single;
      var Contours: TArray<TArray<TLayoutPointF>>);
    class function FlattenContour(const Points: TArray<TLayoutPointF>;
      const OnCurve: TArray<Boolean>): TArray<TLayoutPointF>;
    class procedure AddQuadratic(var Path: TArray<TLayoutPointF>;
      const StartPoint, Control, Stop: TLayoutPointF);
    class procedure Shutdown;
  public
    class function TryOutline(const FamilyName: string; const PixelSize: Single;
      const Bold, Italic: Boolean; const Text: string; out Run: TMarkdownGlyphRun): Boolean; static;
  end;

class procedure TLclGlyphOutliner.EnsureFontConfig;
begin
  if FFontConfigReady then
    Exit;

  FFontConfigReady := True;
  LoadFontConfigLib('', False);
  if Assigned(FcInit) then
    FcInit;
end;

// The file fontconfig would use to draw a family in this style, which is the
// same file the widgetset would pick, so SVG text matches the rest of the UI.
// Results are memoized: a document usually reuses one or two families.
class function TLclGlyphOutliner.ResolveFontFile(const FamilyName: string; const Bold, Italic: Boolean): string;
var
  Key: string;
  Pattern, Font: PFcPattern;
  MatchResult: TFcResult;
  Value: PFcChar8;
  Raw, FileName: RawByteString;
  Weight, Slant, NameLength: Integer;
begin
  if FFiles = nil then
    FFiles := TDictionary<string, string>.Create;

  Key := Format('%s|%d|%d', [FamilyName, Ord(Bold), Ord(Italic)]);
  if FFiles.TryGetValue(Key, Result) then
    Exit;

  Result := '';
  EnsureFontConfig;

  if not Assigned(FcPatternCreate) or not Assigned(FcFontMatch) then
    Exit;

  Pattern := FcPatternCreate();
  if Pattern = nil then
    Exit;

  try
    Raw := UTF8Encode(FamilyName);
    FcPatternAddString(Pattern, pcchar(PAnsiChar(FC_FAMILY)), PAnsiChar(Raw));

    Weight := FC_WEIGHT_REGULAR;
    if Bold then
      Weight := FC_WEIGHT_BOLD;
    FcPatternAddInteger(Pattern, pcchar(PAnsiChar(FC_WEIGHT)), Weight);

    Slant := FC_SLANT_ROMAN;
    if Italic then
      Slant := FC_SLANT_ITALIC;
    FcPatternAddInteger(Pattern, pcchar(PAnsiChar(FC_SLANT)), Slant);

    FcConfigSubstitute(nil, Pattern, FcMatchPattern);
    FcDefaultSubstitute(Pattern);

    Font := FcFontMatch(nil, Pattern, @MatchResult);
    if Font <> nil then
    try
      Value := nil;
      if FcPatternGetString(Font, pcchar(PAnsiChar(FC_FILE)), 0, @Value) = FcResultMatch then
      begin
        NameLength := StrLen(PAnsiChar(Value));
        SetLength(FileName, NameLength);
        if NameLength > 0 then
          Move(Value^, FileName[1], NameLength);
        Result := UTF8Decode(FileName);
      end;
    finally
      FcPatternDestroy(Font);
    end;
  finally
    FcPatternDestroy(Pattern);
  end;

  FFiles.Add(Key, Result);
end;

// Keeps one FreeType face per file and requested pixel size.  FreeType holds the
// outline at the size it was loaded with, so a size change needs its own face.
class function TLclGlyphOutliner.AcquireFont(const FamilyName: string; const PixelSize: Single;
  const Bold, Italic: Boolean): TFreeTypeFont;
var
  FileName, Key: string;
begin
  Result := nil;

  FileName := ResolveFontFile(FamilyName, Bold, Italic);
  if FileName = '' then
    Exit;

  if FFonts = nil then
    FFonts := TDictionary<string, TFreeTypeFont>.Create;

  Key := Format('%s|%.2f', [FileName, PixelSize]);
  if FFonts.TryGetValue(Key, Result) then
    Exit;

  Result := TFreeTypeFont.Create;
  Result.Name := FileName;
  Result.SizeInPixels := PixelSize;
  // GDI's outliner asks for the unhinted outline; do the same so the curves are
  // the designer's, not a screen-grid approximation.
  Result.Hinted := False;
  Result.KerningEnabled := False;

  FFonts.Add(Key, Result);
end;

// UTF-16 code unit to the code point it starts, joining a surrogate pair.
class function TLclGlyphOutliner.NextCodePoint(const Text: string; var Index: Integer): Integer;
var
  LowSurrogate: Integer;
begin
  Result := Ord(Text[Index]);
  Inc(Index);

  if (Result >= $D800) and (Result <= $DBFF) and (Index <= Length(Text)) then
  begin
    LowSurrogate := Ord(Text[Index]);
    if (LowSurrogate >= $DC00) and (LowSurrogate <= $DFFF) then
    begin
      Result := $10000 + ((Result - $D800) shl 10) + (LowSurrogate - $DC00);
      Inc(Index);
    end;
  end;
end;

class function TLclGlyphOutliner.AppendGlyph(const Font: TFreeTypeFont; const CodePoint: Integer;
  const Pen: Single; var Contours: TArray<TArray<TLayoutPointF>>; out Advance: Single): Boolean;
var
  Glyph: TFreeTypeGlyph;
  Outline: TT_Outline;
begin
  Advance := 0;

  if not Font.CheckInstance then
    Exit(False);

  Glyph := Font.Glyph[Font.CharIndex[CodePoint]];
  if Glyph = nil then
    Exit(False);

  // The pen advances even for a glyph with no outline, so a space keeps its
  // width and the letters after it land where they should.
  Advance := Glyph.Advance;
  Result := True;

  if not Glyph.Loaded then
    Exit;

  Outline := Default(TT_Outline);
  if TT_Get_Glyph_Outline(Glyph.Data, Outline) <> TT_Err_Ok then
    Exit;

  AppendOutline(Outline, Pen, Contours);
end;

// Walks the glyph's own contours and turns each TrueType quadratic run into a
// polyline.  The last four points a loaded glyph carries are the phantom points
// the hinter uses; conEnds stops before them, so they are never read.
class procedure TLclGlyphOutliner.AppendOutline(const Outline: TT_Outline; const Pen: Single;
  var Contours: TArray<TArray<TLayoutPointF>>);
var
  ContourIndex, FirstIndex, LastIndex, PointCount, PointIndex: Integer;
  Points: PLongint;
  Flags: PByte;
  Ends: PWord;
  Local: TArray<TLayoutPointF>;
  OnCurve: TArray<Boolean>;
  Path: TArray<TLayoutPointF>;
  RawX, RawY: Longint;
begin
  if (Outline.n_contours <= 0) or (Outline.n_points <= 0) then
    Exit;

  Points := PLongint(Outline.points);
  Flags := PByte(Outline.flags);
  Ends := PWord(Outline.conEnds);

  FirstIndex := 0;
  for ContourIndex := 0 to Outline.n_contours - 1 do
  begin
    LastIndex := Ends[ContourIndex];
    if LastIndex >= Outline.n_points then
      Break;

    PointCount := LastIndex - FirstIndex + 1;
    if PointCount >= 2 then
    begin
      SetLength(Local, PointCount);
      SetLength(OnCurve, PointCount);
      for PointIndex := 0 to PointCount - 1 do
      begin
        RawX := Points[(FirstIndex + PointIndex) * 2];
        RawY := Points[(FirstIndex + PointIndex) * 2 + 1];
        // 26.6 fixed point to pixels; the font grows Y up, the page grows down.
        Local[PointIndex] := TLayoutPointF.Create(Pen + RawX / FixedScale, -RawY / FixedScale);
        OnCurve[PointIndex] := (Flags[FirstIndex + PointIndex] and TT_Flag_On_Curve) <> 0;
      end;

      Path := FlattenContour(Local, OnCurve);
      if Length(Path) >= 3 then
        Contours := Contours + [Path];
    end;

    FirstIndex := LastIndex + 1;
  end;
end;

class function TLclGlyphOutliner.FlattenContour(const Points: TArray<TLayoutPointF>;
  const OnCurve: TArray<Boolean>): TArray<TLayoutPointF>;
var
  Count, StartIndex, Step, Index, NextIndex: Integer;
  Working: TArray<TLayoutPointF>;
  WorkingOn: TArray<Boolean>;
  Current, Midpoint: TLayoutPointF;
begin
  Count := Length(Points);
  Result := nil;
  if Count < 2 then
    Exit;

  StartIndex := -1;
  for Step := 0 to Count - 1 do
    if OnCurve[Step] then
    begin
      StartIndex := Step;
      Break;
    end;

  if StartIndex < 0 then
  begin
    // Every point is a control point: the real start is the midpoint of the last
    // and first, which is where TrueType puts the implied point of a full turn.
    SetLength(Working, Count + 1);
    SetLength(WorkingOn, Count + 1);
    Working[0] := TLayoutPointF.Create((Points[Count - 1].X + Points[0].X) / 2,
      (Points[Count - 1].Y + Points[0].Y) / 2);
    WorkingOn[0] := True;
    for Step := 0 to Count - 1 do
    begin
      Working[Step + 1] := Points[Step];
      WorkingOn[Step + 1] := False;
    end;
    StartIndex := 0;
    Count := Length(Working);
  end
  else
  begin
    Working := Points;
    WorkingOn := OnCurve;
  end;

  Current := Working[StartIndex];
  Result := Result + [Current];

  Step := 1;
  while Step <= Count do
  begin
    Index := (StartIndex + Step) mod Count;

    if WorkingOn[Index] then
    begin
      Result := Result + [Working[Index]];
      Current := Working[Index];
      Inc(Step);
      Continue;
    end;

    NextIndex := (StartIndex + Step + 1) mod Count;
    if WorkingOn[NextIndex] then
    begin
      AddQuadratic(Result, Current, Working[Index], Working[NextIndex]);
      Current := Working[NextIndex];
      Inc(Step, 2);
    end
    else
    begin
      // Two control points in a row: the curve passes through their midpoint,
      // which becomes the stop of this segment and the start of the next.
      Midpoint := TLayoutPointF.Create((Working[Index].X + Working[NextIndex].X) / 2,
        (Working[Index].Y + Working[NextIndex].Y) / 2);
      AddQuadratic(Result, Current, Working[Index], Midpoint);
      Current := Midpoint;
      Inc(Step);
    end;
  end;
end;

class procedure TLclGlyphOutliner.AddQuadratic(var Path: TArray<TLayoutPointF>;
  const StartPoint, Control, Stop: TLayoutPointF);
var
  Step: Integer;
  Fraction, Inverse: Single;
begin
  for Step := 1 to CurveSegments do
  begin
    Fraction := Step / CurveSegments;
    Inverse := 1 - Fraction;
    Path := Path + [TLayoutPointF.Create(
      Inverse * Inverse * StartPoint.X + 2 * Inverse * Fraction * Control.X + Fraction * Fraction * Stop.X,
      Inverse * Inverse * StartPoint.Y + 2 * Inverse * Fraction * Control.Y + Fraction * Fraction * Stop.Y)];
  end;
end;

class function TLclGlyphOutliner.TryOutline(const FamilyName: string; const PixelSize: Single;
  const Bold, Italic: Boolean; const Text: string; out Run: TMarkdownGlyphRun): Boolean;
var
  Font: TFreeTypeFont;
  Pen, Advance: Single;
  Index, CodePoint: Integer;
begin
  Run := Default(TMarkdownGlyphRun);

  if (Text = '') or (PixelSize <= 0) then
    Exit(False);

  try
    Font := AcquireFont(FamilyName, PixelSize, Bold, Italic);
    if Font = nil then
      Exit(False);

    Pen := 0;
    Index := 1;
    while Index <= Length(Text) do
    begin
      CodePoint := NextCodePoint(Text, Index);
      if not AppendGlyph(Font, CodePoint, Pen, Run.Contours, Advance) then
        Continue;

      Pen := Pen + Advance;
    end;

    Run.Advance := Pen;
    Result := Length(Run.Contours) > 0;
  except
    // A font that cannot be read is one drawing that does not appear, not a
    // failure of the document that embedded it.
    on Exception do
    begin
      Run := Default(TMarkdownGlyphRun);
      Result := False;
    end;
  end;
end;

procedure RegisterLclGlyphOutliner;
begin
  TMarkdownGlyphSupport.RegisterOutliner(TLclGlyphOutliner.TryOutline);
end;

class procedure TLclGlyphOutliner.Shutdown;
var
  Font: TFreeTypeFont;
begin
  if FFonts <> nil then
  begin
    for Font in FFonts.Values do
      Font.Free;
    FreeAndNil(FFonts);
  end;
  FreeAndNil(FFiles);
end;

initialization
  RegisterLclGlyphOutliner;

finalization
  TLclGlyphOutliner.Shutdown;

end.
