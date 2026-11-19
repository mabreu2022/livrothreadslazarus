unit uConcurrentStructures;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  { Fila generica limitada com backpressure e encerramento limpo }
  generic TBoundedThreadQueue<T> = class
  private
    FLock: TCriticalSection;
    FNotEmpty: TEvent;
    FNotFull: TEvent;
    FBuffer: array of T;
    FCapacity: Integer;
    FHead: Integer;
    FTail: Integer;
    FCount: Integer;
    FClosed: Boolean;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;
    function Enqueue(const AItem: T; ATimeoutMs: Cardinal = INFINITE): Boolean;
    function Dequeue(out AItem: T; ATimeoutMs: Cardinal = INFINITE): Boolean;
    procedure Close;
    function Count: Integer;
    function IsClosed: Boolean;
  end;

  TTaskProc = procedure(AData: Pointer) of object;

  TWorkItem = record
    Proc: TTaskProc;
    Data: Pointer;
  end;

  TWorkItemQueue = specialize TBoundedThreadQueue<TWorkItem>;

  TThreadPool = class;

  TPoolWorker = class(TThread)
  private
    FOwner: TThreadPool;
    FWorkerId: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TThreadPool; AWorkerId: Integer);
  end;

  { Pool de threads portavel FPC 3.2.2 com fila limitada }
  TThreadPool = class
  private
    FQueue: TWorkItemQueue;
    FWorkers: array of TPoolWorker;
    FIdleEvent: TEvent;
    FInFlight: LongInt;
    FCompletedTasks: Int64;
    FFailedTasks: Int64;
    FShutdownCalled: Boolean;
    procedure ExecuteWorkItem(const AItem: TWorkItem);
  public
    constructor Create(AWorkerCount, AQueueCapacity: Integer);
    destructor Destroy; override;
    function Submit(AProc: TTaskProc; AData: Pointer = nil;
      ATimeoutMs: Cardinal = INFINITE): Boolean;
    function WaitIdle(ATimeoutMs: Cardinal = 10000): Boolean;
    procedure Shutdown;
    function CompletedTasks: Int64;
    function FailedTasks: Int64;
  end;

  { Cache concorrente protegido por TMultiReadExclusiveWriteSynchronizer }
  TThreadSafeCache = class
  private
    const
      BUCKET_COUNT = 64;
    type
      PCacheNode = ^TCacheNode;
      TCacheNode = record
        Key: string;
        Value: string;
        Next: PCacheNode;
      end;
  private
    FRWLock: TMultiReadExclusiveWriteSynchronizer;
    FBuckets: array[0..BUCKET_COUNT - 1] of PCacheNode;
    FCount: Integer;
    FHits: Int64;
    FMisses: Int64;
    function HashKey(const AKey: string): Cardinal;
    procedure ClearUnlocked;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Put(const AKey, AValue: string);
    function TryGet(const AKey: string; out AValue: string): Boolean;
    function Remove(const AKey: string): Boolean;
    procedure Clear;
    function Count: Integer;
    function Hits: Int64;
    function Misses: Int64;
  end;

implementation

{ TBoundedThreadQueue<T> }

constructor TBoundedThreadQueue.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity <= 0 then
    raise EArgumentException.Create('ACapacity deve ser positivo.');

  FCapacity := ACapacity;
  SetLength(FBuffer, FCapacity);
  FHead := 0;
  FTail := 0;
  FCount := 0;
  FClosed := False;

  FLock := TCriticalSection.Create;
  FNotEmpty := TEvent.Create(nil, True, False, '');
  FNotFull := TEvent.Create(nil, True, True, '');
end;

destructor TBoundedThreadQueue.Destroy;
begin
  Close;
  SetLength(FBuffer, 0);
  FNotFull.Free;
  FNotEmpty.Free;
  FLock.Free;
  inherited Destroy;
end;

function TBoundedThreadQueue.Enqueue(const AItem: T;
  ATimeoutMs: Cardinal): Boolean;
var
  StartTick, Elapsed, Remain: QWord;
  WaitMs: Cardinal;
begin
  StartTick := GetTickCount64;
  while True do
  begin
    FLock.Acquire;
    try
      if FClosed then
        Exit(False);
      if FCount < FCapacity then
      begin
        FBuffer[FTail] := AItem;
        FTail := (FTail + 1) mod FCapacity;
        Inc(FCount);
        FNotEmpty.SetEvent;
        if FCount = FCapacity then
          FNotFull.ResetEvent;
        Exit(True);
      end;
    finally
      FLock.Release;
    end;

    if ATimeoutMs = 0 then
      Exit(False);

    if ATimeoutMs = INFINITE then
      WaitMs := 50
    else
    begin
      Elapsed := GetTickCount64 - StartTick;
      if Elapsed >= ATimeoutMs then
        Exit(False);
      Remain := ATimeoutMs - Elapsed;
      if Remain > 50 then
        WaitMs := 50
      else
        WaitMs := Cardinal(Remain);
    end;

    FNotFull.WaitFor(WaitMs);
  end;
