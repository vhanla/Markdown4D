unit Markdown4DStudioLCL.Main;

// Markdown4D Studio on the LCL -- the Lazarus counterpart of
// Markdown4DStudioVCL and Markdown4DStudioFMX: an editor with a live preview, a
// contents panel built from the headings, formatting commands, find and
// replace, zoom, a light and a dark theme, and HTML export.
//
// As in the other two Studios one editor and one viewer are shared by every
// open document; each document hands its caret, its selection and its preview
// scroll position to the document it belongs to when the reader switches tabs,
// and gets them back on the way in.
//
// The form is built in code rather than from a .lfm, so the whole example is
// readable without the designer and no resource compiler is needed.  Two notes
// for hosts ported from the VCL:
//
//   * strings stay UnicodeString (Markdown4D.Fpc.inc selects DELPHIUNICODE), so
//     every string on its way into an LCL property is converted explicitly;
//   * the LCL stretches alTop / alLeft children in reverse creation order, so
//     the few places where the order matters say which control must be created
//     last, and everything else is placed with explicit bounds.

{$I ../../Source/Markdown4D.Fpc.inc}

interface

uses
  Classes,
  SysUtils,
  Controls,
  ExtCtrls,
  StdCtrls,
  ComCtrls,
  Menus,
  Dialogs,
  Clipbrd,
  Graphics,
  LCLType,
  Forms,
  Generics.Collections,
  Markdown4D.Defines,
  Markdown4D.Ast.Interfaces,
  Markdown4D.Toc,
  Markdown4D.Editor.Model,
  Markdown4D.Theme,
  Markdown4D.Lcl.Editor,
  Markdown4D.Lcl.Viewer,
  Markdown4DStudioLCL.Documents;

type
  // Which panes the workspace shows.
  TStudioViewMode = (EditorOnly, Split, PreviewOnly);

  // What a toolbar button does when it is not a formatting command.
  TStudioAction = (taNew, taOpen, taSave, taEditor, taSplit, taPreview,
    taOutline, taTheme, taZen);

  TStudioLCLForm = class(TForm)
  private
    const
      OutlineWidth = 240;
      ToolBarHeight = 34;
      FindBarHeight = 34;
      StatusBarHeight = 26;
      OutlineDelayMilliseconds = 350;
      DefaultSplitRatio = 0.62;
      MinPaneWidth = 160;
    var
      FDocuments: TStudioDocuments;
      FDocument: TStudioDocument;
      FParsed: IMarkdownDocument;
      FToc: IMarkdownToc;
      FOutlineAnchors: TArray<string>;
      FOutlineLines: TArray<Integer>;
      FViewMode: TStudioViewMode;
      FThemeDark: Boolean;
      FZen: Boolean;
      FOutlineVisible: Boolean;
      FSplitRatio: Single;
      FLoading: Boolean;
      FUpdatingTabs: Boolean;
      FWordCount: Integer;
      FCharacterCount: Integer;
      FToolItems: TList<TControl>;
      // Chrome, top to bottom: the toolbar, the find bar, the contents panel,
      // the workspace and the status strip.
      FMenu: TMainMenu;
      FToolBar: TPanel;
      FFindPanel: TPanel;
      FFindEdit: TEdit;
      FReplaceEdit: TEdit;
      FFindStatus: TLabel;
      FMatchCaseBox: TCheckBox;
      FWholeWordBox: TCheckBox;
      FOutlinePanel: TPanel;
      FOutlineList: TListBox;
      FOutlineSplitter: TSplitter;
      FWorkspace: TPanel;
      FTabs: TTabControl;
      FEditor: TMarkdownEditor;
      FPreviewSplitter: TSplitter;
      FViewer: TMarkdownViewer;
      FStatusStrip: TPanel;
      FStatusPosition: TLabel;
      FStatusInfo: TLabel;
      FOutlineTimer: TTimer;
      FOpenDialog: TOpenDialog;
      FSaveDialog: TSaveDialog;
      FHtmlDialog: TSaveDialog;
      FUndoItem: TMenuItem;
      FRedoItem: TMenuItem;
      FViewModeItems: array[TStudioViewMode] of TMenuItem;
      FThemeItems: array[Boolean] of TMenuItem;
      FOutlineItem: TMenuItem;
      FLinesItem: TMenuItem;
      FZenItem: TMenuItem;
    procedure BuildChrome;
    procedure BuildMenus;
    procedure BuildToolBar;
    procedure BuildFindBar;
    procedure BuildOutlinePanel;
    procedure BuildWorkspace;
    procedure BuildStatusStrip;
    function AddMenuItem(const Parent: TMenuItem; const Caption: string;
      const ShortCut: TShortCut; const OnClick: TNotifyEvent): TMenuItem;
    function AddSubMenu(const Parent: TMenuItem; const Caption: string): TMenuItem;
    procedure AddMenuSeparator(const Parent: TMenuItem);
    function AddMenuCommand(const Parent: TMenuItem; const Caption: string;
      const ShortCut: TShortCut; const Command: TEditorCommand): TMenuItem;
    function CreateToolItem: TButton;
    function AddToolButton(const Caption: string; const OnClick: TNotifyEvent): TButton;
    procedure AddToolSeparator;
    procedure LayoutToolBar;
    // Documents.
    procedure NewDocument;
    procedure OpenDocument;
    procedure OpenFile(const FileName: string);
    procedure CloseActiveDocument;
    function SaveDocument(const Document: TStudioDocument; const ForceDialog: Boolean): Boolean;
    function EnsureSaved: Boolean;
    procedure ActivateDocument(const Index: Integer);
    procedure ShowDocument(const Document: TStudioDocument);
    procedure StoreDocumentState;
    procedure SyncTabs;
    procedure UpdateTabCaption;
    procedure UpdateWindowCaption;
    // Contents.
    procedure ScheduleOutline;
    procedure RebuildOutline;
    // The table of contents is a tree of headings; the panel shows it flat,
    // indented by level, in reading order.
    procedure AppendOutlineEntry(const Entry: IMarkdownTocEntry);
    procedure HandleOutlineClick(Sender: TObject);
    // Find and replace.
    procedure ShowFindBar(const WithReplace: Boolean);
    procedure HideFindBar;
    function FindNeedle: string;
    function FindOptions: TMarkdownFindOptions;
    procedure UpdateFindMarks;
    procedure GoToMatch(const Forward: Boolean);
    procedure ReplaceMatch;
    procedure ReplaceEveryMatch;
    // Status line.
    procedure RecountText;
    procedure UpdateStatus;
    procedure UpdateUndoRedo;
    // View.
    procedure SetViewMode(const Mode: TStudioViewMode);
    procedure ApplyViewMode;
    function SplitEditorWidth: Integer;
    procedure SetTheme(const Dark: Boolean);
    procedure ToggleOutline;
    procedure ToggleZen;
    procedure ApplyChrome;
    // Handlers.
    procedure HandleNewClick(Sender: TObject);
    procedure HandleOpenClick(Sender: TObject);
    procedure HandleSaveClick(Sender: TObject);
    procedure HandleSaveAsClick(Sender: TObject);
    procedure HandleCloseClick(Sender: TObject);
    procedure HandleExportHtmlClick(Sender: TObject);
    procedure HandleCopyHtmlClick(Sender: TObject);
    procedure HandleExitClick(Sender: TObject);
    procedure HandleUndoClick(Sender: TObject);
    procedure HandleRedoClick(Sender: TObject);
    procedure HandleCutClick(Sender: TObject);
    procedure HandleCopyClick(Sender: TObject);
    procedure HandlePasteClick(Sender: TObject);
    procedure HandleSelectAllClick(Sender: TObject);
    procedure HandleFindClick(Sender: TObject);
    procedure HandleFindCloseClick(Sender: TObject);
    procedure HandleReplaceClick(Sender: TObject);
    procedure HandleReplaceOneClick(Sender: TObject);
    procedure HandleReplaceAllClick(Sender: TObject);
    procedure HandleFindNextClick(Sender: TObject);
    procedure HandleFindPreviousClick(Sender: TObject);
    procedure HandleFormatClick(Sender: TObject);
    procedure HandleToolActionClick(Sender: TObject);
    procedure HandleViewModeClick(Sender: TObject);
    procedure HandleOutlineToggleClick(Sender: TObject);
    procedure HandleLineNumbersClick(Sender: TObject);
    procedure HandleZoomInClick(Sender: TObject);
    procedure HandleZoomOutClick(Sender: TObject);
    procedure HandleZoomResetClick(Sender: TObject);
    procedure HandleThemeClick(Sender: TObject);
    procedure HandleZenClick(Sender: TObject);
    procedure HandleAboutClick(Sender: TObject);
    procedure HandleReferenceClick(Sender: TObject);
    procedure HandleEditorChange(Sender: TObject);
    procedure HandleEditorZoomChange(Sender: TObject);
    procedure HandleEditorScroll(Sender: TObject);
    procedure HandleViewerLinkClick(const Sender: TObject; const Url: string);
    // A diagram that fails to lay out would otherwise just leave a gap.
    procedure HandleViewerExtensionError(const Sender: TObject; const Extension: string;
      const Error: Exception);
    procedure HandleFindChanged(Sender: TObject);
    procedure HandleFindKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleTabsChanging(Sender: TObject; var AllowChange: Boolean);
    procedure HandleTabsChange(Sender: TObject);
    procedure HandleOutlineTimer(Sender: TObject);
    procedure HandleResize(Sender: TObject);
    procedure HandleSplitMoved(Sender: TObject);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
    // Focusing a control of a form that is not on screen yet is an error in the
    // LCL, and the very first document is opened from the constructor.
    procedure FocusEditor;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    destructor Destroy; override;
    // Opens the document named on the command line, so the example can be run
    // against any file: Markdown4DStudioLCL ../Shared/demo.md
    procedure OpenStartupDocument;
  end;

