unit uThreadPool;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, uCancellation, uBoundedQueue;

type
  { Barreira Fan-In portavel em FPC 3.2.2+ }
  TCountdownEvent = class
  private
    FLock: TCriticalSection;
    FZeroEvent: TSimpleEvent;
    FRemaining: LongInt;
    function GetRemaining: LongInt;
  public
    constructor Create(AInitialCount: LongInt);
    destructor Destroy; override;
    procedure AddCount(ADelta: LongInt = 1);
    procedure Signal;
    function Wait(ATimeoutMs: Cardinal = INFINITE): Boolean;
    function WaitCancellable(const AToken: ICancellationToken): Boolean;
    property Remaining: LongInt read GetRemaining;
  end;

  TPoolTaskMethod = procedure(AData: Pointer;
    const AToken: ICancellationToken) of object;

  TPoolErrorEvent = procedure(const AErrorClass, AErrorMsg: string;
    AData: Pointer) of object;

  TPoolWorkItem = record
    Method: TPoolTaskMethod;
    Data: Pointer;
    Token: ICancellationToken;
    Countdown: TCountdownEvent;
    OnError: TPoolErrorEvent;
  end;

  TPoolWorkQueue = specialize TBoundedThreadQueue<TPoolWorkItem>;

  TThreadPool = class;

  TPoolWorkerThread = class(TThread)
  private
    FPool: TThreadPool;
    FWorkerIndex: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TThreadPool; AWorkerIndex: Integer);
  end;

  { Thread Pool portavel com fila limitada, captura de excecoes e shutdown }
  TThreadPool = class
  private
    FQueue: TPoolWorkQueue;
    FWorkers: array of TPoolWorkerThread;
    FShutdownCalled: Boolean;
    FActiveWorkers: LongInt;
    FCompletedTasks: Int64;
    FFailedTasks: Int64;
    FDefaultOnError: TPoolErrorEvent;
    function GetWorkerCount: Integer;
    function GetActiveWorkers: LongInt;
    function GetPendingTasks: Integer;
    function GetCompletedTasks: Int64;
    function GetFailedTasks: Int64;
  protected
    procedure RunWorkerLoop(AWorkerIndex: Integer);
  public
    constructor Create(AWorkerCount: Integer = 0; AQueueCapacity: Integer = 256);
    destructor Destroy; override;

    function Submit(AMethod: TPoolTaskMethod; AData: Pointer = nil;
      const AToken: ICancellationToken = nil;
      ACountdown: TCountdownEvent = nil;
      AOnError: TPoolErrorEvent = nil): Boolean;

    procedure Shutdown(AWaitForPending: Boolean = True);

    property WorkerCount: Integer read GetWorkerCount;
    property ActiveWorkers: LongInt read GetActiveWorkers;
    property PendingTasks: Integer read GetPendingTasks;
    property CompletedTasks: Int64 read GetCompletedTasks;
    property FailedTasks: Int64 read GetFailedTasks;
    property OnTaskError: TPoolErrorEvent
      read FDefaultOnError write FDefaultOnError;
  end;

implementation

{ TCountdownEvent }

constructor TCountdownEvent.Create(AInitialCount: LongInt);
begin
  inherited Create;
  if AInitialCount < 0 then
    raise EArgumentOutOfRangeException.Create(
      'AInitialCount de TCountdownEvent nao pode ser negativo');
  FLock := TCriticalSection.Create;
  FZeroEvent := TSimpleEvent.Create;
  FRemaining := AInitialCount;
  if FRemaining = 0 then
    FZeroEvent.SetEvent;
end;

destructor TCountdownEvent.Destroy;
begin
  FZeroEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TCountdownEvent.AddCount(ADelta: LongInt);
begin
  if ADelta <= 0 then
    Exit;
  FLock.Acquire;
  try
    if FRemaining = 0 then
      FZeroEvent.ResetEvent;
    Inc(FRemaining, ADelta);
  finally
    FLock.Release;
  end;
end;

procedure TCountdownEvent.Signal;
begin
  FLock.Acquire;
  try
    if FRemaining > 0 then
    begin
      Dec(FRemaining);
      if FRemaining = 0 then
        FZeroEvent.SetEvent;
    end;
  finally
    FLock.Release;
  end;
end;

