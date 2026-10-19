unit Markdown4D.Toc.Tests;

interface

uses
  DUnitX.TestFramework,
  Markdown4D.Toc;

type
  [TestFixture]
  TMarkdownTocTests = class
  private
    const
      SampleDocument =
        '# Introduction'#10 +
        #10 +
        'Intro text.'#10 +
        #10 +
        '## Getting *Started*'#10 +
        '### Details'#10 +
        '## Getting *Started*'#10 +
        '# Reference'#10 +
        '## Getting *Started*'#10;
      GettingStartedCaption = 'Getting Started';
    class function BuildToc: IMarkdownToc;
    // The anchors the outline gives every heading of SampleDocument, flattened
    // in reading order, and the ids read back out of rendered HTML.
    class function OutlineAnchors: TArray<string>;
    class function RenderedIds(const Html: string): TArray<string>;
    // A single string for what the two lists say, so a mismatch shows both.
    class function Joined(const Values: TArray<string>): string;

  public
    [Test]
    procedure FromDocument_SampleDocument_BuildsNestedHeadingTree;

    [Test]
    procedure FromDocument_HeadingWithEmphasis_StripsInlineFormattingFromCaption;

    [Test]
    procedure FromDocument_Headings_GeneratesLowercaseHyphenatedAnchors;

    [Test]
    procedure FromDocument_DuplicateHeadings_AppendsNumericSuffixesToAnchors;

    [Test]
    procedure FromDocument_Headings_ReportsSourceLines;

    [Test]
    procedure FromDocument_NilDocument_RaisesMarkdownError;

    [Test]
    procedure TryFindHeading_DuplicateAnchor_FindsThatHeading;

    [Test]
    procedure TryFindHeading_AccentsAndAmpersand_FindsHeading;

    [Test]
    procedure TryFindHeading_UnknownAnchor_ReturnsFalse;

    // The renderer and the table of contents both hand captions to
    // TMarkdownAnchors, so the ids it writes are the anchors the outline and an
    // in-page #link name the same headings by. Off by default, because the
    // conformance corpora compare the rendered HTML byte for byte.
    [Test]
    procedure Renderer_HeadingAnchorsOff_WritesNoIds;

    [Test]
    procedure Renderer_HeadingAnchorsOn_WritesTheAnchorsTheTocGives;

    [Test]
    procedure Renderer_HeadingAnchorsOn_ChangesNothingElse;
  end;

implementation

uses
  System.Generics.Collections,
  Markdown4D,
  Markdown4D.Defines,
  Markdown4D.Ast.Interfaces,
  Markdown4D.Extensions.Interfaces,
  Markdown4D.Pipeline,
  Markdown4D.Pipeline.Configuration;

procedure TMarkdownTocTests.FromDocument_SampleDocument_BuildsNestedHeadingTree;
begin
  const Toc = BuildToc;

  Assert.AreEqual(2, Toc.EntryCount);

  const Introduction = Toc.Entries[0];
  Assert.AreEqual('Introduction', Introduction.Caption);
  Assert.AreEqual(1, Introduction.Level);
  Assert.AreEqual(2, Introduction.ChildCount);

  const FirstGettingStarted = Introduction.Children[0];
  Assert.AreEqual(2, FirstGettingStarted.Level);
  Assert.AreEqual(1, FirstGettingStarted.ChildCount);

  const Details = FirstGettingStarted.Children[0];
  Assert.AreEqual('Details', Details.Caption);
  Assert.AreEqual(3, Details.Level);
  Assert.AreEqual(0, Details.ChildCount);

  const Reference = Toc.Entries[1];
  Assert.AreEqual('Reference', Reference.Caption);
  Assert.AreEqual(1, Reference.Level);
  Assert.AreEqual(1, Reference.ChildCount);
end;

procedure TMarkdownTocTests.FromDocument_HeadingWithEmphasis_StripsInlineFormattingFromCaption;
begin
  const Toc = BuildToc;

  const Introduction = Toc.Entries[0];
  const FirstGettingStarted = Introduction.Children[0];
  Assert.AreEqual(GettingStartedCaption, FirstGettingStarted.Caption);

  const SecondGettingStarted = Introduction.Children[1];
  Assert.AreEqual(GettingStartedCaption, SecondGettingStarted.Caption);
