unit uStressTests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  uStressSync, uConcurrentStructures;

type
  TInt64Queue = specialize TBoundedThreadQueue<Int64>;

  { Suita 1: Estresse de TBoundedThreadQueue }
  TBoundedQueueStressTests = class(TTestCase)
  private
    FActiveQueue: TInt64Queue;
    procedure OnQueueWatchdogTimeout(Sender: TObject);
  published
    procedure TestMPMCExactIntegrity;
    procedure TestBackpressureAndGracefulClose;
  end;

  { Suita 2: Estresse de TThreadPool }
  TThreadPoolStressTests = class(TTestCase)
  private
    FActivePool: TThreadPool;
    FAccumulatedSum: Int64;
    FValidExecuted: Int64;
    procedure OnPoolWatchdogTimeout(Sender: TObject);
    procedure SumWorkProc(AData: Pointer);
    procedure MixedFaultProc(AData: Pointer);
  published
    procedure TestHighContentionThroughput;
    procedure TestExceptionIsolationUnderLoad;
  end;

  { Suita 3: Estresse de TThreadSafeCache + Watchdog }
  TThreadSafeCacheStressTests = class(TTestCase)
  private
    FStallReleaseEvent: TEvent;
    procedure OnStallWatchdogTimeout(Sender: TObject);
  published
    procedure TestReadWriteHeavyContention;
    procedure TestWatchdogDetectsSimulatedStall;
  end;

implementation

type
  { Produtor para teste MPMC da fila limitada }
  TQueueProducerThread = class(TThread)
  private
    FQueue: TInt64Queue;
    FBarrier: TStartBarrier;
    FStartVal: Int64;
    FCount: Integer;
    FEnqueued: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TInt64Queue; ABarrier: TStartBarrier;
      AStartVal: Int64; ACount: Integer);
    property Enqueued: Integer read FEnqueued;
  end;

  { Consumidor para teste MPMC da fila limitada }
  TQueueConsumerThread = class(TThread)
  private
    FQueue: TInt64Queue;
    FBarrier: TStartBarrier;
    FTargetCount: PInt64;
    FTargetSum: PInt64;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TInt64Queue; ABarrier: TStartBarrier;
      ATargetCount, ATargetSum: PInt64);
  end;

  { Cliente concorrente submetendo tarefas ao TThreadPool }
  TPoolSubmitterThread = class(TThread)
  private
    FPool: TThreadPool;
    FBarrier: TStartBarrier;
    FProc: TTaskProc;
    FStartVal: PtrInt;
    FCount: Integer;
    FRejected: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TThreadPool; ABarrier: TStartBarrier;
      AProc: TTaskProc; AStartVal: PtrInt; ACount: Integer);
    property Rejected: Integer read FRejected;
  end;

  { Thread leitora/escritora de estresse do TThreadSafeCache }
  TCacheStressThread = class(TThread)
  private
    FCache: TThreadSafeCache;
    FBarrier: TStartBarrier;
    FIsWriter: Boolean;
    FWorkerId: Integer;
    FOperations: Integer;
    FCorruptReads: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(ACache: TThreadSafeCache; ABarrier: TStartBarrier;
      AIsWriter: Boolean; AWorkerId, AOperations: Integer);
    property CorruptReads: LongInt read FCorruptReads;
  end;

  { Thread que simula trava controlada para validar TDeadlockWatchdog }
  TSimulatedStallThread = class(TThread)
  private
    FReleaseEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AReleaseEvent: TEvent);
  end;

{ TQueueProducerThread }

