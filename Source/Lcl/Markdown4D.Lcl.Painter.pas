unit Markdown4D.Lcl.Painter;

// ============================================================================
//  Markdown4D.Lcl.Painter
//
//  Free Pascal / Lazarus (LCL) implementation of IPainter -- the rendering
//  bridge that replaces Markdown4D.Vcl.Painter (TCanvas + Winapi.Windows) on
//  Linux and any other widgetset LCL supports.
//
//  The neutral Core and Layout units hand the display list to an IPainter; this
//  unit consumes exactly that interface and turns it into LCL TCanvas calls.
//  The two places where the platform leaks through are handled here:
//
//    * STRINGS -- the neutral units speak Delphi UTF-16 (see Markdown4D.Fpc.inc);
//      every string that crosses into an LCL API is UTF8Encode'd first, because
//      an implicit UnicodeString -> AnsiString conversion is Latin-1, not UTF-8.
//    * ALPHA   -- Win32 relied on AlphaBlend/CreateDIBSection.  Here the existing
//      TMarkdownPolygonRasterizer already produces a premultiplied BGRA raster,
//      which is byte-for-byte the ARGB32 layout Cairo (and therefore GTK3/LCL)
//      wants, so a TLazIntfImage built with Init_BPP32_B8G8R8A8_BIO_TTB can be
//      drawn straight through the canvas and composited with its own alpha.
//    * ORIGIN  -- the display list is in document coordinates, but a viewer
//      paints one screenful at a time.  OriginY names the document Y that maps
//      to the top of the canvas; every Y this unit computes subtracts it, so
//      drawing and clipping (SetClip) stay in the same space and a scrolled
//      slice needs no per-item adjustment.
// ============================================================================

{$I ../Markdown4D.Fpc.inc}

interface

uses
  SysUtils,
  Types,
  Classes,
  Generics.Collections,
  LCLType,
  LCLIntf,
  Graphics,
  Markdown4D.Image.Rasterizer,
  Markdown4D.Layout.Defaults,
  Markdown4D.Layout.Interfaces,
  Markdown4D.Layout.MeasureCache;

