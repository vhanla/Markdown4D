unit Markdown4D.Toc;

{$SCOPEDENUMS ON}

interface

uses
  System.Generics.Collections,
  Markdown4D.Ast.Interfaces;

type
  IMarkdownTocEntry = interface
    ['{9A208737-00DA-409D-8D0F-4471A92ED548}']
    function GetCaption: string;
    function GetLevel: Integer;
    function GetAnchor: string;
    function GetSourceLine: Integer;
    function GetChildCount: Integer;
    function GetChild(const Index: Integer): IMarkdownTocEntry;
    property Caption: string read GetCaption;
    property Level: Integer read GetLevel;
    property Anchor: string read GetAnchor;
    // The line of the source the heading was written on, counted from 1 as the
    // parser counts lines -- not from 0 as TMarkdownSourceLineMap and
    // SourceLineToScrollOffset do, so subtract 1 before handing it to those.
    property SourceLine: Integer read GetSourceLine;
    property ChildCount: Integer read GetChildCount;
    property Children[const Index: Integer]: IMarkdownTocEntry read GetChild;
  end;

  IMarkdownToc = interface
    ['{FD266CFD-7347-4ABF-8A2F-3F1900D22AF0}']
    function GetEntryCount: Integer;
    function GetEntry(const Index: Integer): IMarkdownTocEntry;
    function GetEnumerator: TEnumerator<IMarkdownTocEntry>;
    property EntryCount: Integer read GetEntryCount;
    property Entries[const Index: Integer]: IMarkdownTocEntry read GetEntry;
  end;

  TMarkdownToc = class
  public
    class function FromDocument(const Document: IMarkdownDocument): IMarkdownToc;
    // The heading a link such as #getting-started-1 points at, by the anchors
    // FromDocument gives the headings.
    class function TryFindHeading(const Document: IMarkdownDocument; const Anchor: string;
                                  out Heading: IMarkdownHeading): Boolean;
  end;

  // The anchors headings are named with. The table of contents and the HTML
  // renderer -- when it is asked for heading anchors -- hand captions to one of
  // these, so an outline entry, an in-page #link and an id all name the same
  // heading: the caption lower-cased, its letters, digits and underscores kept,
  // its spaces and dashes written as dashes, and a number appended once a
  // caption is used again. One of these remembers the captions it has seen, so
  // headings are named in the order the document reads.
  TMarkdownAnchors = class
  private
    const
      CaptionSeparator = ' ';
      AnchorDash = '-';
      AnchorSuffixFormat = '%s-%d';
    var
      FUsage: TDictionary<string, Integer>;
  public
    constructor Create;
    destructor Destroy; override;
    // The plain text of a heading: its inline formatting, images and link
    // destinations taken off, its line breaks read as spaces.
    class function CaptionOf(const Heading: IMarkdownNode): string; static;
    class function Slugify(const Caption: string): string; static;
    // The anchor the caption takes, remembering the ones handed out before.
    function Reserve(const Caption: string): string;
    function ReserveHeading(const Heading: IMarkdownNode): string;
  end;

implementation

uses
  System.SysUtils,
  System.Character,
  Markdown4D.Defines;

type
  TMarkdownTocEntry = class(TInterfacedObject, IMarkdownTocEntry)
  private
    FCaption: string;
    FLevel: Integer;
    FAnchor: string;
    FSourceLine: Integer;
    FChildren: TList<IMarkdownTocEntry>;

  public
    constructor Create(const Caption, Anchor: string; const Level, SourceLine: Integer);
    destructor Destroy; override;
    function GetCaption: string;
    function GetLevel: Integer;
    function GetAnchor: string;
    function GetSourceLine: Integer;
    function GetChildCount: Integer;
    function GetChild(const Index: Integer): IMarkdownTocEntry;
    procedure AddChild(const Child: IMarkdownTocEntry);
    property Level: Integer read FLevel;
  end;

  TMarkdownTocInstance = class(TInterfacedObject, IMarkdownToc)
  private
    FEntries: TList<IMarkdownTocEntry>;

  public
    constructor Create;
    destructor Destroy; override;
    function GetEntryCount: Integer;
    function GetEntry(const Index: Integer): IMarkdownTocEntry;
    function GetEnumerator: TEnumerator<IMarkdownTocEntry>;
    procedure AddEntry(const Entry: IMarkdownTocEntry);
  end;

  TMarkdownTocBuilder = class
  private
    var
      FToc: TMarkdownTocInstance;
      FOpenEntries: TList<TMarkdownTocEntry>;
      FAnchors: TMarkdownAnchors;
    class function HeadingsInOrder(const Document: IMarkdownDocument): TArray<IMarkdownHeading>;
    procedure AddHeading(const Heading: IMarkdownHeading);

  public
    constructor Create;
    destructor Destroy; override;
    function TryFindHeading(const Document: IMarkdownDocument; const Anchor: string;
                            out Heading: IMarkdownHeading): Boolean;
    function Build(const Document: IMarkdownDocument): IMarkdownToc;
  end;

