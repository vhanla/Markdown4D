unit Markdown4D.Lcl.AutoScroll;

{$I ../Markdown4D.Fpc.inc}

// ============================================================================
//  Markdown4D.Lcl.AutoScroll
//
//  FPC/LCL counterpart of Markdown4D.Vcl.AutoScroll.  Middle-click autoscroll
//  for an LCL control: it holds the mouse, steps the scrolling on a timer from
//  wherever the pointer is, also outside the window, and shows the pan cursor
//  for the direction.
//
//  Two platform details differ from the VCL unit:
//
//    * CAPTURE -- Win32 used SetCapture/GetCapture through the control; LCL
//      offers the process-wide SetCaptureControl/GetCaptureControl helpers in
//      Controls, which is what the mouse-capture contract is built on here.
//    * CURSOR -- the pan cursors live in Markdown4D.AutoScroll.Cursors, which
//      is Windows-only.  On every other platform it reports that it applied
//      nothing, so the control's own cursor is left alone and there is nothing
//      to put back on stop.
// ============================================================================

interface

uses
  Classes,
  Types,
  Controls,
  ExtCtrls,
  Markdown4D.Layout.Interfaces,
  Markdown4D.AutoScroll;

type
  TMarkdownLclAutoScroller = class
  private
    const
      TickMilliseconds = 16;
      StandardPixelsPerInch = 96;
    var
      FControl: TControl;
      FTarget: IMarkdownAutoScrollTarget;
      FAutoScroll: TMarkdownAutoScroll;
      FTimer: TTimer;
      FEnabled: Boolean;
      FStoppedByRightClick: Boolean;
      FCursorApplied: Boolean;
    procedure HandleTimer(Sender: TObject);
    procedure SetEnabled(const Value: Boolean);
    function TryStart(const X, Y: Integer): Boolean;
    function PointerInControl: TPoint;
    function Scale: Single;
    procedure ShowCursor(const PointerY: Integer);
    procedure RestoreCursor;
    function OwnCursor: TCursor;

  public
    constructor Create(const Control: TControl; const Target: IMarkdownAutoScrollTarget);
    destructor Destroy; override;
    function IsActive: Boolean;
    // A press while autoscrolling only ends it; a middle press starts it.
    // True when the press is taken.
    function TryHandlePress(const Button: TMouseButton; const X, Y: Integer): Boolean;
    // True once after a right click ended autoscroll, so that click opens no
    // context menu either.
    function TakeSuppressedMenu: Boolean;
    procedure HandleMove(const X, Y: Integer);
    procedure HandleMiddleUp;
    procedure Stop;
    procedure PaintOrigin(const Painter: IPainter; const BackgroundColor, TextColor: TLayoutColor);
    property Enabled: Boolean read FEnabled write SetEnabled;
  end;

implementation

uses
  SysUtils,
  Forms,
  Markdown4D.AutoScroll.Icon,
  Markdown4D.AutoScroll.Cursors;

constructor TMarkdownLclAutoScroller.Create(const Control: TControl;
  const Target: IMarkdownAutoScrollTarget);
begin
  inherited Create;

  FControl := Control;
  FTarget := Target;
  FEnabled := True;

  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := TickMilliseconds;
  FTimer.OnTimer := HandleTimer;
end;

destructor TMarkdownLclAutoScroller.Destroy;
begin
  FTimer.Free;

  inherited Destroy;
end;

function TMarkdownLclAutoScroller.IsActive: Boolean;
begin
  Result := FAutoScroll.IsActive;
end;

procedure TMarkdownLclAutoScroller.SetEnabled(const Value: Boolean);
begin
  FEnabled := Value;
  if not Value then
    Stop;
end;

function TMarkdownLclAutoScroller.TryHandlePress(const Button: TMouseButton; const X, Y: Integer): Boolean;
var
  Focusable: TWinControl;