constructor TQueueProducerThread.Create(AQueue: TInt64Queue;
  ABarrier: TStartBarrier; AStartVal: Int64; ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FBarrier := ABarrier;
  FStartVal := AStartVal;
  FCount := ACount;
  FEnqueued := 0;
end;

procedure TQueueProducerThread.Execute;
var
  I: Integer;
begin
  TThread.NameThreadForDebugging('QueueProducer');
  if not FBarrier.ArriveAndWait(5000) then
    Exit;

  for I := 0 to FCount - 1 do
  begin
    if not FQueue.Enqueue(FStartVal + I, 5000) then
      Break;
    Inc(FEnqueued);
  end;
end;

{ TQueueConsumerThread }

constructor TQueueConsumerThread.Create(AQueue: TInt64Queue;
  ABarrier: TStartBarrier; ATargetCount, ATargetSum: PInt64);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FBarrier := ABarrier;
  FTargetCount := ATargetCount;
  FTargetSum := ATargetSum;
end;

procedure TQueueConsumerThread.Execute;
var
  Val, LocalCount, LocalSum: Int64;
begin
  TThread.NameThreadForDebugging('QueueConsumer');
  if not FBarrier.ArriveAndWait(5000) then
    Exit;

  LocalCount := 0;
  LocalSum := 0;
  while FQueue.Dequeue(Val, 5000) do
  begin
    Inc(LocalCount);
    Inc(LocalSum, Val);
  end;

  InterlockedExchangeAdd64(FTargetCount^, LocalCount);
  InterlockedExchangeAdd64(FTargetSum^, LocalSum);
end;

{ TPoolSubmitterThread }

constructor TPoolSubmitterThread.Create(APool: TThreadPool;
  ABarrier: TStartBarrier; AProc: TTaskProc; AStartVal: PtrInt;
  ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPool := APool;
  FBarrier := ABarrier;
  FProc := AProc;
  FStartVal := AStartVal;
  FCount := ACount;
  FRejected := 0;
end;

procedure TPoolSubmitterThread.Execute;
var
  I: Integer;
begin
  TThread.NameThreadForDebugging('PoolSubmitter');
  if not FBarrier.ArriveAndWait(5000) then
    Exit;

  for I := 0 to FCount - 1 do
  begin
    if not FPool.Submit(FProc, Pointer(FStartVal + I), 5000) then
      Inc(FRejected);
  end;
end;

{ TCacheStressThread }

constructor TCacheStressThread.Create(ACache: TThreadSafeCache;
  ABarrier: TStartBarrier; AIsWriter: Boolean; AWorkerId,
  AOperations: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCache := ACache;
  FBarrier := ABarrier;
  FIsWriter := AIsWriter;
  FWorkerId := AWorkerId;
  FOperations := AOperations;
  FCorruptReads := 0;
end;

procedure TCacheStressThread.Execute;
var
  I, KeyId: Integer;
  Key, Val, ExpectedPrefix: string;
begin
  TThread.NameThreadForDebugging(
    AnsiString('CacheStress-' + IntToStr(FWorkerId)));
  if not FBarrier.ArriveAndWait(5000) then
    Exit;

  for I := 1 to FOperations do
  begin
    KeyId := (I + FWorkerId * 13) mod 128;
    Key := 'k-' + IntToStr(KeyId);
    ExpectedPrefix := 'val-' + Key + '-';

    if FIsWriter then
    begin
      if (I mod 17) = 0 then
        FCache.Remove(Key)
      else
        FCache.Put(Key, ExpectedPrefix + IntToStr(I));
    end
    else
    begin
      if FCache.TryGet(Key, Val) then
      begin
        if Copy(Val, 1, Length(ExpectedPrefix)) <> ExpectedPrefix then
          InterlockedIncrement(FCorruptReads);
      end;
    end;
  end;
end;

{ TSimulatedStallThread }

constructor TSimulatedStallThread.Create(AReleaseEvent: TEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FReleaseEvent := AReleaseEvent;
end;

procedure TSimulatedStallThread.Execute;
begin
  TThread.NameThreadForDebugging('SimulatedStall');
  FReleaseEvent.WaitFor(5000);
end;

{ TBoundedQueueStressTests }

procedure TBoundedQueueStressTests.OnQueueWatchdogTimeout(Sender: TObject);
begin
  if Assigned(FActiveQueue) then
    FActiveQueue.Close;
end;

procedure TBoundedQueueStressTests.TestMPMCExactIntegrity;
const
  PRODUCERS = 4;
  CONSUMERS = 4;
  ITEMS_PER_PROD = 10000;
  TOTAL_ITEMS: Int64 = PRODUCERS * ITEMS_PER_PROD;
var
  Queue: TInt64Queue;
  Barrier: TStartBarrier;
  Watchdog: TDeadlockWatchdog;
  Prods: array[0..PRODUCERS - 1] of TQueueProducerThread;
  Cons: array[0..CONSUMERS - 1] of TQueueConsumerThread;
  ConsumedCount, ConsumedSum, ExpectedSum: Int64;
  I: Integer;
begin
  ConsumedCount := 0;
  ConsumedSum := 0;
  Queue := TInt64Queue.Create(128);
  FActiveQueue := Queue;
  Barrier := TStartBarrier.Create(PRODUCERS + CONSUMERS);
  Watchdog := TDeadlockWatchdog.Create(10000, @OnQueueWatchdogTimeout);
  try
    Watchdog.Start;

    for I := 0 to PRODUCERS - 1 do
      Prods[I] := TQueueProducerThread.Create(
        Queue, Barrier, Int64(I) * ITEMS_PER_PROD + 1, ITEMS_PER_PROD);
    for I := 0 to CONSUMERS - 1 do
      Cons[I] := TQueueConsumerThread.Create(
        Queue, Barrier, @ConsumedCount, @ConsumedSum);

    for I := 0 to PRODUCERS - 1 do
      Prods[I].Start;
    for I := 0 to CONSUMERS - 1 do
      Cons[I].Start;

    for I := 0 to PRODUCERS - 1 do
    begin
      Prods[I].WaitFor;
      Prods[I].Free;
    end;

    Queue.Close;

    for I := 0 to CONSUMERS - 1 do
    begin
      Cons[I].WaitFor;
      Cons[I].Free;
    end;

    Watchdog.SignalCompleted;

    ExpectedSum := (TOTAL_ITEMS * (TOTAL_ITEMS + 1)) div 2;
    AssertFalse('Watchdog disparou (possivel deadlock)', Watchdog.TimedOut);
    AssertEquals('Contagem total consumida', TOTAL_ITEMS, ConsumedCount);
    AssertEquals('Soma aritmetica exata', ExpectedSum, ConsumedSum);
    AssertEquals('Fila deve terminar vazia', 0, Queue.Count);
  finally
    FActiveQueue := nil;
    Watchdog.Free;
    Barrier.Free;
    Queue.Free;
  end;
end;

procedure TBoundedQueueStressTests.TestBackpressureAndGracefulClose;
const
  CAPACITY = 16;
  PRODUCERS = 4;
var
  Queue: TInt64Queue;
  Barrier: TStartBarrier;
  Watchdog: TDeadlockWatchdog;
  Prods: array[0..PRODUCERS - 1] of TQueueProducerThread;
  I, TotalEnqueued: Integer;
  Timer: TContentionTimer;
begin
  Queue := TInt64Queue.Create(CAPACITY);
  FActiveQueue := Queue;
  Barrier := TStartBarrier.Create(PRODUCERS);
  Watchdog := TDeadlockWatchdog.Create(4000, @OnQueueWatchdogTimeout);
  try
    Watchdog.Start;
    for I := 0 to PRODUCERS - 1 do
      Prods[I] := TQueueProducerThread.Create(Queue, Barrier, 1, 500);
    for I := 0 to PRODUCERS - 1 do
      Prods[I].Start;

    { Aguarda a fila encher por backpressure (nenhum consumidor ativo) }
    Timer.Start;
    while (Queue.Count < CAPACITY) and (Timer.ElapsedMs < 1500) do
      Sleep(5);

    AssertEquals('Backpressure deve saturar na capacidade',
      CAPACITY, Queue.Count);

    { Fechar a fila deve acordar e liberar todos os produtores bloqueados }
    Queue.Close;

    TotalEnqueued := 0;
    for I := 0 to PRODUCERS - 1 do
    begin
      Prods[I].WaitFor;
      Inc(TotalEnqueued, Prods[I].Enqueued);
      Prods[I].Free;
    end;

    Watchdog.SignalCompleted;
    AssertFalse('Watchdog nao deve disparar no Close', Watchdog.TimedOut);
    AssertEquals('Total aceito antes do Close', CAPACITY, TotalEnqueued);
  finally
    FActiveQueue := nil;
    Watchdog.Free;
    Barrier.Free;
    Queue.Free;
  end;
end;

{ TThreadPoolStressTests }

procedure TThreadPoolStressTests.OnPoolWatchdogTimeout(Sender: TObject);
begin
  if Assigned(FActivePool) then
    FActivePool.Shutdown;
end;

procedure TThreadPoolStressTests.SumWorkProc(AData: Pointer);
begin
  InterlockedExchangeAdd64(FAccumulatedSum, PtrInt(AData));
end;

procedure TThreadPoolStressTests.MixedFaultProc(AData: Pointer);
var
  Val: PtrInt;
begin
  Val := PtrInt(AData);
  if (Val mod 5) = 0 then
    raise Exception.CreateFmt('Erro simulado na tarefa %d', [Val]);
  InterlockedIncrement64(FValidExecuted);
end;

procedure TThreadPoolStressTests.TestHighContentionThroughput;
const
  WORKERS = 4;
  SUBMITTERS = 8;
  TASKS_PER_SUB = 2500;
  TOTAL_TASKS: Int64 = SUBMITTERS * TASKS_PER_SUB;
var
  Pool: TThreadPool;
  Barrier: TStartBarrier;
  Watchdog: TDeadlockWatchdog;
  Subs: array[0..SUBMITTERS - 1] of TPoolSubmitterThread;
  I, TotalRejected: Integer;
  ExpectedSum: Int64;
begin
  FAccumulatedSum := 0;
  Pool := TThreadPool.Create(WORKERS, 256);
  FActivePool := Pool;
  Barrier := TStartBarrier.Create(SUBMITTERS);
  Watchdog := TDeadlockWatchdog.Create(10000, @OnPoolWatchdogTimeout);
  try
    Watchdog.Start;

    for I := 0 to SUBMITTERS - 1 do
      Subs[I] := TPoolSubmitterThread.Create(
        Pool, Barrier, @SumWorkProc,
        PtrInt(I * TASKS_PER_SUB + 1), TASKS_PER_SUB);
    for I := 0 to SUBMITTERS - 1 do
      Subs[I].Start;

    TotalRejected := 0;
    for I := 0 to SUBMITTERS - 1 do
    begin
      Subs[I].WaitFor;
      Inc(TotalRejected, Subs[I].Rejected);
      Subs[I].Free;
    end;

    AssertTrue('Pool deve drenar dentro do prazo', Pool.WaitIdle(8000));
    Watchdog.SignalCompleted;

    ExpectedSum := (TOTAL_TASKS * (TOTAL_TASKS + 1)) div 2;
    AssertFalse('Watchdog nao deve disparar', Watchdog.TimedOut);
    AssertEquals('Nenhuma tarefa rejeitada', 0, TotalRejected);
    AssertEquals('Tarefas concluidas', TOTAL_TASKS, Pool.CompletedTasks);
    AssertEquals('Zero falhas', Int64(0), Pool.FailedTasks);
    AssertEquals('Soma acumulada exata', ExpectedSum, FAccumulatedSum);
  finally
    FActivePool := nil;
    Watchdog.Free;
    Barrier.Free;
    Pool.Free;
  end;
end;

procedure TThreadPoolStressTests.TestExceptionIsolationUnderLoad;
const
  TOTAL_TASKS = 1000;
var
  Pool: TThreadPool;
  Watchdog: TDeadlockWatchdog;
  I: Integer;
begin
  FValidExecuted := 0;
  Pool := TThreadPool.Create(4, 128);
  FActivePool := Pool;
  Watchdog := TDeadlockWatchdog.Create(8000, @OnPoolWatchdogTimeout);
  try
    Watchdog.Start;

    for I := 1 to TOTAL_TASKS do
      AssertTrue('Submit deve aceitar tarefa',
        Pool.Submit(@MixedFaultProc, Pointer(PtrInt(I)), 5000));

    AssertTrue('WaitIdle deve concluir', Pool.WaitIdle(5000));
    Watchdog.SignalCompleted;

    AssertFalse('Watchdog nao deve disparar', Watchdog.TimedOut);
    AssertEquals('Excecoes isoladas (multiplos de 5)',
      Int64(200), Pool.FailedTasks);
    AssertEquals('Tarefas validas concluidas',
      Int64(800), Pool.CompletedTasks);
    AssertEquals('Contador de validas', Int64(800), FValidExecuted);
  finally
    FActivePool := nil;
    Watchdog.Free;
    Pool.Free;
  end;
end;

{ TThreadSafeCacheStressTests }

procedure TThreadSafeCacheStressTests.OnStallWatchdogTimeout(Sender: TObject);
begin
  if Assigned(FStallReleaseEvent) then
    FStallReleaseEvent.SetEvent;
end;

procedure TThreadSafeCacheStressTests.TestReadWriteHeavyContention;
const
  READERS = 6;
  WRITERS = 2;
  OPS_PER_THREAD = 6000;
var
  Cache: TThreadSafeCache;
  Barrier: TStartBarrier;
  Watchdog: TDeadlockWatchdog;
  Threads: array[0..READERS + WRITERS - 1] of TCacheStressThread;
  I: Integer;
  TotalCorrupt: LongInt;
begin
  Cache := TThreadSafeCache.Create;
  Barrier := TStartBarrier.Create(READERS + WRITERS);
  Watchdog := TDeadlockWatchdog.Create(10000);
  try
    { Semente inicial de chaves para maximizar acertos concorrentes }
    for I := 0 to 127 do
      Cache.Put('k-' + IntToStr(I), 'val-k-' + IntToStr(I) + '-0');

    Watchdog.Start;
    for I := 0 to READERS - 1 do
      Threads[I] := TCacheStressThread.Create(
        Cache, Barrier, False, I + 1, OPS_PER_THREAD);
    for I := 0 to WRITERS - 1 do
      Threads[READERS + I] := TCacheStressThread.Create(
        Cache, Barrier, True, READERS + I + 1, OPS_PER_THREAD);

    for I := 0 to High(Threads) do
      Threads[I].Start;

    TotalCorrupt := 0;
    for I := 0 to High(Threads) do
    begin
      Threads[I].WaitFor;
      Inc(TotalCorrupt, Threads[I].CorruptReads);
      Threads[I].Free;
    end;

    Watchdog.SignalCompleted;

    AssertFalse('Watchdog nao deve disparar', Watchdog.TimedOut);
    AssertEquals('Zero leituras corrompidas', 0, TotalCorrupt);
    AssertEquals('Total de leituras contabilizadas',
      Int64(READERS * OPS_PER_THREAD), Cache.Hits + Cache.Misses);
    AssertTrue('Deve registrar cache hits sob contencao', Cache.Hits > 0);
  finally
    Watchdog.Free;
    Barrier.Free;
    Cache.Free;
  end;
end;

procedure TThreadSafeCacheStressTests.TestWatchdogDetectsSimulatedStall;
var
  Watchdog: TDeadlockWatchdog;
  Stalled: TSimulatedStallThread;
  Timer: TContentionTimer;
  Elapsed: QWord;
begin
  FStallReleaseEvent := TEvent.Create(nil, True, False, '');
  Watchdog := TDeadlockWatchdog.Create(150, @OnStallWatchdogTimeout);
  Stalled := TSimulatedStallThread.Create(FStallReleaseEvent);
  try
    Timer.Start;
    Watchdog.Start;
    Stalled.Start;

    { A thread simulada so destrava quando o watchdog dispara }
    Stalled.WaitFor;
    Elapsed := Timer.ElapsedMs;

    AssertTrue('Watchdog deve acusar timeout na trava simulada',
      Watchdog.TimedOut);
    AssertTrue('Destravamento deve ocorrer apos ~150 ms e antes de 3000 ms',
      (Elapsed >= 100) and (Elapsed < 3000));
  finally
    Stalled.Free;
    Watchdog.Free;
    FreeAndNil(FStallReleaseEvent);
  end;
end;

initialization
  RegisterTest('Concorrencia', TBoundedQueueStressTests);
  RegisterTest('Concorrencia', TThreadPoolStressTests);
  RegisterTest('Concorrencia', TThreadSafeCacheStressTests);

end.