type
  TMarkdownLclImageResolver = reference to function(const Source: string): TGraphic;

  TMarkdownLclBrokenImageQuery = reference to function(const Source: string): Boolean;

  TMarkdownLclPainter = class(TInterfacedObject, IPainter)
  private
    const
      OpaqueAlpha = $FF;
      PlaceholderBorderColor = TLayoutColor($FF9E9E9E);
      PlaceholderStrokeWidth = 1.0;
      BrokenImageCrossColor = TLayoutColor($FFC0392B);
      // Room around a wedge or a stroke for the pixels its anti-aliased edge
      // reaches into.
      WedgeBufferMargin = 2;
    var
      FCanvas: TCanvas;
      FPixelsPerInch: Integer;
      FSavedDepth: Integer;
      FFamilyCache: TDictionary<string, string>;
      FMetricsCache: TDictionary<string, TTextMetric>;
      FMeasureCache: TMarkdownMeasureCache;
      FLastMetricsFont: TMarkdownFontStyle;
      FLastMetricsPixelsPerInch: Integer;
      FLastMetrics: TTextMetric;
      FHasLastMetrics: Boolean;
      FAppliedFontKey: string;
      FHasAppliedFont: Boolean;
      FOriginY: Integer;
      FImageResolver: TMarkdownLclImageResolver;
      FBrokenImageQuery: TMarkdownLclBrokenImageQuery;
    procedure ApplyFont(const Font: TMarkdownFontStyle);
    function FontKey(const Font: TMarkdownFontStyle): string;
    function FontPixelHeight(const Font: TMarkdownFontStyle): Integer;
    function ResolveFamilyName(const FamilyName: string): string;
    class function LookupFamilyName(const FamilyName: string): string;
    class function IsFamilyInstalled(const FamilyName: string): Boolean;
    function TextMetricsOf(const Font: TMarkdownFontStyle): TTextMetric;
    function LookupTextMetrics(const Font: TMarkdownFontStyle): TTextMetric;
    function MeasureCache: TMarkdownMeasureCache;
    procedure FillRectOpaque(const Bounds: TLayoutRectF; const Color: TLayoutColor);
    procedure FillRectBlended(const Bounds: TLayoutRectF; const Color: TLayoutColor);
    procedure DrawResolvedImage(const Bounds: TLayoutRectF; const Graphic: TGraphic; const SourceRect: TLayoutRectF);
    procedure BlitBitmap(const Bounds: TLayoutRectF; const Bitmap: TBitmap; const SourceRect: TLayoutRectF);
    procedure BlendRaster(const Raster: TMarkdownPixelRaster; const Left, Top: Integer);
    procedure BlendRasterStretched(const Raster: TMarkdownPixelRaster; const Dest: TRect);
    procedure DrawImagePlaceholder(const Bounds: TLayoutRectF);
    procedure DrawBrokenImagePlaceholder(const Bounds: TLayoutRectF);
    procedure BlendContours(const Contours: TArray<TArray<TLayoutPointF>>; const Color: TLayoutColor);
    class function WedgeOutlineLoops(const Center: TLayoutPointF;
      const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single): TArray<TArray<TLayoutPointF>>;
    class function WedgePath(const Center: TLayoutPointF;
      const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single): TArray<TLayoutPointF>;
    class function PremultipliedPixel(const Color: TLayoutColor): Cardinal;
    class function ToLclColor(const Color: TLayoutColor): TColor;
    class function ToRoundedRect(const Bounds: TLayoutRectF): TRect;
    function ToDeviceRect(const Bounds: TLayoutRectF): TRect;
    class function CropBitmap(const Bitmap: TBitmap; const Source: TRect): TBitmap;
  public
    constructor Create(const Canvas: TCanvas; const PixelsPerInch: Integer = ReferencePixelsPerInch);
    destructor Destroy; override;
    function MeasureText(const Text: string; const Font: TMarkdownFontStyle): TLayoutSizeF;
    function LineHeight(const Font: TMarkdownFontStyle): Single;
    function Baseline(const Font: TMarkdownFontStyle): Single;
    procedure DrawTextRun(const TopLeft: TLayoutPointF; const Text: string; const Font: TMarkdownFontStyle;
      const Color: TLayoutColor);
    procedure FillRect(const Bounds: TLayoutRectF; const Color: TLayoutColor);
    procedure DrawRect(const Bounds: TLayoutRectF; const Color: TLayoutColor; const StrokeWidth: Single);
    procedure DrawLine(const StartPoint, EndPoint: TLayoutPointF; const Color: TLayoutColor;
      const StrokeWidth: Single);
    procedure DrawImage(const Bounds: TLayoutRectF; const Source: string; const SourceRect: TLayoutRectF);
    procedure FillWedge(const Center: TLayoutPointF; const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single;
      const Color: TLayoutColor);
    procedure DrawWedge(const Center: TLayoutPointF; const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single;
      const Color: TLayoutColor; const StrokeWidth: Single);
    procedure FillPolygon(const Points: TArray<TLayoutPointF>; const Color: TLayoutColor);
    procedure DrawPolygon(const Points: TArray<TLayoutPointF>; const Color: TLayoutColor; const StrokeWidth: Single);
    procedure SaveState;
    procedure SetClip(const Bounds: TLayoutRectF);
    procedure RestoreState;
    property PixelsPerInch: Integer read FPixelsPerInch write FPixelsPerInch;
    // The document Y that maps to the top of the canvas.  The viewer renders a
    // scrolled slice by setting this, and SetClip sees the same offset, so the
    // clip follows the drawing.
    property OriginY: Integer read FOriginY write FOriginY;
    property ImageResolver: TMarkdownLclImageResolver read FImageResolver write FImageResolver;
    property BrokenImageQuery: TMarkdownLclBrokenImageQuery read FBrokenImageQuery write FBrokenImageQuery;
  end;

implementation

uses
  Math,
  Forms,
  IntfGraphics,
  GraphType,
  Markdown4D.Defines,
  Markdown4D.Viewer.Shared;

constructor TMarkdownLclPainter.Create(const Canvas: TCanvas; const PixelsPerInch: Integer);
begin
  inherited Create;

  FCanvas := Canvas;
  FPixelsPerInch := PixelsPerInch;
  FFamilyCache := TDictionary<string, string>.Create;
  FMetricsCache := TDictionary<string, TTextMetric>.Create;
end;

destructor TMarkdownLclPainter.Destroy;
begin
  FMeasureCache.Free;
  FMetricsCache.Free;
  FFamilyCache.Free;

  inherited Destroy;
end;

function TMarkdownLclPainter.MeasureText(const Text: string; const Font: TMarkdownFontStyle): TLayoutSizeF;
var
  Extent: TSize;
  Metrics: TTextMetric;
