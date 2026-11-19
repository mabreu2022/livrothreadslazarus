unit uRestSyncWorker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fphttpclient, openssl, opensslsockets,
  fpjson, jsonparser, uSyncTypes, uSyncPrimitives, uSqliteRepo;

type
  TRestSyncWorker = class(TThread)
  private
    FJob: TSyncJob;
    FDbPath: string;
    FSemaphore: TCountingSemaphore;
    FRateLimiter: TLocalRateLimiter;
    FCancel: TSyncCancellation;
    FOnPacket: TSyncPacketCallback;
    FClientLock: TCriticalSection;
    FActiveClient: TFPHTTPClient;
    FLastProgressTick: QWord;
    FRecordsSaved: Integer;
    FSuccess: Boolean;
    FErrorMessage: string;
    procedure HandleDataReceived(Sender: TObject;
      const ContentLength, CurrentPos: Int64);
    procedure EmitLog(const AText: string);
    procedure EmitProgress(AContentLen, ACurrentPos: Int64);
    procedure EmitJobDone;
    function ParsePostsJson(const ARawJson, ASourceUrl: string;
      ALatencyMs: QWord): TPostDTOArray;
    function DownloadWithRetry(out ARawJson: string;
      out ALatencyMs: QWord): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AJob: TSyncJob; const ADbPath: string;
      ASemaphore: TCountingSemaphore; ARateLimiter: TLocalRateLimiter;
      ACancel: TSyncCancellation; AOnPacket: TSyncPacketCallback);
    destructor Destroy; override;
    procedure AbortActiveHttp;
    property Success: Boolean read FSuccess;
    property RecordsSaved: Integer read FRecordsSaved;
    property ErrorMessage: string read FErrorMessage;
  end;

  TSyncBatchRunner = class(TThread)
  private
    FJobs: TSyncJobArray;
    FDbPath: string;
    FMaxConcurrency: Integer;
    FCancel: TSyncCancellation;
    FOnPacket: TSyncPacketCallback;
    FWorkersLock: TCriticalSection;
    FWorkers: array of TRestSyncWorker;
    procedure EmitBatchFinished(ASuccess: Boolean; const AMsg: string;
      const ASnapshot: TPostDTOArray);
  protected
    procedure Execute; override;
  public
    constructor Create(const AJobs: TSyncJobArray; const ADbPath: string;
      AMaxConcurrency: Integer; ACancel: TSyncCancellation;
      AOnPacket: TSyncPacketCallback);
    destructor Destroy; override;
    procedure AbortAllHttp;
  end;

procedure EnsureOpenSslInitialized;

implementation

var
  GSslLock: TCriticalSection = nil;
  GSslInitAttempted: Boolean = False;

procedure EnsureOpenSslInitialized;
begin
  GSslLock.Acquire;
  try
    if not GSslInitAttempted then
    begin
      GSslInitAttempted := True;
      InitSSLInterface;
    end;
  finally
    GSslLock.Release;
  end;
end;

{ TRestSyncWorker }

constructor TRestSyncWorker.Create(const AJob: TSyncJob;
  const ADbPath: string; ASemaphore: TCountingSemaphore;
  ARateLimiter: TLocalRateLimiter; ACancel: TSyncCancellation;
  AOnPacket: TSyncPacketCallback);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FJob := AJob;
  FDbPath := ADbPath;
  FSemaphore := ASemaphore;
  FRateLimiter := ARateLimiter;
  FCancel := ACancel;
  FOnPacket := AOnPacket;
  FClientLock := TCriticalSection.Create;
  FActiveClient := nil;
  FLastProgressTick := 0;
  FRecordsSaved := 0;
  FSuccess := False;
end;

destructor TRestSyncWorker.Destroy;
begin
  FClientLock.Free;
  inherited Destroy;
end;

procedure TRestSyncWorker.AbortActiveHttp;
begin
  FClientLock.Acquire;
  try
    if Assigned(FActiveClient) then
      FActiveClient.Terminate;
  finally
    FClientLock.Release;
  end;
end;

procedure TRestSyncWorker.EmitLog(const AText: string);
var
  Pkg: PSyncUiPacket;
begin
  if not Assigned(FOnPacket) then
    Exit;
  Pkg := NewSyncPacket(sekLog);
  Pkg^.JobIndex := FJob.JobIndex;
  Pkg^.MessageText := AText;
  FOnPacket(Pkg);
