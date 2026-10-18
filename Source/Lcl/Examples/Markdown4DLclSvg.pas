program Markdown4DLclSvg;

// Smoke test for the LCL side of the SVG engine: rasterize an SVG that draws a
// gradient, a stroked shape and text, and write the result out as a PNG.
//
// The text is the interesting part here: there is no system text API behind
// this engine, so the letters come from TMarkdownGlyphSupport, which the LCL
// glyph outliner fills in by reading the font file through FreeType.  Run under
// any X/Qt/GTK session (or Xvfb) with the LCL unit paths on the search path.

{$I ../../Markdown4D.Fpc.inc}

uses
  Interfaces,
  Forms,
  Graphics,
  IntfGraphics,
  GraphType,
  SysUtils,
  Markdown4D.Image.Svg,
  Markdown4D.Image.Svg.Native,
  Markdown4D.Lcl.Glyphs;

const
  SampleSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="460" height="220">' +
    '<defs>' +
    '<linearGradient id="warm" x1="0" y1="0" x2="1" y2="1">' +
    '<stop offset="0" stop-color="#e0533d"/>' +
    '<stop offset="1" stop-color="#2c6fb5"/>' +
    '</linearGradient>' +
    '</defs>' +
    '<rect x="0" y="0" width="460" height="220" fill="#ffffff"/>' +
    '<circle cx="74" cy="104" r="54" fill="url(#warm)" opacity="0.9"/>' +
    '<path d="M160 162 L222 52 L284 162 Z" fill="none" stroke="#3a7d44" stroke-width="6" stroke-linejoin="round"/>' +
    '<text x="24" y="200" font-family="DejaVu Sans" font-size="34" font-weight="bold" fill="#202020">Text as outlines</text>' +
    '</svg>';

// Hands a premultiplied BGRA raster to a TBitmap as a 32-bit image surface, so
// the per-pixel alpha of the drawing survives the trip to the file.
function RasterToBitmap(const Raster: TMarkdownSvgRaster): TBitmap;
var
  Image: TLazIntfImage;
  Description: TRawImageDescription;
  RowIndex, RowBytes: Integer;
begin
  Image := TLazIntfImage.Create(0, 0);
  try
    // The description goes in through the property, not through the object the
    // reader hands back: the setter is what allocates the bytes the rows live in.
    Description.Init_BPP32_B8G8R8A8_BIO_TTB(Raster.Width, Raster.Height);
    Image.DataDescription := Description;

    RowBytes := Raster.Width * SizeOf(Cardinal);
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

var
  Raster: TMarkdownSvgRaster;
  Bitmap: TBitmap;
  OutputPath: string;
begin
  Application.Initialize;

  if not TMarkdownSvgSupport.TryRasterize(TEncoding.UTF8.GetBytes(SampleSvg), 0, 0, Raster) then
    raise Exception.Create('the SVG engine would not draw the sample');

  Bitmap := RasterToBitmap(Raster);
  try
    OutputPath := ParamStr(1);
    if OutputPath = '' then
      OutputPath := 'markdown4d-lcl-svg.png';
    Bitmap.SaveToFile(OutputPath);
    WriteLn('wrote ', OutputPath, ' (', Raster.Width, 'x', Raster.Height, ')');
  finally
    Bitmap.Free;
  end;
end.
