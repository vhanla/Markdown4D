unit Markdown4D.Lcl.Viewer;

{$I ../Markdown4D.Fpc.inc}

// ============================================================================
//  Markdown4D.Lcl.Viewer
//
//  Free Pascal / Lazarus (LCL) counterpart of Markdown4D.Vcl.Viewer: the
//  control an application drops on a form to show markdown.
//
//  Almost everything the viewer does lives in the framework-neutral
//  Markdown4D.Viewer.Model, so this unit is the widget shell around it: it owns
//  the paint buffer, the timers, the scrollbar, the mouse and key handling and
//  the image plumbing, and it speaks to the model the way the VCL viewer did.
//
//  Where the platform had to change:
//
//    * UNITS     -- a host program that uses the viewer must list cthreads before
//      every other unit on Unix.  Remote images are fetched on TTask, which
//      links FPC's System.Threading, whose thread pool faults while the units
//      initialize if the RTL's pthread shims were never installed.
//
//    * SCROLLING -- the VCL control asked for a WS_VSCROLL window style and
//      drove the native bar with SetScrollInfo/WM_VSCROLL.  LCL's GTK3 widgets
//      only grow a scrollbar on a TScrollingWinControl, so the viewer derives
//      from that and drives its VertScrollBar.  ScrollBy is overridden to
//      repaint instead of blitting: the content is drawn from the model offset.
//    * ORIGIN    -- the VCL scrolled by moving the canvas origin (SetWindowOrgEx,
//      clip included).  GTK3's scrolling window instead moves the GtkLayout bin
//      window, so the canvas origin is already the top of the visible slice:
//      the viewer renders that slice into its buffer one scroll up (the
//      painter's OriginY, which keeps SetClip in the same space) and blits the
//      buffer back down at the offset, which is what Paint does.
//    * STRINGS   -- every string that crosses into an LCL API is UTF8Encode'd;
//      the neutral layer speaks UTF-16 (see Markdown4D.Fpc.inc).
//    * CLIPBOARD -- Windows raises EClipboardException; LCL has no such type, so
//      a failed copy is swallowed as itself: one copy that does not happen.
//    * NO THEMING HOOKS -- the VCL style hook that darkened the scrollbar has no
//      LCL equivalent; the widgetset paints the bar.
// ============================================================================

interface

uses
  SysUtils,
  Types,
  Classes,
  Generics.Collections,
  LMessages,
  LCLType,
  LCLIntf,
  Controls,
  Graphics,
  Forms,
  Menus,
  ExtCtrls,
  Clipbrd,
  Markdown4D.Ast.Interfaces,
  Markdown4D.Layout.Interfaces,
  Markdown4D.Layout.DisplayList,
  Markdown4D.Theme,
  Markdown4D.Viewer.Model,
  Markdown4D.Layout.TextSearch,
  Markdown4D.Viewer.Clicks,
  Markdown4D.Layout.ResizePacer,
  Markdown4D.Layout.Zoom,
  Markdown4D.Layout.Pointer,
  Markdown4D.Viewer.ContextMenu,
  Markdown4D.AutoScroll,
  Markdown4D.Lcl.AutoScroll,
  Markdown4D.Viewer.ImageDownloader,
  Markdown4D.Viewer.ImageSettings,
  Markdown4D.Viewer.Lifetime,
  Markdown4D.Image.Svg,
  Markdown4D.Lcl.Painter;