begin
  if MeasureCache.TryGetSize(Text, Font, FPixelsPerInch, Result) then
    Exit;

  ApplyFont(Font);

  Extent := FCanvas.TextExtent(UTF8Encode(Text));
  Metrics := TextMetricsOf(Font);
  Result := TLayoutSizeF.Create(Extent.cx, Metrics.tmHeight + Metrics.tmExternalLeading);
  MeasureCache.Add(Text, Font, FPixelsPerInch, Result);
end;

function TMarkdownLclPainter.LineHeight(const Font: TMarkdownFontStyle): Single;
var
  Metrics: TTextMetric;
begin
  Metrics := TextMetricsOf(Font);
  Result := Metrics.tmHeight + Metrics.tmExternalLeading;
end;

function TMarkdownLclPainter.Baseline(const Font: TMarkdownFontStyle): Single;
begin
  Result := TextMetricsOf(Font).tmAscent;
end;

procedure TMarkdownLclPainter.DrawTextRun(const TopLeft: TLayoutPointF; const Text: string;
  const Font: TMarkdownFontStyle; const Color: TLayoutColor);
var
  Metrics: TTextMetric;
begin
  ApplyFont(Font);
  FCanvas.Font.Color := ToLclColor(Color);
  FCanvas.Brush.Style := bsClear;

  Metrics := TextMetricsOf(Font);

  // The neutral layer places the run's baseline at TopLeft.Y + ascent.  LCL's
  // TextOut anchors the top of the text cell at Y, so the baseline lands at
  // Y + tmAscent when Y is the run's top -- exactly what the DOM asks for.
  FCanvas.TextOut(Round(TopLeft.X), Round(TopLeft.Y) - FOriginY, UTF8Encode(Text));
end;

procedure TMarkdownLclPainter.FillRect(const Bounds: TLayoutRectF; const Color: TLayoutColor);
var
  Alpha: Byte;
begin
  Alpha := TMarkdownViewerShared.AlphaOf(Color);
  if Alpha = 0 then
    Exit;

  if Alpha = OpaqueAlpha then
    FillRectOpaque(Bounds, Color)
  else
    FillRectBlended(Bounds, Color);
end;

procedure TMarkdownLclPainter.FillRectOpaque(const Bounds: TLayoutRectF; const Color: TLayoutColor);
begin
  FCanvas.Brush.Style := bsSolid;
  FCanvas.Brush.Color := ToLclColor(Color);
  FCanvas.FillRect(ToDeviceRect(Bounds));
end;

procedure TMarkdownLclPainter.FillRectBlended(const Bounds: TLayoutRectF; const Color: TLayoutColor);
var
  Raster: TMarkdownPixelRaster;
  Dest: TRect;
begin
  // A one-pixel premultiplied raster stretched over the rectangle: every pixel
  // of the destination gets the same alpha blend, without touching the source
  // image underneath the way a brush fill would.
  Raster := TMarkdownPixelRaster.Create(1, 1);
  Move(PremultipliedPixel(Color), Raster.Pixels[0], SizeOf(Cardinal));

  Dest := ToDeviceRect(Bounds);
  BlendRasterStretched(Raster, Dest);
end;

procedure TMarkdownLclPainter.DrawRect(const Bounds: TLayoutRectF; const Color: TLayoutColor;
  const StrokeWidth: Single);
var
  Dest: TRect;
begin
  if (TMarkdownViewerShared.AlphaOf(Color) = 0) or (StrokeWidth <= 0) then
    Exit;

  FCanvas.Pen.Style := psSolid;
  FCanvas.Pen.Color := ToLclColor(Color);
  FCanvas.Pen.Width := Round(StrokeWidth);
  if FCanvas.Pen.Width < 1 then
    FCanvas.Pen.Width := 1;
  FCanvas.Brush.Style := bsClear;

  Dest := ToDeviceRect(Bounds);
  FCanvas.Rectangle(Dest.Left, Dest.Top, Dest.Right, Dest.Bottom);
end;

procedure TMarkdownLclPainter.DrawLine(const StartPoint, EndPoint: TLayoutPointF; const Color: TLayoutColor;
  const StrokeWidth: Single);
begin
  if TMarkdownViewerShared.AlphaOf(Color) = 0 then
    Exit;

  FCanvas.Pen.Style := psSolid;
  FCanvas.Pen.Color := ToLclColor(Color);
  FCanvas.Pen.Width := Round(StrokeWidth);
  if FCanvas.Pen.Width < 1 then
    FCanvas.Pen.Width := 1;

  FCanvas.MoveTo(Round(StartPoint.X), Round(StartPoint.Y) - FOriginY);
  FCanvas.LineTo(Round(EndPoint.X), Round(EndPoint.Y) - FOriginY);
end;