var
  StudioForm: TStudioLCLForm;

implementation

uses
  Math,
  LCLIntf,
  Markdown4D,
  Markdown4D.Extensions.Chart.BlockOverride,
  Markdown4D.Extensions.Mermaid.BlockOverride,
  Markdown4DStudioLCL.Html;

// Declared here because the window opens its first document before the body
// below is reached.
function WelcomeText: string; forward;

{ The window }

constructor TStudioLCLForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);

  // The extensions the demo document reaches for: charts and Mermaid diagrams
  // are registered per process, exactly as the VCL and FMX Studios do.
  TChartBlockOverride.RegisterOverride;
  TMermaidBlockOverride.RegisterOverride;

  FDocuments := TStudioDocuments.Create;
  FToolItems := TList<TControl>.Create;
  FSplitRatio := DefaultSplitRatio;
  FOutlineVisible := True;
  FViewMode := TStudioViewMode.Split;

  Caption := UTF8Encode('Markdown4D Studio');
  Position := poDesigned;
  Left := 80;
  Top := 60;
  Width := 1200;
  Height := 820;
  Constraints.MinWidth := 640;
  Constraints.MinHeight := 420;

  FOpenDialog := TOpenDialog.Create(Self);
  FOpenDialog.Filter := UTF8Encode('Markdown files|*.md;*.markdown;*.mdown;*.txt|All files|*');
  FOpenDialog.Options := FOpenDialog.Options + [ofFileMustExist];
  FOpenDialog.InitialDir := UTF8Encode(ExtractFileDir(Application.ExeName));

  FSaveDialog := TSaveDialog.Create(Self);
  FSaveDialog.Filter := UTF8Encode('Markdown files|*.md;*.markdown|All files|*');
  FSaveDialog.DefaultExt := UTF8Encode('md');
  FSaveDialog.Options := FSaveDialog.Options + [ofOverwritePrompt];

  FHtmlDialog := TSaveDialog.Create(Self);
  FHtmlDialog.Filter := UTF8Encode('HTML files|*.html;*.htm|All files|*');
  FHtmlDialog.DefaultExt := UTF8Encode('html');
  FHtmlDialog.Options := FHtmlDialog.Options + [ofOverwritePrompt];

  BuildChrome;

  FEditor.Preview := FViewer;
  FEditor.SyncScroll := True;

  ApplyViewMode;
  ApplyChrome;
  SetTheme(False);
  FLinesItem.Checked := True;
  FOutlineItem.Checked := True;

  NewDocument;

  OnCloseQuery := HandleCloseQuery;
end;

destructor TStudioLCLForm.Destroy;
begin
  FToolItems.Free;
  FDocuments.Free;

  inherited Destroy;
end;

procedure TStudioLCLForm.OpenStartupDocument;
begin
  if ParamCount >= 1 then
    OpenFile(UTF8Decode(ParamStr(1)));
end;

procedure TStudioLCLForm.BuildChrome;
begin
  // The order below is the order the LCL aligns them in only where it does not
  // matter: the workspace fills, the status strip takes the bottom, and the two
  // top bars are created bottom-bar-first because an alTop child placed last
  // sits above the ones before it.
  BuildWorkspace;
  BuildStatusStrip;
  BuildFindBar;
  BuildToolBar;
  BuildOutlinePanel;
  BuildMenus;
end;

{ Menus }

function TStudioLCLForm.AddSubMenu(const Parent: TMenuItem; const Caption: string): TMenuItem;
begin
  Result := TMenuItem.Create(Self);
  Result.Caption := UTF8Encode(Caption);
  Parent.Add(Result);
end;

function TStudioLCLForm.AddMenuItem(const Parent: TMenuItem; const Caption: string;
  const ShortCut: TShortCut; const OnClick: TNotifyEvent): TMenuItem;
begin
  Result := AddSubMenu(Parent, Caption);
  Result.ShortCut := ShortCut;
  Result.OnClick := OnClick;
end;

procedure TStudioLCLForm.AddMenuSeparator(const Parent: TMenuItem);
var
  Item: TMenuItem;
begin
  Item := TMenuItem.Create(Self);
  Item.Caption := '-';
  Parent.Add(Item);
end;

// The command travels on Tag, so one handler serves every formatting item.
function TStudioLCLForm.AddMenuCommand(const Parent: TMenuItem; const Caption: string;
  const ShortCut: TShortCut; const Command: TEditorCommand): TMenuItem;
begin
  Result := AddMenuItem(Parent, Caption, ShortCut, HandleFormatClick);
  Result.Tag := Ord(Command);
end;

procedure TStudioLCLForm.BuildMenus;
var
  FileMenu, EditMenu, FormatMenu, ViewMenu, HelpMenu, ThemeMenu: TMenuItem;
