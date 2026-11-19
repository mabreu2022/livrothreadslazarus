unit uSqliteRepo;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, DB, SQLDB, SQLite3Conn, SQLite3Dyn,
  uSyncTypes;

type
  { Sessao SQLite dedicada a UMA unica thread (Conexao + Transacao + Query) }
  TSqliteWorkerSession = class
  private
    FConn: TSQLite3Connection;
    FTrans: TSQLTransaction;
    FQuery: TSQLQuery;
    FDbPath: string;
    procedure ConfigurePragmas(AEnableWal: Boolean);
    function IsBusyError(E: Exception): Boolean;
  public
    constructor Create(const ADbPath: string; AEnableWal: Boolean = False);
    destructor Destroy; override;
    function UpsertPosts(const AItems: TPostDTOArray): Integer;
    function FetchLatestPosts(AMaxRows: Integer): TPostDTOArray;
  end;

{ Inicializa a DLL/SO do SQLite sob lock para evitar corrida em sqlite3dyn }
procedure EnsureSqliteDriverLoaded;
procedure EnsureDatabaseSchema(const ADbPath: string);
function LoadSnapshotFromDatabase(const ADbPath: string;
  AMaxRows: Integer = 500): TPostDTOArray;

implementation

var
  GDriverLock: TCriticalSection = nil;
  GDriverReady: Boolean = False;

procedure EnsureSqliteDriverLoaded;
begin
  GDriverLock.Acquire;
  try
    if not GDriverReady then
    begin
      InitializeSQLite;
      GDriverReady := True;
    end;
  finally
    GDriverLock.Release;
  end;
end;

procedure EnsureDatabaseSchema(const ADbPath: string);
var
  Session: TSqliteWorkerSession;
  DirPath: string;
begin
  DirPath := ExtractFileDir(ADbPath);
  if (DirPath <> '') and (not DirectoryExists(DirPath)) then
    ForceDirectories(DirPath);

  Session := TSqliteWorkerSession.Create(ADbPath, True);
  try
    Session.FTrans.StartTransaction;
    try
      Session.FConn.ExecuteDirect(
        'CREATE TABLE IF NOT EXISTS synced_posts (' +
        '  external_id INTEGER PRIMARY KEY,' +
        '  user_id INTEGER NOT NULL,' +
        '  title TEXT NOT NULL,' +
        '  body TEXT NOT NULL,' +
        '  source_url TEXT NOT NULL,' +
        '  latency_ms INTEGER NOT NULL,' +
        '  synced_at REAL NOT NULL' +
        ');'
      );
      Session.FConn.ExecuteDirect(
        'CREATE INDEX IF NOT EXISTS idx_posts_synced_at ' +
        'ON synced_posts(synced_at DESC);'
      );
      Session.FTrans.Commit;
    except
      if Session.FTrans.Active then
        Session.FTrans.Rollback;
      raise;
    end;
  finally
    Session.Free;
  end;
end;

function LoadSnapshotFromDatabase(const ADbPath: string;
  AMaxRows: Integer): TPostDTOArray;
var
  Session: TSqliteWorkerSession;
begin
  Result := nil;
  if not FileExists(ADbPath) then
    Exit;
  Session := TSqliteWorkerSession.Create(ADbPath, False);
  try
    Result := Session.FetchLatestPosts(AMaxRows);
  finally
    Session.Free;
  end;
end;

{ TSqliteWorkerSession }

constructor TSqliteWorkerSession.Create(const ADbPath: string;
  AEnableWal: Boolean);
begin
  inherited Create;
  EnsureSqliteDriverLoaded;
  FDbPath := ADbPath;

  FConn := TSQLite3Connection.Create(nil);
  FTrans := TSQLTransaction.Create(nil);
  FQuery := TSQLQuery.Create(nil);
  try
    FConn.DatabaseName := FDbPath;
    FConn.OpenFlags := [sofReadWrite, sofCreate, sofFullMutex];
    FConn.Params.Values['foreign_keys'] := 'ON';
    FConn.Transaction := FTrans;

    FTrans.DataBase := FConn;
    FTrans.Action := caRollback;

    FQuery.DataBase := FConn;
    FQuery.Transaction := FTrans;

    FConn.Open;
    ConfigurePragmas(AEnableWal);
  except
    FQuery.Free;
    FTrans.Free;
    FConn.Free;
    raise;
  end;
end;

destructor TSqliteWorkerSession.Destroy;
begin
  if Assigned(FQuery) then
  begin
    if FQuery.Active then
      FQuery.Close;
    FQuery.Free;
  end;
  if Assigned(FTrans) then
  begin
    if FTrans.Active then
      FTrans.Rollback;
    FTrans.Free;
  end;
  if Assigned(FConn) then
  begin
    if FConn.Connected then
      FConn.Close;
    FConn.Free;
  end;
  inherited Destroy;
end;