end;

procedure TRestSyncWorker.EmitProgress(AContentLen, ACurrentPos: Int64);
var
  Pkg: PSyncUiPacket;
begin
  if not Assigned(FOnPacket) then
    Exit;
  Pkg := NewSyncPacket(sekProgress);
  Pkg^.JobIndex := FJob.JobIndex;
  Pkg^.ContentLength := AContentLen;
  Pkg^.BytesReceived := ACurrentPos;
  Pkg^.MessageText := FJob.LabelText;
  FOnPacket(Pkg);
end;

procedure TRestSyncWorker.EmitJobDone;
var
  Pkg: PSyncUiPacket;
begin
  if not Assigned(FOnPacket) then
    Exit;
  Pkg := NewSyncPacket(sekJobDone);
  Pkg^.JobIndex := FJob.JobIndex;
  Pkg^.Success := FSuccess;
  Pkg^.RecordsSaved := FRecordsSaved;
  Pkg^.MessageText := FErrorMessage;
  FOnPacket(Pkg);
end;

procedure TRestSyncWorker.HandleDataReceived(Sender: TObject;
  const ContentLength, CurrentPos: Int64);
const
  THROTTLE_MS = 80;
var
  NowTick: QWord;
  IsComplete: Boolean;
begin
  if Terminated or FCancel.IsCancelled then
  begin
    if Sender is TFPHTTPClient then
      TFPHTTPClient(Sender).Terminate;
    Exit;
  end;

  NowTick := GetTickCount64;
  IsComplete := (ContentLength > 0) and (CurrentPos >= ContentLength);
  if IsComplete or (NowTick - FLastProgressTick >= THROTTLE_MS) then
  begin
    FLastProgressTick := NowTick;
    EmitProgress(ContentLength, CurrentPos);
  end;
end;

function TRestSyncWorker.DownloadWithRetry(out ARawJson: string;
  out ALatencyMs: QWord): Boolean;
const
  MAX_ATTEMPTS = 3;
var
  Attempt, StatusCode: Integer;
  StartTick: QWord;
  BackoffMs: Cardinal;
  Client: TFPHTTPClient;
  BufStream: TStringStream;
  TransientErr: Boolean;
begin
  Result := False;
  ARawJson := '';
  ALatencyMs := 0;

  for Attempt := 1 to MAX_ATTEMPTS do
  begin
    if Terminated or FCancel.IsCancelled then
    begin
      FErrorMessage := 'Cancelado pelo usuario';
      Exit(False);
    end;

    if not FRateLimiter.WaitSlot(FCancel) then
    begin
      FErrorMessage := 'Cancelado na fila de rate limit';
      Exit(False);
    end;

    Client := TFPHTTPClient.Create(nil);
    BufStream := TStringStream.Create('');
    try
      Client.ConnectTimeout := 5000;
      Client.IOTimeout := 8000;
      Client.AllowRedirect := True;
      Client.MaxRedirects := 5;
      Client.AddHeader('Accept', 'application/json');
      Client.AddHeader('User-Agent', 'LazarusThreadsBook-Sync/1.0');
      Client.OnDataReceived := @HandleDataReceived;

      FClientLock.Acquire;
      try
        FActiveClient := Client;
      finally
        FClientLock.Release;
      end;

      StartTick := GetTickCount64;
      try
        Client.HTTPMethod('GET', FJob.EndpointUrl, BufStream, []);
        ALatencyMs := GetTickCount64 - StartTick;
        StatusCode := Client.ResponseStatusCode;

        if Client.Terminated or FCancel.IsCancelled then
        begin
          FErrorMessage := 'Download interrompido via Terminate';
          Exit(False);
        end;

        if (StatusCode >= 200) and (StatusCode < 300) then
        begin
          ARawJson := BufStream.DataString;
          Exit(True);
        end;

        FErrorMessage := Format('HTTP %d (%s)',
          [StatusCode, Client.ResponseStatusText]);
        TransientErr := (StatusCode = 429) or (StatusCode >= 500);
      except
        on E: Exception do
        begin
          ALatencyMs := GetTickCount64 - StartTick;
          FErrorMessage := E.ClassName + ': ' + E.Message;
          TransientErr := not (Client.Terminated or FCancel.IsCancelled);
        end;
      end;
    finally
      FClientLock.Acquire;
      try
        FActiveClient := nil;
      finally
        FClientLock.Release;
      end;
      BufStream.Free;
      Client.Free;
    end;

    if (not TransientErr) or (Attempt = MAX_ATTEMPTS) then
      Exit(False);

    BackoffMs := Cardinal(350 * (1 shl (Attempt - 1)));
    EmitLog(Format('[Job #%d] Tentativa %d falhou (%s). Retry em %d ms...',
      [FJob.JobIndex, Attempt, FErrorMessage, BackoffMs]));
    if FCancel.WaitForCancel(BackoffMs) then
    begin
      FErrorMessage := 'Cancelado durante backoff de retry';
      Exit(False);
    end;
  end;