end;

procedure TMarkdownTocTests.FromDocument_Headings_GeneratesLowercaseHyphenatedAnchors;
begin
  const Toc = BuildToc;

  const Introduction = Toc.Entries[0];
  Assert.AreEqual('introduction', Introduction.Anchor);

  const FirstGettingStarted = Introduction.Children[0];
  const Details = FirstGettingStarted.Children[0];
  Assert.AreEqual('details', Details.Anchor);

  const Reference = Toc.Entries[1];
  Assert.AreEqual('reference', Reference.Anchor);
end;

procedure TMarkdownTocTests.FromDocument_DuplicateHeadings_AppendsNumericSuffixesToAnchors;
begin
  const Toc = BuildToc;

  const Introduction = Toc.Entries[0];
  Assert.AreEqual('getting-started', Introduction.Children[0].Anchor);
  Assert.AreEqual('getting-started-1', Introduction.Children[1].Anchor);

  const Reference = Toc.Entries[1];
  Assert.AreEqual('getting-started-2', Reference.Children[0].Anchor);
end;

procedure TMarkdownTocTests.FromDocument_Headings_ReportsSourceLines;
begin
  const Toc = BuildToc;

  const Introduction = Toc.Entries[0];
  Assert.AreEqual(1, Introduction.SourceLine);

  const FirstGettingStarted = Introduction.Children[0];
  Assert.AreEqual(5, FirstGettingStarted.SourceLine);
  Assert.AreEqual(6, FirstGettingStarted.Children[0].SourceLine);
  Assert.AreEqual(7, Introduction.Children[1].SourceLine);

  const Reference = Toc.Entries[1];
  Assert.AreEqual(8, Reference.SourceLine);
  Assert.AreEqual(9, Reference.Children[0].SourceLine);
end;

procedure TMarkdownTocTests.TryFindHeading_DuplicateAnchor_FindsThatHeading;
begin
  const Document = TMarkdown.Parse(SampleDocument);
  const Expected = TMarkdownToc.FromDocument(Document).Entries[0].Children[1].SourceLine;

  var Heading: IMarkdownHeading;
  const IsFound = TMarkdownToc.TryFindHeading(Document, 'getting-started-1', Heading);

  Assert.IsTrue(IsFound);
  Assert.AreEqual(Expected, Heading.SourceLine);
end;

