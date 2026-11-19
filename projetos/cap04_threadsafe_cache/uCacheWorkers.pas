unit uCacheWorkers;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  uSemaphore, uThreadSafeCache;

type
  TStressMetrics = record
    ActiveOriginSlots: LongInt;
    PeakOriginSlots: LongInt;
    MaxOriginSlots: Integer;
    OriginAcquires: Int64;
    OriginTimeouts: Int64;
    TotalReadOps: Int64;
    TotalWriteOps: Int64;
  end;

  TCacheStressController = class;

  { Thread leitora: consulta o cache continuamente e busca na origem
    (controlada por TCountingSemaphore) quando ocorre cache miss }
  TCacheReaderThread = class(TThread)
  private
    FController: TCacheStressController;
    FWorkerIndex: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AController: TCacheStressController;
      AWorkerIndex: Integer);
  end;

  { Thread escritora: renova chaves aleatorias com TTL curto }
  TCacheWriterThread = class(TThread)
  private
    FController: TCacheStressController;
    FWorkerIndex: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AController: TCacheStressController;
      AWorkerIndex: Integer);
  end;

  { Controlador de carga concorrente com semaforo e metricas atomicas }
  TCacheStressController = class
  private
    FCache: TThreadSafeTTLCache;
    FSemaphore: TCountingSemaphore;
    FStopEvent: TSimpleEvent;
    FWorkers: TList;
    FKeySpace: Integer;
    FDefaultTTLMs: QWord;

    FActiveOriginSlots: LongInt;
    FPeakOriginSlots: LongInt;
    FOriginAcquires: Int64;
    FOriginTimeouts: Int64;
    FTotalReadOps: Int64;
    FTotalWriteOps: Int64;

    procedure UpdatePeakLockFree(ACurrent: LongInt);
  public
    constructor Create(ACache: TThreadSafeTTLCache;
      AMaxOriginPermits, AKeySpace: Integer; ADefaultTTLMs: QWord);
    destructor Destroy; override;

    procedure StartWorkers(AReaderCount, AWriterCount: Integer);
    procedure StopWorkers;
    function FetchFromOriginAndCache(const AKey: string;
      AWorkerId: Integer): Boolean;
    function GetMetrics: TStressMetrics;
    function IsRunning: Boolean;

    property Cache: TThreadSafeTTLCache read FCache;
    property StopEvent: TSimpleEvent read FStopEvent;
    property KeySpace: Integer read FKeySpace;
    property DefaultTTLMs: QWord read FDefaultTTLMs;
  end;

implementation

{ TCacheReaderThread }