end;

function TBoundedThreadQueue.Dequeue(out AItem: T;
  ATimeoutMs: Cardinal): Boolean;
var
  StartTick, Elapsed, Remain: QWord;
  WaitMs: Cardinal;
begin
  AItem := Default(T);
  StartTick := GetTickCount64;
  while True do
  begin
    FLock.Acquire;
    try
      if FCount > 0 then
      begin
        AItem := FBuffer[FHead];
        FBuffer[FHead] := Default(T);
        FHead := (FHead + 1) mod FCapacity;
        Dec(FCount);
        FNotFull.SetEvent;
        if (FCount = 0) and (not FClosed) then
          FNotEmpty.ResetEvent;
        Exit(True);
      end;
      if FClosed then
        Exit(False);
    finally
      FLock.Release;
    end;

    if ATimeoutMs = 0 then
      Exit(False);

    if ATimeoutMs = INFINITE then
      WaitMs := 50
    else
    begin
      Elapsed := GetTickCount64 - StartTick;
      if Elapsed >= ATimeoutMs then
        Exit(False);
      Remain := ATimeoutMs - Elapsed;
      if Remain > 50 then
        WaitMs := 50
      else
        WaitMs := Cardinal(Remain);
    end;

    FNotEmpty.WaitFor(WaitMs);
  end;
end;

procedure TBoundedThreadQueue.Close;
begin
  FLock.Acquire;
  try
    if not FClosed then
    begin
      FClosed := True;
      FNotEmpty.SetEvent;
      FNotFull.SetEvent;
    end;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.IsClosed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FClosed;
  finally
    FLock.Release;
  end;
end;

{ TPoolWorker }