procedure TMarkdownTocTests.TryFindHeading_AccentsAndAmpersand_FindsHeading;
begin
  const Caption = 'Caf'#$00E9' & Cr'#$00E8'me';
  const Document = TMarkdown.Parse('# Intro'#10#10'## ' + Caption);

  var Heading: IMarkdownHeading;
  const IsFound = TMarkdownToc.TryFindHeading(Document, 'caf'#$00E9'--cr'#$00E8'me', Heading);

  Assert.IsTrue(IsFound);
  Assert.AreEqual(2, Heading.Level);
end;

procedure TMarkdownTocTests.TryFindHeading_UnknownAnchor_ReturnsFalse;
begin
  const Document = TMarkdown.Parse(SampleDocument);

  var Heading: IMarkdownHeading;
  const IsFound = TMarkdownToc.TryFindHeading(Document, 'nowhere', Heading);

  Assert.IsFalse(IsFound);
end;

procedure TMarkdownTocTests.FromDocument_NilDocument_RaisesMarkdownError;
begin
  Assert.WillRaise(
    procedure
    begin
      TMarkdownToc.FromDocument(nil);
    end,
    EMarkdownError,
    'FromDocument must raise EMarkdownError when the document is nil');
end;

class function TMarkdownTocTests.BuildToc: IMarkdownToc;
begin
  const Document = TMarkdown.Parse(SampleDocument);

  Result := TMarkdownToc.FromDocument(Document);
end;

// The anchors the outline gives every heading of SampleDocument, flattened in
// reading order.
class function TMarkdownTocTests.OutlineAnchors: TArray<string>;
var
  Anchors: TList<string>;

  procedure Walk(const Entry: IMarkdownTocEntry);
  var
    Index: Integer;
  begin
    Anchors.Add(Entry.Anchor);
    for Index := 0 to Entry.ChildCount - 1 do
      Walk(Entry.Children[Index]);
  end;

var
  Index: Integer;
begin
  Anchors := TList<string>.Create;
  try
    const Toc = BuildToc;
    for Index := 0 to Toc.EntryCount - 1 do
      Walk(Toc.Entries[Index]);
    Result := Anchors.ToArray;
  finally
    Anchors.Free;
  end;
end;

// The id of every heading element, in order, read back out of the HTML.
class function TMarkdownTocTests.RenderedIds(const Html: string): TArray<string>;
var
  Ids: TList<string>;
  Position, TagEnd, IdStart, IdEnd: Integer;
  Remaining, Tag: string;
begin
  Ids := TList<string>.Create;
  try
    Remaining := Html;
    while True do
    begin
      Position := Remaining.IndexOf('<h');
      if Position < 0 then
        Break;
      Remaining := Remaining.Substring(Position);
      TagEnd := Remaining.IndexOf('>');
      if TagEnd < 0 then
        Break;

      Tag := Remaining.Substring(0, TagEnd + 1);
      IdStart := Tag.IndexOf(' id="');
      IdEnd := -1;
      if IdStart >= 0 then
        IdEnd := Tag.IndexOf('"', IdStart + 5);
      if (IdStart >= 0) and (IdEnd > IdStart + 5) then
        Ids.Add(Tag.Substring(IdStart + 5, IdEnd - IdStart - 5))
      else
        Ids.Add('');

      Remaining := Remaining.Substring(TagEnd + 1);
    end;

    Result := Ids.ToArray;
  finally
    Ids.Free;
  end;
end;

class function TMarkdownTocTests.Joined(const Values: TArray<string>): string;
var
  Text: TStringBuilder;
begin
  Text := TStringBuilder.Create;
  try
    for var Value in Values do
      Text.Append(Value).Append('|');
    Result := Text.ToString;
  finally
    Text.Free;
  end;
end;

procedure TMarkdownTocTests.Renderer_HeadingAnchorsOff_WritesNoIds;
begin
  const Html = TMarkdown.ToUnsafeHtml(SampleDocument, TMarkdownDialect.Gfm);

  for var Id in RenderedIds(Html) do
    Assert.AreEqual('', Id, 'the shared pipelines must not name the headings');

  Assert.IsTrue(Html.Contains('<h2>Getting <em>Started</em></h2>'));
end;

procedure TMarkdownTocTests.Renderer_HeadingAnchorsOn_WritesTheAnchorsTheTocGives;
begin
  const Pipeline = TMarkdownPipeline.Create.UseCommonMark.UseGfm.UnsafeHtml.UnsafeLinks.HeadingAnchors.Build;
  const Html = Pipeline.ToHtml(SampleDocument);

  Assert.AreEqual(Joined(OutlineAnchors), Joined(RenderedIds(Html)));
  Assert.IsTrue(Html.Contains('<h2 id="getting-started">Getting <em>Started</em></h2>'));
end;

procedure TMarkdownTocTests.Renderer_HeadingAnchorsOn_ChangesNothingElse;
begin
  const Pipeline = TMarkdownPipeline.Create.UseCommonMark.UseGfm.UnsafeHtml.UnsafeLinks.HeadingAnchors.Build;
  const Anchored = Pipeline.ToHtml(SampleDocument);
  const Plain = TMarkdown.ToUnsafeHtml(SampleDocument, TMarkdownDialect.Gfm);

  // Taking the ids out again gives the default rendering, byte for byte.
  var Stripped := Anchored;
  var Position := Stripped.IndexOf(' id="');
  while Position >= 0 do
  begin
    const IdEnd = Stripped.IndexOf('"', Position + 5);
    Stripped := Stripped.Remove(Position, IdEnd + 1 - Position);
    Position := Stripped.IndexOf(' id="', Position);
  end;

  Assert.AreEqual(Plain, Stripped);
end;

end.
