unit Markdown4D.Lcl.Register;

{$I ../Markdown4D.Fpc.inc}

// ============================================================================
//  Markdown4D.Lcl.Register
//
//  Design-time entry point for the Lazarus package: the one unit a component
//  package lists to have the viewer and the editor appear on the palette.
//
//  The LCL side needs no equivalent of the VCL unit's registration of style
//  hooks -- the widgetset paints its own controls -- and the rendering bridges
//  (SVG rasterizer, image decoder, FreeType glyph outliner, math font) register
//  themselves when their unit is part of the build, which the viewer and the
//  editor already guarantee.
// ============================================================================

interface

procedure Register;

implementation

uses
  Classes,
  Markdown4D.Lcl.Viewer,
  Markdown4D.Lcl.Editor;

procedure Register;
begin
  RegisterComponents('Markdown4D', [TMarkdownViewer, TMarkdownEditor]);
end;

end.