type
  TMarkdownLinkClickEvent = procedure(const Sender: TObject; const Url: string) of object;

  TMarkdownLinkHoverEvent = procedure(const Sender: TObject; const Url: string) of object;

  TMarkdownResolveImageEvent = procedure(const Sender: TObject; const Url: string; const Picture: TPicture;
    var Handled: Boolean) of object;

  // Republished from the shared layer so existing code keeps finding the type
  // through this unit.
  TMarkdownViewerImageSettings = Markdown4D.Viewer.ImageSettings.TMarkdownViewerImageSettings;

  TMarkdownExtensionErrorEvent = Markdown4D.Viewer.Model.TMarkdownExtensionErrorEvent;

  // Vetoes or permits one remote image, starting from Images.AllowRemote. Use it
  // to decide per address, for instance to allow only hosts the application
  // knows.
  TMarkdownRemoteImageEvent = procedure(const Sender: TObject; const Url: string;
    var Allow: Boolean) of object;

  TMarkdownViewer = class(TScrollingWinControl, IMarkdownAutoScrollTarget)
  private
    const
      DefaultControlWidth = 300;
      DefaultControlHeight = 200;
      AnchorMark = '#';
      SelectionFillColor = TLayoutColor($402F81F7);
      MatchFillColor = TLayoutColor($55E3B341);
      CopyButtonWidth = 54;
      CopyButtonHeight = 22;
      CopyButtonMargin = 6;
      CopyButtonFontSize = 12;
      CopyButtonStrokeWidth = 1.0;
      CopyFeedbackMilliseconds = 1200;
      MenuSeparatorCaption = '-';
    var
      FLifetime: IMarkdownViewerLifetime;
      FImages: TMarkdownViewerImageSettings;
      FDocumentFolder: string;
      FImageDownloader: TMarkdownImageDownloader;
      FRequestedImageSources: TDictionary<string, Boolean>;
      FTheme: TMarkdownTheme;
      FOwnsTheme: Boolean;
      FThemePreset: TMarkdownThemePreset;
      FDesignSampleActive: Boolean;
      FModel: TMarkdownViewerModel;
      FMeasureBitmap: TBitmap;
      FMeasurePainter: TMarkdownLclPainter;
      FMeasurePainterLifetime: IPainter;
      FBuffer: TBitmap;
      FFlushTimer: TTimer;
      FResizeTimer: TTimer;
      FResizePacer: TMarkdownResizePacer;
      FAppliedWidth: Integer;
      FLoadedImages: TObjectDictionary<string, TGraphic>;
      FUpdatingScrollBar: Boolean;
      FSelecting: Boolean;
      FClickCounter: TMarkdownClickCounter;
      FClickGesture: TMarkdownClickGesture;
      FAutoScroller: TMarkdownLclAutoScroller;
      FLastMousePoint: TPoint;
      FHasLastMousePoint: Boolean;
      FCodeHoverActive: Boolean;
      FCodeHoverRect: TLayoutRectF;
      FCodeHoverText: string;
      FCopyButtonRect: TLayoutRectF;
      FCopyFeedback: Boolean;
      FCopyFeedbackTimer: TTimer;
      FContextMenu: TPopupMenu;
      FPressedLinkUrl: string;
      FHasPressedDisclosure: Boolean;
      FPressedDisclosureKey: Integer;
      FHoveredLinkUrl: string;
      FOnLinkClick: TMarkdownLinkClickEvent;
      FOnLinkHover: TMarkdownLinkHoverEvent;
      FOnResolveImage: TMarkdownResolveImageEvent;
      FOnRemoteImageRequest: TMarkdownRemoteImageEvent;
      FOnScroll: TNotifyEvent;
      FOnAutoScrollChange: TNotifyEvent;
      FOnZoomChange: TNotifyEvent;
      FZoomTimer: TTimer;
      FZoomPacer: TMarkdownResizePacer;
      FPendingZoom: Integer;
      FCopyAsMarkdown: Boolean;
      FOnExtensionError: TMarkdownExtensionErrorEvent;
    function InvokeOnMainThread(const Action: TThreadProcedure): Boolean;
    procedure HandleModelExtensionError(const Sender: TObject; const Extension: string; const Error: Exception);
    procedure HandleFlushTimer(Sender: TObject);
    procedure ApplyViewport;
    procedure ApplyViewportNow;
    procedure HandleResizeTimer(Sender: TObject);
    procedure StepZoom(const Percent: Integer);
    procedure ApplyZoomNow;
    procedure HandleZoomTimer(Sender: TObject);
    function TryHandleZoomKey(const Key: Word): Boolean;
    procedure ResolvePendingImages;
    procedure ResolvePendingImage(const Source: string);
    function TryResolveImageThroughEvent(const Source, Url: string): Boolean;
    function AllowsRemoteImage(const Url: string): Boolean;
    procedure LoadLocalImage(const Source, FilePath: string);
    procedure HandleImageDataArrived(const Source: string; const Data: TBytes);
    procedure HandleImageDownloadFailed(const Source: string);
    function TryLoadSvg(const Source: string; const Data: TBytes): Boolean;
    procedure ApplyLoadedPicture(const Source: string; const Picture: TPicture);
    procedure ApplyFailedImage(const Source: string);
    procedure StoreLoadedImage(const Source: string; const Graphic: TGraphic);
    function ResolveLoadedImage(const Source: string): TGraphic;
    function IsImageBroken(const Source: string): Boolean;
    procedure RenderToBuffer;
    procedure EnsureBufferSize;
    procedure ScrollToBottom;
    procedure SetScrollPosition(const Value: Single);
    procedure ScrollToMatch(const Match: TMarkdownFoundRange);
    procedure UpdateScrollBar;
    function LineScrollAmount: Integer;
    function ContentPixelsPerInch: Integer;
    function ContentPointOf(const X, Y: Integer): TLayoutPointF;
    procedure UpdateHoverCursor(const Point: TLayoutPointF);
    procedure SetHoveredLinkUrl(const Value: string);
    function TryFindLinkUrl(const Point: TLayoutPointF; out Url: string): Boolean;
    procedure UpdateCodeHover(const Point: TLayoutPointF);
    procedure RefreshCodeHover;
    function PointOnCopyButton(const Point: TLayoutPointF): Boolean;
    procedure ClearCodeHover;
    procedure CopyCodeToClipboard(const Text: string);
    procedure SelectForPress(const Point: TLayoutPointF; const X, Y: Integer; const IsDoubleClick: Boolean);
    procedure FinishLinkClick(const X, Y: Integer);
    procedure FinishDisclosureClick(const X, Y: Integer);
    procedure RaiseClick(const Kind: TMarkdownClickKind);
    function GetAutoScrollEnabled: Boolean;
    function GetIsAutoScrolling: Boolean;
    function GetSelectedMarkdown: string;
    procedure PutOnClipboard(const Text: string);
    procedure CopyForShortcut(const Shift: TShiftState);
    function GetZoom: Integer;
    procedure SetZoom(const Value: Integer);
    procedure PaintAutoScrollOrigin;
    procedure SetAutoScrollEnabled(const Value: Boolean);
    function CanAutoScroll: Boolean;
    procedure AutoScrollBy(const Delta: Single);
    procedure AutoScrollChanged;
    procedure CNKeyDown(var Message: TLMKeyDown); message CN_KEYDOWN;
    procedure WMKillFocus(var Message: TLMKillFocus); message LM_KILLFOCUS;
    procedure WMVScroll(var Message: TLMVScroll); message LM_VSCROLL;
    procedure WMEraseBkgnd(var Message: TLMEraseBkgnd); message LM_ERASEBKGND;
    procedure WMGetDlgCode(var Message: TLMGetDlgCode); message LM_GETDLGCODE;
    procedure CMMouseLeave(var Message: TLMessage); message CM_MOUSELEAVE;
    procedure HandleCopyFeedbackTimer(Sender: TObject);
    procedure DrawCopyButton(const Painter: IPainter);
    procedure ShowContextMenu(const X, Y: Integer);
    procedure HandleContextItemClick(Sender: TObject);
    function GetContentHeight: Integer;
    function GetScrollOffset: Single;
    function GetDisplayList: IMarkdownDisplayList;
    function GetLayoutCount: Integer;
    function GetText: string;
    procedure SetText(const Value: string);
    procedure SetImages(const Value: TMarkdownViewerImageSettings);
    function IsTextStored: Boolean;
    procedure SetThemePreset(const Value: TMarkdownThemePreset);
    procedure EnsureDesignSample;
    procedure SetTheme(const Value: TMarkdownTheme);
    function GetSelectedText: string;

  protected
    procedure Resize; override;
    procedure ChangeScale(Multiplier, Divider: Integer); override;
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoContextPopup(MousePos: TPoint; var Handled: Boolean); override;

  public
    constructor Create(Owner: TComponent); override;
    destructor Destroy; override;
    // The viewer paints the display list itself, from the model offset, so the
    // widgetset must not scroll (blit) the window behind its back.
    procedure ScrollBy(DeltaX, DeltaY: Integer); override;
    procedure LoadFromFile(const FileName: string);
    procedure LoadFromStream(const Stream: TStream);
    procedure AppendMarkdown(const Markdown: string);
    // Select the next match and scroll it into view; a repeated search moves
    // on and wraps to the first match after the last. FindPrevious walks back.
    function FindText(const Needle: string): Boolean; overload;
    function FindText(const Needle: string; const Options: TMarkdownFindOptions): Boolean; overload;
    function FindPrevious(const Needle: string): Boolean; overload;
    function FindPrevious(const Needle: string; const Options: TMarkdownFindOptions): Boolean; overload;
    function FindMatchCount(const Needle: string): Integer; overload;
    function FindMatchCount(const Needle: string; const Options: TMarkdownFindOptions): Integer; overload;
    // Which match the selection is, counted from 0, for a "3 of 12"; -1 when
    // the selection is not a match.
    function FindMatchIndex(const Needle: string; const Options: TMarkdownFindOptions): Integer;
    // Mark every match until ClearHighlights or an empty needle; the marks
    // follow the document as it changes.
    procedure HighlightMatches(const Needle: string); overload;
    procedure HighlightMatches(const Needle: string; const Options: TMarkdownFindOptions); overload;
    procedure ClearHighlights;
    function HighlightCount: Integer;
    procedure CopySelectionToClipboard;
    procedure CopySelectionAsMarkdown;
    // Scrolls the heading a link like #getting-started points at to the top.
    // A click on such a link does this itself; OnLinkClick is raised only for
    // an anchor the document does not have.
    function ScrollToAnchor(const Anchor: string): Boolean;
    // Where a line of Text shows, as the ScrollOffset that brings it to the
    // top, and which line shows at an offset, so an editor beside the viewer
    // can keep both in step. Lines count from 0.
    function SourceLineToScrollOffset(const SourceLine: Integer): Single;
    function ScrollOffsetToSourceLine(const Offset: Single): Integer;
    // The markdown behind the selection: within one line with the markup
    // around it, over several lines whole lines, a table whole.
    property SelectedMarkdown: string read GetSelectedMarkdown;
    procedure SelectAll;
    procedure ClearSelection;
    procedure ZoomIn;
    procedure ZoomOut;
    procedure ResetZoom;
    // Answers the stretch of markdown the selection in the preview was
    // rendered from, so an editor can put its own selection on those same
    // characters before a formatting command runs.
    function TryGetSelectionSourceSegment(out Segment: TMarkdownSegment): Boolean;
    property Theme: TMarkdownTheme read FTheme write SetTheme;
    property ContentHeight: Integer read GetContentHeight;
    property ScrollOffset: Single read GetScrollOffset write SetScrollPosition;
    property DisplayList: IMarkdownDisplayList read GetDisplayList;
    // Advances every time the content is laid out again (first width, resize,
    // arriving images, upgrading diagrams), so an attached editor can tell that
    // its scroll mapping went stale.
    property LayoutCount: Integer read GetLayoutCount;
    property SelectedText: string read GetSelectedText;
    property IsAutoScrolling: Boolean read GetIsAutoScrolling;

  published
    property Text: string read GetText write SetText stored IsTextStored;
    property ThemePreset: TMarkdownThemePreset read FThemePreset write SetThemePreset
      default TMarkdownThemePreset.Light;
    property Images: TMarkdownViewerImageSettings read FImages write SetImages;
    // A middle click scrolls the content by the distance of the pointer from
    // where it was pressed, until the next click, key or wheel turn.
    property AutoScroll: Boolean read GetAutoScrollEnabled write SetAutoScrollEnabled default True;
    property Align;
    property Anchors;
    property Constraints;
    property Enabled;
    property PopupMenu;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Visible;
    property OnLinkClick: TMarkdownLinkClickEvent read FOnLinkClick write FOnLinkClick;
    property OnLinkHover: TMarkdownLinkHoverEvent read FOnLinkHover write FOnLinkHover;
    property OnResolveImage: TMarkdownResolveImageEvent read FOnResolveImage write FOnResolveImage;
    property OnRemoteImageRequest: TMarkdownRemoteImageEvent read FOnRemoteImageRequest
      write FOnRemoteImageRequest;
    property OnScroll: TNotifyEvent read FOnScroll write FOnScroll;
    property OnClick;
    property OnDblClick;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnAutoScrollChange: TNotifyEvent read FOnAutoScrollChange write FOnAutoScrollChange;
    // In percent: every font, spacing and image grows with it. Ctrl+wheel and
    // Ctrl+Plus/Minus step through the levels browsers use, Ctrl+0 resets it.
    property Zoom: Integer read GetZoom write SetZoom default TMarkdownZoom.DefaultPercent;
    property OnZoomChange: TNotifyEvent read FOnZoomChange write FOnZoomChange;
    // Offers Copy as Markdown on the context menu and Ctrl+Shift+C. Off, the
    // menu leaves the entry out and Ctrl+Shift+C copies plain text, for an
    // application that keeps the source to itself.
    property CopyAsMarkdown: Boolean read FCopyAsMarkdown write FCopyAsMarkdown default True;
    property OnExtensionError: TMarkdownExtensionErrorEvent read FOnExtensionError write FOnExtensionError;
  end;