begin
  FMenu := TMainMenu.Create(Self);
  Menu := FMenu;

  FileMenu := AddSubMenu(FMenu.Items, '&File');
  AddMenuItem(FileMenu, '&New', ShortCut(Ord('N'), [ssCtrl]), HandleNewClick);
  AddMenuItem(FileMenu, '&Open...', ShortCut(Ord('O'), [ssCtrl]), HandleOpenClick);
  AddMenuItem(FileMenu, '&Save', ShortCut(Ord('S'), [ssCtrl]), HandleSaveClick);
  AddMenuItem(FileMenu, 'Save &As...', ShortCut(Ord('S'), [ssCtrl, ssShift]), HandleSaveAsClick);
  AddMenuSeparator(FileMenu);
  AddMenuItem(FileMenu, '&Export HTML...', 0, HandleExportHtmlClick);
  AddMenuItem(FileMenu, 'Cop&y HTML to clipboard', 0, HandleCopyHtmlClick);
  AddMenuSeparator(FileMenu);
  AddMenuItem(FileMenu, '&Close', ShortCut(Ord('W'), [ssCtrl]), HandleCloseClick);
  AddMenuItem(FileMenu, 'E&xit', 0, HandleExitClick);

  EditMenu := AddSubMenu(FMenu.Items, '&Edit');
  FUndoItem := AddMenuItem(EditMenu, '&Undo', ShortCut(Ord('Z'), [ssCtrl]), HandleUndoClick);
  FRedoItem := AddMenuItem(EditMenu, '&Redo', ShortCut(Ord('Y'), [ssCtrl]), HandleRedoClick);
  AddMenuSeparator(EditMenu);
  AddMenuItem(EditMenu, 'Cu&t', ShortCut(Ord('X'), [ssCtrl]), HandleCutClick);
  AddMenuItem(EditMenu, '&Copy', ShortCut(Ord('C'), [ssCtrl]), HandleCopyClick);
  AddMenuItem(EditMenu, '&Paste', ShortCut(Ord('V'), [ssCtrl]), HandlePasteClick);
  AddMenuSeparator(EditMenu);
  AddMenuItem(EditMenu, 'Select &All', ShortCut(Ord('A'), [ssCtrl]), HandleSelectAllClick);
  AddMenuSeparator(EditMenu);
  AddMenuItem(EditMenu, '&Find...', ShortCut(Ord('F'), [ssCtrl]), HandleFindClick);
  AddMenuItem(EditMenu, 'Find &Next', ShortCut(VK_F3, []), HandleFindNextClick);
  AddMenuItem(EditMenu, 'Find &Previous', ShortCut(VK_F3, [ssShift]), HandleFindPreviousClick);
  AddMenuItem(EditMenu, '&Replace...', ShortCut(Ord('H'), [ssCtrl]), HandleReplaceClick);

  FormatMenu := AddSubMenu(FMenu.Items, 'F&ormat');
  AddMenuCommand(FormatMenu, '&Bold', ShortCut(Ord('B'), [ssCtrl]), TEditorCommand.Bold);
  AddMenuCommand(FormatMenu, '&Italic', ShortCut(Ord('I'), [ssCtrl]), TEditorCommand.Italic);
  AddMenuCommand(FormatMenu, '&Strikethrough', 0, TEditorCommand.Strikethrough);
  AddMenuCommand(FormatMenu, '&Link', ShortCut(Ord('K'), [ssCtrl]), TEditorCommand.Link);
  AddMenuSeparator(FormatMenu);
  AddMenuCommand(FormatMenu, 'Heading &1', ShortCut(Ord('1'), [ssCtrl, ssAlt]), TEditorCommand.Heading1);
  AddMenuCommand(FormatMenu, 'Heading &2', ShortCut(Ord('2'), [ssCtrl, ssAlt]), TEditorCommand.Heading2);
  AddMenuCommand(FormatMenu, 'Heading &3', ShortCut(Ord('3'), [ssCtrl, ssAlt]), TEditorCommand.Heading3);
  AddMenuSeparator(FormatMenu);
  AddMenuCommand(FormatMenu, '&Bullet list', 0, TEditorCommand.BulletList);
  AddMenuCommand(FormatMenu, '&Numbered list', 0, TEditorCommand.NumberedList);
  AddMenuCommand(FormatMenu, '&Quote', 0, TEditorCommand.Quote);
  AddMenuCommand(FormatMenu, 'Code &block', 0, TEditorCommand.CodeBlock);
  AddMenuCommand(FormatMenu, '&Table', 0, TEditorCommand.Table);

  ViewMenu := AddSubMenu(FMenu.Items, '&View');
  FViewModeItems[TStudioViewMode.EditorOnly] :=
    AddMenuItem(ViewMenu, '&Editor only', ShortCut(Ord('1'), [ssCtrl]), HandleViewModeClick);
  FViewModeItems[TStudioViewMode.Split] :=
    AddMenuItem(ViewMenu, '&Split', ShortCut(Ord('2'), [ssCtrl]), HandleViewModeClick);
  FViewModeItems[TStudioViewMode.PreviewOnly] :=
    AddMenuItem(ViewMenu, '&Preview only', ShortCut(Ord('3'), [ssCtrl]), HandleViewModeClick);
  FViewModeItems[TStudioViewMode.EditorOnly].Tag := Ord(TStudioViewMode.EditorOnly);
  FViewModeItems[TStudioViewMode.Split].Tag := Ord(TStudioViewMode.Split);
  FViewModeItems[TStudioViewMode.PreviewOnly].Tag := Ord(TStudioViewMode.PreviewOnly);
  AddMenuSeparator(ViewMenu);
  FOutlineItem := AddMenuItem(ViewMenu, 'Contents &panel', ShortCut(VK_F4, []), HandleOutlineToggleClick);
  FLinesItem := AddMenuItem(ViewMenu, 'Line &numbers', 0, HandleLineNumbersClick);
  AddMenuSeparator(ViewMenu);
  AddMenuItem(ViewMenu, 'Zoom &in', 0, HandleZoomInClick);
  AddMenuItem(ViewMenu, 'Zoom &out', 0, HandleZoomOutClick);
  AddMenuItem(ViewMenu, '&Reset zoom', ShortCut(Ord('0'), [ssCtrl]), HandleZoomResetClick);
  AddMenuSeparator(ViewMenu);
  ThemeMenu := AddSubMenu(ViewMenu, '&Theme');
  FThemeItems[False] := AddMenuItem(ThemeMenu, '&Light', 0, HandleThemeClick);
  FThemeItems[True] := AddMenuItem(ThemeMenu, '&Dark', 0, HandleThemeClick);
  FThemeItems[False].Tag := 0;
  FThemeItems[True].Tag := 1;
  AddMenuSeparator(ViewMenu);
  FZenItem := AddMenuItem(ViewMenu, '&Zen mode', ShortCut(VK_F11, []), HandleZenClick);

  HelpMenu := AddSubMenu(FMenu.Items, '&Help');
  AddMenuItem(HelpMenu, 'Markdown &reference', 0, HandleReferenceClick);
  AddMenuSeparator(HelpMenu);
  AddMenuItem(HelpMenu, '&About Markdown4D', 0, HandleAboutClick);
end;

{ Toolbar }

function TStudioLCLForm.CreateToolItem: TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FToolBar;
  Result.AutoSize := False;
  Result.Top := 4;
  Result.Height := ToolBarHeight - 8;
  // Placed by LayoutToolBar, which keeps the order they were declared in.
  FToolItems.Add(Result);
end;

function TStudioLCLForm.AddToolButton(const Caption: string;
  const OnClick: TNotifyEvent): TButton;
begin
  Result := CreateToolItem;
  Result.Caption := UTF8Encode(Caption);
  Result.Width := 16 + Length(Caption) * 7;
  Result.OnClick := OnClick;
end;

procedure TStudioLCLForm.AddToolSeparator;
var
  Bevel: TBevel;
begin
  Bevel := TBevel.Create(Self);
  Bevel.Parent := FToolBar;
  Bevel.Shape := bsLeftLine;
  Bevel.Top := 6;
  Bevel.Height := ToolBarHeight - 12;
  Bevel.Width := 2;
  FToolItems.Add(Bevel);
end;

procedure TStudioLCLForm.LayoutToolBar;
var
  Index: Integer;
  NextLeft: Integer;
begin
  NextLeft := 6;

  for Index := 0 to FToolItems.Count - 1 do
  begin
    FToolItems[Index].Left := NextLeft;
    Inc(NextLeft, FToolItems[Index].Width + 4);
  end;
end;

procedure TStudioLCLForm.BuildToolBar;
var
  Button: TButton;
