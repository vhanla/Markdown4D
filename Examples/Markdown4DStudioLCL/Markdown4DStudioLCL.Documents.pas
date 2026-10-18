unit Markdown4DStudioLCL.Documents;

// The document model behind the Studio example: what one tab holds, and the
// handful of file operations the File menu needs.
//
// The framework-specific halves (the tab strip, the editor, the preview) live in
// Markdown4DStudioLCL.Main; keeping the document itself free of controls is what
// lets the editor and the viewer be a single pair shared by every tab, which is
// how the VCL and FMX Studios work as well.

{$I ../../Source/Markdown4D.Fpc.inc}

interface

uses
  Classes,
  Generics.Collections,
  Markdown4D.Defines,
  Markdown4D.Editor.Model,
  Markdown4D.Text.FileFormat;

type
  TStudioDocument = class
  private
    FFileName: string;
    FTitle: string;
    FText: string;
    FFormat: TMarkdownTextFormat;
    FEditorState: IMarkdownEditorState;
    FPreviewOffset: Single;
    FModified: Boolean;
  public
    constructor Create(const Title: string);
    // What the tab shows: the file name, or the placeholder an unsaved
    // document was given, plus a mark while there are unsaved changes.
    function DisplayName: string;
    function TabCaption: string;
    function HasFile: Boolean;
    // Loads the file and remembers the shape it had on disk (encoding and line
    // endings), so Save can write the same shape back.
    procedure LoadFromFile(const FileName: string);
    procedure SaveToFile(const FileName: string);
    property FileName: string read FFileName;
    property Text: string read FText write FText;
    property Format: TMarkdownTextFormat read FFormat;
    // Where the caret and the selection were, and how far the preview was
    // scrolled, so switching tabs comes back to the same place.
    property EditorState: IMarkdownEditorState read FEditorState write FEditorState;
    property PreviewOffset: Single read FPreviewOffset write FPreviewOffset;
    property Modified: Boolean read FModified write FModified;
  end;

  TStudioDocuments = class
  private
    FItems: TList<TStudioDocument>;
    FUntitledCount: Integer;
    function GetCount: Integer;
    function GetItem(const Index: Integer): TStudioDocument;
  public
    constructor Create;
    destructor Destroy; override;
    function AddUntitled: TStudioDocument;
    function AddFromFile(const FileName: string): TStudioDocument;
    function IndexOf(const Document: TStudioDocument): Integer;
    function FindByFile(const FileName: string): TStudioDocument;
    procedure Delete(const Index: Integer);
    property Count: Integer read GetCount;
    property Items[const Index: Integer]: TStudioDocument read GetItem; default;
  end;

implementation

uses
  SysUtils;

{ TStudioDocument }

constructor TStudioDocument.Create(const Title: string);
begin
  inherited Create;

  FTitle := Title;
  // A brand new document is UTF-8 without a mark, with the line ending this
  // platform writes; loading a file replaces this with the file's own shape.
  FFormat := TMarkdownTextFormat.Default;
end;

function TStudioDocument.DisplayName: string;
begin
  if FFileName <> '' then
    Result := ExtractFileName(FFileName)
  else
    Result := FTitle;
end;

function TStudioDocument.TabCaption: string;
begin
  Result := DisplayName;
  if FModified then
    Result := Result + ' *';
end;

function TStudioDocument.HasFile: Boolean;
begin
  Result := FFileName <> '';
end;

procedure TStudioDocument.LoadFromFile(const FileName: string);
begin
  FText := TMarkdownTextFile.Load(FileName, FFormat);
  FFileName := FileName;
  FModified := False;
end;

procedure TStudioDocument.SaveToFile(const FileName: string);
begin
  TMarkdownTextFile.Save(FileName, FText, FFormat);
  FFileName := FileName;
  FModified := False;
end;

{ TStudioDocuments }

constructor TStudioDocuments.Create;
begin
  inherited Create;

  FItems := TList<TStudioDocument>.Create;
end;

destructor TStudioDocuments.Destroy;
var
  Document: TStudioDocument;
begin
  for Document in FItems do
    Document.Free;

  FItems.Free;

  inherited Destroy;
end;

function TStudioDocuments.AddUntitled: TStudioDocument;
begin
  Inc(FUntitledCount);

  Result := TStudioDocument.Create(Format('Untitled %d', [FUntitledCount]));
  FItems.Add(Result);
end;

function TStudioDocuments.AddFromFile(const FileName: string): TStudioDocument;
begin
  Result := TStudioDocument.Create(FileName);
  try
    Result.LoadFromFile(FileName);
  except
    Result.Free;
    raise;
  end;

  FItems.Add(Result);
end;

function TStudioDocuments.IndexOf(const Document: TStudioDocument): Integer;
begin
  Result := FItems.IndexOf(Document);
end;

function TStudioDocuments.FindByFile(const FileName: string): TStudioDocument;
var
  Document: TStudioDocument;
begin
  Result := nil;

  for Document in FItems do
    if Document.HasFile and
       (CompareStr(ExpandFileName(Document.FileName), ExpandFileName(FileName)) = 0) then
      Exit(Document);
end;

procedure TStudioDocuments.Delete(const Index: Integer);
begin
  FItems[Index].Free;
  FItems.Delete(Index);
end;

function TStudioDocuments.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TStudioDocuments.GetItem(const Index: Integer): TStudioDocument;
begin
  Result := FItems[Index];
end;

end.