implementation

uses
  Math,
  System.IOUtils,
  IntfGraphics,
  GraphType,
  Markdown4D.Math.Font,
  Markdown4D.Consts,
  Markdown4D.DesignSample,
  Markdown4D.Text.FileFormat,
  Markdown4D.Layout.Defaults,
  Markdown4D.Layout.HitTest,
  Markdown4D.Layout.Renderer,
  Markdown4D.Viewer.Shared,
  // Self-registering bridges: the SVG rasterizer, the image decoder, the
  // FreeType glyph outliner and the bundled math font.  Using them is what
  // makes them part of the build.
  Markdown4D.Image.Svg.Native,
  Markdown4D.Lcl.ImageDecoder,
  Markdown4D.Lcl.Glyphs,
  Markdown4D.Lcl.MathFont;

constructor TMarkdownViewer.Create(Owner: TComponent);
begin
  inherited Create(Owner);

  TMarkdownMathFont.EnsureInstalled;

  FLifetime := TMarkdownViewerLifetime.Create;

  // The control decides itself which release is a click; see RaiseClick.
  ControlStyle := ControlStyle + [csOpaque] - [csClickEvents];
  Width := DefaultControlWidth;
  Height := DefaultControlHeight;
  TabStop := True;
  // The bar is driven from UpdateScrollBar; no auto-range computation may run
  // behind it and overwrite the content size the model reports.
  VertScrollBar.Visible := True;

  FImages := TMarkdownViewerImageSettings.Create;
  FTheme := TMarkdownTheme.CreateLight;
  FOwnsTheme := True;
  FLoadedImages := TObjectDictionary<string, TGraphic>.Create([doOwnsValues]);
  FRequestedImageSources := TDictionary<string, Boolean>.Create;
  FImageDownloader := TMarkdownImageDownloader.Create(HandleImageDataArrived, HandleImageDownloadFailed);
  FImageDownloader.OnAddressAllowed := AllowsRemoteImage;

  FMeasureBitmap := TBitmap.Create;
  FMeasureBitmap.SetSize(1, 1);
  FMeasurePainter := TMarkdownLclPainter.Create(FMeasureBitmap.Canvas, ContentPixelsPerInch);
  FMeasurePainterLifetime := FMeasurePainter;
  FModel := TMarkdownViewerModel.Create(FTheme, FMeasurePainterLifetime);
  FModel.OnExtensionError := HandleModelExtensionError;

  FBuffer := TBitmap.Create;

  FFlushTimer := TTimer.Create(Self);
  FFlushTimer.Enabled := False;
  FFlushTimer.Interval := FlushTimerIntervalMilliseconds;
  FFlushTimer.OnTimer := HandleFlushTimer;

  FResizeTimer := TTimer.Create(Self);
  FResizeTimer.Enabled := False;
  FResizeTimer.Interval := TMarkdownResizePacer.SettleMilliseconds;
  FResizeTimer.OnTimer := HandleResizeTimer;

  FPendingZoom := TMarkdownZoom.DefaultPercent;
  FCopyAsMarkdown := True;
  FZoomTimer := TTimer.Create(Self);
  FZoomTimer.Enabled := False;
  FZoomTimer.Interval := TMarkdownResizePacer.SettleMilliseconds;
  FZoomTimer.OnTimer := HandleZoomTimer;

  FCopyFeedbackTimer := TTimer.Create(Self);
  FCopyFeedbackTimer.Enabled := False;
  FCopyFeedbackTimer.Interval := CopyFeedbackMilliseconds;
  FCopyFeedbackTimer.OnTimer := HandleCopyFeedbackTimer;

  FAutoScroller := TMarkdownLclAutoScroller.Create(Self, Self);

  TMarkdownViewerShared.RegisterDefaultHighlighters;
end;

destructor TMarkdownViewer.Destroy;
begin
  FAutoScroller.Free;
  FLifetime.Shutdown;
  FImageDownloader.Free;
  FRequestedImageSources.Free;
  FModel.Free;
  FMeasurePainter := nil;
  FMeasurePainterLifetime := nil;
  FMeasureBitmap.Free;
  FBuffer.Free;
  FLoadedImages.Free;
  if FOwnsTheme then
    FTheme.Free;
  FImages.Free;

  inherited Destroy;
end;

function TMarkdownViewer.InvokeOnMainThread(const Action: TThreadProcedure): Boolean;
var
  Lifetime: IMarkdownViewerLifetime;
begin
  if GetCurrentThreadId = MainThreadID then
  begin
    Result := False;
    Exit;
  end;

  Lifetime := FLifetime;
  TThread.Queue(nil,
    procedure
    begin
      if Lifetime.IsAlive then
        Action();
    end);
  Result := True;
end;

procedure TMarkdownViewer.LoadFromFile(const FileName: string);
var
  Format: TMarkdownTextFormat;
begin
  FDocumentFolder := TPath.GetDirectoryName(TPath.GetFullPath(FileName));
  Text := TMarkdownTextFile.Load(FileName, Format);
end;

procedure TMarkdownViewer.LoadFromStream(const Stream: TStream);
var
  Bytes: TArray<Byte>;
  Encoding: TMarkdownTextEncoding;
  Copy: TMemoryStream;
begin
  Copy := TMemoryStream.Create;
  try
    Copy.CopyFrom(Stream, 0);
    SetLength(Bytes, Copy.Size);
    if Copy.Size > 0 then
    begin
      Copy.Position := 0;
      Copy.ReadBuffer(Bytes[0], Copy.Size);
    end;
  finally
    Copy.Free;
  end;

  Text := TMarkdownTextFile.DecodeBytes(Bytes, Encoding);
end;

procedure TMarkdownViewer.AppendMarkdown(const Markdown: string);
begin
  if InvokeOnMainThread(
    procedure
    begin
      AppendMarkdown(Markdown);
    end) then
    Exit;

  FModel.AppendMarkdown(Markdown, Int64(GetTickCount64));
  FFlushTimer.Enabled := True;
end;

procedure TMarkdownViewer.HandleModelExtensionError(const Sender: TObject; const Extension: string;
  const Error: Exception);
begin
  if Assigned(FOnExtensionError) then
    FOnExtensionError(Self, Extension, Error);
end;

procedure TMarkdownViewer.HandleFlushTimer(Sender: TObject);
var
  Flushed: Boolean;
begin
  Flushed := FModel.TryFlush(Int64(GetTickCount64));
  if Flushed then
  begin
    if FModel.ShouldAutoFollow then
      ScrollToBottom;
    ResolvePendingImages;
    RefreshCodeHover;
    UpdateScrollBar;
    Invalidate;
  end;

  if not FModel.IsDirty then
    FFlushTimer.Enabled := False;
end;

function TMarkdownViewer.FindText(const Needle: string): Boolean;
begin
  Result := FindText(Needle, Default(TMarkdownFindOptions));
end;

function TMarkdownViewer.FindText(const Needle: string; const Options: TMarkdownFindOptions): Boolean;
var
  Match: TMarkdownFoundRange;
begin
  Result := FModel.TrySelectNextMatch(Needle, Options, Match);
  if Result then
    ScrollToMatch(Match);
end;

function TMarkdownViewer.FindPrevious(const Needle: string): Boolean;
begin
  Result := FindPrevious(Needle, Default(TMarkdownFindOptions));
end;

function TMarkdownViewer.FindPrevious(const Needle: string; const Options: TMarkdownFindOptions): Boolean;
var
  Match: TMarkdownFoundRange;
begin
  Result := FModel.TrySelectPreviousMatch(Needle, Options, Match);
  if Result then
    ScrollToMatch(Match);
