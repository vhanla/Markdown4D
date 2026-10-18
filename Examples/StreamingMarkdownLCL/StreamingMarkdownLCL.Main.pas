unit StreamingMarkdownLCL.Main;

// The Lazarus (LCL) counterpart of StreamingMarkdownVCL.Main and
// StreamingMarkdownFMX.Main: a chat window whose answers arrive in chunks and
// are re-rendered as the text grows.
//
// The form is built in code instead of from a .lfm, so the whole example is one
// readable unit and needs no resource compiler.  The chunking state machine and
// the sample answer come from StreamingMarkdown.Demo, the same unit the VCL and
// FMX demos use.
//
// Two notes for hosts ported from the VCL:
//   * strings stay UnicodeString (Markdown4D.Fpc.inc selects DELPHIUNICODE), so
//     anything crossing into an LCL property is converted explicitly, because an
//     implicit UnicodeString -> AnsiString conversion is not UTF-8;
//   * the layout timer recomputes each message's height from the viewer's
//     ContentHeight, the same way the other two demos do.

{$I ../../Source/Markdown4D.Fpc.inc}

interface

uses
  Classes,
  Generics.Collections,
  Controls,
  ExtCtrls,
  StdCtrls,
  LCLType,
  Forms,
  Markdown4D.Lcl.Viewer,
  StreamingMarkdown.Demo;

type
  TStreamingMarkdownLCLForm = class(TForm)
  private
    const
      MessageMargin = 8;
      MessageHeightPadding = 12;
      MinMessageHeight = 48;
      MinChunkLength = 30;
      MaxChunkLength = 80;
      MinTickMilliseconds = 30;
      MaxTickMilliseconds = 60;
      UserMessagePrefix = '**You:**'#10#10;
    var
      FMessageViewers: TList<TMarkdownViewer>;
      FStreamingViewer: TMarkdownViewer;
      FCannedResponse: string;
      FStreamer: TMarkdownStreamer;
      FScrollBox: TScrollBox;
      FPromptEdit: TEdit;
      FSendButton: TButton;
      FStreamTimer: TTimer;
      FLayoutTimer: TTimer;
      FContentBottom: Integer;
    procedure BuildControls;
    procedure SendPrompt;
    function AddMessageViewer(const Markdown: string): TMarkdownViewer;
    procedure StartStreaming;
    procedure AppendNextChunk;
    procedure FinishStreaming;
    procedure SyncMessageHeights;
    procedure ScrollMessagesToBottom;
    procedure HandleShow(Sender: TObject);
    procedure HandleSendClick(Sender: TObject);
    procedure HandlePromptKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleStreamTimer(Sender: TObject);
    procedure HandleLayoutTimer(Sender: TObject);
    procedure HandleLinkClick(const Sender: TObject; const Url: string);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    destructor Destroy; override;
  end;

var
  StreamingMarkdownLCLForm: TStreamingMarkdownLCLForm;

implementation

uses
  SysUtils,
  Math,
  LCLIntf,
  Markdown4D.Extensions.Chart.BlockOverride,
  Markdown4D.Extensions.Mermaid.BlockOverride;

constructor TStreamingMarkdownLCLForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);

  // The extensions the canned answer reaches for: charts and Mermaid diagrams
  // are registered per process, exactly as the VCL and FMX demos do.
  TChartBlockOverride.RegisterOverride;
  TMermaidBlockOverride.RegisterOverride;

  Randomize;
  FMessageViewers := TList<TMarkdownViewer>.Create;
  FCannedResponse := TMarkdownStreamer.BuildSampleAnswer;
  FStreamer := TMarkdownStreamer.Create;

  Caption := UTF8Encode('StreamingMarkdown on the LCL');
  Position := poDesigned;
  Left := 160;
  Top := 120;
  Width := 860;
  Height := 660;
  Constraints.MinWidth := 520;
  Constraints.MinHeight := 360;

  BuildControls;

  OnShow := HandleShow;
end;