function TCountdownEvent.Wait(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FZeroEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TCountdownEvent.WaitCancellable(
  const AToken: ICancellationToken): Boolean;
begin
  while True do
  begin
    if FZeroEvent.WaitFor(25) = wrSignaled then
      Exit(True);
    if Assigned(AToken) and AToken.IsCancelled then
      Exit(False);
  end;
end;

function TCountdownEvent.GetRemaining: LongInt;
begin
  FLock.Acquire;
  try
    Result := FRemaining;
  finally
    FLock.Release;
  end;
end;

{ TPoolWorkerThread }

constructor TPoolWorkerThread.Create(APool: TThreadPool; AWorkerIndex: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPool := APool;
  FWorkerIndex := AWorkerIndex;
end;

procedure TPoolWorkerThread.Execute;
begin
  FPool.RunWorkerLoop(FWorkerIndex);
end;

{ TThreadPool }

constructor TThreadPool.Create(AWorkerCount: Integer; AQueueCapacity: Integer);
var
  Count, I: Integer;
begin
  inherited Create;
  if AWorkerCount <= 0 then
    Count := Max(2, Integer(TThread.ProcessorCount))
  else
    Count := AWorkerCount;

  FShutdownCalled := False;
  FActiveWorkers := 0;
  FCompletedTasks := 0;
  FFailedTasks := 0;
  FQueue := TPoolWorkQueue.Create(Max(1, AQueueCapacity));

  SetLength(FWorkers, Count);
  for I := 0 to Count - 1 do
  begin
    FWorkers[I] := TPoolWorkerThread.Create(Self, I);
    FWorkers[I].Start;
  end;
end;

destructor TThreadPool.Destroy;
begin
  Shutdown(True);
  FQueue.Free;
  inherited Destroy;
end;

function TThreadPool.Submit(AMethod: TPoolTaskMethod; AData: Pointer;
  const AToken: ICancellationToken; ACountdown: TCountdownEvent;
  AOnError: TPoolErrorEvent): Boolean;
var
  Item: TPoolWorkItem;
begin
  if not Assigned(AMethod) then
    Exit(False);

  Item.Method := AMethod;
  Item.Data := AData;
  Item.Token := AToken;
  Item.Countdown := ACountdown;
  Item.OnError := AOnError;

  Result := FQueue.Enqueue(Item, AToken);
  if (not Result) and Assigned(ACountdown) then
  begin
    { Evita que barreira Fan-In trave se a submissao for rejeitada }
    ACountdown.Signal;
  end;
end;

procedure TThreadPool.RunWorkerLoop(AWorkerIndex: Integer);
var
  Item: TPoolWorkItem;
  ErrHandler: TPoolErrorEvent;
begin
  { AWorkerIndex disponivel para telemetria/depuracao por worker }
  if AWorkerIndex < 0 then
    Exit;

  while FQueue.TryDequeue(Item) do
  begin
    InterlockedIncrement(FActiveWorkers);
    try
      try
        if (not Assigned(Item.Token)) or (not Item.Token.IsCancelled) then
        begin
          Item.Method(Item.Data, Item.Token);
          InterlockedIncrement64(FCompletedTasks);
        end;
      except
        on E: ECancellationRequested do
          ; { Cancelamento cooperativo e encerramento esperado }
        on E: Exception do
        begin
          InterlockedIncrement64(FFailedTasks);
          ErrHandler := Item.OnError;
          if not Assigned(ErrHandler) then
            ErrHandler := FDefaultOnError;
          if Assigned(ErrHandler) then
            ErrHandler(E.ClassName, E.Message, Item.Data);
        end;
      end;
    finally
      if Assigned(Item.Countdown) then
        Item.Countdown.Signal;
      InterlockedDecrement(FActiveWorkers);
    end;
  end;
end;

procedure TThreadPool.Shutdown(AWaitForPending: Boolean);
var
  I: Integer;
  Dropped: TPoolWorkItem;
begin
  if FShutdownCalled then
    Exit;
  FShutdownCalled := True;

  if AWaitForPending then
    FQueue.CompleteAdding
  else
  begin
    FQueue.Abort;
    { Drena itens descartados e libera eventuais barreiras Countdown }
    while FQueue.TryDequeueNoWait(Dropped) do
      if Assigned(Dropped.Countdown) then
        Dropped.Countdown.Signal;
  end;

  for I := 0 to High(FWorkers) do
  begin
    if Assigned(FWorkers[I]) then
    begin
      FWorkers[I].WaitFor;
      FreeAndNil(FWorkers[I]);
    end;
  end;
  SetLength(FWorkers, 0);
end;

function TThreadPool.GetWorkerCount: Integer;
begin
  Result := Length(FWorkers);
end;

function TThreadPool.GetActiveWorkers: LongInt;
begin
  Result := InterlockedCompareExchange(FActiveWorkers, 0, 0);
end;

function TThreadPool.GetPendingTasks: Integer;
begin
  Result := FQueue.Count;
end;

function TThreadPool.GetCompletedTasks: Int64;
begin
  Result := InterlockedCompareExchange64(FCompletedTasks, 0, 0);
end;

function TThreadPool.GetFailedTasks: Int64;
begin
  Result := InterlockedCompareExchange64(FFailedTasks, 0, 0);
end;

end.