end;

function TRestSyncWorker.ParsePostsJson(const ARawJson, ASourceUrl: string;
  ALatencyMs: QWord): TPostDTOArray;
var
  Root: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  I: Integer;
  NowStamp: TDateTime;

  function ExtractPost(AObj: TJSONObject): TPostDTO;
  begin
    Result := Default(TPostDTO);
    Result.ExternalId := AObj.Get('id', 0);
    Result.UserId := AObj.Get('userId', 0);
    Result.Title := AObj.Get('title', '');
    Result.Body := AObj.Get('body', '');
    Result.SourceUrl := ASourceUrl;
    Result.LatencyMs := ALatencyMs;
    Result.SyncedAt := NowStamp;
  end;

begin
  Result := nil;
  if Trim(ARawJson) = '' then
    Exit;

  NowStamp := Now;
  Root := GetJSON(ARawJson);
  try
    if Root is TJSONArray then
    begin
      Arr := TJSONArray(Root);
      SetLength(Result, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        if Arr.Items[I] is TJSONObject then
          Result[I] := ExtractPost(TJSONObject(Arr.Items[I]));
      end;
    end
    else if Root is TJSONObject then
    begin
      Obj := TJSONObject(Root);
      SetLength(Result, 1);
      Result[0] := ExtractPost(Obj);
    end;
  finally
    Root.Free;
  end;
end;

procedure TRestSyncWorker.Execute;
var
  PermitAcquired: Boolean;
  RawJson: string;
  LatencyMs: QWord;
  Items: TPostDTOArray;
  Session: TSqliteWorkerSession;
begin
  TThread.NameThreadForDebugging(
    AnsiString('RestSyncWorker-' + IntToStr(FJob.JobIndex)));

  PermitAcquired := False;
  try
    EmitLog(Format('[Job #%d] Aguardando slot do semaforo (%s)',
      [FJob.JobIndex, FJob.LabelText]));

    PermitAcquired := FSemaphore.Acquire(INFINITE, FCancel);
    if (not PermitAcquired) or Terminated or FCancel.IsCancelled then
    begin
      FErrorMessage := 'Cancelado antes de iniciar requisicao';
      Exit;
    end;

    EmitLog(Format('[Job #%d] GET %s', [FJob.JobIndex, FJob.EndpointUrl]));
    if not DownloadWithRetry(RawJson, LatencyMs) then
      Exit;

    if Terminated or FCancel.IsCancelled then
    begin
      FErrorMessage := 'Cancelado antes de persistir no SQLite';
      Exit;
    end;

    Items := ParsePostsJson(RawJson, FJob.EndpointUrl, LatencyMs);
    if Length(Items) = 0 then
    begin
      FSuccess := True;
      FErrorMessage := 'Resposta JSON vazia (0 itens)';
      Exit;
    end;

    { Conexao SQLite dedicada EXCLUSIVA desta worker thread }
    Session := TSqliteWorkerSession.Create(FDbPath, False);
    try
      FRecordsSaved := Session.UpsertPosts(Items);
    finally
      Session.Free;
    end;

    FSuccess := True;
    FErrorMessage := Format('OK: %d registros salvos (%d ms)',
      [FRecordsSaved, LatencyMs]);
    EmitLog(Format('[Job #%d] %s', [FJob.JobIndex, FErrorMessage]));
  except
    on E: Exception do
    begin
      FSuccess := False;
      FErrorMessage := E.ClassName + ': ' + E.Message;
      EmitLog(Format('[Job #%d] ERRO: %s', [FJob.JobIndex, FErrorMessage]));
    end;
  end;

  if PermitAcquired then
    FSemaphore.Release;

  EmitJobDone;
end;

{ TSyncBatchRunner }

constructor TSyncBatchRunner.Create(const AJobs: TSyncJobArray;
  const ADbPath: string; AMaxConcurrency: Integer;
  ACancel: TSyncCancellation; AOnPacket: TSyncPacketCallback);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FJobs := Copy(AJobs, 0, Length(AJobs));
  FDbPath := ADbPath;
  if AMaxConcurrency < 1 then
    FMaxConcurrency := 1
  else
    FMaxConcurrency := AMaxConcurrency;
  FCancel := ACancel;
  FOnPacket := AOnPacket;
  FWorkersLock := TCriticalSection.Create;
end;

destructor TSyncBatchRunner.Destroy;
begin
  FWorkersLock.Free;
  inherited Destroy;
end;

procedure TSyncBatchRunner.AbortAllHttp;
var
  I: Integer;
begin
  FWorkersLock.Acquire;
  try
    for I := 0 to High(FWorkers) do
      if Assigned(FWorkers[I]) then
      begin
        FWorkers[I].Terminate;
        FWorkers[I].AbortActiveHttp;
      end;
  finally
    FWorkersLock.Release;
  end;
end;

procedure TSyncBatchRunner.EmitBatchFinished(ASuccess: Boolean;
  const AMsg: string; const ASnapshot: TPostDTOArray);
var
  Pkg: PSyncUiPacket;
begin
  if not Assigned(FOnPacket) then
    Exit;
  Pkg := NewSyncPacket(sekBatchFinished);
  Pkg^.Success := ASuccess;
  Pkg^.MessageText := AMsg;
  Pkg^.Snapshot := ASnapshot;
  FOnPacket(Pkg);
end;

procedure TSyncBatchRunner.Execute;
var
  Sem: TCountingSemaphore;
  Limiter: TLocalRateLimiter;
  I, OkCount, TotalSaved: Integer;
  Snapshot: TPostDTOArray;
  StartTick: QWord;
  Summary: string;
begin
  TThread.NameThreadForDebugging('SyncBatchRunner');
  StartTick := GetTickCount64;
  Snapshot := nil;
  Sem := nil;
  Limiter := nil;

  try
    EnsureOpenSslInitialized;
    EnsureDatabaseSchema(FDbPath);

    Sem := TCountingSemaphore.Create(FMaxConcurrency, FMaxConcurrency);
    Limiter := TLocalRateLimiter.Create(120);

    FWorkersLock.Acquire;
    try
      SetLength(FWorkers, Length(FJobs));
      for I := 0 to High(FJobs) do
        FWorkers[I] := TRestSyncWorker.Create(
          FJobs[I], FDbPath, Sem, Limiter, FCancel, FOnPacket);
    finally
      FWorkersLock.Release;
    end;

    for I := 0 to High(FWorkers) do
      FWorkers[I].Start;

    OkCount := 0;
    TotalSaved := 0;
    for I := 0 to High(FWorkers) do
    begin
      FWorkers[I].WaitFor;
      if FWorkers[I].Success then
      begin
        Inc(OkCount);
        Inc(TotalSaved, FWorkers[I].RecordsSaved);
      end;
    end;

    { Le snapshot completo desconectado para entrega thread-safe a UI }
    Snapshot := LoadSnapshotFromDatabase(FDbPath, 500);

    if FCancel.IsCancelled then
      Summary := Format('Sincronizacao cancelada (%d/%d jobs OK, %d itens)',
        [OkCount, Length(FJobs), TotalSaved])
    else
      Summary := Format('Concluido em %d ms (%d/%d jobs OK, %d registros)',
        [GetTickCount64 - StartTick, OkCount, Length(FJobs), TotalSaved]);

    EmitBatchFinished(not FCancel.IsCancelled, Summary, Snapshot);
  except
    on E: Exception do
      EmitBatchFinished(False, 'Falha no lote: ' + E.Message, Snapshot);
  end;

  FWorkersLock.Acquire;
  try
    for I := 0 to High(FWorkers) do
      FreeAndNil(FWorkers[I]);
    SetLength(FWorkers, 0);
  finally
    FWorkersLock.Release;
  end;

  Limiter.Free;
  Sem.Free;
end;

initialization
  GSslLock := TCriticalSection.Create;

finalization
  FreeAndNil(GSslLock);

end.
