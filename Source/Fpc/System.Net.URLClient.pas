unit System.Net.URLClient;

// ============================================================================
//  Minimal FPC stand-in for Delphi's System.Net.URLClient.
//
//  The neutral code only names this unit as the origin of the URL types the
//  HTTP client uses; it never calls into it directly.  FPC has no such unit, so
//  this file exists to satisfy the `uses` clause of
//  Markdown4D.Viewer.ImageDownloader.  The header types are re-exported from
//  the HTTP client shim so a caller that expects them here still finds them.
// ============================================================================

{$MODE DELPHIUNICODE}
{$H+}

interface

type
  TNetHeader = record
    Name: string;
    Value: string;
  end;

  TNetHeaders = array of TNetHeader;

implementation

end.