// Everything below the form is created here; the message stack itself is laid
// out by SyncMessageHeights.
procedure TStreamingMarkdownLCLForm.BuildControls;
var
  Header: TLabel;
  InputPanel: TPanel;
begin
  Header := TLabel.Create(Self);
  Header.Parent := Self;
  Header.Align := alTop;
  Header.BorderSpacing.Left := 12;
  Header.BorderSpacing.Right := 12;
  Header.BorderSpacing.Top := 10;
  Header.BorderSpacing.Bottom := 4;
  Header.Caption := UTF8Encode('Answers stream in and render as they arrive.');

  FScrollBox := TScrollBox.Create(Self);
  FScrollBox.Parent := Self;
  FScrollBox.Align := alClient;
  FScrollBox.BorderStyle := bsNone;
  FScrollBox.HorzScrollBar.Visible := False;

  InputPanel := TPanel.Create(Self);
  InputPanel.Parent := Self;
  InputPanel.Align := alBottom;
  InputPanel.Height := 56;
  InputPanel.BevelOuter := bvNone;

  FSendButton := TButton.Create(Self);
  FSendButton.Parent := InputPanel;
  FSendButton.Align := alRight;
  FSendButton.BorderSpacing.Left := 6;
  FSendButton.BorderSpacing.Right := 12;
  FSendButton.BorderSpacing.Top := 12;
  FSendButton.BorderSpacing.Bottom := 12;
  FSendButton.Width := 96;
  FSendButton.Caption := UTF8Encode('Send');
  FSendButton.OnClick := HandleSendClick;

  FPromptEdit := TEdit.Create(Self);
  FPromptEdit.Parent := InputPanel;
  FPromptEdit.Align := alClient;
  FPromptEdit.BorderSpacing.Left := 12;
  FPromptEdit.BorderSpacing.Right := 6;
  FPromptEdit.BorderSpacing.Top := 14;
  FPromptEdit.BorderSpacing.Bottom := 14;
  FPromptEdit.Text := UTF8Encode('Show me what the viewer can render');
  FPromptEdit.OnKeyDown := HandlePromptKeyDown;

  // The stream timer emits one chunk per tick; its interval is jittered so the
  // arrival pattern looks like a real token stream.
  FStreamTimer := TTimer.Create(Self);
  FStreamTimer.Enabled := False;
  FStreamTimer.OnTimer := HandleStreamTimer;

  // A slower timer re-measures the messages and follows the growing answer.
  FLayoutTimer := TTimer.Create(Self);
  FLayoutTimer.Interval := 60;
  FLayoutTimer.Enabled := True;
  FLayoutTimer.OnTimer := HandleLayoutTimer;
end;

// A chat demo should demonstrate itself: the first show streams the canned
// answer without waiting for a prompt.
procedure TStreamingMarkdownLCLForm.HandleShow(Sender: TObject);
begin
  if FMessageViewers.Count > 0 then
    Exit;

  AddMessageViewer(UserMessagePrefix + 'Describe the renderer');
  StartStreaming;
end;

procedure TStreamingMarkdownLCLForm.HandleSendClick(Sender: TObject);
begin
  SendPrompt;
end;

procedure TStreamingMarkdownLCLForm.HandlePromptKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if Key <> VK_RETURN then
    Exit;

  Key := 0;
  if FSendButton.Enabled then
    SendPrompt;
end;

procedure TStreamingMarkdownLCLForm.SendPrompt;
var
  Prompt: string;
begin
  // The LCL hands back UTF-8 bytes; the viewer wants UTF-16 code units.
  Prompt := Trim(UTF8Decode(FPromptEdit.Text));
  if Prompt = '' then
    Exit;

  AddMessageViewer(UserMessagePrefix + Prompt);
  FPromptEdit.Text := '';
  StartStreaming;
end;