end;

procedure TMarkdownViewer.ScrollToMatch(const Match: TMarkdownFoundRange);
var
  Offset: Single;
begin
  if FModel.TryGetScrollTarget(Match, Offset) then
    SetScrollPosition(Offset)
  else
    Invalidate;
end;

function TMarkdownViewer.FindMatchCount(const Needle: string): Integer;
begin
  Result := FindMatchCount(Needle, Default(TMarkdownFindOptions));
end;

function TMarkdownViewer.FindMatchCount(const Needle: string; const Options: TMarkdownFindOptions): Integer;
begin
  Result := FModel.MatchCount(Needle, Options);
end;

function TMarkdownViewer.FindMatchIndex(const Needle: string; const Options: TMarkdownFindOptions): Integer;
begin
  Result := FModel.MatchIndex(Needle, Options);
end;

procedure TMarkdownViewer.HighlightMatches(const Needle: string);
begin
  HighlightMatches(Needle, Default(TMarkdownFindOptions));
end;

procedure TMarkdownViewer.HighlightMatches(const Needle: string; const Options: TMarkdownFindOptions);
begin
  FModel.HighlightMatches(Needle, Options);
  Invalidate;
end;

procedure TMarkdownViewer.ClearHighlights;
begin
  FModel.ClearHighlights;
  Invalidate;
end;

function TMarkdownViewer.HighlightCount: Integer;
begin
  Result := FModel.HighlightCount;
end;

procedure TMarkdownViewer.CopySelectionToClipboard;
begin
  PutOnClipboard(FModel.SelectedText);
end;

procedure TMarkdownViewer.CopySelectionAsMarkdown;
begin
  PutOnClipboard(FModel.SelectedMarkdown);
end;

function TMarkdownViewer.GetSelectedMarkdown: string;
begin
  Result := FModel.SelectedMarkdown;
end;

// Ctrl+Shift+C copies the markdown, unless the application keeps the source
// to itself; then it copies plain text as Ctrl+C does.
procedure TMarkdownViewer.CopyForShortcut(const Shift: TShiftState);
var
  WantsMarkdown: Boolean;
begin
  WantsMarkdown := (ssShift in Shift) and FCopyAsMarkdown;
  if WantsMarkdown then
    CopySelectionAsMarkdown
  else
    CopySelectionToClipboard;
end;

procedure TMarkdownViewer.PutOnClipboard(const Text: string);
begin
  if Text = '' then
    Exit;

  try
    Clipboard.AsText := UTF8Encode(Text);
  except
    // The clipboard can be held by another process, or be absent in a session
    // without a display: a copy that cannot happen is not an error.
    Exit;
  end;
end;

procedure TMarkdownViewer.SelectAll;
begin
  if FModel.SelectAll then
    Invalidate;
end;

procedure TMarkdownViewer.ClearSelection;
begin
  FModel.ClearSelection;
  Invalidate;
end;

procedure TMarkdownViewer.ShowContextMenu(const X, Y: Integer);
var
  Items: TArray<TViewerContextItem>;
  Item: TViewerContextItem;
  Separator: TMenuItem;
  Entry: TMenuItem;
  Origin: TPoint;
begin
  // A menu assigned by the host wins; the built-in one is the fallback.
  if PopupMenu <> nil then
    Exit;

  if FContextMenu = nil then
    FContextMenu := TPopupMenu.Create(Self);

  FContextMenu.Items.Clear;

  Items := TMarkdownViewerContextMenu.Build(FModel, FCopyAsMarkdown);
  for Item in Items do
  begin
    if Item.StartsGroup and (FContextMenu.Items.Count > 0) then
    begin
      Separator := TMenuItem.Create(FContextMenu);
      Separator.Caption := UTF8Encode(MenuSeparatorCaption);
      FContextMenu.Items.Add(Separator);
    end;

    Entry := TMenuItem.Create(FContextMenu);
    Entry.Caption := UTF8Encode(Item.Caption);
    Entry.Enabled := Item.Enabled;
    Entry.ShortCut := Item.ShortCut;
    Entry.Tag := Ord(Item.Command);
    Entry.OnClick := HandleContextItemClick;
    FContextMenu.Items.Add(Entry);
  end;

  Origin := ClientToScreen(Point(X, Y));
  FContextMenu.Popup(Origin.X, Origin.Y);
end;

procedure TMarkdownViewer.HandleContextItemClick(Sender: TObject);
var
  Command: TViewerContextCommand;
begin
  Command := TViewerContextCommand(TMenuItem(Sender).Tag);

  if TMarkdownViewerContextMenu.Execute(FModel, Command) then
  begin
    Invalidate;
    Exit;
  end;

  case Command of
    TViewerContextCommand.Copy           : CopySelectionToClipboard;
    TViewerContextCommand.CopyAsMarkdown : CopySelectionAsMarkdown;
  else
    raise ENotSupportedException.CreateFmt('Unhandled context command: %d', [Ord(Command)]);
  end;
end;

procedure TMarkdownViewer.Resize;
begin
  inherited Resize;

  // TScrollingWinControl sizes itself from its constructor, which runs this
  // before the viewer's own fields exist; there is nothing to lay out yet.
  if FModel = nil then
    Exit;

  ApplyViewport;
  ResolvePendingImages;
  UpdateScrollBar;
  Invalidate;
end;

procedure TMarkdownViewer.ApplyViewport;
var
  IsNewWidth: Boolean;
  ReflowsNow: Boolean;
begin
  IsNewWidth := (ClientWidth <> FAppliedWidth);
  ReflowsNow := ((not IsNewWidth) or FResizePacer.TryReflowNow(GetTickCount64, FModel.LastLayoutMilliseconds));
  if ReflowsNow then
  begin
    ApplyViewportNow;
    Exit;
  end;

  FModel.SetViewport(FAppliedWidth, ClientHeight);
  FResizeTimer.Enabled := False;
  FResizeTimer.Enabled := True;
end;

procedure TMarkdownViewer.ApplyViewportNow;
begin
  FResizeTimer.Enabled := False;
  FAppliedWidth := ClientWidth;
  FModel.SetViewport(ClientWidth, ClientHeight);
end;

procedure TMarkdownViewer.HandleResizeTimer(Sender: TObject);
begin
  if not FResizePacer.TryFlush(GetTickCount64, TMarkdownPointer.IsPrimaryButtonDown) then
    Exit;

  ApplyViewportNow;
  ResolvePendingImages;
  UpdateScrollBar;
  Invalidate;
end;

procedure TMarkdownViewer.ChangeScale(Multiplier, Divider: Integer);
begin
  inherited ChangeScale(Multiplier, Divider);

  if FMeasurePainter = nil then
    Exit;

  FMeasurePainter.PixelsPerInch := ContentPixelsPerInch;
  FModel.RefreshLayout;
  UpdateScrollBar;
  Invalidate;
end;

procedure TMarkdownViewer.Paint;
begin
  if FModel = nil then
    Exit;

  EnsureDesignSample;
  EnsureBufferSize;
  RenderToBuffer;
  PaintAutoScrollOrigin;
  // GTK3's scrolling window moves the GtkLayout bin window, so the canvas origin
  // is the top of the visible slice rather than the top of the widget: the
  // buffer, which holds that slice, lands at the scroll offset.  Drawing it at 0
  // would push it one screen further up and out of the clip.
  Canvas.Draw(0, Round(FModel.ScrollOffset), FBuffer);
end;

procedure TMarkdownViewer.PaintAutoScrollOrigin;
var
  Painter: IPainter;
begin
  if not FAutoScroller.IsActive then
    Exit;

  Painter := TMarkdownLclPainter.Create(FBuffer.Canvas, ContentPixelsPerInch);
  FAutoScroller.PaintOrigin(Painter, FTheme.BackgroundColor, FTheme.TextColor);
end;

procedure TMarkdownViewer.EnsureDesignSample;
begin
  if not (csDesigning in ComponentState) then
    Exit;

  if FDesignSampleActive then
    Exit;

  if FModel.FullText <> '' then
    Exit;

  FDesignSampleActive := True;
  FModel.Text := TMarkdownDesignSample.Markdown;
  UpdateScrollBar;
end;

procedure TMarkdownViewer.EnsureBufferSize;
var
  BufferWidth: Integer;
  BufferHeight: Integer;
  SizeChanged: Boolean;