procedure TMarkdownLclPainter.DrawImage(const Bounds: TLayoutRectF; const Source: string;
  const SourceRect: TLayoutRectF);
var
  Graphic: TGraphic;
  IsAvailable: Boolean;
  IsBroken: Boolean;
begin
  Graphic := nil;
  if Assigned(FImageResolver) then
    Graphic := FImageResolver(Source);

  IsAvailable := (Graphic <> nil) and not Graphic.Empty;
  if IsAvailable then
  begin
    DrawResolvedImage(Bounds, Graphic, SourceRect);
    Exit;
  end;

  IsBroken := Assigned(FBrokenImageQuery) and FBrokenImageQuery(Source);
  if IsBroken then
    DrawBrokenImagePlaceholder(Bounds)
  else
    DrawImagePlaceholder(Bounds);
end;

procedure TMarkdownLclPainter.DrawResolvedImage(const Bounds: TLayoutRectF; const Graphic: TGraphic;
  const SourceRect: TLayoutRectF);
var
  Converted: TBitmap;
begin
  if Graphic is TBitmap then
  begin
    BlitBitmap(Bounds, TBitmap(Graphic), SourceRect);
    Exit;
  end;

  Converted := TBitmap.Create;
  try
    Converted.Assign(Graphic);
    BlitBitmap(Bounds, Converted, SourceRect);
  finally
    Converted.Free;
  end;
end;

procedure TMarkdownLclPainter.BlitBitmap(const Bounds: TLayoutRectF; const Bitmap: TBitmap;
  const SourceRect: TLayoutRectF);
var
  Source: TRect;
  HasSourceRect: Boolean;
  Dest: TRect;
  Cropped: TBitmap;
begin
  Source := Rect(0, 0, Bitmap.Width, Bitmap.Height);
  HasSourceRect := (SourceRect.Width > 0) and (SourceRect.Height > 0);
  Dest := ToDeviceRect(Bounds);

  if HasSourceRect then
  begin
    Cropped := CropBitmap(Bitmap, ToRoundedRect(SourceRect));
    try
      FCanvas.StretchDraw(Dest, Cropped);
    finally
      Cropped.Free;
    end;
    Exit;
  end;

  // StretchDraw composites the bitmap's own alpha on GTK3/Qt (the source is a
  // CAIRO_CONTENT_COLOR_ALPHA surface), so a 32-bit PNG keeps its transparency.
  FCanvas.StretchDraw(Dest, Bitmap);
end;

// Copies a sub-rectangle through TLazIntfImage so per-pixel alpha survives; a
// plain Canvas.CopyRect would flatten it against the destination.
class function TMarkdownLclPainter.CropBitmap(const Bitmap: TBitmap; const Source: TRect): TBitmap;
var
  SrcImage: TLazIntfImage;
  DstImage: TLazIntfImage;
  Description: TRawImageDescription;
  XIndex, YIndex: Integer;
begin
  SrcImage := Bitmap.CreateIntfImage;
  try
    DstImage := TLazIntfImage.Create(0, 0);
    try
      // The description goes in through the property (see BitmapFromRaster):
      // only the setter picks the pixel functions Colors needs and allocates
      // the rows, so mutating the reader's object would leave the image empty.
      Description.Init_BPP32_B8G8R8A8_BIO_TTB(Source.Right - Source.Left, Source.Bottom - Source.Top);
      DstImage.DataDescription := Description;

      for YIndex := 0 to DstImage.Height - 1 do
        for XIndex := 0 to DstImage.Width - 1 do
          DstImage.Colors[XIndex, YIndex] := SrcImage.Colors[Source.Left + XIndex, Source.Top + YIndex];

      Result := TBitmap.Create;
      try
        Result.LoadFromIntfImage(DstImage);
      except
        Result.Free;
        raise;
      end;
    finally
      DstImage.Free;
    end;
  finally
    SrcImage.Free;
  end;
end;

procedure TMarkdownLclPainter.FillWedge(const Center: TLayoutPointF;
  const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single; const Color: TLayoutColor);
var
  Path: TArray<TLayoutPointF>;
  MinX, MinY, MaxX, MaxY: Single;
  Left, Top, BufferWidth, BufferHeight: Integer;
  Local: TArray<TLayoutPointF>;
  Index: Integer;
  Raster: TMarkdownPixelRaster;