constructor TCacheReaderThread.Create(AController: TCacheStressController;
  AWorkerIndex: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FController := AController;
  FWorkerIndex := AWorkerIndex;
end;

procedure TCacheReaderThread.Execute;
var
  Seed: Cardinal;
  KeyIdx: Integer;
  Key, Val: string;
begin
  { PRNG local por thread evita contencao no estado global de Random }
  Seed := Cardinal(GetTickCount64) xor Cardinal(FWorkerIndex * 2654435761);

  while not Terminated do
  begin
    Seed := Seed * 1664525 + 1013904223;
    KeyIdx := Integer((Seed shr 16) mod Cardinal(FController.KeySpace));
    Key := 'item:' + IntToStr(KeyIdx);

    InterlockedIncrement64(FController.FTotalReadOps);
    if not FController.Cache.TryGet(Key, Val) then
      FController.FetchFromOriginAndCache(Key, FWorkerIndex);

    { Breve pausa orientavel a evento para nao saturar 100% da UI }
    if FController.StopEvent.WaitFor(1) = wrSignaled then
      Break;
  end;
end;

{ TCacheWriterThread }

constructor TCacheWriterThread.Create(AController: TCacheStressController;
  AWorkerIndex: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FController := AController;
  FWorkerIndex := AWorkerIndex;
end;

procedure TCacheWriterThread.Execute;
var
  Seed: Cardinal;
  KeyIdx: Integer;
  Key, Val: string;
  TTL: QWord;
begin
  Seed := Cardinal(GetTickCount64) xor
    Cardinal((FWorkerIndex + 97) * 2246822519);

  while not Terminated do
  begin
    Seed := Seed * 1664525 + 1013904223;
    KeyIdx := Integer((Seed shr 16) mod Cardinal(FController.KeySpace));
    Key := 'item:' + IntToStr(KeyIdx);
    TTL := FController.DefaultTTLMs + ((Seed shr 8) mod 1500);
    Val := Format('writer-%d@%d', [FWorkerIndex, GetTickCount64]);

    FController.Cache.Put(Key, Val, TTL);
    InterlockedIncrement64(FController.FTotalWriteOps);

    if FController.StopEvent.WaitFor(15) = wrSignaled then
      Break;
  end;
end;

{ TCacheStressController }

constructor TCacheStressController.Create(ACache: TThreadSafeTTLCache;
  AMaxOriginPermits, AKeySpace: Integer; ADefaultTTLMs: QWord);
begin
  inherited Create;
  FCache := ACache;
  FSemaphore := TCountingSemaphore.Create(AMaxOriginPermits,
    AMaxOriginPermits);
  FStopEvent := TSimpleEvent.Create;
  FWorkers := TList.Create;
  FKeySpace := AKeySpace;
  FDefaultTTLMs := ADefaultTTLMs;
  FActiveOriginSlots := 0;
  FPeakOriginSlots := 0;
  FOriginAcquires := 0;
  FOriginTimeouts := 0;
  FTotalReadOps := 0;
  FTotalWriteOps := 0;
end;

destructor TCacheStressController.Destroy;
begin
  StopWorkers;
  FreeAndNil(FWorkers);
  FreeAndNil(FStopEvent);
  FreeAndNil(FSemaphore);
  inherited Destroy;
end;

procedure TCacheStressController.UpdatePeakLockFree(ACurrent: LongInt);
var
  Observed: LongInt;
begin
  { Maximo atomico lock-free via laco CAS (Compare-And-Swap) }
  repeat
    Observed := InterlockedExchangeAdd(FPeakOriginSlots, 0);
    if ACurrent <= Observed then
      Exit;
  until InterlockedCompareExchange(
    FPeakOriginSlots, ACurrent, Observed) = Observed;
end;

function TCacheStressController.FetchFromOriginAndCache(const AKey: string;
  AWorkerId: Integer): Boolean;
var
  WaitRes: TWaitResult;
  ActiveNow: LongInt;
begin
  Result := False;
  WaitRes := FSemaphore.Acquire(150);
  if WaitRes = wrTimeout then
  begin
    InterlockedIncrement64(FOriginTimeouts);
    Exit;
  end;
  if WaitRes <> wrSignaled then
    Exit;

  try
    InterlockedIncrement64(FOriginAcquires);
    ActiveNow := InterlockedIncrement(FActiveOriginSlots);
    UpdatePeakLockFree(ActiveNow);
    try
      { Simula latencia de I/O na origem (banco de dados / API) }
      if FStopEvent.WaitFor(25) = wrSignaled then
        Exit;

      FCache.Put(AKey,
        Format('origin-w%d@%d', [AWorkerId, GetTickCount64]),
        FDefaultTTLMs);
      Result := True;
    finally
      InterlockedDecrement(FActiveOriginSlots);
    end;
  finally
    FSemaphore.Release;
  end;
end;

procedure TCacheStressController.StartWorkers(AReaderCount,
  AWriterCount: Integer);
var
  I: Integer;
  T: TThread;
begin
  StopWorkers;

  FStopEvent.ResetEvent;
  FSemaphore.ResetCancel;
  InterlockedExchange(FActiveOriginSlots, 0);
  InterlockedExchange(FPeakOriginSlots, 0);
  InterlockedExchange64(FOriginAcquires, 0);
  InterlockedExchange64(FOriginTimeouts, 0);
  InterlockedExchange64(FTotalReadOps, 0);
  InterlockedExchange64(FTotalWriteOps, 0);

  for I := 1 to AReaderCount do
  begin
    T := TCacheReaderThread.Create(Self, I);
    FWorkers.Add(T);
    T.Start;
  end;

  for I := 1 to AWriterCount do
  begin
    T := TCacheWriterThread.Create(Self, I);
    FWorkers.Add(T);
    T.Start;
  end;
end;

procedure TCacheStressController.StopWorkers;
var
  I: Integer;
  T: TThread;
begin
  if FWorkers.Count = 0 then
    Exit;

  { 1. Sinaliza parada e libera qualquer thread bloqueada no semaforo }
  FStopEvent.SetEvent;
  FSemaphore.CancelWaiters;

  for I := 0 to FWorkers.Count - 1 do
    TThread(FWorkers[I]).Terminate;

  { 2. Aguarda encerramento gracioso e libera todas as instancias }
  for I := 0 to FWorkers.Count - 1 do
  begin
    T := TThread(FWorkers[I]);
    T.WaitFor;
    T.Free;
  end;
  FWorkers.Clear;
end;

function TCacheStressController.GetMetrics: TStressMetrics;
begin
  Result.ActiveOriginSlots := InterlockedExchangeAdd(FActiveOriginSlots, 0);
  Result.PeakOriginSlots := InterlockedExchangeAdd(FPeakOriginSlots, 0);
  Result.MaxOriginSlots := FSemaphore.MaxCount;
  Result.OriginAcquires := InterlockedExchangeAdd64(FOriginAcquires, 0);
  Result.OriginTimeouts := InterlockedExchangeAdd64(FOriginTimeouts, 0);
  Result.TotalReadOps := InterlockedExchangeAdd64(FTotalReadOps, 0);
  Result.TotalWriteOps := InterlockedExchangeAdd64(FTotalWriteOps, 0);
end;

function TCacheStressController.IsRunning: Boolean;
begin
  Result := FWorkers.Count > 0;
end;

end.