begin
  BufferWidth := Max(1, ClientWidth);
  BufferHeight := Max(1, ClientHeight);
  SizeChanged := (FBuffer.Width <> BufferWidth) or (FBuffer.Height <> BufferHeight);
  if SizeChanged then
    FBuffer.SetSize(BufferWidth, BufferHeight);
end;

procedure TMarkdownViewer.RenderToBuffer;
var
  Painter: TMarkdownLclPainter;
  PainterLifetime: IPainter;
  ScrollY: Integer;
  Viewport: TLayoutRectF;
  Rect: TLayoutRectF;
begin
  Painter := TMarkdownLclPainter.Create(FBuffer.Canvas, ContentPixelsPerInch);
  PainterLifetime := Painter;
  Painter.ImageResolver := ResolveLoadedImage;
  Painter.BrokenImageQuery := IsImageBroken;

  // The display list is in content coordinates; OriginY puts the scrolled slice
  // into the buffer, for the drawing and the clip alike (see the unit header).
  ScrollY := Round(FModel.ScrollOffset);
  Painter.OriginY := ScrollY;

  Viewport := TLayoutRectF.Create(0, ScrollY, ClientWidth, ScrollY + ClientHeight);
  TMarkdownDisplayListRenderer.Render(FModel.DisplayList, PainterLifetime, Viewport, FTheme.BackgroundColor);

  for Rect in FModel.HighlightRectsWithin(Viewport) do
    PainterLifetime.FillRect(Rect, MatchFillColor);

  for Rect in FModel.SelectionRects do
    PainterLifetime.FillRect(Rect, SelectionFillColor);

  if FCodeHoverActive then
    DrawCopyButton(PainterLifetime);
end;

function TMarkdownViewer.ResolveLoadedImage(const Source: string): TGraphic;
begin
  if not FLoadedImages.TryGetValue(Source, Result) then
    Result := nil;
end;

function TMarkdownViewer.IsImageBroken(const Source: string): Boolean;
begin
  Result := FModel.ImageSlotState(Source) = TMarkdownImageSlotState.Failed;
end;

procedure TMarkdownViewer.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Point: TLayoutPointF;
begin
  inherited MouseDown(Button, Shift, X, Y);

  FClickGesture.PressElsewhere;
  if FAutoScroller.TryHandlePress(Button, X, Y) then
    Exit;

  if Button = TMouseButton.mbRight then
  begin
    if CanFocus then
      SetFocus;

    ShowContextMenu(X, Y);
    Exit;
  end;

  if Button <> TMouseButton.mbLeft then
    Exit;

  if CanFocus then
    SetFocus;

  Point := ContentPointOf(X, Y);
  if PointOnCopyButton(Point) then
  begin
    CopyCodeToClipboard(FCodeHoverText);
    FCopyFeedback := True;
    FCopyFeedbackTimer.Enabled := False;
    FCopyFeedbackTimer.Enabled := True;
    Invalidate;
    Exit;
  end;

  if TryFindLinkUrl(Point, FPressedLinkUrl) then
    Exit;

  FPressedLinkUrl := '';
  FHasPressedDisclosure := FModel.TryGetDisclosureAt(Point, FPressedDisclosureKey);
  if FHasPressedDisclosure then
    Exit;

  FSelecting := True;
  SelectForPress(Point, X, Y, ssDouble in Shift);
  Invalidate;
end;

procedure TMarkdownViewer.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
begin
  if FAutoScroller.TakeSuppressedMenu then
  begin
    Handled := True;
    Exit;
  end;

  inherited DoContextPopup(MousePos, Handled);
end;

// Windows reports a double click but not a third one; the counter takes the
// user's double-click time and distance to recognise it.  LCL's widgetset may
// answer 0 for either metric on a platform that has no such setting, so both
// fall back to the toolkit's own defaults.
procedure TMarkdownViewer.SelectForPress(const Point: TLayoutPointF; const X, Y: Integer;
  const IsDoubleClick: Boolean);
var
  Tolerance: Single;
  Interval: Cardinal;
  ClickCount: Integer;
begin
  Tolerance := Max(GetSystemMetrics(SM_CXDOUBLECLK), GetSystemMetrics(SM_CYDOUBLECLK)) / 2;
  if Tolerance <= 0 then
    Tolerance := Mouse.DragThreshold;

  Interval := GetDoubleClickTime;
  if Interval = 0 then
    Interval := 500;

  ClickCount := FClickCounter.RegisterPress(GetTickCount64, X, Y, IsDoubleClick, Interval, Tolerance);

  FClickGesture.PressInText(X, Y, ClickCount);

  if ClickCount = TMarkdownClickCounter.TripleClick then
    FModel.SelectLineAt(Point)
  else if ClickCount = TMarkdownClickCounter.DoubleClick then
    FModel.SelectWordAt(Point)
  else
    FModel.SetSelectionAnchor(Point);
end;

procedure TMarkdownViewer.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  ContentPoint: TLayoutPointF;
begin
  inherited MouseMove(Shift, X, Y);

  FLastMousePoint := Point(X, Y);
  FHasLastMousePoint := True;

  if FAutoScroller.IsActive then
  begin
    FAutoScroller.HandleMove(X, Y);
    Exit;
  end;

  ContentPoint := ContentPointOf(X, Y);
  if FSelecting then
  begin
    FModel.SetSelectionExtent(ContentPoint);
    Invalidate;
    Exit;
  end;

  UpdateCodeHover(ContentPoint);
  if PointOnCopyButton(ContentPoint) then
  begin
    Cursor := crHandPoint;
    Exit;
  end;

  UpdateHoverCursor(ContentPoint);
end;

procedure TMarkdownViewer.RefreshCodeHover;
begin
  if not FHasLastMousePoint then
    Exit;

  UpdateCodeHover(ContentPointOf(FLastMousePoint.X, FLastMousePoint.Y));
end;

procedure TMarkdownViewer.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  ClickKind: TMarkdownClickKind;
begin
  inherited MouseUp(Button, Shift, X, Y);

  if Button = TMouseButton.mbMiddle then
  begin
    FAutoScroller.HandleMiddleUp;
    Exit;
  end;

  if Button <> TMouseButton.mbLeft then
    Exit;

  ClickKind := FClickGesture.Release(X, Y, Mouse.DragThreshold);

  if FSelecting then
    FSelecting := False
  else
  begin
    FinishLinkClick(X, Y);
    FinishDisclosureClick(X, Y);
  end;

  RaiseClick(ClickKind);
end;

procedure TMarkdownViewer.FinishLinkClick(const X, Y: Integer);
var
  PressedUrl: string;
  ReleasedUrl: string;
  IsSameLink: Boolean;
  IsFollowedHere: Boolean;
begin
  if FPressedLinkUrl = '' then
    Exit;

  PressedUrl := FPressedLinkUrl;
  FPressedLinkUrl := '';

  IsSameLink := TryFindLinkUrl(ContentPointOf(X, Y), ReleasedUrl) and (ReleasedUrl = PressedUrl);
  if not IsSameLink then
    Exit;

  IsFollowedHere := (Copy(PressedUrl, 1, Length(AnchorMark)) = AnchorMark) and ScrollToAnchor(PressedUrl);
  if IsFollowedHere then
    Exit;

  if Assigned(FOnLinkClick) then
    FOnLinkClick(Self, PressedUrl);
end;

procedure TMarkdownViewer.FinishDisclosureClick(const X, Y: Integer);
var
  ReleasedKey: Integer;
  IsSameDisclosure: Boolean;
begin
  if not FHasPressedDisclosure then
    Exit;

  FHasPressedDisclosure := False;

  IsSameDisclosure := (FModel.TryGetDisclosureAt(ContentPointOf(X, Y), ReleasedKey) and
                       (ReleasedKey = FPressedDisclosureKey));
  if not IsSameDisclosure then
    Exit;

  FModel.ToggleDisclosure(FPressedDisclosureKey);
  ResolvePendingImages;
  RefreshCodeHover;
  UpdateScrollBar;
  Invalidate;
end;

function TMarkdownViewer.SourceLineToScrollOffset(const SourceLine: Integer): Single;
begin
  Result := FModel.SourceLineToScrollOffset(SourceLine);
end;

function TMarkdownViewer.ScrollOffsetToSourceLine(const Offset: Single): Integer;
begin
  Result := FModel.ScrollOffsetToSourceLine(Offset);
end;

function TMarkdownViewer.ScrollToAnchor(const Anchor: string): Boolean;
var
  Offset: Single;