begin
  FToolBar := TPanel.Create(Self);
  FToolBar.Parent := Self;
  FToolBar.Align := alTop;
  FToolBar.Height := ToolBarHeight;
  FToolBar.BevelOuter := bvNone;

  Button := AddToolButton('New', HandleNewClick);
  Button := AddToolButton('Open', HandleOpenClick);
  Button := AddToolButton('Save', HandleSaveClick);
  AddToolSeparator;

  Button := AddToolButton('B', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Bold);
  Button.Font.Style := [fsBold];
  Button := AddToolButton('I', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Italic);
  Button.Font.Style := [fsItalic];
  Button := AddToolButton('S', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Strikethrough);
  Button.Font.Style := [fsStrikeOut];
  Button := AddToolButton('Link', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Link);
  Button := AddToolButton('Code', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.CodeBlock);
  AddToolSeparator;

  Button := AddToolButton('H1', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Heading1);
  Button := AddToolButton('H2', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Heading2);
  Button := AddToolButton('H3', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Heading3);
  Button := AddToolButton('List', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.BulletList);
  Button := AddToolButton('1.', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.NumberedList);
  Button := AddToolButton('Quote', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Quote);
  Button := AddToolButton('Table', HandleFormatClick);
  Button.Tag := Ord(TEditorCommand.Table);
  AddToolSeparator;

  Button := AddToolButton('Editor', HandleToolActionClick);
  Button.Tag := Ord(TStudioAction.taEditor);
  Button := AddToolButton('Split', HandleToolActionClick);
  Button.Tag := Ord(TStudioAction.taSplit);
  Button := AddToolButton('Preview', HandleToolActionClick);
  Button.Tag := Ord(TStudioAction.taPreview);
  AddToolSeparator;

  Button := AddToolButton('Contents', HandleToolActionClick);
  Button.Tag := Ord(TStudioAction.taOutline);
  Button := AddToolButton('Theme', HandleToolActionClick);
  Button.Tag := Ord(TStudioAction.taTheme);
  Button := AddToolButton('Zen', HandleToolActionClick);
  Button.Tag := Ord(TStudioAction.taZen);

  LayoutToolBar;
end;

{ Find bar }

procedure TStudioLCLForm.BuildFindBar;
var
  Label_: TLabel;
  Button: TButton;
  NextLeft: Integer;
begin
  FFindPanel := TPanel.Create(Self);
  FFindPanel.Parent := Self;
  FFindPanel.Align := alTop;
  FFindPanel.Height := FindBarHeight;
  FFindPanel.BevelOuter := bvNone;
  FFindPanel.Visible := False;

  Label_ := TLabel.Create(Self);
  Label_.Parent := FFindPanel;
  Label_.Left := 10;
  Label_.Top := 9;
  Label_.Caption := UTF8Encode('Find:');

  FFindEdit := TEdit.Create(Self);
  FFindEdit.Parent := FFindPanel;
  FFindEdit.Left := 50;
  FFindEdit.Top := 5;
  FFindEdit.Width := 190;
  FFindEdit.OnChange := HandleFindChanged;
  FFindEdit.OnKeyDown := HandleFindKeyDown;

  Label_ := TLabel.Create(Self);
  Label_.Parent := FFindPanel;
  Label_.Left := 250;
  Label_.Top := 9;
  Label_.Caption := UTF8Encode('Replace:');

  FReplaceEdit := TEdit.Create(Self);
  FReplaceEdit.Parent := FFindPanel;
  FReplaceEdit.Left := 310;
  FReplaceEdit.Top := 5;
  FReplaceEdit.Width := 190;
  FReplaceEdit.OnKeyDown := HandleFindKeyDown;

  FMatchCaseBox := TCheckBox.Create(Self);
  FMatchCaseBox.Parent := FFindPanel;
  FMatchCaseBox.Left := 508;
  FMatchCaseBox.Top := 7;
  FMatchCaseBox.Width := 100;
  FMatchCaseBox.Caption := UTF8Encode('Match case');
  FMatchCaseBox.OnChange := HandleFindChanged;

  FWholeWordBox := TCheckBox.Create(Self);
  FWholeWordBox.Parent := FFindPanel;
  FWholeWordBox.Left := 606;
  FWholeWordBox.Top := 7;
  FWholeWordBox.Width := 110;
  FWholeWordBox.Caption := UTF8Encode('Whole word');
  FWholeWordBox.OnChange := HandleFindChanged;

  FFindStatus := TLabel.Create(Self);
  FFindStatus.Parent := FFindPanel;
  FFindStatus.Left := 722;
  FFindStatus.Top := 9;
  FFindStatus.Width := 120;
  FFindStatus.Caption := '';

  NextLeft := 846;

  Button := TButton.Create(Self);
  Button.Parent := FFindPanel;
  Button.Left := NextLeft;
  Button.Top := 4;
  Button.Width := 66;
  Button.Height := FindBarHeight - 8;
  Button.Caption := UTF8Encode('Previous');
  Button.OnClick := HandleFindPreviousClick;
  Inc(NextLeft, 70);

  Button := TButton.Create(Self);
  Button.Parent := FFindPanel;
  Button.Left := NextLeft;
  Button.Top := 4;
  Button.Width := 60;
  Button.Height := FindBarHeight - 8;
  Button.Caption := UTF8Encode('Next');
  Button.OnClick := HandleFindNextClick;
  Inc(NextLeft, 64);

  Button := TButton.Create(Self);
  Button.Parent := FFindPanel;
  Button.Left := NextLeft;
  Button.Top := 4;
  Button.Width := 70;
  Button.Height := FindBarHeight - 8;
  Button.Caption := UTF8Encode('Replace');
  Button.OnClick := HandleReplaceOneClick;
  Inc(NextLeft, 74);

  Button := TButton.Create(Self);
  Button.Parent := FFindPanel;
  Button.Left := NextLeft;
  Button.Top := 4;
  Button.Width := 86;
  Button.Height := FindBarHeight - 8;
  Button.Caption := UTF8Encode('Replace all');
  Button.OnClick := HandleReplaceAllClick;
  Inc(NextLeft, 90);

  Button := TButton.Create(Self);
  Button.Parent := FFindPanel;
  Button.Left := NextLeft;
  Button.Top := 4;
  Button.Width := 56;
  Button.Height := FindBarHeight - 8;
  Button.Caption := UTF8Encode('Close');
  Button.OnClick := HandleFindCloseClick;
end;

{ Contents panel }

procedure TStudioLCLForm.BuildOutlinePanel;
begin
  // The workspace is laid out first and the splitter before the panel, because
  // an alLeft child created last ends up leftmost; the splitter resizes the
  // panel beside it.
  FOutlineSplitter := TSplitter.Create(Self);
  FOutlineSplitter.Parent := Self;
  FOutlineSplitter.Align := alLeft;
  FOutlineSplitter.Width := 6;

  FOutlinePanel := TPanel.Create(Self);
  FOutlinePanel.Parent := Self;
  FOutlinePanel.Align := alLeft;
  FOutlinePanel.Width := OutlineWidth;
  FOutlinePanel.BevelOuter := bvNone;

  FOutlineList := TListBox.Create(Self);
  FOutlineList.Parent := FOutlinePanel;
  FOutlineList.Align := alClient;
  FOutlineList.BorderStyle := bsNone;
  FOutlineList.OnClick := HandleOutlineClick;
end;

{ Workspace }

procedure TStudioLCLForm.BuildWorkspace;
begin
  FWorkspace := TPanel.Create(Self);
  FWorkspace.Parent := Self;
  FWorkspace.Align := alClient;
  FWorkspace.BevelOuter := bvNone;

  FTabs := TTabControl.Create(Self);
  FTabs.Parent := FWorkspace;
  FTabs.Align := alTop;
  FTabs.OnChanging := HandleTabsChanging;
  FTabs.OnChange := HandleTabsChange;

  // Created viewer first, then the splitter, then the editor: the editor is
  // then leftmost, the splitter resizes it, and the viewer takes the rest.
  FViewer := TMarkdownViewer.Create(Self);
  FViewer.Parent := FWorkspace;
  FViewer.Align := alClient;
  FViewer.OnLinkClick := HandleViewerLinkClick;
  FViewer.OnExtensionError := HandleViewerExtensionError;

  FPreviewSplitter := TSplitter.Create(Self);
  FPreviewSplitter.Parent := FWorkspace;
  FPreviewSplitter.Align := alLeft;
  FPreviewSplitter.Width := 6;
  FPreviewSplitter.OnMoved := HandleSplitMoved;

  FEditor := TMarkdownEditor.Create(Self);
  FEditor.Parent := FWorkspace;
  FEditor.Align := alLeft;
  FEditor.Width := 600;
  FEditor.ShowLineNumbers := True;
  FEditor.OnChange := HandleEditorChange;
  FEditor.OnScroll := HandleEditorScroll;
  FEditor.OnZoomChange := HandleEditorZoomChange;

  FOutlineTimer := TTimer.Create(Self);
  FOutlineTimer.Interval := OutlineDelayMilliseconds;
  FOutlineTimer.Enabled := False;
  FOutlineTimer.OnTimer := HandleOutlineTimer;

  OnResize := HandleResize;
