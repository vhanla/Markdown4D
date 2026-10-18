program StreamingMarkdownLCL;

// StreamingMarkdownLCL -- the Lazarus (LCL) counterpart of the VCL and FMX
// streaming chat demos: a chat window whose answers render as they stream in.
//
// Build (from the repository root, after tools/fpcport/makefpc.sh):
//
//   tools/fpcport/lclbuild.sh build/fpc \
//     Examples/StreamingMarkdownLCL/StreamingMarkdownLCL.lpr
//
// Run:
//
//   DISPLAY=:0 ./StreamingMarkdownLCL
//
// Or open StreamingMarkdownLCL.lpi in Lazarus and press F9.

{$I ../../Source/Markdown4D.Fpc.inc}

uses
  // The viewer's image downloader runs on TTask, which links FPC's
  // System.Threading; on Unix that requires cthreads to be the very first unit,
  // or its thread pool crashes while the units initialize.
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Forms,
  StreamingMarkdownLCL.Main;

begin
  Application.Initialize;
  StreamingMarkdownLCLForm := TStreamingMarkdownLCLForm.CreateNew(nil);
  StreamingMarkdownLCLForm.Show;
  Application.Run;
end.