begin
  Result := FModel.TryGetAnchorOffset(Anchor, Offset);
  if Result then
    SetScrollPosition(Offset);
end;

// Raised last, once the press is fully handled, so a handler may open a modal
// window or free the form.
procedure TMarkdownViewer.RaiseClick(const Kind: TMarkdownClickKind);
begin
  case Kind of
    TMarkdownClickKind.None        : ;
    TMarkdownClickKind.Click       : Click;
    TMarkdownClickKind.DoubleClick : DblClick;
  else
    raise ENotSupportedException.CreateFmt('Unhandled click kind: %d', [Ord(Kind)]);
  end;
end;

function TMarkdownViewer.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  CanScroll: Boolean;
  Notches: Single;
begin
  if FAutoScroller.IsActive then
  begin
    FAutoScroller.Stop;
    Result := True;
    Exit;
  end;

  if ssCtrl in Shift then
  begin
    if WheelDelta > 0 then
      ZoomIn
    else
      ZoomOut;

    Result := True;
    Exit;
  end;

  // Content that already fits has nothing to scroll; leaving the wheel
  // unhandled lets a surrounding scroll box move the viewer itself instead.
  CanScroll := ContentHeight > ClientHeight;
  if not CanScroll then
  begin
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
    Exit;
  end;

  Notches := WheelDelta / MouseWheelDeltaPerNotch;
  SetScrollPosition(FModel.ScrollOffset - (Notches * WheelLinesPerNotch * LineScrollAmount));

  Result := True;
end;

procedure TMarkdownViewer.KeyDown(var Key: Word; Shift: TShiftState);
var
  IsZoomKey: Boolean;
begin
  if FAutoScroller.IsActive then
  begin
    FAutoScroller.Stop;
    Key := 0;
    Exit;
  end;

  inherited KeyDown(Key, Shift);

  IsZoomKey := (ssCtrl in Shift) and TryHandleZoomKey(Key);
  if IsZoomKey then
  begin
    Key := 0;
    Exit;
  end;

  case Key of
    VK_UP:
      SetScrollPosition(FModel.ScrollOffset - LineScrollAmount);
    VK_DOWN:
      SetScrollPosition(FModel.ScrollOffset + LineScrollAmount);
    VK_PRIOR:
      SetScrollPosition(FModel.ScrollOffset - ClientHeight);
    VK_NEXT:
      SetScrollPosition(FModel.ScrollOffset + ClientHeight);
    VK_HOME:
      SetScrollPosition(0);
    VK_END:
      ScrollToBottom;
    Ord('A'):
      if ssCtrl in Shift then
        SelectAll;
    Ord('C'):
      if ssCtrl in Shift then
        CopyForShortcut(Shift);
  end;
end;

function TMarkdownViewer.GetAutoScrollEnabled: Boolean;
begin
  Result := FAutoScroller.Enabled;
end;

function TMarkdownViewer.GetZoom: Integer;
begin
  Result := FPendingZoom;
end;

procedure TMarkdownViewer.SetZoom(const Value: Integer);
begin
  FPendingZoom := TMarkdownZoom.Clamp(Value);
  ApplyZoomNow;
end;

procedure TMarkdownViewer.ZoomIn;
begin
  StepZoom(TMarkdownZoom.StepIn(FPendingZoom));
end;

procedure TMarkdownViewer.ZoomOut;
begin
  StepZoom(TMarkdownZoom.StepOut(FPendingZoom));
end;

procedure TMarkdownViewer.ResetZoom;
begin
  StepZoom(TMarkdownZoom.DefaultPercent);
end;

// A slow document waits until the wheel rests, so turning it several notches
// lays the document out once.
procedure TMarkdownViewer.StepZoom(const Percent: Integer);
begin
  FPendingZoom := TMarkdownZoom.Clamp(Percent);

  if FZoomPacer.TryReflowNow(GetTickCount64, FModel.LastLayoutMilliseconds) then
  begin
    ApplyZoomNow;
    Exit;
  end;

  FZoomTimer.Enabled := False;
  FZoomTimer.Enabled := True;
end;

procedure TMarkdownViewer.ApplyZoomNow;
var
  IsChange: Boolean;
begin
  FZoomTimer.Enabled := False;

  IsChange := (FModel.Zoom <> FPendingZoom);
  if not IsChange then
    Exit;

  FModel.Zoom := FPendingZoom;
  UpdateScrollBar;
  Invalidate;

  if Assigned(FOnZoomChange) then
    FOnZoomChange(Self);
end;

procedure TMarkdownViewer.HandleZoomTimer(Sender: TObject);
begin
  if FZoomPacer.TryFlush(GetTickCount64, False) then
    ApplyZoomNow;
end;

function TMarkdownViewer.TryHandleZoomKey(const Key: Word): Boolean;
begin
  Result := True;

  case TMarkdownZoom.ActionOfKey(Key) of
    TMarkdownZoomAction.StepIn  : ZoomIn;
    TMarkdownZoomAction.StepOut : ZoomOut;
    TMarkdownZoomAction.Reset   : ResetZoom;
  else
    Result := False;
  end;
end;

function TMarkdownViewer.GetIsAutoScrolling: Boolean;
begin
  Result := FAutoScroller.IsActive;
end;

procedure TMarkdownViewer.SetAutoScrollEnabled(const Value: Boolean);
begin
  FAutoScroller.Enabled := Value;
end;

function TMarkdownViewer.CanAutoScroll: Boolean;
begin
  Result := (ContentHeight > ClientHeight);
end;

procedure TMarkdownViewer.AutoScrollBy(const Delta: Single);
begin
  SetScrollPosition(FModel.ScrollOffset + Delta);
end;

procedure TMarkdownViewer.AutoScrollChanged;
begin
  Invalidate;

  if Assigned(FOnAutoScrollChange) then
    FOnAutoScrollChange(Self);
end;

// The message loop sends a key here before menu and action shortcuts and before
// the form's KeyPreview, so the key that ends autoscroll reaches none of them.
procedure TMarkdownViewer.CNKeyDown(var Message: TLMKeyDown);
begin
  if FAutoScroller.IsActive then
  begin
    FAutoScroller.Stop;
    Message.Result := 1;
    Exit;
  end;

  inherited;
end;

procedure TMarkdownViewer.WMKillFocus(var Message: TLMKillFocus);
begin
  inherited;

  FAutoScroller.Stop;
end;

// The native bar reports SB_THUMBTRACK with the pointer position, which is all
// this handler needs: unlike the VCL unit there is no second source of truth to
// ask (GetScrollInfo's SIF_TRACKPOS), and Message.Pos is a full LongInt.
procedure TMarkdownViewer.WMVScroll(var Message: TLMVScroll);
begin
  case Message.ScrollCode of
    SB_LINEUP:
      SetScrollPosition(FModel.ScrollOffset - LineScrollAmount);
    SB_LINEDOWN:
      SetScrollPosition(FModel.ScrollOffset + LineScrollAmount);
    SB_PAGEUP:
      SetScrollPosition(FModel.ScrollOffset - ClientHeight);
    SB_PAGEDOWN:
      SetScrollPosition(FModel.ScrollOffset + ClientHeight);
    SB_TOP:
      SetScrollPosition(0);
    SB_BOTTOM:
      ScrollToBottom;
    SB_THUMBPOSITION, SB_THUMBTRACK:
      SetScrollPosition(Message.Pos);
  end;

  Message.Result := 0;
end;

procedure TMarkdownViewer.WMEraseBkgnd(var Message: TLMEraseBkgnd);
begin
  Message.Result := 1;
end;

procedure TMarkdownViewer.WMGetDlgCode(var Message: TLMGetDlgCode);
begin
  Message.Result := DLGC_WANTARROWS;
end;

procedure TMarkdownViewer.CMMouseLeave(var Message: TLMessage);
begin
  inherited;

  Cursor := crDefault;
  SetHoveredLinkUrl('');
  FHasLastMousePoint := False;
  ClearCodeHover;
end;

procedure TMarkdownViewer.ScrollToBottom;
begin
  if FModel.DisplayList = nil then
    Exit;

  SetScrollPosition(FModel.DisplayList.Height);
end;

procedure TMarkdownViewer.SetScrollPosition(const Value: Single);
begin
  FModel.ScrollOffset := Value;
  UpdateScrollBar;
  Invalidate;

  if Assigned(FOnScroll) then
    FOnScroll(Self);
