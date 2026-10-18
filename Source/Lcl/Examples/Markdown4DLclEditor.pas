program Markdown4DLclEditor;

// Visual smoke test for the LCL editor control.  It puts a markdown source pane
// next to a live preview of the same document and shows the pieces a host needs
// to see working: line numbers, syntax highlighting, match highlighting, the
// caret, the scrollbar, and the two-way preview link.
//
//   Markdown4DLclEditor [caret-offset]
//
// The optional argument places the caret at that source offset, so a screenshot
// can show it.  Diagnostics (text length, caret, match count, client size,
// whether the native bar is up, the preview's length) go to stdout.

{$I ../../Markdown4D.Fpc.inc}

uses
  // The preview's image downloader runs on TTask, which links FPC's
  // System.Threading; on Unix that requires cthreads to be the very first unit,
  // or its thread pool crashes while the units initialize.
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  Math,
  Interfaces,
  Forms,
  Controls,
  ExtCtrls,
  Markdown4D.Lcl.Editor,
  Markdown4D.Lcl.Viewer;

const
  FormWidth = 1360;
  FormHeight = 820;
  EditorWidth = 640;
  MatchNeedle = 'paragraph';

type
  TEditorForm = class(TForm)
  private
    FEditor: TMarkdownEditor;
    FPreview: TMarkdownViewer;
    FSplitter: TSplitter;
    FReport: TTimer;
    FCaretOffset: Integer;
    FApplied: Boolean;
    FWatching: Boolean;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure HandleReport(Sender: TObject);
  end;

function SampleSource: string;
var
  Lines: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('# Markdown4D editor on LCL');
    Lines.Add('');
    Lines.Add('The pane on the left is the source, the one on the right is the');
    Lines.Add('preview, and they scroll together while **SyncScroll** is on.');
    Lines.Add('');
    Lines.Add('## A list');
    Lines.Add('');
    Lines.Add('- plain item');
    Lines.Add('- [x] a completed task');
    Lines.Add('- [ ] a pending task');
    Lines.Add('');
    Lines.Add('## Table');
    Lines.Add('');
    Lines.Add('| Pane   | Shows           |');
    Lines.Add('| ------ | --------------- |');
    Lines.Add('| left   | the source text |');
    Lines.Add('| right  | the preview     |');
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
    Lines.Add('## A long section');
    Lines.Add('');
    for Index := 1 to 10 do
    begin
      Lines.Add(Format('Paragraph %d. The quick brown fox jumps over the lazy dog ' +
        'while the editor wraps and measures one row at a time. Tap Tab to ' +
        'indent and Shift+Tab to outdent, or Ctrl+Z to undo.', [Index]));
      Lines.Add('');
    end;

    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

constructor TEditorForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);

  Caption := 'Markdown4D LCL Editor';
  Position := poDesigned;
  Left := 60;
  Top := 60;
  Width := FormWidth;
  Height := FormHeight;

  FEditor := TMarkdownEditor.Create(Self);
  FEditor.Parent := Self;
  FEditor.Align := alLeft;
  FEditor.Width := EditorWidth;
  FEditor.ShowLineNumbers := True;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alLeft;
  FSplitter.Width := 4;

  FPreview := TMarkdownViewer.Create(Self);
  FPreview.Parent := Self;
  FPreview.Align := alClient;

  FEditor.Preview := FPreview;
  FEditor.Text := SampleSource;

  if ParamCount >= 1 then
    FCaretOffset := StrToIntDef(ParamStr(1), 0);

  // A watcher keeps the line coming, so an interaction test can drive the
  // control with xdotool and read the state back from stdout.
  FWatching := GetEnvironmentVariable('MD4D_WATCH') <> '';

  FReport := TTimer.Create(Self);
  FReport.Interval := 1200;
  FReport.OnTimer := HandleReport;
end;

procedure TEditorForm.HandleReport(Sender: TObject);
var
  Around: string;
begin
  if not FApplied then
  begin
    FApplied := True;
    FEditor.HighlightMatches(MatchNeedle);
    if FCaretOffset > 0 then
      FEditor.CaretPosition := FCaretOffset;
    FEditor.SetFocus;
  end;

  Around := Copy(FEditor.Text, Max(1, FEditor.CaretPosition - 12), 24);
  Around := StringReplace(Around, #10, '\n', [rfReplaceAll]);
  Around := StringReplace(Around, #13, '\r', [rfReplaceAll]);

  WriteLn('text=', Length(FEditor.Text),
    ' caret=', FEditor.CaretPosition,
    ' matches=', FEditor.HighlightCount,
    ' selected=', Length(FEditor.SelectedText),
    ' line=', FEditor.FirstVisibleSourceLine,
    ' autoscroll=', BoolToStr(FEditor.IsAutoScrolling, True),
    ' undo=', BoolToStr(FEditor.CanUndo, True),
    ' redo=', BoolToStr(FEditor.CanRedo, True),
    ' client=', FEditor.ClientWidth, 'x', FEditor.ClientHeight,
    ' scrollbar=', BoolToStr(FEditor.VertScrollBar.IsScrollBarVisible, True),
    ' preview=', Length(FPreview.Text),
    ' at="', Around, '"');
  Flush(Output);

  FReport.Enabled := FWatching;
end;

var
  Form: TEditorForm;
begin
  Application.Initialize;
  Form := TEditorForm.CreateNew(nil);
  Form.Show;
  Application.Run;
end.