begin
  if (TMarkdownViewerShared.AlphaOf(Color) = 0) or (OuterRadius <= 0) or (SweepAngle = 0) then
    Exit;

  Path := WedgePath(Center, OuterRadius, InnerRadius, StartAngle, SweepAngle);
  if Length(Path) < 3 then
    Exit;

  // Fill the wedge into a small transparent buffer and alpha-blend that onto
  // the canvas: the same coverage rasterizer keeps the arcs smooth, and shared
  // radial edges stay seam-free because a later wedge blends over its neighbour.
  MinX := Path[0].X;
  MinY := Path[0].Y;
  MaxX := Path[0].X;
  MaxY := Path[0].Y;
  for Index := 1 to High(Path) do
  begin
    MinX := Min(MinX, Path[Index].X);
    MinY := Min(MinY, Path[Index].Y);
    MaxX := Max(MaxX, Path[Index].X);
    MaxY := Max(MaxY, Path[Index].Y);
  end;

  Left := Floor(MinX) - WedgeBufferMargin;
  Top := Floor(MinY) - WedgeBufferMargin;
  BufferWidth := Ceil(MaxX) - Left + WedgeBufferMargin;
  BufferHeight := Ceil(MaxY) - Top + WedgeBufferMargin;
  if (BufferWidth <= 0) or (BufferHeight <= 0) then
    Exit;

  SetLength(Local, Length(Path));
  for Index := 0 to High(Path) do
    Local[Index] := TLayoutPointF.Create(Path[Index].X - Left, Path[Index].Y - Top);

  Raster := TMarkdownPolygonRasterizer.Fill(Local, Color, BufferWidth, BufferHeight);

  BlendRaster(Raster, Left, Top);
end;

// Builds an anti-aliasable float path for a pie slice or doughnut sector, using
// a 0deg-at-3-o'clock clockwise polar convention that matches the chart labels.
class function TMarkdownLclPainter.WedgePath(const Center: TLayoutPointF;
  const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single): TArray<TLayoutPointF>;
const
  DegreesToRadians = Pi / 180;
  SegmentDegrees = 1.5;
var
  Steps, PointCount, Index, Step: Integer;
  HasHole: Boolean;
  Angle: Single;
begin
  Steps := Max(1, Ceil(Abs(SweepAngle) / SegmentDegrees));
  HasHole := InnerRadius > 0;

  PointCount := Steps + 1;
  if HasHole then
    PointCount := PointCount + (Steps + 1)
  else
    PointCount := PointCount + 1;

  SetLength(Result, PointCount);

  Index := 0;
  for Step := 0 to Steps do
  begin
    Angle := (StartAngle + SweepAngle * Step / Steps) * DegreesToRadians;
    Result[Index] := TLayoutPointF.Create(Center.X + OuterRadius * Cos(Angle), Center.Y + OuterRadius * Sin(Angle));
    Inc(Index);
  end;

  if HasHole then
  begin
    for Step := Steps downto 0 do
    begin
      Angle := (StartAngle + SweepAngle * Step / Steps) * DegreesToRadians;
      Result[Index] := TLayoutPointF.Create(Center.X + InnerRadius * Cos(Angle), Center.Y + InnerRadius * Sin(Angle));
      Inc(Index);
    end;
  end
  else
  begin
    Result[Index] := TLayoutPointF.Create(Center.X, Center.Y);
  end;
end;

procedure TMarkdownLclPainter.FillPolygon(const Points: TArray<TLayoutPointF>; const Color: TLayoutColor);
begin
  if (TMarkdownViewerShared.AlphaOf(Color) = 0) or (Length(Points) < 3) then
    Exit;

  // The same coverage rasterizer that draws the wedges gives every polygon
  // smooth edges instead of the canvas' own hard-edged polygon fill.
  BlendContours([Points], Color);
end;

// Strokes a polygon by turning it into the same kind of stroke band the SVG
// engine builds for a path (a quad per edge plus a round join per vertex), then
// rasterizes and blends it exactly as FillWedge does its slice.
procedure TMarkdownLclPainter.DrawPolygon(const Points: TArray<TLayoutPointF>; const Color: TLayoutColor;
  const StrokeWidth: Single);
var
  Contours: TArray<TArray<TLayoutPointF>>;
begin
  if (TMarkdownViewerShared.AlphaOf(Color) = 0) or (StrokeWidth <= 0) or (Length(Points) < 3) then
    Exit;

  Contours := TMarkdownPolygonRasterizer.StrokeContours(Points, True, StrokeWidth / 2, True, False);
  BlendContours(Contours, Color);
end;