class function TMarkdownToc.FromDocument(const Document: IMarkdownDocument): IMarkdownToc;
begin
  if Document = nil then
    raise EMarkdownError.Create('Document must not be nil');

  const Builder = TMarkdownTocBuilder.Create;
  try
    Result := Builder.Build(Document);
  finally
    Builder.Free;
  end;
end;

class function TMarkdownToc.TryFindHeading(const Document: IMarkdownDocument; const Anchor: string;
  out Heading: IMarkdownHeading): Boolean;
begin
  if Document = nil then
    raise EMarkdownError.Create('Document must not be nil');

  const Builder = TMarkdownTocBuilder.Create;
  try
    Result := Builder.TryFindHeading(Document, Anchor, Heading);
  finally
    Builder.Free;
  end;
end;

constructor TMarkdownTocBuilder.Create;
begin
  inherited Create;

  FOpenEntries := TList<TMarkdownTocEntry>.Create;
  FAnchors := TMarkdownAnchors.Create;
end;

destructor TMarkdownTocBuilder.Destroy;
begin
  FAnchors.Free;
  FOpenEntries.Free;

  inherited Destroy;
end;

constructor TMarkdownAnchors.Create;
begin
  inherited Create;

  FUsage := TDictionary<string, Integer>.Create;
end;

destructor TMarkdownAnchors.Destroy;
begin
  FUsage.Free;

  inherited Destroy;
end;

// A document is walked in reading order by pushing the children of a node back
// to front, so the top of the stack is what comes next.
procedure PushChildrenReversed(const Pending: TStack<IMarkdownNode>; const Node: IMarkdownNode);
begin
  for var Index := Node.ChildCount - 1 downto 0 do
  begin
    Pending.Push(Node.Children[Index]);
  end;
end;

class function TMarkdownAnchors.Slugify(const Caption: string): string;
begin
  const Slug = TStringBuilder.Create;
  try
    for var CaptionChar in Caption.ToLower do
    begin
      const KeepsCharacter = CaptionChar.IsLetterOrDigit or (CaptionChar = '_');
      const BecomesDash = (CaptionChar = CaptionSeparator) or (CaptionChar = AnchorDash);

      if KeepsCharacter then
        Slug.Append(CaptionChar)
      else if BecomesDash then
        Slug.Append(AnchorDash);
    end;

    Result := Slug.ToString;
  finally
    Slug.Free;
  end;
end;

function TMarkdownAnchors.Reserve(const Caption: string): string;
begin
  const Anchor = Slugify(Caption);

  var UsedCount: Integer;
  if not FUsage.TryGetValue(Anchor, UsedCount) then
    UsedCount := 0;
  FUsage.AddOrSetValue(Anchor, UsedCount + 1);

  if UsedCount = 0 then
  begin
    Result := Anchor;
    Exit;
  end;

  Result := Format(AnchorSuffixFormat, [Anchor, UsedCount]);
end;

function TMarkdownAnchors.ReserveHeading(const Heading: IMarkdownNode): string;
begin
  Result := Reserve(CaptionOf(Heading));
end;

class function TMarkdownAnchors.CaptionOf(const Heading: IMarkdownNode): string;
begin
  const CaptionText = TStringBuilder.Create;
  const Pending = TStack<IMarkdownNode>.Create;
  try
    PushChildrenReversed(Pending, Heading);

    while Pending.Count > 0 do
    begin
      const Current = Pending.Pop;

      case Current.Kind of
        TMarkdownNodeKind.Text, TMarkdownNodeKind.CodeSpan, TMarkdownNodeKind.Math:
          CaptionText.Append((Current as IMarkdownText).Literal);
        TMarkdownNodeKind.SoftLineBreak, TMarkdownNodeKind.HardLineBreak:
          CaptionText.Append(CaptionSeparator);
      else
        PushChildrenReversed(Pending, Current);
      end;
    end;

    Result := CaptionText.ToString;
  finally
    Pending.Free;
    CaptionText.Free;
  end;
end;

