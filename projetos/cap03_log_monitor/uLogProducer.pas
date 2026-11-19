unit uLogProducer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TLogLevel = (llInfo, llWarn, llError);

  TDispatchMode = (dmNaiveSync, dmBatchedAsync);

  PLogEntry = ^TLogEntry;
  TLogEntry = record
    Seq: Int64;
    TimestampMs: QWord;
    Level: TLogLevel;
    MessageText: string;
  end;

  TOnSingleLogEvent = procedure(const AEntry: TLogEntry) of object;
  TOnBatchSignalEvent = procedure(AForceFinal: Boolean) of object;
  TOnProducerDoneEvent = procedure(ATotalProduced: Int64;
    AElapsedMs: QWord; AAborted: Boolean) of object;

  { Fila segura para transferencia em lote (Padrao Drain Queue) }
  TLogBatchQueue = class
  private
    FThreadList: TThreadList;
    FPendingSignal: LongInt;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Enqueue(const AEntry: TLogEntry);
    function DrainTo(ADest: TList): Integer;
    function TryClaimSignal: Boolean;
    procedure ResetSignal;
    procedure Clear;
  end;

  { Thread produtora de logs em alta vazao }
  TLogProducerThread = class(TThread)
  private
    FMode: TDispatchMode;
    FTargetCount: Int64;
    FThrottleMs: QWord;
    FQueue: TLogBatchQueue;
    FOnSingleLog: TOnSingleLogEvent;
    FOnBatchSignal: TOnBatchSignalEvent;
    FOnDone: TOnProducerDoneEvent;

    FCurrentEntry: TLogEntry;
    FProducedCount: Int64;
    FElapsedMs: QWord;
    FAborted: Boolean;

    procedure DispatchSingleInMainThread;
    procedure NotifyDoneInMainThread;
    function BuildLogEntry(ASeq: Int64; ANowMs: QWord): TLogEntry;
  protected
    procedure Execute; override;
  public
    constructor Create(AMode: TDispatchMode; ATargetCount: Int64;
      AThrottleMs: QWord; AQueue: TLogBatchQueue;
      AOnSingleLog: TOnSingleLogEvent;
      AOnBatchSignal: TOnBatchSignalEvent;
      AOnDone: TOnProducerDoneEvent);

    function GetProducedCount: Int64;
  end;

function LogLevelToStr(ALevel: TLogLevel): string;
procedure FreeLogEntryList(AList: TList);

implementation

function LogLevelToStr(ALevel: TLogLevel): string;
begin
  case ALevel of
    llInfo:  Result := 'INFO ';
    llWarn:  Result := 'WARN ';
    llError: Result := 'ERROR';
  end;
end;

procedure FreeLogEntryList(AList: TList);
var
  I: Integer;
  Entry: PLogEntry;
begin
  for I := 0 to AList.Count - 1 do
  begin
    Entry := PLogEntry(AList[I]);
    Dispose(Entry);
  end;
  AList.Clear;
end;

{ TLogBatchQueue }

constructor TLogBatchQueue.Create;
begin
  inherited Create;
  FThreadList := TThreadList.Create;
  FPendingSignal := 0;
end;

destructor TLogBatchQueue.Destroy;
begin
  Clear;
  FThreadList.Free;
  inherited Destroy;
end;

procedure TLogBatchQueue.Enqueue(const AEntry: TLogEntry);
var
  Item: PLogEntry;
  List: TList;
begin
  New(Item);
  Item^ := AEntry;
  List := FThreadList.LockList;
  try
    List.Add(Item);
  finally
    FThreadList.UnlockList;
  end;
end;

function TLogBatchQueue.DrainTo(ADest: TList): Integer;
var
  Src: TList;
  I: Integer;
begin
  Src := FThreadList.LockList;
  try
    Result := Src.Count;
    if Result = 0 then
      Exit;
    if ADest.Capacity < ADest.Count + Result then
      ADest.Capacity := ADest.Count + Result;
    for I := 0 to Result - 1 do
      ADest.Add(Src[I]);
    Src.Clear;
  finally
    FThreadList.UnlockList;
  end;
end;

