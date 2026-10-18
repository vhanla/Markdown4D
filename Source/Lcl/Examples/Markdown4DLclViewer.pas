program Markdown4DLclViewer;

// Visual smoke test for the LCL viewer control.  It builds a document that
// exercises the shell's wiring -- headings, lists, a task list, a table, a
// fenced code block with its copy button, an inline SVG image, and enough text
// to scroll -- and shows it in a window.
//
//   Markdown4DLclViewer [scroll-offset]
//
// The optional argument scrolls the view that many pixels after a moment, so a
// screenshot can be taken from a scrolled position.  Diagnostics (content size,
// client size, whether the native bar is up) go to stdout.

{$I ../../Markdown4D.Fpc.inc}

uses
  // The viewer's image downloader runs on TTask, which links FPC's
  // System.Threading; on Unix that requires cthreads to be the very first unit,
  // or its thread pool crashes while the units initialize.
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  Interfaces,
  Forms,
  Controls,
  ExtCtrls,
  Markdown4D.Lcl.Viewer;

const
  ViewerWidth = 1000;
  ViewerHeight = 760;

type
  TViewerForm = class(TForm)
  private
    FViewer: TMarkdownViewer;
    FReport: TTimer;
    FScrollOffset: Integer;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure HandleReport(Sender: TObject);
  end;

function SampleDocument: string;
var
  Lines: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('# Markdown4D on LCL');
    Lines.Add('');
    Lines.Add('A **bold** and *italic* run, some `inline code`, and a');
    Lines.Add('[link](https://example.com) that the control turns into a hand cursor.');
    Lines.Add('');
    Lines.Add('## Lists');
    Lines.Add('');
    Lines.Add('- Nested lists');
    Lines.Add('- [x] A completed task');
    Lines.Add('- [ ] A pending task');
    Lines.Add('  - with a nested item under it');
    Lines.Add('');
    Lines.Add('1. First');
    Lines.Add('2. Second');
    Lines.Add('3. Third');
    Lines.Add('');
    Lines.Add('> A block quote that wraps over a couple of lines, so that the');
    Lines.Add('> quote bar and the muted text are both visible.');
    Lines.Add('');
    Lines.Add('## Table');
    Lines.Add('');
    Lines.Add('| Feature | State |');
    Lines.Add('| ------- | ----- |');
    Lines.Add('| Painter | done  |');
    Lines.Add('| Viewer  | here  |');
    Lines.Add('| Editor  | next  |');
    Lines.Add('');
    Lines.Add('## Inline SVG');
    Lines.Add('');
    Lines.Add('![a native SVG](/tmp/opencode/demo.svg)');
    Lines.Add('');
    Lines.Add('## A fenced code block');
    Lines.Add('');
    Lines.Add('```pascal');
    Lines.Add('procedure Hello(const Who: string);');
    Lines.Add('begin');
    Lines.Add('  WriteLn(''hello '', Who);');
    Lines.Add('end;');
    Lines.Add('```');
    Lines.Add('');
    Lines.Add('## A long section, so the control has to scroll');
    Lines.Add('');
    for Index := 1 to 14 do
    begin
      Lines.Add(Format('Paragraph %d. The quick brown fox jumps over the lazy dog while the ' +
        'layout engine measures one line at a time. A second sentence makes this ' +
        'paragraph wrap onto several lines of its own.', [Index]));
      Lines.Add('');
    end;

    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

constructor TViewerForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);

  Caption := 'Markdown4D LCL Viewer';
  Position := poDesigned;
  Left := 60;
  Top := 60;
  Width := ViewerWidth;
  Height := ViewerHeight;

  FViewer := TMarkdownViewer.Create(Self);
  FViewer.Parent := Self;
  FViewer.Align := alClient;
  FViewer.Text := SampleDocument;

  if ParamCount >= 1 then
    FScrollOffset := StrToIntDef(ParamStr(1), 0);

  FReport := TTimer.Create(Self);
  FReport.Interval := 1200;
  FReport.OnTimer := HandleReport;
end;

procedure TViewerForm.HandleReport(Sender: TObject);
begin
  FReport.Enabled := False;

  if FScrollOffset <> 0 then
    FViewer.ScrollOffset := FScrollOffset;

  WriteLn('content=', FViewer.ContentHeight,
    ' client=', FViewer.ClientWidth, 'x', FViewer.ClientHeight,
    ' scrollbar=', BoolToStr(FViewer.VertScrollBar.IsScrollBarVisible, True),
    ' offset=', Round(FViewer.ScrollOffset),
    ' layouts=', FViewer.LayoutCount);
  Flush(Output);
end;

var
  Form: TViewerForm;
begin
  Application.Initialize;
  Form := TViewerForm.CreateNew(nil);
  Form.Show;
  Application.Run;
end.