// A wedge's outline is one closed loop (arc plus the straight radii that close
// it) for any partial slice; a full turn is instead its own outer, and inner,
// circle, because the forward-then-backward arcs of WedgePath would coincide
// and cancel under the non-zero rule.
procedure TMarkdownLclPainter.DrawWedge(const Center: TLayoutPointF;
  const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single; const Color: TLayoutColor;
  const StrokeWidth: Single);
var
  HalfWidth: Single;
  Loops: TArray<TArray<TLayoutPointF>>;
  Contours: TArray<TArray<TLayoutPointF>>;
  Loop: TArray<TLayoutPointF>;
begin
  if (TMarkdownViewerShared.AlphaOf(Color) = 0) or (StrokeWidth <= 0) or (OuterRadius <= 0) or
    (SweepAngle = 0) then
    Exit;

  HalfWidth := StrokeWidth / 2;
  Loops := WedgeOutlineLoops(Center, OuterRadius, InnerRadius, StartAngle, SweepAngle);

  Contours := nil;
  for Loop in Loops do
    Contours := Contours + TMarkdownPolygonRasterizer.StrokeContours(Loop, True, HalfWidth, True, False);

  BlendContours(Contours, Color);
end;

class function TMarkdownLclPainter.WedgeOutlineLoops(const Center: TLayoutPointF;
  const OuterRadius, InnerRadius, StartAngle, SweepAngle: Single): TArray<TArray<TLayoutPointF>>;
begin
  if Abs(SweepAngle) < 360 then
  begin
    Result := [WedgePath(Center, OuterRadius, InnerRadius, StartAngle, SweepAngle)];
    Exit;
  end;

  Result := [TMarkdownPolygonRasterizer.Disc(Center, OuterRadius)];
  if InnerRadius > 0 then
    Result := Result + [TMarkdownPolygonRasterizer.Disc(Center, InnerRadius)];
end;

// Shared tail for DrawPolygon and DrawWedge: sizes a buffer to the contours'
// own extent, fills every contour into it as one figure, and blends it.
procedure TMarkdownLclPainter.BlendContours(const Contours: TArray<TArray<TLayoutPointF>>; const Color: TLayoutColor);
var
  MinX, MinY, MaxX, MaxY: Single;
  Left, Top, BufferWidth, BufferHeight: Integer;
  Contour: TArray<TLayoutPointF>;
  Point: TLayoutPointF;
  Translated: TArray<TArray<TLayoutPointF>>;
  ContourIndex, PointIndex: Integer;
  Raster: TMarkdownPixelRaster;
begin
  if Length(Contours) = 0 then
    Exit;

  MinX := Contours[0][0].X;
  MinY := Contours[0][0].Y;
  MaxX := Contours[0][0].X;
  MaxY := Contours[0][0].Y;
  for Contour in Contours do
    for Point in Contour do
    begin
      MinX := Min(MinX, Point.X);
      MinY := Min(MinY, Point.Y);
      MaxX := Max(MaxX, Point.X);
      MaxY := Max(MaxY, Point.Y);
    end;

  Left := Floor(MinX) - WedgeBufferMargin;
  Top := Floor(MinY) - WedgeBufferMargin;
  BufferWidth := Ceil(MaxX) - Left + WedgeBufferMargin;
  BufferHeight := Ceil(MaxY) - Top + WedgeBufferMargin;
  if (BufferWidth <= 0) or (BufferHeight <= 0) then
    Exit;

  SetLength(Translated, Length(Contours));
  for ContourIndex := 0 to High(Contours) do
  begin
    SetLength(Translated[ContourIndex], Length(Contours[ContourIndex]));
    for PointIndex := 0 to High(Contours[ContourIndex]) do
    begin
      Point := Contours[ContourIndex][PointIndex];
      Translated[ContourIndex][PointIndex] := TLayoutPointF.Create(Point.X - Left, Point.Y - Top);
    end;
  end;

  Raster := TMarkdownPixelRaster.Create(BufferWidth, BufferHeight);
  TMarkdownPolygonRasterizer.FillContoursInto(Raster, Translated, Color);

  BlendRaster(Raster, Left, Top);
end;

procedure TMarkdownLclPainter.DrawImagePlaceholder(const Bounds: TLayoutRectF);
begin
  DrawRect(Bounds, PlaceholderBorderColor, PlaceholderStrokeWidth);
end;

procedure TMarkdownLclPainter.DrawBrokenImagePlaceholder(const Bounds: TLayoutRectF);
begin
  DrawRect(Bounds, PlaceholderBorderColor, PlaceholderStrokeWidth);
  DrawLine(TLayoutPointF.Create(Bounds.Left, Bounds.Top), TLayoutPointF.Create(Bounds.Right, Bounds.Bottom),
    BrokenImageCrossColor, PlaceholderStrokeWidth);
  DrawLine(TLayoutPointF.Create(Bounds.Right, Bounds.Top), TLayoutPointF.Create(Bounds.Left, Bounds.Bottom),
    BrokenImageCrossColor, PlaceholderStrokeWidth);