end;

// How wide the source pane is: a share of what the workspace has, kept between
// the two panes whatever the window manager does to the window afterwards.
function TStudioLCLForm.SplitEditorWidth: Integer;
var
  Available: Integer;
begin
  Available := FWorkspace.ClientWidth;
  if Available <= 2 * MinPaneWidth then
    Exit(MinPaneWidth);

  Result := Round(Available * FSplitRatio);
  if Result < MinPaneWidth then
    Result := MinPaneWidth;
  if Result > Available - MinPaneWidth then
    Result := Available - MinPaneWidth;
end;

procedure TStudioLCLForm.HandleResize(Sender: TObject);
begin
  if (FViewMode = TStudioViewMode.Split) and (FEditor.Align = alLeft) then
    FEditor.Width := SplitEditorWidth;
end;

{ Status strip }

procedure TStudioLCLForm.BuildStatusStrip;
begin
  FStatusStrip := TPanel.Create(Self);
  FStatusStrip.Parent := Self;
  FStatusStrip.Align := alBottom;
  FStatusStrip.Height := StatusBarHeight;
  FStatusStrip.BevelOuter := bvNone;

  FStatusPosition := TLabel.Create(Self);
  FStatusPosition.Parent := FStatusStrip;
  FStatusPosition.Align := alLeft;
  FStatusPosition.Width := 220;
  FStatusPosition.BorderSpacing.Left := 8;
  FStatusPosition.Layout := tlCenter;
  FStatusPosition.Caption := '';

  FStatusInfo := TLabel.Create(Self);
  FStatusInfo.Parent := FStatusStrip;
  FStatusInfo.Align := alRight;
  FStatusInfo.Width := 460;
  FStatusInfo.BorderSpacing.Right := 8;
  FStatusInfo.Layout := tlCenter;
  FStatusInfo.Alignment := taRightJustify;
  FStatusInfo.Caption := '';
end;

{ Documents }

procedure TStudioLCLForm.NewDocument;
begin
  StoreDocumentState;

  FDocument := FDocuments.AddUntitled;
  FDocument.Text := WelcomeText;
  ShowDocument(FDocument);
  SyncTabs;
  UpdateWindowCaption;
  FocusEditor;
end;

procedure TStudioLCLForm.OpenDocument;
begin
  if not FOpenDialog.Execute then
    Exit;

  OpenFile(UTF8Decode(FOpenDialog.FileName));
end;

procedure TStudioLCLForm.OpenFile(const FileName: string);
var
  Existing: TStudioDocument;
  Document: TStudioDocument;