end;

// Pushes the content size and the offset out to the native bar.  Visible is set
// on the bar itself exactly when the content is taller than the view, which is
// what makes GTK3 grow (and shrink) the scrollbar; LCL then takes the bar out of
// ClientWidth, as Windows did.
procedure TMarkdownViewer.UpdateScrollBar;
var
  ContentSize: Integer;
  Bar: TControlScrollBar;
begin
  if (FModel = nil) or not HandleAllocated then
    Exit;

  if FUpdatingScrollBar then
    Exit;

  FUpdatingScrollBar := True;
  try
    ContentSize := 0;
    if FModel.DisplayList <> nil then
      ContentSize := Round(FModel.DisplayList.Height);

    Bar := VertScrollBar;
    Bar.Range := ContentSize;
    Bar.Page := Min(Max(1, ClientHeight), High(Bar.Page));
    Bar.Increment := Min(Max(1, LineScrollAmount), High(Bar.Increment));
    Bar.Position := Round(FModel.ScrollOffset);
    UpdateScrollbars;
  finally
    FUpdatingScrollBar := False;
  end;
end;

procedure TMarkdownViewer.ScrollBy(DeltaX, DeltaY: Integer);
begin
  // Deliberately not inherited: the content is painted from the model offset,
  // so a widgetset blit would only leave stale pixels behind.
  Invalidate;
end;

function TMarkdownViewer.LineScrollAmount: Integer;
begin
  Result := MulDiv(ScrollLineDips, ContentPixelsPerInch, ReferencePixelsPerInch);
end;

// The content follows the scale the desktop reports, as its size does.  LCL
// folds the monitor scale into Screen.PixelsPerInch, so this is the DPI the
// layout engine must convert its device-independent lengths against.
function TMarkdownViewer.ContentPixelsPerInch: Integer;
begin
  Result := Screen.PixelsPerInch;
  if Result <= 0 then
    Result := ReferencePixelsPerInch;
end;

function TMarkdownViewer.ContentPointOf(const X, Y: Integer): TLayoutPointF;
begin
  Result := TLayoutPointF.Create(X, Y + FModel.ScrollOffset);
end;

procedure TMarkdownViewer.UpdateHoverCursor(const Point: TLayoutPointF);
var
  Url: string;
  DisclosureKey: Integer;
  IsOverLink: Boolean;
  IsOverDisclosure: Boolean;
begin
  IsOverLink := TryFindLinkUrl(Point, Url);
  IsOverDisclosure := FModel.TryGetDisclosureAt(Point, DisclosureKey);
  if IsOverLink or IsOverDisclosure then
    Cursor := crHandPoint
  else
    Cursor := crDefault;

  SetHoveredLinkUrl(Url);
end;

procedure TMarkdownViewer.SetHoveredLinkUrl(const Value: string);
begin
  if Value = FHoveredLinkUrl then
    Exit;

  FHoveredLinkUrl := Value;
  if Assigned(FOnLinkHover) then
    FOnLinkHover(Self, FHoveredLinkUrl);
end;

function TMarkdownViewer.TryFindLinkUrl(const Point: TLayoutPointF; out Url: string): Boolean;
var
  Link: IMarkdownLink;
begin
  Url := '';
  if FModel.DisplayList = nil then
  begin
    Result := False;
    Exit;
  end;

  Result := TMarkdownHitTester.TryFindLink(FModel.DisplayList, Point, Link);
  if Result then
    Url := Link.Destination;
end;

procedure TMarkdownViewer.UpdateCodeHover(const Point: TLayoutPointF);
var
  Region: TMarkdownCodeBlockRegion;
  OverCode: Boolean;
  Fits: Boolean;
  Right: Single;
  Top: Single;
  ButtonRect: TLayoutRectF;
  Unchanged: Boolean;
begin
  OverCode := FModel.TryGetCodeBlockAt(Point, Region);
  Fits := OverCode and (Region.Rect.Width >= CopyButtonWidth + 2 * CopyButtonMargin) and
    (Region.Rect.Height >= CopyButtonHeight + CopyButtonMargin);

  if not Fits then
  begin
    if FCodeHoverActive then
    begin
      FCodeHoverActive := False;
      FCopyFeedback := False;
      Invalidate;
    end;
    Exit;
  end;

  Right := Region.Rect.Right - CopyButtonMargin;
  Top := Region.Rect.Top + CopyButtonMargin;
  ButtonRect := TLayoutRectF.Create(Right - CopyButtonWidth, Top, Right, Top + CopyButtonHeight);

  Unchanged := FCodeHoverActive and SameValue(FCodeHoverRect.Top, Region.Rect.Top) and
    SameValue(FCodeHoverRect.Left, Region.Rect.Left) and (FCodeHoverText = Region.Text);
  if Unchanged then
    Exit;

  FCodeHoverActive := True;
  FCodeHoverRect := Region.Rect;
  FCodeHoverText := Region.Text;
  FCopyButtonRect := ButtonRect;
  FCopyFeedback := False;
  Invalidate;
end;

function TMarkdownViewer.PointOnCopyButton(const Point: TLayoutPointF): Boolean;
begin
  Result := FCodeHoverActive and FCopyButtonRect.Contains(Point);
end;

procedure TMarkdownViewer.ClearCodeHover;
begin
  if FCodeHoverActive or FCopyFeedback then
  begin
    FCodeHoverActive := False;
    FCopyFeedback := False;
    FCodeHoverText := '';
    Invalidate;
  end;
end;

procedure TMarkdownViewer.CopyCodeToClipboard(const Text: string);
begin
  if Text = '' then
    Exit;

  try
    Clipboard.AsText := UTF8Encode(Text);
  except
    Exit;
  end;
end;

procedure TMarkdownViewer.HandleCopyFeedbackTimer(Sender: TObject);
begin
  FCopyFeedback := False;
  FCopyFeedbackTimer.Enabled := False;
  Invalidate;
end;

procedure TMarkdownViewer.DrawCopyButton(const Painter: IPainter);
var
  Caption: string;
  Font: TMarkdownFontStyle;
  Size: TLayoutSizeF;
  Tx: Single;
  Ty: Single;
  LabelColor: TLayoutColor;
begin
  Caption := CopyCodeCaption;
  if FCopyFeedback then
    Caption := CopiedCodeCaption;

  Font := TMarkdownFontStyle.Create(FTheme.BaseFont.FamilyName, CopyButtonFontSize);

  Painter.FillRect(FCopyButtonRect, FTheme.BackgroundColor);
  Painter.DrawRect(FCopyButtonRect, FTheme.TableBorderColor, CopyButtonStrokeWidth);

  Size := Painter.MeasureText(Caption, Font);
  Tx := FCopyButtonRect.Left + (CopyButtonWidth - Size.Width) / 2;
  Ty := FCopyButtonRect.Top + (CopyButtonHeight - Painter.LineHeight(Font)) / 2;

  LabelColor := FTheme.BlockQuoteTextColor;
  if FCopyFeedback then
    LabelColor := FTheme.LinkColor;

  Painter.DrawTextRun(TLayoutPointF.Create(Tx, Ty), Caption, Font, LabelColor);
end;

procedure TMarkdownViewer.ResolvePendingImages;
var
  Source: string;
begin
  for Source in FModel.PendingImageSources do
    ResolvePendingImage(Source);
end;

procedure TMarkdownViewer.ResolvePendingImage(const Source: string);
var
  Url: string;
  Resolved: Boolean;
begin
  if FRequestedImageSources.ContainsKey(Source) then
    Exit;

  Resolved := TMarkdownViewerShared.TryResolveImageUrl(Source, FImages.BaseUrl, FDocumentFolder,
    FImages.RestrictToDocumentFolder, Url);
  if not Resolved then
  begin
    ApplyFailedImage(Source);
    Exit;
  end;

  if TryResolveImageThroughEvent(Source, Url) then
    Exit;

  if TMarkdownViewerShared.IsHttpUrl(Url) then
  begin
    if not AllowsRemoteImage(Url) then
    begin
      ApplyFailedImage(Source);
      Exit;
    end;

    FRequestedImageSources.Add(Source, True);
    FImageDownloader.Download(Source, Url, FImages.MaxBytes);
    Exit;
  end;

  LoadLocalImage(Source, Url);
end;

