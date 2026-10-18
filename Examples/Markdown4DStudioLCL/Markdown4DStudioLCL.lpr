program Markdown4DStudioLCL;

// Markdown4DStudioLCL -- the Lazarus (LCL) counterpart of the VCL and FMX
// Studios: an editor with a live preview, a contents panel, formatting
// commands, find and replace, zoom, a light and a dark theme, and HTML export.
//
// Build (from the repository root, after tools/fpcport/makefpc.sh):
//
//   tools/fpcport/lclbuild.sh build/fpc \
//     Examples/Markdown4DStudioLCL/Markdown4DStudioLCL.lpr
//
// Run, optionally on a file:
//
//   DISPLAY=:0 ./Markdown4DStudioLCL ../Shared/demo.md
//
// Or open Markdown4DStudioLCL.lpi in Lazarus and press F9.

{$I ../../Source/Markdown4D.Fpc.inc}

uses
  // The viewer's image downloader runs on TTask, which links FPC's
  // System.Threading; on Unix that requires cthreads to be the very first unit,
  // or its thread pool crashes while the units initialize.
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Forms,
  Markdown4DStudioLCL.Main;

begin
  Application.Initialize;
  StudioForm := TStudioLCLForm.CreateNew(nil);
  StudioForm.Show;
  StudioForm.OpenStartupDocument;
  Application.Run;
end.