begin
  if IsActive then
  begin
    FStoppedByRightClick := (Button = TMouseButton.mbRight);
    Stop;
    Result := True;
    Exit;
  end;

  Result := (Button = TMouseButton.mbMiddle) and FEnabled;
  if not Result then
    Exit;

  if FControl is TWinControl then
  begin
    Focusable := TWinControl(FControl);
    if Focusable.CanFocus then
      Focusable.SetFocus;
  end;

  TryStart(X, Y);
end;

function TMarkdownLclAutoScroller.TakeSuppressedMenu: Boolean;
begin
  Result := FStoppedByRightClick;
  FStoppedByRightClick := False;
end;

function TMarkdownLclAutoScroller.TryStart(const X, Y: Integer): Boolean;
begin
  Result := FEnabled and FTarget.CanAutoScroll;
  if not Result then
    Exit;

  FAutoScroll.Start(X, Y, Scale, GetTickCount64);
  SetCaptureControl(FControl);
  FTimer.Enabled := True;

  ShowCursor(Y);
  FTarget.AutoScrollChanged;
end;

procedure TMarkdownLclAutoScroller.HandleMove(const X, Y: Integer);
begin
  if not IsActive then
    Exit;

  FAutoScroll.PointerMoved(X, Y);
  ShowCursor(Y);
end;

procedure TMarkdownLclAutoScroller.HandleMiddleUp;
var
  Stopped: Boolean;
begin
  if not IsActive then
    Exit;

  Stopped := FAutoScroll.Release;
  if Stopped then
    Stop;
end;

procedure TMarkdownLclAutoScroller.Stop;
var
  WasActive: Boolean;
begin
  WasActive := IsActive;

  FAutoScroll.Stop;
  FTimer.Enabled := False;
  if not WasActive then
    Exit;

  if GetCaptureControl = FControl then
    SetCaptureControl(nil);
  RestoreCursor;
  FTarget.AutoScrollChanged;
end;

// Only the platforms whose cursor unit applied a pan cursor have anything to
// put back; on Linux TryApply reports False and the control's own cursor was
// never replaced, so the widgetset keeps painting it as it moves along.
procedure TMarkdownLclAutoScroller.RestoreCursor;
begin
  if not FCursorApplied then
    Exit;

  FCursorApplied := False;
  FControl.Cursor := OwnCursor;
end;

function TMarkdownLclAutoScroller.OwnCursor: TCursor;
begin
  Result := FControl.Cursor;
  if Result = crDefault then
    Result := crArrow;
end;

procedure TMarkdownLclAutoScroller.PaintOrigin(const Painter: IPainter;
  const BackgroundColor, TextColor: TLayoutColor);
var
  Origin: TLayoutPointF;
begin
  if not IsActive then
    Exit;

  Origin := TLayoutPointF.Create(FAutoScroll.OriginX, FAutoScroll.OriginY);
  TMarkdownAutoScrollIcon.Paint(Painter, Origin, Scale, BackgroundColor, TextColor);
end;

procedure TMarkdownLclAutoScroller.HandleTimer(Sender: TObject);
var
  Pointer: TPoint;
  Delta: Single;
begin
  if not IsActive then
  begin
    FTimer.Enabled := False;
    Exit;
  end;

  Pointer := PointerInControl;
  ShowCursor(Pointer.Y);

  Delta := FAutoScroll.Step(GetTickCount64, Pointer.Y);
  if Delta <> 0 then
    FTarget.AutoScrollBy(Delta);
end;

function TMarkdownLclAutoScroller.PointerInControl: TPoint;
var
  ScreenPoint: TPoint;
begin
  ScreenPoint := Mouse.CursorPos;

  Result := FControl.ScreenToClient(ScreenPoint);
end;

function TMarkdownLclAutoScroller.Scale: Single;
begin
  Result := Screen.PixelsPerInch / StandardPixelsPerInch;
end;

procedure TMarkdownLclAutoScroller.ShowCursor(const PointerY: Integer);
var
  Direction: TMarkdownAutoScrollDirection;
begin
  Direction := FAutoScroll.Direction(PointerY);
  if TMarkdownAutoScrollCursors.TryApply(Direction) then
    FCursorApplied := True;
end;

end.
