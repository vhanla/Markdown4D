unit Markdown4D.Layout.Defaults;

{$SCOPEDENUMS ON}

interface

const
  // Shared viewer/editor defaults, framework-neutral: the VCL and FMX
  // implementations must stay in lockstep on these values.
  ReferencePixelsPerInch = 96;
  WheelLinesPerNotch = 3;
  MouseWheelDeltaPerNotch = 120;
  ScrollLineDips = 40;
  TextLeftPaddingDips = 6;
  GutterPaddingDips = 8;
  CaretWidthDips = 1;
  FlushTimerIntervalMilliseconds = 25;
  AutoScrollIntervalMilliseconds = 50;
  PreviewDebounceIntervalMilliseconds = 60;

  // Font family mapping shared by the VCL and FMX painters
  MonospaceFamilyName = 'monospace';
  SansSerifFamilyName = 'sans-serif';
  SerifFamilyName = 'serif';
  MathFamilyName = 'math';
  MonospaceFallbackFamilyName = 'Consolas';
  SerifFallbackFamilyName = 'Georgia';
  DefaultFallbackFamilyName = 'Segoe UI';

  // Concrete monospace families, in preference order.  Every entry is known to
  // be monospace: when the family a document asks for (the themes use
  // 'Consolas') is not installed, the painters walk this list and take the
  // first entry the system has, instead of falling back to
  // DefaultFallbackFamilyName -- the proportional UI font.  Column alignment in
  // code blocks, in tables of characters and in ASCII art depends on the face
  // really being monospace, and the fallback is what silently broke it off
  // Windows (see TMarkdownViewerShared.IsMonospaceFamilyName).
  MonospaceFamilyCandidates: array[0..8] of string = (
    'Consolas', 'Cascadia Mono', 'Menlo', 'Monaco', 'DejaVu Sans Mono',
    'Liberation Mono', 'Noto Sans Mono', 'Ubuntu Mono', 'Courier New');

  ColorChannelMax = 255;

  UnbalancedRestoreMessage = 'RestoreState called without a matching SaveState';

implementation

end.