function TMarkdownTocBuilder.Build(const Document: IMarkdownDocument): IMarkdownToc;
begin
  const Toc = TMarkdownTocInstance.Create;
  Result := Toc;
  FToc := Toc;

  for var Heading in HeadingsInOrder(Document) do
  begin
    AddHeading(Heading);
  end;
end;

// Anchors are numbered in reading order, so the heading is found by handing out
// the anchors again until one matches.
function TMarkdownTocBuilder.TryFindHeading(const Document: IMarkdownDocument; const Anchor: string;
  out Heading: IMarkdownHeading): Boolean;
begin
  Heading := nil;

  for var Candidate in HeadingsInOrder(Document) do
  begin
    const Caption = TMarkdownAnchors.CaptionOf(Candidate);
    const IsTarget = (FAnchors.Reserve(Caption) = Anchor);
    if IsTarget then
    begin
      Heading := Candidate;
      Result := True;
      Exit;
    end;
  end;

  Result := False;
end;

class function TMarkdownTocBuilder.HeadingsInOrder(const Document: IMarkdownDocument): TArray<IMarkdownHeading>;
begin
  const Headings = TList<IMarkdownHeading>.Create;
  const Pending = TStack<IMarkdownNode>.Create;
  try
    PushChildrenReversed(Pending, Document);

    while Pending.Count > 0 do
    begin
      const Current = Pending.Pop;

      if Current.Kind = TMarkdownNodeKind.Heading then
        Headings.Add(Current as IMarkdownHeading)
      else
        PushChildrenReversed(Pending, Current);
    end;

    Result := Headings.ToArray;
  finally
    Pending.Free;
    Headings.Free;
  end;
end;

procedure TMarkdownTocBuilder.AddHeading(const Heading: IMarkdownHeading);
begin
  const Caption = TMarkdownAnchors.CaptionOf(Heading);
  const Anchor = FAnchors.Reserve(Caption);
  const Entry = TMarkdownTocEntry.Create(Caption, Anchor, Heading.Level, Heading.SourceLine);
  const Added: IMarkdownTocEntry = Entry;

  while (FOpenEntries.Count > 0) and (FOpenEntries.Last.Level >= Heading.Level) do
  begin
    FOpenEntries.Delete(FOpenEntries.Count - 1);
  end;

  if FOpenEntries.Count = 0 then
    FToc.AddEntry(Added)
  else
    FOpenEntries.Last.AddChild(Added);

  FOpenEntries.Add(Entry);
end;

constructor TMarkdownTocEntry.Create(const Caption, Anchor: string; const Level, SourceLine: Integer);
begin
  inherited Create;

  FCaption := Caption;
  FAnchor := Anchor;
  FLevel := Level;
  FSourceLine := SourceLine;
  FChildren := TList<IMarkdownTocEntry>.Create;
end;

destructor TMarkdownTocEntry.Destroy;
begin
  FChildren.Free;

  inherited Destroy;
end;

function TMarkdownTocEntry.GetCaption: string;
begin
  Result := FCaption;
end;

function TMarkdownTocEntry.GetLevel: Integer;
begin
  Result := FLevel;
end;

function TMarkdownTocEntry.GetAnchor: string;
begin
  Result := FAnchor;
end;

function TMarkdownTocEntry.GetSourceLine: Integer;
begin
  Result := FSourceLine;
end;

function TMarkdownTocEntry.GetChildCount: Integer;
begin
  Result := FChildren.Count;
end;

function TMarkdownTocEntry.GetChild(const Index: Integer): IMarkdownTocEntry;
begin
  Result := FChildren[Index];
end;

procedure TMarkdownTocEntry.AddChild(const Child: IMarkdownTocEntry);
begin
  FChildren.Add(Child);
end;

constructor TMarkdownTocInstance.Create;
begin
  inherited Create;

  FEntries := TList<IMarkdownTocEntry>.Create;
end;

destructor TMarkdownTocInstance.Destroy;
begin
  FEntries.Free;

  inherited Destroy;
end;

function TMarkdownTocInstance.GetEntryCount: Integer;
begin
  Result := FEntries.Count;
end;

function TMarkdownTocInstance.GetEntry(const Index: Integer): IMarkdownTocEntry;
begin
  Result := FEntries[Index];
end;

function TMarkdownTocInstance.GetEnumerator: TEnumerator<IMarkdownTocEntry>;
begin
  Result := FEntries.GetEnumerator;
end;

procedure TMarkdownTocInstance.AddEntry(const Entry: IMarkdownTocEntry);
begin
  FEntries.Add(Entry);
end;

end.