function TLogBatchQueue.TryClaimSignal: Boolean;
begin
  { Coalescencia atomica: garante no maximo 1 chamada assincrona em voo }
  Result := InterlockedCompareExchange(FPendingSignal, 1, 0) = 0;
end;

procedure TLogBatchQueue.ResetSignal;
begin
  InterlockedExchange(FPendingSignal, 0);
end;

procedure TLogBatchQueue.Clear;
var
  List: TList;
begin
  List := FThreadList.LockList;
  try
    FreeLogEntryList(List);
  finally
    FThreadList.UnlockList;
  end;
  InterlockedExchange(FPendingSignal, 0);
end;

{ TLogProducerThread }

constructor TLogProducerThread.Create(AMode: TDispatchMode;
  ATargetCount: Int64; AThrottleMs: QWord; AQueue: TLogBatchQueue;
  AOnSingleLog: TOnSingleLogEvent; AOnBatchSignal: TOnBatchSignalEvent;
  AOnDone: TOnProducerDoneEvent);
begin
  inherited Create(True); // Cria suspensa para inicializar campos
  FreeOnTerminate := False;
  FMode := AMode;
  FTargetCount := ATargetCount;
  FThrottleMs := AThrottleMs;
  FQueue := AQueue;
  FOnSingleLog := AOnSingleLog;
  FOnBatchSignal := AOnBatchSignal;
  FOnDone := AOnDone;
  FProducedCount := 0;
  FElapsedMs := 0;
  FAborted := False;
end;

function TLogProducerThread.BuildLogEntry(ASeq: Int64;
  ANowMs: QWord): TLogEntry;
const
  CPayloads: array[0..3] of string = (
    'Requisicao HTTP 200 /api/v1/orders',
    'Pool de conexoes atingiu 82% de uso',
    'Timeout transitorio no gateway de pagamento',
    'Checkpoint de replicacao concluido'
  );
begin
  Result.Seq := ASeq;
  Result.TimestampMs := ANowMs;
  if (ASeq mod 25) = 0 then
    Result.Level := llError
  else if (ASeq mod 7) = 0 then
    Result.Level := llWarn
  else
    Result.Level := llInfo;
  Result.MessageText := CPayloads[ASeq and 3];
end;

procedure TLogProducerThread.DispatchSingleInMainThread;
begin
  if Assigned(FOnSingleLog) then
    FOnSingleLog(FCurrentEntry);
end;

procedure TLogProducerThread.NotifyDoneInMainThread;
begin
  if Assigned(FOnDone) then
    FOnDone(FProducedCount, FElapsedMs, FAborted);
end;

function TLogProducerThread.GetProducedCount: Int64;
begin
  Result := InterlockedExchangeAdd64(FProducedCount, 0);
end;

procedure TLogProducerThread.Execute;
var
  Seq: Int64;
  StartMs, NowMs, LastSignalMs: QWord;
  Entry: TLogEntry;
begin
  StartMs := GetTickCount64;
  LastSignalMs := StartMs;
  Seq := 0;

  while (not Terminated) and (Seq < FTargetCount) do
  begin
    Inc(Seq);
    NowMs := GetTickCount64;
    Entry := BuildLogEntry(Seq, NowMs);

    if FMode = dmNaiveSync then
    begin
      { MODO INGENUO: bloqueia a thread produtora a cada evento }
      FCurrentEntry := Entry;
      InterlockedExchange64(FProducedCount, Seq);
      Synchronize(@DispatchSingleInMainThread);
    end
    else
    begin
      { MODO LOTEADO: enfileira em memoria e coalesca notificacao }
      FQueue.Enqueue(Entry);
      InterlockedExchange64(FProducedCount, Seq);

      if (NowMs - LastSignalMs >= FThrottleMs) and
         Assigned(FOnBatchSignal) then
      begin
        LastSignalMs := NowMs;
        FOnBatchSignal(False);
      end;
    end;
  end;

  FAborted := Terminated;
  FElapsedMs := GetTickCount64 - StartMs;
  if FElapsedMs = 0 then
    FElapsedMs := 1;

  if (FMode = dmBatchedAsync) and Assigned(FOnBatchSignal) then
    FOnBatchSignal(True);

  { Avisa a UI sobre o termino (seguro mesmo durante WaitFor) }
  Synchronize(@NotifyDoneInMainThread);
end;

end.