function TStreamingMarkdownLCLForm.AddMessageViewer(const Markdown: string): TMarkdownViewer;
begin
  Result := TMarkdownViewer.Create(Self);
  Result.Parent := FScrollBox;
  // The stack is laid out by SyncMessageHeights, not by the LCL: alTop children
  // are ordered by reverse creation order, which would put the newest message
  // at the top of the chat.
  Result.Align := alNone;
  Result.Height := MinMessageHeight;
  Result.OnLinkClick := HandleLinkClick;
  Result.Text := Markdown;

  FMessageViewers.Add(Result);
end;

procedure TStreamingMarkdownLCLForm.StartStreaming;
begin
  FStreamingViewer := AddMessageViewer('');
  FStreamer.Reset(FCannedResponse);
  FSendButton.Enabled := False;
  FStreamTimer.Interval := MinTickMilliseconds;
  FStreamTimer.Enabled := True;
end;

procedure TStreamingMarkdownLCLForm.HandleStreamTimer(Sender: TObject);
begin
  if not FStreamer.HasMore then
  begin
    FinishStreaming;
    Exit;
  end;

  AppendNextChunk;
end;

procedure TStreamingMarkdownLCLForm.AppendNextChunk;
var
  RequestedLength: Integer;
begin
  RequestedLength := MinChunkLength + Random(MaxChunkLength - MinChunkLength + 1);
  FStreamingViewer.AppendMarkdown(FStreamer.NextChunk(RequestedLength));

  FStreamTimer.Interval := MinTickMilliseconds +
    Random(MaxTickMilliseconds - MinTickMilliseconds + 1);
end;

procedure TStreamingMarkdownLCLForm.FinishStreaming;
begin
  FStreamTimer.Enabled := False;
  FStreamingViewer := nil;
  // One last pass: the final chunk may have grown the answer after the last
  // tick of the layout timer had already run.
  SyncMessageHeights;
  ScrollMessagesToBottom;
  FSendButton.Enabled := True;
  FPromptEdit.SetFocus;
end;

// A viewer paints from its own model, so nothing tells it how tall its content
// is: the stack is measured and laid out here, top to bottom, and the height of
// every message is the height the layout engine reports for the current width.
procedure TStreamingMarkdownLCLForm.SyncMessageHeights;
var
  Viewer: TMarkdownViewer;
  DesiredHeight: Integer;
  NextTop: Integer;
begin
  NextTop := MessageMargin;

  for Viewer in FMessageViewers do
  begin
    DesiredHeight := Max(MinMessageHeight, Viewer.ContentHeight + MessageHeightPadding);
    Viewer.SetBounds(MessageMargin, NextTop,
      Max(0, FScrollBox.ClientWidth - 2 * MessageMargin), DesiredHeight);
    Inc(NextTop, DesiredHeight + MessageMargin);
  end;

  // Where the content ends, for the scroll box and for ScrollMessagesToBottom.
  FContentBottom := NextTop;
end;

procedure TStreamingMarkdownLCLForm.HandleLayoutTimer(Sender: TObject);
begin
  SyncMessageHeights;

  if FStreamingViewer <> nil then
    ScrollMessagesToBottom;
end;

// The scroll box is told where the content ends instead of trusting its own
// auto range, which lags the height the layout engine has just asked for.
procedure TStreamingMarkdownLCLForm.ScrollMessagesToBottom;
var
  Target: Integer;
begin
  Target := FContentBottom - FScrollBox.ClientHeight;
  if Target > FScrollBox.VertScrollBar.Range then
    Target := FScrollBox.VertScrollBar.Range;
  if Target < 0 then
    Target := 0;

  FScrollBox.VertScrollBar.Position := Target;
end;

procedure TStreamingMarkdownLCLForm.HandleLinkClick(const Sender: TObject;
  const Url: string);
begin
  if (Pos('http://', Url) = 1) or (Pos('https://', Url) = 1) then
    OpenURL(UTF8Encode(Url));
end;

destructor TStreamingMarkdownLCLForm.Destroy;
begin
  FStreamer.Free;
  FMessageViewers.Free;

  inherited Destroy;
end;

end.
