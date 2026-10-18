program Markdown4DLclRender;

// Headless(ish) smoke test for the LCL painter: parse a sample document, lay it
// out against a TMarkdownLclPainter over an offscreen TBitmap, render the
// display list, and write the result out as a PNG.  Run under any X/Qt/GTK
// session (or Xvfb) with the LCL unit paths on the search path.

{$I ../../Markdown4D.Fpc.inc}

uses
  Interfaces,
  Forms,
  Graphics,
  SysUtils,
  Markdown4D,
  Markdown4D.Defines,
  Markdown4D.Ast.Interfaces,
  Markdown4D.Theme,
  Markdown4D.Layout.Interfaces,
  Markdown4D.Layout.Defaults,
  Markdown4D.Layout.Engine,
  Markdown4D.Layout.Renderer,
  Markdown4D.Layout.DisplayList,
  Markdown4D.Lcl.ImageDecoder,
  Markdown4D.Lcl.MathFont,
  Markdown4D.Lcl.Painter;

const
  SampleMarkdown =
    '# Markdown4D on LCL' + #10 +
    '' + #10 +
    'A **bold** and *italic* run, some `inline code`, and a [link](https://example.com).' + #10 +
    '' + #10 +
    '## Highlights' + #10 +
    '' + #10 +
    '- Nested lists' + #10 +
    '- [x] A completed task' + #10 +
    '- [ ] A pending task' + #10 +
    '- ' + #10 +
    '  - with' + #10 +
    '  - children' + #10 +
    '' + #10 +
    '> A block quote with a semi-transparent background.' + #10 +
    '' + #10 +
    '```pascal' + #10 +
    'begin' + #10 +
    '  WriteLn(''Hello, Markdown4D'');' + #10 +
    'end.' + #10 +
    '```' + #10 +
    '' + #10 +
    '| Column | Value |' + #10 +
    '| ------ | ----- |' + #10 +
    '| alpha  | 1     |' + #10 +
    '| beta   | 2     |' + #10 +
    '' + #10 +
    'Inline math: $E = mc^2$, and a displayed one:' + #10 +
    '' + #10 +
    '$$\int_0^1 x^2\,dx = \frac{1}{3}$$' + #10;

  BitmapWidth = 760;
  BitmapHeight = 900;

function RenderToBitmap(const MarkdownText: string; const Theme: TMarkdownTheme;
  const Bitmap: TBitmap): IMarkdownDisplayList;
var
  Painter: IPainter;
  Document: IMarkdownDocument;
  Viewport: TLayoutRectF;
begin
  Bitmap.SetSize(BitmapWidth, BitmapHeight);

  Painter := TMarkdownLclPainter.Create(Bitmap.Canvas);
  Document := TMarkdown.Parse(MarkdownText, TMarkdownDialect.Gfm);
  Result := TMarkdownLayoutEngine.LayoutDocument(Document, BitmapWidth, Theme, Painter);

  Viewport := TLayoutRectF.Create(0, 0, BitmapWidth, BitmapHeight);
  TMarkdownDisplayListRenderer.Render(Result, Painter, Viewport, Theme.BackgroundColor);
end;

var
  Bitmap: TBitmap;
  DisplayList: IMarkdownDisplayList;
  OutputPath: string;
begin
  Application.Initialize;

  Bitmap := TBitmap.Create;
  try
    DisplayList := RenderToBitmap(SampleMarkdown, TMarkdownTheme.CreateLight, Bitmap);
    if (DisplayList = nil) or (DisplayList.ItemCount = 0) then
      raise Exception.Create('layout produced an empty display list');

    OutputPath := ParamStr(1);
    if OutputPath = '' then
      OutputPath := 'markdown4d-lcl.png';
    Bitmap.SaveToFile(OutputPath);
    WriteLn('wrote ', OutputPath, ' (', Bitmap.Width, 'x', Bitmap.Height,
      ', ', DisplayList.ItemCount, ' display items)');
  finally
    Bitmap.Free;
  end;
end.
