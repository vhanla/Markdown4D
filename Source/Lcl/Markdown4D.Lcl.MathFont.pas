unit Markdown4D.Lcl.MathFont;

{$I ../Markdown4D.Fpc.inc}

// ============================================================================
//  Markdown4D.Lcl.MathFont
//
//  FPC/LCL counterpart of Markdown4D.Vcl.MathFont.  Using this unit installs the
//  bundled STIX Two Math font so formulas look the same on every machine, and
//  leaves the platform's own math font in place when it cannot.
//
//  Windows installs a font for the process with AddFontMemResourceEx, straight
//  from memory.  Linux has no such call: text reaches the screen through
//  fontconfig, so the bundled OTF is unpacked once to a temporary file and added
//  to the application's fontconfig configuration, which is the same set Pango --
//  and therefore GTK -- resolves family names against.
//
//  The resource is the one the VCL unit uses, embedded the FPC way (a plain
//  {$R} directive) rather than a Delphi linker resource.
// ============================================================================

interface

implementation

uses
  DynLibs,
  SysUtils,
  Classes,
  // libfontconfig is loaded lazily through its own binding so a machine without
  // it simply skips the step instead of failing to start.  DynLibs must come
  // first: it installs the platform's dynamic-loader driver that libfontconfig
  // needs to open the shared library.
  libfontconfig,
  Markdown4D.Math.Font;

{$R '../Fonts/STIXTwoMath.res'}

const
  ResourceName = 'STIXTWOMATH';

// Adds the unpacked font file to the current fontconfig configuration.  Returns
// False when fontconfig is not present or refuses the file, in which case the
// caller leaves the math font unregistered and the painter falls back to the
// platform's own.
function RegisterWithFontConfig(const FileName: string): Boolean;
var
  Config: PFcConfig;
  Path: AnsiString;
begin
  Result := False;

  if LoadFontConfigLib('', False) = 0 then
    Exit;

  if Assigned(FcInit) then
    FcInit;

  if not Assigned(FcConfigGetCurrent) or not Assigned(FcConfigAppFontAddFile) then
    Exit;

  Config := FcConfigGetCurrent();
  Path := UTF8Encode(FileName);
  Result := FcConfigAppFontAddFile(Config, PAnsiChar(Path)) <> 0;
end;

function InstallBundledMathFont: string;
var
  Stream: TResourceStream;
  FileName: string;
begin
  Result := '';

  try
    Stream := TResourceStream.Create(HInstance, ResourceName, RT_RCDATA);
    try
      FileName := IncludeTrailingPathDelimiter(GetTempDir) + 'markdown4d-STIXTwoMath.otf';
      Stream.SaveToFile(FileName);
    finally
      Stream.Free;
    end;
  except
    // A missing or unreadable resource is not fatal: the platform math font is
    // still there to fall back to.
    on Exception do
      Exit;
  end;

  if RegisterWithFontConfig(FileName) then
    Result := TMarkdownMathFont.BundledFamilyName;
end;

initialization
  TMarkdownMathFont.RegisterInstaller(InstallBundledMathFont);

end.