end;

// Turns a premultiplied BGRA raster into a bitmap the canvas can draw.  The
// bytes go through a 32-bit image surface, which is the one path that keeps
// per-pixel alpha all the way onto the canvas.
function BitmapFromRaster(const Raster: TMarkdownPixelRaster): TBitmap;
var
  Image: TLazIntfImage;
  Description: TRawImageDescription;
  RowIndex, RowBytes: Integer;
begin
  Result := nil;
  if Raster.IsEmpty then
    Exit;

  RowBytes := Raster.Width * SizeOf(Cardinal);
  Image := TLazIntfImage.Create(0, 0);
  try
    // The description is set through the property, and not through the object
    // the reader hands back: the setter is what checks it, picks the pixel
    // functions and allocates the rows GetDataLineStart returns.  Changing the
    // reader's object alone would leave the image with no data at all.
    Description.Init_BPP32_B8G8R8A8_BIO_TTB(Raster.Width, Raster.Height);
    Image.DataDescription := Description;

    for RowIndex := 0 to Raster.Height - 1 do
      Move(Raster.Pixels[RowIndex * RowBytes], PByte(Image.GetDataLineStart(RowIndex))^, RowBytes);

    Result := TBitmap.Create;
    try
      Result.LoadFromIntfImage(Image);
    except
      Result.Free;
      raise;
    end;
  finally
    Image.Free;
  end;
end;

// Hands a premultiplied BGRA raster to the widgetset as a 32-bit image surface,
// which is the one path that blends per-pixel alpha onto the canvas.
procedure TMarkdownLclPainter.BlendRaster(const Raster: TMarkdownPixelRaster; const Left, Top: Integer);
var
  Bitmap: TBitmap;
begin
  Bitmap := BitmapFromRaster(Raster);
  if Bitmap = nil then
    Exit;

  try
    FCanvas.Draw(Left, Top - FOriginY, Bitmap);
  finally
    Bitmap.Free;
  end;
end;

procedure TMarkdownLclPainter.BlendRasterStretched(const Raster: TMarkdownPixelRaster; const Dest: TRect);
var
  Bitmap: TBitmap;
begin
  Bitmap := BitmapFromRaster(Raster);
  if Bitmap = nil then
    Exit;

  try
    FCanvas.StretchDraw(Dest, Bitmap);
  finally
    Bitmap.Free;
  end;
end;

procedure TMarkdownLclPainter.SaveState;
begin
  FCanvas.SaveHandleState;
  Inc(FSavedDepth);
end;

procedure TMarkdownLclPainter.SetClip(const Bounds: TLayoutRectF);
var
  Dest: TRect;
begin
  Dest := ToDeviceRect(Bounds);
  IntersectClipRect(FCanvas.Handle, Dest.Left, Dest.Top, Dest.Right, Dest.Bottom);
end;

procedure TMarkdownLclPainter.RestoreState;
begin
  if FSavedDepth = 0 then
    raise EMarkdownError.Create(UnbalancedRestoreMessage);

  FCanvas.RestoreHandleState;
  Dec(FSavedDepth);
  FCanvas.Refresh;
end;

procedure TMarkdownLclPainter.ApplyFont(const Font: TMarkdownFontStyle);
var
  Key: string;
begin
  Key := FontKey(Font);
  if FHasAppliedFont and (Key = FAppliedFontKey) then
    Exit;

  FCanvas.Font.Name := UTF8Encode(ResolveFamilyName(Font.FamilyName));
  FCanvas.Font.Height := FontPixelHeight(Font);
  FCanvas.Font.Style := TMarkdownViewerShared.FontStylesOf(Font);
  // ClearType keeps text on the offscreen buffer as crisp as the rest of the
  // desktop where the widgetset honours it; GTK/Qt ignore the hint.
  FCanvas.Font.Quality := TFontQuality.fqCleartypeNatural;

  FAppliedFontKey := Key;
  FHasAppliedFont := True;
end;

function TMarkdownLclPainter.FontPixelHeight(const Font: TMarkdownFontStyle): Integer;
begin
  Result := -Round(Font.Size * FPixelsPerInch / ReferencePixelsPerInch);
end;

function TMarkdownLclPainter.FontKey(const Font: TMarkdownFontStyle): string;
var
  StyleBits: Integer;