// Starts from the setting and lets the application narrow or widen it per
// address, which is the point of having the event at all.
function TMarkdownViewer.AllowsRemoteImage(const Url: string): Boolean;
begin
  Result := FImages.AllowRemote;

  if Assigned(FOnRemoteImageRequest) then
    FOnRemoteImageRequest(Self, Url, Result);
end;

function TMarkdownViewer.TryResolveImageThroughEvent(const Source, Url: string): Boolean;
var
  Picture: TPicture;
  Handled: Boolean;
begin
  if not Assigned(FOnResolveImage) then
  begin
    Result := False;
    Exit;
  end;

  Picture := TPicture.Create;
  try
    Handled := False;
    FOnResolveImage(Self, Url, Picture, Handled);
    if not Handled then
    begin
      Result := False;
      Exit;
    end;

    ApplyLoadedPicture(Source, Picture);
    Result := True;
  finally
    Picture.Free;
  end;
end;

procedure TMarkdownViewer.LoadLocalImage(const Source, FilePath: string);
var
  FileData: TBytes;
  Picture: TPicture;
begin
  if not TFile.Exists(FilePath) then
  begin
    ApplyFailedImage(Source);
    Exit;
  end;

  if TMarkdownSvgSupport.IsAvailable then
  begin
    FileData := TFile.ReadAllBytes(FilePath);
    if TMarkdownSvgSupport.LooksLikeSvg(FileData) then
    begin
      if not TryLoadSvg(Source, FileData) then
        ApplyFailedImage(Source);
      Exit;
    end;
  end;

  Picture := TPicture.Create;
  try
    try
      Picture.LoadFromFile(FilePath);
    except
      // PNG, JPEG, GIF and BMP each fail decoding through their own exception
      // hierarchy (EPngError does not descend from EInvalidGraphic, unlike
      // EJPEG and GIFException), so no single specific type covers a corrupt
      // file across the registered graphic classes.
      ApplyFailedImage(Source);
      Exit;
    end;

    ApplyLoadedPicture(Source, Picture);
  finally
    Picture.Free;
  end;
end;

procedure TMarkdownViewer.HandleImageDataArrived(const Source: string; const Data: TBytes);
var
  Picture: TPicture;
  Stream: TBytesStream;
begin
  FRequestedImageSources.Remove(Source);

  if TMarkdownSvgSupport.IsAvailable and TMarkdownSvgSupport.LooksLikeSvg(Data) then
  begin
    if not TryLoadSvg(Source, Data) then
      ApplyFailedImage(Source);
    Exit;
  end;

  Picture := TPicture.Create;
  try
    Stream := TBytesStream.Create(Data);
    try
      try
        Picture.LoadFromStream(Stream);
      except
        // Same reasoning as LoadLocalImage: a downloaded image is an outside
        // boundary, and its format's decoder does not share a specific
        // exception with the others registered on TPicture.
        ApplyFailedImage(Source);
        Exit;
      end;
    finally
      Stream.Free;
    end;

    ApplyLoadedPicture(Source, Picture);
  finally
    Picture.Free;
  end;
end;

procedure TMarkdownViewer.HandleImageDownloadFailed(const Source: string);
begin
  FRequestedImageSources.Remove(Source);
  ApplyFailedImage(Source);
end;

// The SVG engine hands back a premultiplied BGRA raster, which is the same
// 32-bit layout a TLazIntfImage built as B8G8R8A8 wants; going through the
// image (rather than ScanLine on a bitmap) is what keeps its alpha.
function TMarkdownViewer.TryLoadSvg(const Source: string; const Data: TBytes): Boolean;
var
  Raster: TMarkdownSvgRaster;
  Picture: TPicture;
  Bitmap: TBitmap;
  Image: TLazIntfImage;
  Description: TRawImageDescription;
  Row: Integer;
  RowBytes: Integer;
begin
  if not TMarkdownSvgSupport.TryRasterize(Data, 0, 0, Raster) then
  begin
    Result := False;
    Exit;
  end;

  Picture := TPicture.Create;
  try
    Bitmap := TBitmap.Create;
    try
      Image := TLazIntfImage.Create(0, 0);
      try
        Description.Init_BPP32_B8G8R8A8_BIO_TTB(Raster.Width, Raster.Height);
        Image.DataDescription := Description;

        RowBytes := Raster.Width * 4;
        for Row := 0 to Raster.Height - 1 do
          Move(Raster.Pixels[Row * RowBytes], PByte(Image.GetDataLineStart(Row))^, RowBytes);

        Bitmap.LoadFromIntfImage(Image);
      finally
        Image.Free;
      end;

      Picture.Bitmap.Assign(Bitmap);
    finally
      Bitmap.Free;
    end;

    ApplyLoadedPicture(Source, Picture);
  finally
    Picture.Free;
  end;

  Result := True;
end;

procedure TMarkdownViewer.ApplyLoadedPicture(const Source: string; const Picture: TPicture);
var
  HasGraphic: Boolean;
begin
  HasGraphic := (Picture.Graphic <> nil) and not Picture.Graphic.Empty;
  if not HasGraphic then
  begin
    ApplyFailedImage(Source);
    Exit;
  end;

  StoreLoadedImage(Source, Picture.Graphic);
  FModel.NotifyImageArrived(Source, TLayoutSizeF.Create(Picture.Graphic.Width, Picture.Graphic.Height));
  UpdateScrollBar;
  Invalidate;
end;

procedure TMarkdownViewer.ApplyFailedImage(const Source: string);
begin
  FModel.NotifyImageFailed(Source);
  Invalidate;
end;

procedure TMarkdownViewer.StoreLoadedImage(const Source: string; const Graphic: TGraphic);
var
  Clone: TGraphic;
begin
  Clone := TGraphicClass(Graphic.ClassType).Create;
  try
    Clone.Assign(Graphic);
  except
    Clone.Free;
    raise;
  end;

  FLoadedImages.AddOrSetValue(Source, Clone);
end;

function TMarkdownViewer.GetContentHeight: Integer;
begin
  Result := 0;
  if FModel.DisplayList <> nil then
    Result := Ceil(FModel.DisplayList.Height);
end;

function TMarkdownViewer.GetScrollOffset: Single;
begin
  Result := FModel.ScrollOffset;
end;

function TMarkdownViewer.GetDisplayList: IMarkdownDisplayList;
begin
  Result := FModel.DisplayList;
end;

function TMarkdownViewer.GetLayoutCount: Integer;
begin
  Result := FModel.LayoutCount;
end;

function TMarkdownViewer.GetText: string;
begin
  Result := FModel.FullText;
end;

procedure TMarkdownViewer.SetText(const Value: string);
begin
  if InvokeOnMainThread(
    procedure
    begin
      SetText(Value);
    end) then
    Exit;

  FDesignSampleActive := False;
  FImageDownloader.CancelPending;
  FRequestedImageSources.Clear;
  ClearCodeHover;
  FModel.Text := Value;
  FModel.ScrollOffset := 0;
  ResolvePendingImages;
  UpdateScrollBar;
  Invalidate;
end;

procedure TMarkdownViewer.SetImages(const Value: TMarkdownViewerImageSettings);
begin
  FImages.Assign(Value);
end;

function TMarkdownViewer.IsTextStored: Boolean;
begin
  Result := not FDesignSampleActive;
end;

procedure TMarkdownViewer.SetThemePreset(const Value: TMarkdownThemePreset);
begin
  FThemePreset := Value;

  if FOwnsTheme then
    FTheme.Free;

  FTheme := TMarkdownTheme.CreatePreset(Value);
  FOwnsTheme := True;
  ClearCodeHover;
  FModel.ApplyTheme(FTheme);
  UpdateScrollBar;
  Invalidate;
end;

procedure TMarkdownViewer.SetTheme(const Value: TMarkdownTheme);
var
  IsUnchanged: Boolean;
begin
  IsUnchanged := (Value = nil) or (Value = FTheme);
  if IsUnchanged then
    Exit;

  if FOwnsTheme then
    FTheme.Free;

  FTheme := Value;
  FOwnsTheme := False;
  ClearCodeHover;
  FModel.ApplyTheme(FTheme);
  UpdateScrollBar;
  Invalidate;
end;

function TMarkdownViewer.GetSelectedText: string;
begin
  Result := FModel.SelectedText;
end;

function TMarkdownViewer.TryGetSelectionSourceSegment(out Segment: TMarkdownSegment): Boolean;
begin
  Result := FModel.TryGetSelectionSourceSegment(Segment);
end;

end.