begin
  // A file that is already open comes to the front instead of being loaded
  // twice, so two tabs never edit the same file behind each other's back.
  Existing := FDocuments.FindByFile(FileName);
  if Existing <> nil then
  begin
    ActivateDocument(FDocuments.IndexOf(Existing));
    Exit;
  end;

  try
    Document := FDocuments.AddFromFile(FileName);
  except
    on E: Exception do
    begin
      MessageDlg(UTF8Encode(Format('Cannot open %s'#10#10'%s', [FileName, E.Message])),
        mtError, [mbOK], 0);
      Exit;
    end;
  end;

  ActivateDocument(FDocuments.IndexOf(Document));
  FocusEditor;
end;

procedure TStudioLCLForm.CloseActiveDocument;
var
  Answer: Integer;
begin
  if FDocument = nil then
    Exit;

  StoreDocumentState;

  if FDocument.Modified then
  begin
    Answer := MessageDlg(UTF8Encode(Format('Save changes to %s?', [FDocument.DisplayName])),
      mtConfirmation, [mbYes, mbNo, mbCancel], 0);

    if Answer = mrCancel then
      Exit;

    if (Answer = mrYes) and (not SaveDocument(FDocument, False)) then
      Exit;
  end;

  FDocuments.Delete(FDocuments.IndexOf(FDocument));
  FDocument := nil;

  if FDocuments.Count = 0 then
    NewDocument
  else
  begin
    ActivateDocument(0);
    SyncTabs;
    UpdateWindowCaption;
  end;
end;

function TStudioLCLForm.SaveDocument(const Document: TStudioDocument;
  const ForceDialog: Boolean): Boolean;
var
  Target: string;
begin
  Result := False;

  if Document = nil then
    Exit;

  if Document = FDocument then
    StoreDocumentState;

  if ForceDialog or (not Document.HasFile) then
  begin
    if Document.HasFile then
      Target := Document.FileName
    else
      Target := Document.DisplayName + '.md';

    FSaveDialog.FileName := UTF8Encode(Target);
    if not FSaveDialog.Execute then
      Exit;

    Target := UTF8Decode(FSaveDialog.FileName);
  end
  else
    Target := Document.FileName;

  try
    Document.SaveToFile(Target);
  except
    on E: Exception do
    begin
      MessageDlg(UTF8Encode(Format('Cannot save %s'#10#10'%s', [Target, E.Message])),
        mtError, [mbOK], 0);
      Exit;
    end;
  end;

  SyncTabs;
  UpdateWindowCaption;
  UpdateStatus;

  Result := True;
end;

// Every document with unsaved changes gets a say before the window closes or
// the application quits; a cancel anywhere stops the whole thing.
function TStudioLCLForm.EnsureSaved: Boolean;
var
  Index: Integer;
  Document: TStudioDocument;
  Answer: Integer;
begin
  Result := False;

  for Index := 0 to FDocuments.Count - 1 do
  begin
    Document := FDocuments[Index];

    if not Document.Modified then
      Continue;

    Answer := MessageDlg(UTF8Encode(Format('Save changes to %s?', [Document.DisplayName])),
      mtConfirmation, [mbYes, mbNo, mbCancel], 0);

    if Answer = mrYes then
    begin
      if not SaveDocument(Document, False) then
        Exit;
    end
    else if Answer <> mrNo then
      Exit;
  end;

  Result := True;
end;

procedure TStudioLCLForm.ActivateDocument(const Index: Integer);
begin
  if (Index < 0) or (Index >= FDocuments.Count) then
    Exit;

  StoreDocumentState;

  FDocument := FDocuments[Index];
  ShowDocument(FDocument);
  SyncTabs;
  UpdateWindowCaption;
end;

procedure TStudioLCLForm.ShowDocument(const Document: TStudioDocument);
begin
  FLoading := True;
  try
    FEditor.Text := Document.Text;
    // The editor pushes text to its preview on a timer; the document being
    // opened cannot wait for it, or the scroll position restored below would
    // belong to the text of the document that was just replaced.
    FEditor.FlushPreview;

    if Document.EditorState <> nil then
      FEditor.LoadEditState(Document.EditorState);

    FViewer.ScrollOffset := Document.PreviewOffset;
  finally
    FLoading := False;
  end;

  RebuildOutline;
  RecountText;
  UpdateStatus;
  UpdateUndoRedo;
end;

procedure TStudioLCLForm.StoreDocumentState;
begin
  if (FDocument = nil) or FLoading then
    Exit;

  FDocument.Text := FEditor.Text;
  FDocument.EditorState := FEditor.SaveEditState;
  FDocument.PreviewOffset := FViewer.ScrollOffset;
end;

procedure TStudioLCLForm.SyncTabs;
var
  Index: Integer;
begin
  FUpdatingTabs := True;
  try
    FTabs.Tabs.BeginUpdate;
    try
      FTabs.Tabs.Clear;
      for Index := 0 to FDocuments.Count - 1 do
        FTabs.Tabs.Add(UTF8Encode(FDocuments[Index].TabCaption));
    finally
      FTabs.Tabs.EndUpdate;
    end;

    FTabs.TabIndex := FDocuments.IndexOf(FDocument);
  finally
    FUpdatingTabs := False;
  end;
end;

procedure TStudioLCLForm.UpdateTabCaption;
var
  Index: Integer;
  Caption_: string;
begin
  Index := FDocuments.IndexOf(FDocument);
  if Index < 0 then
    Exit;

  Caption_ := FDocument.TabCaption;
  if FTabs.Tabs[Index] = UTF8Encode(Caption_) then
    Exit;

  FUpdatingTabs := True;
  try
    FTabs.Tabs[Index] := UTF8Encode(Caption_);
  finally
    FUpdatingTabs := False;
  end;
end;

procedure TStudioLCLForm.UpdateWindowCaption;
begin
  if FDocument = nil then
  begin
    Caption := UTF8Encode('Markdown4D Studio');
    Exit;
  end;

  Caption := UTF8Encode(Format('%s - Markdown4D Studio', [FDocument.TabCaption]));
end;

{ Contents }

procedure TStudioLCLForm.ScheduleOutline;
begin
  FOutlineTimer.Enabled := False;
  FOutlineTimer.Enabled := True;
end;

procedure TStudioLCLForm.AppendOutlineEntry(const Entry: IMarkdownTocEntry);
var
  Index: Integer;
  Count: Integer;
begin
  Count := Length(FOutlineAnchors);
  SetLength(FOutlineAnchors, Count + 1);
  SetLength(FOutlineLines, Count + 1);
  FOutlineAnchors[Count] := Entry.Anchor;
  FOutlineLines[Count] := Entry.SourceLine;

  FOutlineList.Items.Add(UTF8Encode(StringOfChar(' ', (Entry.Level - 1) * 2) + Entry.Caption));

  for Index := 0 to Entry.ChildCount - 1 do
    AppendOutlineEntry(Entry.Children[Index]);
end;

procedure TStudioLCLForm.RebuildOutline;
var
  Entry: IMarkdownTocEntry;
begin
  FOutlineTimer.Enabled := False;

  FParsed := TMarkdown.Parse(FEditor.Text, TMarkdownDialect.Gfm);
  FToc := TMarkdownToc.FromDocument(FParsed);

  SetLength(FOutlineAnchors, 0);
  SetLength(FOutlineLines, 0);

  FOutlineList.Items.BeginUpdate;
  try
    FOutlineList.Items.Clear;

    for Entry in FToc do
      AppendOutlineEntry(Entry);
  finally
    FOutlineList.Items.EndUpdate;
  end;
end;

procedure TStudioLCLForm.HandleOutlineClick(Sender: TObject);
var
  Index: Integer;
begin
  Index := FOutlineList.ItemIndex;
  if (Index < 0) or (Index > High(FOutlineAnchors)) then
    Exit;

  // The preview jumps to the heading itself; the editor is taken to the line
  // the heading was written on.
  FViewer.ScrollToAnchor(FOutlineAnchors[Index]);
  FEditor.ScrollToSourceLine(FOutlineLines[Index]);
end;

{ Find and replace }

procedure TStudioLCLForm.ShowFindBar(const WithReplace: Boolean);
begin
  FFindPanel.Visible := True;

  FReplaceEdit.ReadOnly := not WithReplace;
  if WithReplace then
    FReplaceEdit.SetFocus
  else
    FFindEdit.SetFocus;

  if FFindEdit.Text <> '' then
  begin
    FFindEdit.SelectAll;
    UpdateFindMarks;
  end;
end;

procedure TStudioLCLForm.HideFindBar;
begin
  FFindPanel.Visible := False;
  FFindStatus.Caption := '';
  FEditor.ClearHighlights;
  FViewer.ClearHighlights;
  FocusEditor;
end;

function TStudioLCLForm.FindNeedle: string;
begin
  Result := UTF8Decode(FFindEdit.Text);
end;

function TStudioLCLForm.FindOptions: TMarkdownFindOptions;
begin
  Result := TMarkdownFindOptions.Create(FMatchCaseBox.Checked, FWholeWordBox.Checked);
end;

procedure TStudioLCLForm.UpdateFindMarks;
var
  Needle: string;
  Count: Integer;
begin
  Needle := FindNeedle;

  // Both panes mark every hit, so the reader sees where they are before
  // stepping through them.
  FEditor.HighlightMatches(Needle, FindOptions);
  FViewer.HighlightMatches(Needle, FindOptions);

  if Needle = '' then
    FFindStatus.Caption := ''
  else
  begin
    Count := FEditor.FindMatchCount(Needle, FindOptions);
    FFindStatus.Caption := UTF8Encode(Format('%d matches', [Count]));
  end;
end;

procedure TStudioLCLForm.GoToMatch(const Forward: Boolean);
var
  Needle: string;
  Found: Boolean;
  Index, Count: Integer;
begin
  Needle := FindNeedle;
  if Needle = '' then
    Exit;

  if Forward then
    Found := FEditor.FindNext(Needle, FindOptions)
  else
    Found := FEditor.FindPrevious(Needle, FindOptions);

  Count := FEditor.FindMatchCount(Needle, FindOptions);
  Index := FEditor.FindMatchIndex(Needle, FindOptions);

  if not Found then
    FFindStatus.Caption := UTF8Encode('not found')
  else if Index >= 0 then
    FFindStatus.Caption := UTF8Encode(Format('%d of %d', [Index + 1, Count]))
  else
    FFindStatus.Caption := UTF8Encode(Format('%d matches', [Count]));
end;

procedure TStudioLCLForm.ReplaceMatch;
var
  Needle: string;
begin
  Needle := FindNeedle;
  if Needle = '' then
    Exit;

  FEditor.ReplaceCurrent(Needle, UTF8Decode(FReplaceEdit.Text), FindOptions);
  UpdateFindMarks;
end;

procedure TStudioLCLForm.ReplaceEveryMatch;
var
  Needle: string;
  Replaced: Integer;
begin
  Needle := FindNeedle;
  if Needle = '' then
    Exit;

  Replaced := FEditor.ReplaceAll(Needle, UTF8Decode(FReplaceEdit.Text), FindOptions);
  UpdateFindMarks;
  FFindStatus.Caption := UTF8Encode(Format('%d replaced', [Replaced]));
end;

{ Status line }

procedure TStudioLCLForm.UpdateStatus;
var
  Text: string;
  Ch: Char;
  Index, Caret, Line, Column: Integer;
  Mode: string;
begin
  Text := FEditor.Text;
  Caret := FEditor.CaretPosition;

  Line := 1;
  Column := 1;
  for Index := 1 to Length(Text) do
  begin
    if Index > Caret then
      Break;

    if Text[Index] = LineFeed then
    begin
      Inc(Line);
      Column := 1;
    end
    else
      Inc(Column);
  end;

  case FViewMode of
    TStudioViewMode.PreviewOnly: Mode := 'preview';
    TStudioViewMode.EditorOnly: Mode := 'editor';
  else
    Mode := 'split';
  end;

  if FThemeDark then
    Mode := Mode + ', dark'
  else
    Mode := Mode + ', light';

  FStatusPosition.Caption := UTF8Encode(Format('Ln %d, Col %d', [Line, Column]));
  FStatusInfo.Caption := UTF8Encode(Format('%d words  %d chars  %s  %d%%',
    [FWordCount, FCharacterCount, Mode, FEditor.Zoom]));
end;

// Counting words and characters walks the whole document, so it happens when
// the text changes rather than every time the status line is refreshed.
procedure TStudioLCLForm.RecountText;
var
  Text: string;
  Ch: Char;
  Index: Integer;
  InWord, IsSpace: Boolean;
begin
  Text := FEditor.Text;

  FWordCount := 0;
  FCharacterCount := 0;
  InWord := False;

  for Index := 1 to Length(Text) do
  begin
    Ch := Text[Index];
    IsSpace := (Ch = ' ') or (Ch = #9) or (Ch = #13) or (Ch = LineFeed);

    if IsSpace then
      InWord := False
    else
    begin
      Inc(FCharacterCount);
      if not InWord then
      begin
        Inc(FWordCount);
        InWord := True;
      end;
    end;
  end;
end;

procedure TStudioLCLForm.UpdateUndoRedo;
begin
  FUndoItem.Enabled := FEditor.CanUndo;
  FRedoItem.Enabled := FEditor.CanRedo;
end;

{ View }

procedure TStudioLCLForm.SetViewMode(const Mode: TStudioViewMode);
begin
  if FViewMode = Mode then
    Exit;

  FViewMode := Mode;
  ApplyViewMode;
end;

procedure TStudioLCLForm.ApplyViewMode;
begin
  case FViewMode of
    TStudioViewMode.EditorOnly:
      begin
        FPreviewSplitter.Visible := False;
        FViewer.Visible := False;
        FEditor.Visible := True;
        FEditor.Align := alClient;
      end;
    TStudioViewMode.PreviewOnly:
      begin
        FPreviewSplitter.Visible := False;
        FEditor.Visible := False;
        FViewer.Visible := True;
        FViewer.Align := alClient;
      end;
  else
    begin
      FEditor.Visible := True;
      FViewer.Visible := True;
      FPreviewSplitter.Visible := True;
      FEditor.Align := alLeft;
      FEditor.Width := SplitEditorWidth;
      FViewer.Align := alClient;
    end;
  end;

  FViewModeItems[TStudioViewMode.EditorOnly].Checked := FViewMode = TStudioViewMode.EditorOnly;
  FViewModeItems[TStudioViewMode.Split].Checked := FViewMode = TStudioViewMode.Split;
  FViewModeItems[TStudioViewMode.PreviewOnly].Checked := FViewMode = TStudioViewMode.PreviewOnly;

  UpdateStatus;
end;

procedure TStudioLCLForm.SetTheme(const Dark: Boolean);
begin
  FThemeDark := Dark;

  if FThemeDark then
  begin
    FEditor.ThemePreset := TMarkdownThemePreset.Dark;
    FViewer.ThemePreset := TMarkdownThemePreset.Dark;
  end
  else
  begin
    FEditor.ThemePreset := TMarkdownThemePreset.Light;
    FViewer.ThemePreset := TMarkdownThemePreset.Light;
  end;

  FThemeItems[False].Checked := not FThemeDark;
  FThemeItems[True].Checked := FThemeDark;

  UpdateStatus;
end;

procedure TStudioLCLForm.ToggleOutline;
begin
  FOutlineVisible := not FOutlineVisible;
  ApplyChrome;
  FOutlineItem.Checked := FOutlineVisible;
end;

procedure TStudioLCLForm.ToggleZen;
begin
  FZen := not FZen;
  ApplyChrome;
  FZenItem.Checked := FZen;

  if FZen then
    FocusEditor;
end;

// Zen mode takes the chrome away and gives it back; the contents panel keeps
// its own visibility, so leaving zen restores what the reader had.
procedure TStudioLCLForm.ApplyChrome;
begin
  FToolBar.Visible := not FZen;
  FStatusStrip.Visible := not FZen;
  FOutlineSplitter.Visible := (not FZen) and FOutlineVisible;
  FOutlinePanel.Visible := (not FZen) and FOutlineVisible;

  if FZen then
    FFindPanel.Visible := False;
end;

{ Handlers: documents }

procedure TStudioLCLForm.HandleNewClick(Sender: TObject);
begin
  NewDocument;
end;

procedure TStudioLCLForm.HandleOpenClick(Sender: TObject);
begin
  OpenDocument;
end;

procedure TStudioLCLForm.HandleSaveClick(Sender: TObject);
begin
  SaveDocument(FDocument, False);
end;

procedure TStudioLCLForm.HandleSaveAsClick(Sender: TObject);
begin
  SaveDocument(FDocument, True);
end;

procedure TStudioLCLForm.HandleCloseClick(Sender: TObject);
begin
  CloseActiveDocument;
end;

procedure TStudioLCLForm.HandleExitClick(Sender: TObject);
begin
  Close;
end;

procedure TStudioLCLForm.HandleExportHtmlClick(Sender: TObject);
var
  Title: string;
  Html: string;
begin
  if FDocument = nil then
    Exit;

  Title := FDocument.DisplayName;
  if FDocument.HasFile then
    FHtmlDialog.FileName := UTF8Encode(ChangeFileExt(ExtractFileName(FDocument.FileName), '.html'))
  else
    FHtmlDialog.FileName := UTF8Encode(ChangeFileExt(Title, '.html'));

  if not FHtmlDialog.Execute then
    Exit;

  Html := TStudioHtml.BuildDocument(FEditor.Text, Title, FThemeDark);

  try
    TStudioHtml.SaveToFile(UTF8Decode(FHtmlDialog.FileName), Html);
  except
    on E: Exception do
      MessageDlg(UTF8Encode(Format('Cannot write the file'#10#10'%s', [E.Message])),
        mtError, [mbOK], 0);
  end;
end;

// The clipboard gets the HTML source, which pastes into an editor as markup;
// the VCL Studio also publishes it in the Windows HTML clipboard format, which
// is a Windows-only shape.
procedure TStudioLCLForm.HandleCopyHtmlClick(Sender: TObject);
var
  Html: string;
begin
  Html := TStudioHtml.BuildDocument(FEditor.Text, 'Markdown', FThemeDark);
  Clipboard.AsText := UTF8Encode(Html);
  FStatusInfo.Caption := UTF8Encode('HTML copied to the clipboard');
end;

procedure TStudioLCLForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := EnsureSaved;
end;

procedure TStudioLCLForm.FocusEditor;
begin
  if Visible and FEditor.CanFocus then
    FEditor.SetFocus;
end;

procedure TStudioLCLForm.HandleTabsChanging(Sender: TObject; var AllowChange: Boolean);
begin
  if FUpdatingTabs then
    Exit;

  // The document that is being left keeps its caret and its place.
  StoreDocumentState;
end;

procedure TStudioLCLForm.HandleTabsChange(Sender: TObject);
begin
  if FUpdatingTabs then
    Exit;

  ActivateDocument(FTabs.TabIndex);
  FocusEditor;
end;

{ Handlers: editing }

procedure TStudioLCLForm.HandleUndoClick(Sender: TObject);
begin
  FEditor.Undo;
  FocusEditor;
  UpdateUndoRedo;
end;

procedure TStudioLCLForm.HandleRedoClick(Sender: TObject);
begin
  FEditor.Redo;
  FocusEditor;
  UpdateUndoRedo;
end;

procedure TStudioLCLForm.HandleCutClick(Sender: TObject);
begin
  Clipboard.AsText := UTF8Encode(FEditor.SelectedText);
  // Inserting nothing over the selection is what cuts it.
  FEditor.InsertText('');
  FocusEditor;
end;

procedure TStudioLCLForm.HandleCopyClick(Sender: TObject);
begin
  Clipboard.AsText := UTF8Encode(FEditor.SelectedText);
  FocusEditor;
end;

procedure TStudioLCLForm.HandlePasteClick(Sender: TObject);
begin
  FEditor.InsertText(UTF8Decode(Clipboard.AsText));
  FocusEditor;
end;

procedure TStudioLCLForm.HandleSelectAllClick(Sender: TObject);
begin
  FEditor.SelectAll;
  FocusEditor;
end;

procedure TStudioLCLForm.HandleFormatClick(Sender: TObject);
var
  Command: TEditorCommand;
  Value: Integer;
begin
  Value := TComponent(Sender).Tag;
  Command := TEditorCommand(Value);

  // With the editor out of sight its caret sits wherever it was left; the
  // selection made in the preview says which characters were meant.
  if FViewMode = TStudioViewMode.PreviewOnly then
    FEditor.TryAdoptPreviewSelection;

  FEditor.ExecuteCommand(Command);
  FocusEditor;
  UpdateUndoRedo;
end;

procedure TStudioLCLForm.HandleToolActionClick(Sender: TObject);
var
  Action: TStudioAction;
begin
  Action := TStudioAction(TComponent(Sender).Tag);

  case Action of
    TStudioAction.taNew: NewDocument;
    TStudioAction.taOpen: OpenDocument;
    TStudioAction.taSave: SaveDocument(FDocument, False);
    TStudioAction.taEditor: SetViewMode(TStudioViewMode.EditorOnly);
    TStudioAction.taSplit: SetViewMode(TStudioViewMode.Split);
    TStudioAction.taPreview: SetViewMode(TStudioViewMode.PreviewOnly);
    TStudioAction.taOutline: ToggleOutline;
    TStudioAction.taTheme: SetTheme(not FThemeDark);
    TStudioAction.taZen: ToggleZen;
  end;
end;

procedure TStudioLCLForm.HandleEditorChange(Sender: TObject);
begin
  if FLoading then
    Exit;

  if FDocument <> nil then
    // The document keeps the text only when it is stored; the editor is the
    // one that holds it while it is on screen.
    FDocument.Modified := True;

  RecountText;
  UpdateTabCaption;
  UpdateWindowCaption;
  UpdateStatus;
  UpdateUndoRedo;
  ScheduleOutline;
end;

procedure TStudioLCLForm.HandleEditorScroll(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TStudioLCLForm.HandleEditorZoomChange(Sender: TObject);
begin
  // The preview follows the editor's zoom, including Ctrl+wheel over the text.
  FViewer.Zoom := FEditor.Zoom;
  UpdateStatus;
end;

procedure TStudioLCLForm.HandleViewerLinkClick(const Sender: TObject; const Url: string);
begin
  // Anchors inside the document were already followed by the viewer; anything
  // else leaves the program to the desktop.
  if (Pos('http://', Url) = 1) or (Pos('https://', Url) = 1) then
    OpenURL(UTF8Encode(Url));
end;

procedure TStudioLCLForm.HandleViewerExtensionError(const Sender: TObject; const Extension: string;
  const Error: Exception);
begin
  FStatusInfo.Caption := UTF8Encode(Format('%s: %s', [Extension, Error.Message]));
end;

procedure TStudioLCLForm.HandleSplitMoved(Sender: TObject);
begin
  FSplitRatio := FEditor.Width / Max(1, FWorkspace.ClientWidth);
end;

{ Handlers: find and replace }

procedure TStudioLCLForm.HandleFindClick(Sender: TObject);
begin
  ShowFindBar(False);
end;

procedure TStudioLCLForm.HandleFindCloseClick(Sender: TObject);
begin
  HideFindBar;
end;

procedure TStudioLCLForm.HandleReplaceClick(Sender: TObject);
begin
  ShowFindBar(True);
end;

procedure TStudioLCLForm.HandleReplaceOneClick(Sender: TObject);
begin
  ReplaceMatch;
end;

procedure TStudioLCLForm.HandleReplaceAllClick(Sender: TObject);
begin
  ReplaceEveryMatch;
end;

procedure TStudioLCLForm.HandleFindNextClick(Sender: TObject);
begin
  if not FFindPanel.Visible then
    ShowFindBar(False);
  GoToMatch(True);
end;

procedure TStudioLCLForm.HandleFindPreviousClick(Sender: TObject);
begin
  if not FFindPanel.Visible then
    ShowFindBar(False);
  GoToMatch(False);
end;

procedure TStudioLCLForm.HandleFindChanged(Sender: TObject);
begin
  UpdateFindMarks;
end;

procedure TStudioLCLForm.HandleFindKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    HideFindBar;
    Exit;
  end;

  if Key <> VK_RETURN then
    Exit;

  Key := 0;
  GoToMatch(not (ssShift in Shift));
end;

{ Handlers: outline and view }

procedure TStudioLCLForm.HandleOutlineTimer(Sender: TObject);
begin
  RebuildOutline;
end;

procedure TStudioLCLForm.HandleViewModeClick(Sender: TObject);
begin
  SetViewMode(TStudioViewMode(TComponent(Sender).Tag));
end;

procedure TStudioLCLForm.HandleOutlineToggleClick(Sender: TObject);
begin
  ToggleOutline;
end;

procedure TStudioLCLForm.HandleLineNumbersClick(Sender: TObject);
begin
  FEditor.ShowLineNumbers := not FEditor.ShowLineNumbers;
  FLinesItem.Checked := FEditor.ShowLineNumbers;
end;

procedure TStudioLCLForm.HandleZoomInClick(Sender: TObject);
begin
  FEditor.ZoomIn;
end;

procedure TStudioLCLForm.HandleZoomOutClick(Sender: TObject);
begin
  FEditor.ZoomOut;
end;

procedure TStudioLCLForm.HandleZoomResetClick(Sender: TObject);
begin
  FEditor.ResetZoom;
end;

procedure TStudioLCLForm.HandleThemeClick(Sender: TObject);
begin
  SetTheme(TComponent(Sender).Tag = 1);
end;

procedure TStudioLCLForm.HandleZenClick(Sender: TObject);
begin
  ToggleZen;
end;

procedure TStudioLCLForm.HandleReferenceClick(Sender: TObject);
begin
  OpenURL('https://commonmark.org/help/');
end;

procedure TStudioLCLForm.HandleAboutClick(Sender: TObject);
var
  Info: string;
begin
  Info := 'Markdown4D Studio (LCL)'#10#10 +
    'Markdown4D ' + TMarkdown.Version + #10 +
    'Free Pascal ' + {$I %FPCVERSION%} + ' on ' + {$I %FPCTARGETOS%} + #10 +
    'Lazarus Component Library';

  MessageDlg(UTF8Encode(Info), mtInformation, [mbOK], 0);
end;

{ The document the window opens with }

function WelcomeText: string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('# Welcome to Markdown4D Studio');
    Lines.Add('');
    Lines.Add('The left pane is the source, the right pane is the preview, and the');
    Lines.Add('preview follows the caret while SyncScroll is on. The panel on the');
    Lines.Add('left is built from the headings of this document: click an entry to');
    Lines.Add('jump to it.');
    Lines.Add('');
    Lines.Add('## Formatting');
    Lines.Add('');
    Lines.Add('Select some text and press **Ctrl+B** for bold, *Ctrl+I* for italic,');
    Lines.Add('or Ctrl+K for a link. The rest of the Format menu wraps lists,');
    Lines.Add('quotes, tables and fenced code blocks.');
    Lines.Add('');
    Lines.Add('## A table');
    Lines.Add('');
    Lines.Add('| Pane | Shows |');
    Lines.Add('| --- | --- |');
    Lines.Add('| left | the source |');
    Lines.Add('| right | the preview |');
    Lines.Add('');
    Lines.Add('## A code block');
    Lines.Add('');
    Lines.Add('```pascal');
    Lines.Add('procedure Hello(const Who: string);');
    Lines.Add('begin');
    Lines.Add('  WriteLn(''hello '', Who);');
    Lines.Add('end;');
    Lines.Add('```');
    Lines.Add('');
    Lines.Add('## Where to go next');
    Lines.Add('');
    Lines.Add('Open `Examples/Shared/demo.md` from the File menu: it shows the');
    Lines.Add('tables, task lists, charts and Mermaid diagrams the renderer draws');
    Lines.Add('natively on the canvas.');
    Lines.Add('');

    Result := UTF8Decode(Lines.Text);
  finally
    Lines.Free;
  end;
end;

end.
