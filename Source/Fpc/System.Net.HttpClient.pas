unit System.Net.HttpClient;

// ============================================================================
//  Minimal FPC stand-in for Delphi's System.Net.HttpClient.
//
//  FPC ships no HTTP client in the System.Net namespace.  The nearest real
//  implementation is fcl-web's TFPHTTPClient, which this unit wraps under the
//  names the neutral code uses: THTTPClient, IHTTPResponse and
//  TReceiveDataCallback.
//
//  Only the surface Markdown4D.Viewer.ImageDownloader relies on is provided:
//    * the two timeout properties, HandleRedirects and ReceiveDataCallback;
//    * a single Get(URL, Stream) returning a status and its headers, so the
//      caller can inspect a redirect's Location without the client following
//      it (redirects are judged one hop at a time by the caller).
//
//  HTTPS works through fcl-web's opensslsockets handler.
// ============================================================================

{$MODE DELPHIUNICODE}
{$H+}

interface

uses
  Classes;

type
  IHTTPResponse = interface
    function GetStatusCode: Integer;
    function GetHeaderValue(const AName: string): string;
    property StatusCode: Integer read GetStatusCode;
    property HeaderValue[const AName: string]: string read GetHeaderValue; default;
  end;

  // Delphi types this as an anonymous-method reference, and the caller assigns
  // one; a `reference to procedure` matches, a `of object` pointer would not.
  TReceiveDataCallback = reference to procedure(const Sender: TObject;
    AContentLength, AReadCount: Int64; var AAbort: Boolean);

  THTTPClient = class
  private
    FConnectionTimeout: Integer;
    FResponseTimeout: Integer;
    FHandleRedirects: Boolean;
    FReceiveDataCallback: TReceiveDataCallback;
    FLastRead: Int64;
    procedure DataReceived(Sender: TObject; const ContentLength, CurrentPos: Int64);
  public
    constructor Create;
    function Get(const AURL: string; const AResponseContent: TStream): IHTTPResponse;
    property ConnectionTimeout: Integer read FConnectionTimeout write FConnectionTimeout;
    property ResponseTimeout: Integer read FResponseTimeout write FResponseTimeout;
    property HandleRedirects: Boolean read FHandleRedirects write FHandleRedirects;
    property ReceiveDataCallback: TReceiveDataCallback
      read FReceiveDataCallback write FReceiveDataCallback;
  end;

implementation

uses
  SysUtils,
  fphttpclient,
  opensslsockets;

type
  TMarkdownHttpResponse = class(TInterfacedObject, IHTTPResponse)
  private
    FStatus: Integer;
    FHeaders: TStringList;
  public
    constructor Create(const AStatus: Integer; const AHeaders: TStrings);
    destructor Destroy; override;
    function GetStatusCode: Integer;
    function GetHeaderValue(const AName: string): string;
  end;

constructor TMarkdownHttpResponse.Create(const AStatus: Integer;
  const AHeaders: TStrings);
begin
  inherited Create;
  FStatus := AStatus;
  FHeaders := TStringList.Create;
  if AHeaders <> nil then
    FHeaders.Assign(AHeaders);
end;

destructor TMarkdownHttpResponse.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

function TMarkdownHttpResponse.GetStatusCode: Integer;
begin
  Result := FStatus;
end;

function TMarkdownHttpResponse.GetHeaderValue(const AName: string): string;
var
  Index: Integer;
begin
  Index := FHeaders.IndexOfName(AName);
  if Index >= 0 then
    Result := FHeaders.ValueFromIndex[Index]
  else
    Result := '';
end;

constructor THTTPClient.Create;
begin
  inherited Create;
  FConnectionTimeout := 0;
  FResponseTimeout := 0;
  FHandleRedirects := True;
end;

procedure THTTPClient.DataReceived(Sender: TObject; const ContentLength,
  CurrentPos: Int64);
var
  Abort: Boolean;
begin
  if not Assigned(FReceiveDataCallback) then
    Exit;

  Abort := False;
  FReceiveDataCallback(Self, ContentLength, CurrentPos - FLastRead, Abort);
  FLastRead := CurrentPos;
  if Abort then
    raise EAbort.Create('download aborted by ReceiveDataCallback');
end;

function THTTPClient.Get(const AURL: string;
  const AResponseContent: TStream): IHTTPResponse;
var
  Client: TFPHTTPClient;
begin
  Client := TFPHTTPClient.Create(nil);
  try
    Client.AllowRedirect := FHandleRedirects;
    Client.ConnectTimeout := FConnectionTimeout;
    Client.IOTimeout := FResponseTimeout;
    Client.OnDataReceived := DataReceived;
    FLastRead := 0;
    Client.Get(AURL, AResponseContent);
    Result := TMarkdownHttpResponse.Create(Client.ResponseStatusCode,
      Client.ResponseHeaders);
  finally
    Client.Free;
  end;
end;

end.
