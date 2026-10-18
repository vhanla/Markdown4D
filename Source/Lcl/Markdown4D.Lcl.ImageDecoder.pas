unit Markdown4D.Lcl.ImageDecoder;

{$I ../Markdown4D.Fpc.inc}

// ============================================================================
//  Markdown4D.Lcl.ImageDecoder
//
//  FPC/LCL counterpart of Markdown4D.Vcl.ImageDecoder.  The neutral SVG engine
//  embeds pictures inside a document and asks TMarkdownImageDecoding to turn
//  their bytes into the same premultiplied BGRA raster everything else
//  composites in; this unit registers that decoder using the LCL's own image
//  classes (PNG, JPEG, BMP, GIF, ... via TFPImageBitmap).
//
//  It differs from the VCL unit in one deliberate way: instead of drawing the
//  picture onto a 32-bit bitmap and reading it back -- which on a widgetset that
//  has no premultiplied-alpha convention is easy to get wrong -- it reads the
//  decoded TLazIntfImage directly and premultiplies per pixel.  That is slower
//  than a bulk copy but format-independent and correct for straight-alpha PNGs.
// ============================================================================

interface

procedure RegisterLclImageDecoder;

implementation

uses
  Interfaces,
  SysUtils,
  Classes,
  Graphics,
  FPImage,
  IntfGraphics,
  Markdown4D.Image.Rasterizer,
  Markdown4D.Image.Decoder;

type
  TLclImageDecoder = class
  public
    class function TryDecode(const Data: TBytes; out Raster: TMarkdownPixelRaster): Boolean; static;
  private
    class procedure Rasterize(const Image: TLazIntfImage; out Raster: TMarkdownPixelRaster); static;
  end;

class procedure TLclImageDecoder.Rasterize(const Image: TLazIntfImage; out Raster: TMarkdownPixelRaster);
var
  XIndex, YIndex, Offset: Integer;
  Color: TFPColor;
  Alpha, Red, Green, Blue: Integer;
begin
  Raster := TMarkdownPixelRaster.Create(Image.Width, Image.Height);
  if Raster.IsEmpty then
    Exit;

  Offset := 0;
  for YIndex := 0 to Image.Height - 1 do
    for XIndex := 0 to Image.Width - 1 do
    begin
      Color := Image.Colors[XIndex, YIndex];
      Alpha := Color.Alpha shr 8;                       // 16-bit -> 8-bit
      Red := (Color.Red shr 8) * Alpha div 255;         // premultiply
      Green := (Color.Green shr 8) * Alpha div 255;
      Blue := (Color.Blue shr 8) * Alpha div 255;

      Raster.Pixels[Offset] := Byte(Blue);
      Raster.Pixels[Offset + 1] := Byte(Green);
      Raster.Pixels[Offset + 2] := Byte(Red);
      Raster.Pixels[Offset + 3] := Byte(Alpha);
      Inc(Offset, 4);
    end;
end;

class function TLclImageDecoder.TryDecode(const Data: TBytes; out Raster: TMarkdownPixelRaster): Boolean;
var
  Stream: TBytesStream;
  Picture: TPicture;
  Graphic: TGraphic;
  Image: TLazIntfImage;
  Fallback: TBitmap;
begin
  Raster := Default(TMarkdownPixelRaster);
  Image := nil;

  try
    Stream := TBytesStream.Create(Data);
    try
      Picture := TPicture.Create;
      try
        Picture.LoadFromStream(Stream);
        Graphic := Picture.Graphic;
        if (Graphic = nil) or (Picture.Width <= 0) or (Picture.Height <= 0) then
          Exit(False);

        // Every format the LCL reads decodes through a TRasterImage, whose
        // intf image is the decoded pixels with their alpha intact.
        if Graphic is TRasterImage then
          Image := TRasterImage(Graphic).CreateIntfImage
        else
        begin
          Fallback := TBitmap.Create;
          try
            Fallback.PixelFormat := pf32bit;
            Fallback.SetSize(Picture.Width, Picture.Height);
            Fallback.Canvas.Brush.Style := bsClear;
            Fallback.Canvas.Draw(0, 0, Graphic);
            Image := Fallback.CreateIntfImage;
          finally
            Fallback.Free;
          end;
        end;

        try
          if (Image = nil) or (Image.Width <= 0) or (Image.Height <= 0) then
            Exit(False);

          Rasterize(Image, Raster);
          Result := not Raster.IsEmpty;
        finally
          Image.Free;
        end;
      finally
        Picture.Free;
      end;
    finally
      Stream.Free;
    end;
  except
    // Bytes out of a document are an outside boundary: what cannot be read is
    // one image that does not appear.
    on Exception do
      Result := False;
  end;
end;

procedure RegisterLclImageDecoder;
begin
  if TMarkdownImageDecoding.IsAvailable then
    Exit;

  TMarkdownImageDecoding.RegisterDecoder(TLclImageDecoder.TryDecode);
end;

initialization
  RegisterLclImageDecoder;

end.