constructor TPoolWorker.Create(AOwner: TThreadPool; AWorkerId: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FWorkerId := AWorkerId;
end;

procedure TPoolWorker.Execute;
var
  Item: TWorkItem;
begin
  TThread.NameThreadForDebugging(
    AnsiString('StressPoolWorker-' + IntToStr(FWorkerId)));

  while FOwner.FQueue.Dequeue(Item, INFINITE) do
    FOwner.ExecuteWorkItem(Item);
end;

{ TThreadPool }

constructor TThreadPool.Create(AWorkerCount, AQueueCapacity: Integer);
var
  I: Integer;
begin
  inherited Create;
  if AWorkerCount <= 0 then
    raise EArgumentException.Create('AWorkerCount deve ser positivo.');

  FQueue := TWorkItemQueue.Create(AQueueCapacity);
  FIdleEvent := TEvent.Create(nil, True, True, '');
  FInFlight := 0;
  FCompletedTasks := 0;
  FFailedTasks := 0;
  FShutdownCalled := False;

  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
    FWorkers[I] := TPoolWorker.Create(Self, I + 1);
  for I := 0 to AWorkerCount - 1 do
    FWorkers[I].Start;
end;

destructor TThreadPool.Destroy;
begin
  Shutdown;
  FIdleEvent.Free;
  FQueue.Free;
  inherited Destroy;
end;

procedure TThreadPool.ExecuteWorkItem(const AItem: TWorkItem);
begin
  try
    if Assigned(AItem.Proc) then
      AItem.Proc(AItem.Data);
    InterlockedIncrement64(FCompletedTasks);
  except
    InterlockedIncrement64(FFailedTasks);
  end;

  if InterlockedDecrement(FInFlight) = 0 then
    FIdleEvent.SetEvent;
end;

function TThreadPool.Submit(AProc: TTaskProc; AData: Pointer;
  ATimeoutMs: Cardinal): Boolean;
var
  Item: TWorkItem;
begin
  Item.Proc := AProc;
  Item.Data := AData;

  if InterlockedIncrement(FInFlight) = 1 then
    FIdleEvent.ResetEvent;

  Result := FQueue.Enqueue(Item, ATimeoutMs);
  if not Result then
  begin
    if InterlockedDecrement(FInFlight) = 0 then
      FIdleEvent.SetEvent;
  end;
end;

function TThreadPool.WaitIdle(ATimeoutMs: Cardinal): Boolean;
begin
  if InterlockedCompareExchange(FInFlight, 0, 0) = 0 then
    Exit(True);
  Result := FIdleEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

procedure TThreadPool.Shutdown;
var
  I: Integer;
begin
  if FShutdownCalled then
    Exit;
  FShutdownCalled := True;

  FQueue.Close;
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

function TThreadPool.CompletedTasks: Int64;
begin
  Result := InterlockedCompareExchange64(FCompletedTasks, 0, 0);
end;

function TThreadPool.FailedTasks: Int64;
begin
  Result := InterlockedCompareExchange64(FFailedTasks, 0, 0);
end;

{ TThreadSafeCache }

constructor TThreadSafeCache.Create;
var
  I: Integer;
begin
  inherited Create;
  FRWLock := TMultiReadExclusiveWriteSynchronizer.Create;
  for I := 0 to BUCKET_COUNT - 1 do
    FBuckets[I] := nil;
  FCount := 0;
  FHits := 0;
  FMisses := 0;
end;

destructor TThreadSafeCache.Destroy;
begin
  Clear;
  FRWLock.Free;
  inherited Destroy;
end;

function TThreadSafeCache.HashKey(const AKey: string): Cardinal;
var
  I: Integer;
begin
  { FNV-1a 32-bit simples e rapido }
  Result := 2166136261;
  for I := 1 to Length(AKey) do
  begin
    Result := Result xor Ord(AKey[I]);
    Result := Cardinal(QWord(Result) * 16777619);
  end;
  Result := Result mod BUCKET_COUNT;
end;

procedure TThreadSafeCache.ClearUnlocked;
var
  I: Integer;
  Node, NextNode: PCacheNode;
begin
  for I := 0 to BUCKET_COUNT - 1 do
  begin
    Node := FBuckets[I];
    while Node <> nil do
    begin
      NextNode := Node^.Next;
      Node^.Key := '';
      Node^.Value := '';
      Dispose(Node);
      Node := NextNode;
    end;
    FBuckets[I] := nil;
  end;
  FCount := 0;
end;

procedure TThreadSafeCache.Put(const AKey, AValue: string);
var
  Idx: Cardinal;
  Node: PCacheNode;
begin
  Idx := HashKey(AKey);
  FRWLock.BeginWrite;
  try
    Node := FBuckets[Idx];
    while Node <> nil do
    begin
      if Node^.Key = AKey then
      begin
        Node^.Value := AValue;
        Exit;
      end;
      Node := Node^.Next;
    end;

    New(Node);
    Node^.Key := AKey;
    Node^.Value := AValue;
    Node^.Next := FBuckets[Idx];
    FBuckets[Idx] := Node;
    Inc(FCount);
  finally
    FRWLock.EndWrite;
  end;
end;

function TThreadSafeCache.TryGet(const AKey: string;
  out AValue: string): Boolean;
var
  Idx: Cardinal;
  Node: PCacheNode;
begin
  Result := False;
  AValue := '';
  Idx := HashKey(AKey);

  FRWLock.BeginRead;
  try
    Node := FBuckets[Idx];
    while Node <> nil do
    begin
      if Node^.Key = AKey then
      begin
        AValue := Node^.Value;
        Result := True;
        Break;
      end;
      Node := Node^.Next;
    end;
  finally
    FRWLock.EndRead;
  end;

  if Result then
    InterlockedIncrement64(FHits)
  else
    InterlockedIncrement64(FMisses);
end;

function TThreadSafeCache.Remove(const AKey: string): Boolean;
var
  Idx: Cardinal;
  Prev, Curr: PCacheNode;
begin
  Result := False;
  Idx := HashKey(AKey);
  FRWLock.BeginWrite;
  try
    Prev := nil;
    Curr := FBuckets[Idx];
    while Curr <> nil do
    begin
      if Curr^.Key = AKey then
      begin
        if Prev = nil then
          FBuckets[Idx] := Curr^.Next
        else
          Prev^.Next := Curr^.Next;
        Curr^.Key := '';
        Curr^.Value := '';
        Dispose(Curr);
        Dec(FCount);
        Exit(True);
      end;
      Prev := Curr;
      Curr := Curr^.Next;
    end;
  finally
    FRWLock.EndWrite;
  end;
end;

procedure TThreadSafeCache.Clear;
begin
  FRWLock.BeginWrite;
  try
    ClearUnlocked;
  finally
    FRWLock.EndWrite;
  end;
end;

function TThreadSafeCache.Count: Integer;
begin
  FRWLock.BeginRead;
  try
    Result := FCount;
  finally
    FRWLock.EndRead;
  end;
end;

function TThreadSafeCache.Hits: Int64;
begin
  Result := InterlockedCompareExchange64(FHits, 0, 0);
end;

function TThreadSafeCache.Misses: Int64;
begin
  Result := InterlockedCompareExchange64(FMisses, 0, 0);
end;

end.