procedure TSqliteWorkerSession.ConfigurePragmas(AEnableWal: Boolean);
begin
  { PRAGMAs de sessao devem rodar fora de transacao explicita }
  if FTrans.Active then
    FTrans.Commit;

  FConn.ExecuteDirect('PRAGMA busy_timeout = 5000;');
  if AEnableWal then
    FConn.ExecuteDirect('PRAGMA journal_mode = WAL;');
  FConn.ExecuteDirect('PRAGMA synchronous = NORMAL;');
  FConn.ExecuteDirect('PRAGMA temp_store = MEMORY;');
end;

function TSqliteWorkerSession.IsBusyError(E: Exception): Boolean;
var
  Msg: string;
begin
  Msg := LowerCase(E.Message);
  Result := (Pos('locked', Msg) > 0) or (Pos('busy', Msg) > 0);
end;

function TSqliteWorkerSession.UpsertPosts(const AItems: TPostDTOArray): Integer;
const
  MAX_RETRIES = 4;
var
  Attempt, I: Integer;
  Item: TPostDTO;
begin
  Result := 0;
  if Length(AItems) = 0 then
    Exit;

  for Attempt := 1 to MAX_RETRIES do
  begin
    try
      FQuery.Close;
      FQuery.SQL.Text :=
        'INSERT INTO synced_posts ' +
        '  (external_id, user_id, title, body, source_url, ' +
        '   latency_ms, synced_at) ' +
        'VALUES ' +
        '  (:external_id, :user_id, :title, :body, :source_url, ' +
        '   :latency_ms, :synced_at) ' +
        'ON CONFLICT(external_id) DO UPDATE SET ' +
        '  user_id = excluded.user_id, ' +
        '  title = excluded.title, ' +
        '  body = excluded.body, ' +
        '  source_url = excluded.source_url, ' +
        '  latency_ms = excluded.latency_ms, ' +
        '  synced_at = excluded.synced_at;';

      if not FTrans.Active then
        FTrans.StartTransaction;

      FQuery.Prepare;
      try
        for I := 0 to High(AItems) do
        begin
          Item := AItems[I];
          FQuery.ParamByName('external_id').AsInteger := Item.ExternalId;
          FQuery.ParamByName('user_id').AsInteger := Item.UserId;
          FQuery.ParamByName('title').AsString := Item.Title;
          FQuery.ParamByName('body').AsString := Item.Body;
          FQuery.ParamByName('source_url').AsString := Item.SourceUrl;
          FQuery.ParamByName('latency_ms').AsLargeInt := Int64(Item.LatencyMs);
          FQuery.ParamByName('synced_at').AsFloat := Double(Item.SyncedAt);
          FQuery.ExecSQL;
          Inc(Result);
        end;
      finally
        FQuery.UnPrepare;
      end;

      FTrans.Commit;
      Exit;
    except
      on E: Exception do
      begin
        if FTrans.Active then
          FTrans.Rollback;
        Result := 0;
        if IsBusyError(E) and (Attempt < MAX_RETRIES) then
          Sleep(60 * Attempt)
        else
          raise;
      end;
    end;
  end;
end;

function TSqliteWorkerSession.FetchLatestPosts(AMaxRows: Integer): TPostDTOArray;
var
  Count, Cap: Integer;
begin
  Result := nil;
  Count := 0;
  Cap := 64;
  SetLength(Result, Cap);

  FQuery.Close;
  FQuery.SQL.Text :=
    'SELECT external_id, user_id, title, body, source_url, ' +
    '       latency_ms, synced_at ' +
    'FROM synced_posts ' +
    'ORDER BY synced_at DESC, external_id ASC ' +
    'LIMIT :max_rows;';
  FQuery.ParamByName('max_rows').AsInteger := AMaxRows;

  if not FTrans.Active then
    FTrans.StartTransaction;
  try
    FQuery.Open;
    try
      while not FQuery.EOF do
      begin
        if Count >= Cap then
        begin
          Cap := Cap * 2;
          SetLength(Result, Cap);
        end;
        Result[Count].ExternalId := FQuery.FieldByName('external_id').AsInteger;
        Result[Count].UserId := FQuery.FieldByName('user_id').AsInteger;
        Result[Count].Title := FQuery.FieldByName('title').AsString;
        Result[Count].Body := FQuery.FieldByName('body').AsString;
        Result[Count].SourceUrl := FQuery.FieldByName('source_url').AsString;
        Result[Count].LatencyMs :=
          QWord(FQuery.FieldByName('latency_ms').AsLargeInt);
        Result[Count].SyncedAt :=
          TDateTime(FQuery.FieldByName('synced_at').AsFloat);
        Inc(Count);
        FQuery.Next;
      end;
    finally
      FQuery.Close;
    end;
    FTrans.Commit;
  except
    if FTrans.Active then
      FTrans.Rollback;
    raise;
  end;

  SetLength(Result, Count);
end;

initialization
  GDriverLock := TCriticalSection.Create;

finalization
  if GDriverReady then
  begin
    ReleaseSQLite;
    GDriverReady := False;
  end;
  FreeAndNil(GDriverLock);

end.