begin
  // FPC rejects casting a set to Byte; pack the four style flags by hand so the
  // key still distinguishes every style combination.
  StyleBits := Ord(Font.Bold) or (Ord(Font.Italic) shl 1) or
               (Ord(Font.Underline) shl 2) or (Ord(Font.Strikeout) shl 3);
  Result := Format('%s|%d|%d', [ResolveFamilyName(Font.FamilyName), FontPixelHeight(Font), StyleBits]);
end;

function TMarkdownLclPainter.ResolveFamilyName(const FamilyName: string): string;
begin
  if FFamilyCache.TryGetValue(FamilyName, Result) then
    Exit;

  Result := LookupFamilyName(FamilyName);
  FFamilyCache.Add(FamilyName, Result);
end;

class function TMarkdownLclPainter.LookupFamilyName(const FamilyName: string): string;
begin
  if TMarkdownViewerShared.TryResolveGenericFamily(FamilyName, Result) then
    Exit;

  if IsFamilyInstalled(FamilyName) then
  begin
    Result := FamilyName;
    Exit;
  end;

  Result := DefaultFallbackFamilyName;
end;

class function TMarkdownLclPainter.IsFamilyInstalled(const FamilyName: string): Boolean;
begin
  // A bare TCanvas (offscreen bitmap, no application) has no font list to ask;
  // trusting the requested name then is better than forcing a fallback.
  if not Assigned(Screen) then
    Exit(True);

  try
    Result := Screen.Fonts.IndexOf(UTF8Encode(FamilyName)) >= 0;
  except
    Result := True;
  end;
end;

// Created on the first measurement: the viewer makes a painter for every paint,
// and only the one it lays out with measures.
function TMarkdownLclPainter.MeasureCache: TMarkdownMeasureCache;
begin
  if FMeasureCache = nil then
    FMeasureCache := TMarkdownMeasureCache.Create;

  Result := FMeasureCache;
end;

// Layout asks for the line height and the baseline of nearly every run, mostly
// in the font it asked for last; that answer comes without building a key.
function TMarkdownLclPainter.TextMetricsOf(const Font: TMarkdownFontStyle): TTextMetric;
var
  IsLastFont: Boolean;
begin
  IsLastFont := FHasLastMetrics and (FLastMetricsPixelsPerInch = FPixelsPerInch) and
                Font.SameAs(FLastMetricsFont);
  if IsLastFont then
  begin
    Result := FLastMetrics;
    Exit;
  end;

  Result := LookupTextMetrics(Font);

  FLastMetricsFont := Font;
  FLastMetricsPixelsPerInch := FPixelsPerInch;
  FLastMetrics := Result;
  FHasLastMetrics := True;
end;

function TMarkdownLclPainter.LookupTextMetrics(const Font: TMarkdownFontStyle): TTextMetric;
var
  Key: string;
begin
  Key := FontKey(Font);
  if FMetricsCache.TryGetValue(Key, Result) then
    Exit;

  ApplyFont(Font);
  Result := Default(TTextMetric);
  LCLIntf.GetTextMetrics(FCanvas.Handle, Result);
  FMetricsCache.Add(Key, Result);
end;

class function TMarkdownLclPainter.PremultipliedPixel(const Color: TLayoutColor): Cardinal;
var
  Alpha, Red, Green, Blue: Cardinal;
begin
  Alpha := TMarkdownViewerShared.AlphaOf(Color);
  Red := ((Color shr 16) and $FF) * Alpha div ColorChannelMax;
  Green := ((Color shr 8) and $FF) * Alpha div ColorChannelMax;
  Blue := (Color and $FF) * Alpha div ColorChannelMax;
  Result := (Alpha shl 24) or (Red shl 16) or (Green shl 8) or Blue;
end;

class function TMarkdownLclPainter.ToLclColor(const Color: TLayoutColor): TColor;
begin
  Result := RGBToColor((Color shr 16) and $FF, (Color shr 8) and $FF, Color and $FF);
end;

class function TMarkdownLclPainter.ToRoundedRect(const Bounds: TLayoutRectF): TRect;
begin
  Result := Rect(Round(Bounds.Left), Round(Bounds.Top), Round(Bounds.Right), Round(Bounds.Bottom));
end;

function TMarkdownLclPainter.ToDeviceRect(const Bounds: TLayoutRectF): TRect;
begin
  Result := ToRoundedRect(Bounds);
  Result.Top := Result.Top - FOriginY;
  Result.Bottom := Result.Bottom - FOriginY;
end;

end.
