program specrun;

// Runs the JSON specification corpora (Tests/specs) against the Free Pascal
// port of the parser: every example's markdown is rendered with
// TMarkdown.ToUnsafeHtml and compared with the expected HTML, the same check
// Tests/Markdown4D.Parser.Spec.Corpus.pas performs for the Delphi build.
//
//   specrun [<specs-dir>]        (default: Tests/specs)
//
// Exits non-zero when an example fails, so it can gate a porting run.

{$MODE DELPHIUNICODE}
{$H+}

uses
  SysUtils,
  Classes,
  fpjson,
  jsonparser,
  Markdown4D,
  Markdown4D.Defines,
  Markdown4D.Ast.Interfaces,
  Markdown4D.Pipeline,
  Markdown4D.Extensions.Interfaces,
  Markdown4D.Extensions.Chart,
  Markdown4D.Extensions.Mermaid;

type
  TCorpus = record
    FileName: string;
    Dialect: TMarkdownDialect;
  end;

const
  Corpora: array[0..2] of TCorpus = (
    (FileName: 'commonmark-0.31.2.json'; Dialect: TMarkdownDialect.CommonMark),
    (FileName: 'gfm-0.29.json'; Dialect: TMarkdownDialect.Gfm),
    (FileName: 'math.json'; Dialect: TMarkdownDialect.Gfm));
  // One failing example prints a small report; the rest are only counted.
  ReportLimit = 5;
  ExcerptLength = 160;

var
  Checks: Integer;
  Failures: Integer;

function ReadText(const Path: string): string;
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes, Stream.Size);
    if Length(Bytes) > 0 then
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function NormalizeLineEndings(const Value: string): string;
begin
  Result := StringReplace(Value, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
end;

function FieldText(const Item: TJSONObject; const Name: string): string;
var
  Value: TJSONData;
begin
  if Item.Find(Name, Value) then
    Result := Value.AsUnicodeString
  else
    Result := '';
end;

function FieldNumber(const Item: TJSONObject; const Name: string;
  const Default: Integer): Integer;
var
  Value: TJSONData;
begin
  if Item.Find(Name, Value) then
    Result := Value.AsInteger
  else
    Result := Default;
end;

function FieldFlag(const Item: TJSONObject; const Name: string;
  const Default: Boolean): Boolean;
var
  Value: TJSONData;
begin
  if Item.Find(Name, Value) then
    Result := Value.AsBoolean
  else
    Result := Default;
end;

function Excerpt(const Value: string): string;
begin
  Result := Value;
  if Length(Result) > ExcerptLength then
    Result := Copy(Result, 1, ExcerptLength) + '...';
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

procedure RunCorpus(const SpecsDir: string; const Corpus: TCorpus);
var
  Path: string;
  Data: TJSONData;
  Examples: TJSONArray;
  Item: TJSONObject;
  Number: Integer;
  Index: Integer;
  Failed: Integer;
  Markdown: string;
  Expected: string;
  Actual: string;
begin
  Path := IncludeTrailingPathDelimiter(SpecsDir) + Corpus.FileName;
  Data := GetJSON(ReadText(Path), True);
  try
    Examples := Data as TJSONArray;
    Failed := 0;
    for Index := 0 to Examples.Count - 1 do
    begin
      Item := Examples.Items[Index] as TJSONObject;
      Markdown := FieldText(Item, 'markdown');
      Expected := NormalizeLineEndings(FieldText(Item, 'html'));
      Actual := NormalizeLineEndings(TMarkdown.ToUnsafeHtml(Markdown, Corpus.Dialect));

      Inc(Checks);
      if Actual = Expected then
        Continue;

      Inc(Failed);
      Inc(Failures);
      if Failed > ReportLimit then
        Continue;

      Number := FieldNumber(Item, 'example', Index + 1);
      WriteLn(Format('%s example %d', [Corpus.FileName, Number]));
      WriteLn('  markdown: ', Excerpt(Markdown));
      WriteLn('  expected: ', Excerpt(Expected));
      WriteLn('  actual:   ', Excerpt(Actual));
    end;

    WriteLn(Format('%-24s %4d examples, %d failed',
      [Corpus.FileName, Examples.Count, Failed]));
  finally
    Data.Free;
  end;
end;

// ---------------------------------------------------------------------------
//  Extension corpora.
//
//  Detect-only checks, like the ones the Delphi suites run: a case marked
//  `detected` must expose a model through the extension-data channel the
//  pipeline fills in while it walks the document, and a fallback case must not.
//  The counts the corpus carries (-1 meaning "not applicable to this diagram")
//  are compared too, which is what the traversal fixes need to stay fixed.
// ---------------------------------------------------------------------------

function FindFirstCodeBlock(const Document: IMarkdownDocument;
  out Code: IMarkdownCodeBlock): Boolean;
var
  Index: Integer;
begin
  Code := nil;
  Result := False;
  for Index := 0 to Document.ChildCount - 1 do
  begin
    if Document.Children[Index].Kind <> TMarkdownNodeKind.CodeBlock then
      Continue;
    Code := Document.Children[Index] as IMarkdownCodeBlock;
    Result := True;
    Exit;
  end;
end;

function ChartKindName(const Kind: TChartKind): string;
begin
  case Kind of
    TChartKind.Bar: Result := 'bar';
    TChartKind.Line: Result := 'line';
    TChartKind.Pie: Result := 'pie';
    TChartKind.Doughnut: Result := 'doughnut';
    TChartKind.Radar: Result := 'radar';
    TChartKind.Scatter: Result := 'scatter';
  end;
end;

function MermaidKindName(const Kind: TMermaidDiagramKind): string;
begin
  case Kind of
    TMermaidDiagramKind.Flowchart: Result := 'flowchart';
    TMermaidDiagramKind.Sequence: Result := 'sequence';
    TMermaidDiagramKind.Pie: Result := 'pie';
  end;
end;

function MermaidDirectionName(const Direction: TMermaidDirection): string;
begin
  case Direction of
    TMermaidDirection.TB: Result := 'TB';
    TMermaidDirection.TD: Result := 'TD';
    TMermaidDirection.LR: Result := 'LR';
    TMermaidDirection.BT: Result := 'BT';
    TMermaidDirection.RL: Result := 'RL';
  end;
end;

function TextMismatch(const Field, Actual, Expected: string): string;
begin
  if Actual = Expected then
    Result := ''
  else
    Result := Format('%s "%s", expected "%s"', [Field, Actual, Expected]);
end;

function CountMismatch(const Field: string; const Actual, CorpusValue: Integer): string;
begin
  if (CorpusValue < 0) or (Actual = CorpusValue) then
    Result := ''
  else
    Result := Format('%s %d, expected %d', [Field, Actual, CorpusValue]);
end;

procedure RunChartCorpus(const SpecsDir: string);
var
  Path: string;
  Data: TJSONData;
  Cases: TJSONArray;
  Item: TJSONObject;
  Pipeline: IMarkdownPipeline;
  Document: IMarkdownDocument;
  Code: IMarkdownCodeBlock;
  Model: IChartModel;
  Index: Integer;
  Failed: Integer;
  CaseName: string;
  Markdown: string;
  Detail: string;
begin
  Path := IncludeTrailingPathDelimiter(SpecsDir) + 'charts.json';
  Data := GetJSON(ReadText(Path), True);
  try
    Pipeline := TMarkdownPipeline.Create.UseGfm.Use(TChartExtension.Create)
      .UnsafeHtml.Build;
    Cases := Data as TJSONArray;
    Failed := 0;

    for Index := 0 to Cases.Count - 1 do
    begin
      Item := Cases.Items[Index] as TJSONObject;
      CaseName := FieldText(Item, 'name');
      Markdown := FieldText(Item, 'markdown');
      Detail := '';

      Model := nil;
      Document := Pipeline.Parse(Markdown);
      if FieldFlag(Item, 'detected', False) then
      begin
        if not FindFirstCodeBlock(Document, Code) then
          Detail := 'no code block'
        else if not TChartExtension.TryGetModel(Code, Model) then
          Detail := 'no chart model'
        else
        begin
          Detail := TextMismatch('chartType', ChartKindName(Model.ChartKind),
            FieldText(Item, 'chartType'));
          if Detail = '' then
            Detail := CountMismatch('datasetCount', Model.DatasetCount,
              FieldNumber(Item, 'datasetCount', -1));
          if Detail = '' then
            Detail := CountMismatch('labelCount', Model.LabelCount,
              FieldNumber(Item, 'labelCount', -1));
        end;
      end
      else if FindFirstCodeBlock(Document, Code) and TChartExtension.TryGetModel(Code, Model) then
        Detail := 'unexpected chart model';

      Inc(Checks);
      if Detail = '' then
        Continue;

      Inc(Failed);
      Inc(Failures);
      if Failed <= ReportLimit then
        WriteLn(Format('charts.json %s: %s', [CaseName, Detail]));
    end;

    WriteLn(Format('%-24s %4d cases, %d failed', ['charts.json', Cases.Count, Failed]));
  finally
    Data.Free;
  end;
end;

procedure RunMermaidCorpus(const SpecsDir: string);
var
  Path: string;
  Data: TJSONData;
  Cases: TJSONArray;
  Item: TJSONObject;
  Pipeline: IMarkdownPipeline;
  Document: IMarkdownDocument;
  Code: IMarkdownCodeBlock;
  Model: IMermaidModel;
  Index: Integer;
  Failed: Integer;
  CaseName: string;
  Markdown: string;
  Detail: string;
begin
  Path := IncludeTrailingPathDelimiter(SpecsDir) + 'mermaid.json';
  Data := GetJSON(ReadText(Path), True);
  try
    Pipeline := TMarkdownPipeline.Create.UseGfm.Use(TMermaidExtension.Create)
      .UnsafeHtml.Build;
    Cases := Data as TJSONArray;
    Failed := 0;

    for Index := 0 to Cases.Count - 1 do
    begin
      Item := Cases.Items[Index] as TJSONObject;
      CaseName := FieldText(Item, 'name');
      Markdown := FieldText(Item, 'markdown');
      Detail := '';

      Model := nil;
      Document := Pipeline.Parse(Markdown);
      if FieldFlag(Item, 'detected', False) then
      begin
        if not FindFirstCodeBlock(Document, Code) then
          Detail := 'no code block'
        else if not TMermaidExtension.TryGetModel(Code, Model) then
          Detail := 'no mermaid model'
        else
        begin
          Detail := TextMismatch('diagramKind',
            MermaidKindName(Model.DiagramKind), FieldText(Item, 'diagramKind'));
          if (Detail = '') and (FieldText(Item, 'direction') <> '') then
            Detail := TextMismatch('direction',
              MermaidDirectionName(Model.Direction), FieldText(Item, 'direction'));
          if (Detail = '') and (FieldText(Item, 'title') <> '') then
            Detail := TextMismatch('title', Model.Title, FieldText(Item, 'title'));
          if Detail = '' then
            Detail := CountMismatch('nodeCount', Model.NodeCount,
              FieldNumber(Item, 'nodeCount', -1));
          if Detail = '' then
            Detail := CountMismatch('edgeCount', Model.EdgeCount,
              FieldNumber(Item, 'edgeCount', -1));
          if Detail = '' then
            Detail := CountMismatch('participantCount', Model.ParticipantCount,
              FieldNumber(Item, 'participantCount', -1));
          if Detail = '' then
            Detail := CountMismatch('messageCount', Model.MessageCount,
              FieldNumber(Item, 'messageCount', -1));
          if Detail = '' then
            Detail := CountMismatch('noteCount', Model.NoteCount,
              FieldNumber(Item, 'noteCount', -1));
          if Detail = '' then
            Detail := CountMismatch('sliceCount', Model.SliceCount,
              FieldNumber(Item, 'sliceCount', -1));
        end;
      end
      else if FindFirstCodeBlock(Document, Code) and TMermaidExtension.TryGetModel(Code, Model) then
        Detail := 'unexpected mermaid model';

      Inc(Checks);
      if Detail = '' then
        Continue;

      Inc(Failed);
      Inc(Failures);
      if Failed <= ReportLimit then
        WriteLn(Format('mermaid.json %s: %s', [CaseName, Detail]));
    end;

    WriteLn(Format('%-24s %4d cases, %d failed', ['mermaid.json', Cases.Count, Failed]));
  finally
    Data.Free;
  end;
end;

var
  SpecsDir: string;
  Index: Integer;
begin
  SpecsDir := 'Tests/specs';
  if ParamCount >= 1 then
    SpecsDir := ParamStr(1);

  Checks := 0;
  Failures := 0;
  for Index := Low(Corpora) to High(Corpora) do
    RunCorpus(SpecsDir, Corpora[Index]);
  RunChartCorpus(SpecsDir);
  RunMermaidCorpus(SpecsDir);

  WriteLn(Format('total %d cases, %d failed', [Checks, Failures]));
  if Failures > 0 then
    ExitCode := 1;
end.
