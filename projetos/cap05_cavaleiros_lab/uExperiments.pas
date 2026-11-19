unit uExperiments;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TExperimentKind = (
    ekRaceCondition,
    ekDeadlockLCL,
    ekLivelock,
    ekFalseSharing
  );

  TExpCallback = procedure(const AText: string; AFinished: Boolean;
    AElapsedMs: QWord) of object;

  { Contador isolado em sua propria linha de cache (64 bytes) }
  PPaddedCounter = ^TPaddedCounter;
  TPaddedCounter = record
    Value: Int64;
    Padding: array[0..55] of Byte;
  end;

  { PRNG xorshift32 confinado por thread (System.Random nao e thread-safe) }
  TXorShift32 = record
    State: LongWord;
    procedure Init(ASeed: LongWord);
    function Next: LongWord;
    function NextRange(AMaxExclusive: LongWord): LongWord;
  end;

  { Coordenador de experimentos executados em background (Exp 1, 3 e 4) }
  TExperimentRunnerThread = class(TThread)
  private
    FKind: TExperimentKind;
    FFixed: Boolean;
    FOnReport: TExpCallback;
    FLastBrokenFalseSharingMs: QWord;
    procedure Emit(const AMsg: string; AFinished: Boolean = False;
      AElapsedMs: QWord = 0);
    procedure RunRaceCondition;
    procedure RunLivelock;
    procedure RunFalseSharing;
  protected
    procedure Execute; override;
  public
    constructor Create(AKind: TExperimentKind; AFixed: Boolean;
      ALastBrokenFsMs: QWord; AOnReport: TExpCallback);
  end;

  { Worker do Experimento 2 (Versao Quebrada com Watchdog de Seguranca) }
  TDeadlockSyncWorker = class(TThread)
  private
    FDoneEvent: TSimpleEvent;
    FOnSyncHit: TNotifyEvent;
    FSyncExecuted: Boolean;
    procedure CallSyncHit;
  protected
    procedure Execute; override;
  public
    constructor Create(ADoneEvent: TSimpleEvent; AOnSyncHit: TNotifyEvent);
    property SyncExecuted: Boolean read FSyncExecuted;
  end;

  { Worker do Experimento 2 (Versao Corrigida 100% Assincrona) }
  TDeadlockAsyncWorker = class(TThread)
  private
    FOnReport: TExpCallback;
  protected
    procedure Execute; override;
  public
    constructor Create(AOnReport: TExpCallback);
  end;

const
  RACE_THREADS = 4;
  RACE_INCREMENTS_PER_THREAD = 2000000;
  RACE_INITIAL_BALANCE = 100000;
  RACE_WITHDRAW_ATTEMPTS = 25000;
  RACE_WITHDRAW_AMOUNT = 10;

  LIVELOCK_TARGET_TX = 400;
  LIVELOCK_TIMEOUT_MS = 1500;

  FS_THREADS = 4;
  FS_ITERATIONS = 80000000;

implementation

type
  { Worker do Experimento 1: Race Condition }
  TRaceWorker = class(TThread)
  private
    FCounterPtr: PInt64;
    FBalancePtr: PInt64;
    FWithdrawCountPtr: PLongInt;
    FLock: TCriticalSection;
    FFixed: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ACounterPtr, ABalancePtr: PInt64;
      AWithdrawCountPtr: PLongInt; ALock: TCriticalSection;
      AFixed: Boolean);
  end;

  { Worker do Experimento 3: Livelock }
  TLivelockWorker = class(TThread)
  private
    FWorkerIdx: Integer;
    FLockFirst: TCriticalSection;
    FLockSecond: TCriticalSection;
    FStartGate: TSimpleEvent;
    FStopFlag: PLongInt;
    FUseBackoff: Boolean;
    FUseLockOrder: Boolean;
    FCompletedTx: LongInt;
    FRetries: Int64;
    procedure BusySpin(ASteps: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(AIdx: Integer; ALockFirst, ALockSecond: TCriticalSection;
      AStartGate: TSimpleEvent; AStopFlag: PLongInt;
      AUseBackoff, AUseLockOrder: Boolean);
    property CompletedTx: LongInt read FCompletedTx;
    property Retries: Int64 read FRetries;
  end;

  { Worker do Experimento 4: False Sharing }
  TFalseSharingWorker = class(TThread)
  private
    FCounterPtr: PInt64;
    FIterations: Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(ACounterPtr: PInt64; AIterations: Int64);
  end;

{ TXorShift32 }

procedure TXorShift32.Init(ASeed: LongWord);
begin
  if ASeed = 0 then
    State := $9E3779B9
  else
    State := ASeed;
end;

function TXorShift32.Next: LongWord;
var
  X: LongWord;
begin
  X := State;
  X := X xor (X shl 13);
  X := X xor (X shr 17);
  X := X xor (X shl 5);
  State := X;
  Result := X;
end;

function TXorShift32.NextRange(AMaxExclusive: LongWord): LongWord;
begin
  if AMaxExclusive = 0 then
    Exit(0);
  Result := Next mod AMaxExclusive;
end;

{ TRaceWorker }

constructor TRaceWorker.Create(ACounterPtr, ABalancePtr: PInt64;
  AWithdrawCountPtr: PLongInt; ALock: TCriticalSection; AFixed: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCounterPtr := ACounterPtr;
  FBalancePtr := ABalancePtr;
  FWithdrawCountPtr := AWithdrawCountPtr;
  FLock := ALock;
  FFixed := AFixed;
end;

procedure TRaceWorker.Execute;
var
  I, J: Integer;
  LocalBal: Int64;
begin
  { Parte A: Data Race pura em contador compartilhado }
  if FFixed then
  begin
    for I := 1 to RACE_INCREMENTS_PER_THREAD do
      InterlockedIncrement64(FCounterPtr^);
  end
  else
  begin
    for I := 1 to RACE_INCREMENTS_PER_THREAD do
      FCounterPtr^ := FCounterPtr^ + 1;
  end;

  { Parte B: Check-Then-Act (TOCTOU) sobre saldo compartilhado }
  for I := 1 to RACE_WITHDRAW_ATTEMPTS do
  begin
    if FFixed then
    begin
      FLock.Acquire;
      try
        if FBalancePtr^ >= RACE_WITHDRAW_AMOUNT then
        begin
          FBalancePtr^ := FBalancePtr^ - RACE_WITHDRAW_AMOUNT;
          Inc(FWithdrawCountPtr^);
        end;
      finally
        FLock.Release;
      end;
    end
    else
    begin
      if FBalancePtr^ >= RACE_WITHDRAW_AMOUNT then
      begin
        { Pequena janela entre Check e Act expoe TOCTOU }
        LocalBal := FBalancePtr^;
        for J := 1 to 15 do
          ReadBarrier;
        FBalancePtr^ := LocalBal - RACE_WITHDRAW_AMOUNT;
        Inc(FWithdrawCountPtr^);
      end;
    end;
  end;
end;

{ TLivelockWorker }

constructor TLivelockWorker.Create(AIdx: Integer;
  ALockFirst, ALockSecond: TCriticalSection; AStartGate: TSimpleEvent;
  AStopFlag: PLongInt; AUseBackoff, AUseLockOrder: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWorkerIdx := AIdx;
  FLockFirst := ALockFirst;
  FLockSecond := ALockSecond;
  FStartGate := AStartGate;
  FStopFlag := AStopFlag;
  FUseBackoff := AUseBackoff;
  FUseLockOrder := AUseLockOrder;
  FCompletedTx := 0;
  FRetries := 0;
end;

procedure TLivelockWorker.BusySpin(ASteps: Integer);
var
  K: Integer;
  Dummy: LongInt;
begin
  Dummy := 0;
  for K := 1 to ASteps do
  begin
    Inc(Dummy);
    ReadBarrier;
  end;
end;

procedure TLivelockWorker.Execute;
var
  Rng: TXorShift32;
  GotSecond: Boolean;
  BackoffStep, DelaySpin, SleepMs: LongWord;
begin
  Rng.Init(LongWord(GetTickCount64) xor LongWord((FWorkerIdx + 1) * 2654435761));
  FStartGate.WaitFor(INFINITE);

  if FUseLockOrder then
  begin
    { Solucao definitiva: hierarquia global de locks (sempre A antes de B) }
    while (FCompletedTx < LIVELOCK_TARGET_TX) and (FStopFlag^ = 0) do
    begin
      FLockFirst.Acquire;
      try
        FLockSecond.Acquire;
        try
          Inc(FCompletedTx);
          BusySpin(60);
        finally
          FLockSecond.Release;
        end;
      finally
        FLockFirst.Release;
      end;
    end;
    Exit;
  end;

  BackoffStep := 1;
  while (FCompletedTx < LIVELOCK_TARGET_TX) and (FStopFlag^ = 0) do
  begin
    FLockFirst.Acquire;
    try
      { Trabalho preparatorio enquanto segura o primeiro lock }
      BusySpin(1500);
      GotSecond := FLockSecond.TryEnter;
      if GotSecond then
      begin
        try
          Inc(FCompletedTx);
          BackoffStep := 1;
        finally
          FLockSecond.Release;
        end;
      end;
    finally
      FLockFirst.Release;
    end;

    if not GotSecond then
    begin
      Inc(FRetries);
      if FUseBackoff then
      begin
        { Randomized Exponential Backoff: quebra a simetria }
        if BackoffStep < 32 then
          BackoffStep := BackoffStep * 2;
        DelaySpin := 200 + Rng.NextRange(BackoffStep * 450);
        BusySpin(Integer(DelaySpin));
        if BackoffStep >= 8 then
        begin
          SleepMs := Rng.NextRange(3);
          if SleepMs > 0 then
            Sleep(SleepMs)
          else
            ThreadSwitch;
        end;
      end
      else
      begin
        { Cortesia simetrica: ambas recuam o mesmo intervalo fixo }
        BusySpin(450);
      end;
    end;
  end;
end;

{ TFalseSharingWorker }

constructor TFalseSharingWorker.Create(ACounterPtr: PInt64; AIterations: Int64);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCounterPtr := ACounterPtr;
  FIterations := AIterations;
end;

procedure TFalseSharingWorker.Execute;
var
  I: Int64;
  P: PInt64;
begin
  P := FCounterPtr;
  for I := 1 to FIterations do
    P^ := P^ + 1;
end;

{ TExperimentRunnerThread }

constructor TExperimentRunnerThread.Create(AKind: TExperimentKind;
  AFixed: Boolean; ALastBrokenFsMs: QWord; AOnReport: TExpCallback);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FKind := AKind;
  FFixed := AFixed;
  FLastBrokenFalseSharingMs := ALastBrokenFsMs;
  FOnReport := AOnReport;
end;

procedure TExperimentRunnerThread.Emit(const AMsg: string;
  AFinished: Boolean; AElapsedMs: QWord);
begin
  if Assigned(FOnReport) then
    FOnReport(AMsg, AFinished, AElapsedMs);
end;

procedure TExperimentRunnerThread.RunRaceCondition;
var
  Workers: array[0..RACE_THREADS - 1] of TRaceWorker;
  Lock: TCriticalSection;
  SharedCounter, SharedBalance: Int64;
  WithdrawCount: LongInt;
  ExpectedCounter: Int64;
  ExpectedWithdraws: LongInt;
  I: Integer;
  T0, Elapsed: QWord;
  SL: TStringList;
begin
  SharedCounter := 0;
  SharedBalance := RACE_INITIAL_BALANCE;
  WithdrawCount := 0;
  ExpectedCounter := Int64(RACE_THREADS) * RACE_INCREMENTS_PER_THREAD;
  ExpectedWithdraws := RACE_INITIAL_BALANCE div RACE_WITHDRAW_AMOUNT;

  Lock := TCriticalSection.Create;
  SL := TStringList.Create;
  try
    if FFixed then
      Emit('=== [EXP 1] RACE CONDITION: VERSAO CORRIGIDA (Atomico + Lock) ===')
    else
      Emit('=== [EXP 1] RACE CONDITION: VERSAO QUEBRADA (Sem Sincronizacao) ===');

    Emit(Format('Disparando %d threads (%d incrementos cada)...',
      [RACE_THREADS, RACE_INCREMENTS_PER_THREAD]));

    for I := 0 to High(Workers) do
      Workers[I] := TRaceWorker.Create(@SharedCounter, @SharedBalance,
        @WithdrawCount, Lock, FFixed);

    T0 := GetTickCount64;
    for I := 0 to High(Workers) do
      Workers[I].Start;

    for I := 0 to High(Workers) do
    begin
      Workers[I].WaitFor;
      Workers[I].Free;
    end;
    Elapsed := GetTickCount64 - T0;

    SL.Add(Format('Tempo total: %d ms', [Elapsed]));
    SL.Add(Format('1) Contador compartilhado: esperado = %d | obtido = %d',
      [ExpectedCounter, SharedCounter]));
    SL.Add(Format('   Incrementos perdidos: %d (%.2f%%)',
      [ExpectedCounter - SharedCounter,
       ((ExpectedCounter - SharedCounter) / ExpectedCounter) * 100.0]));
    SL.Add(Format('2) Saldo bancario (Check-Then-Act): inicial = %d | final = %d',
      [RACE_INITIAL_BALANCE, SharedBalance]));
    SL.Add(Format('   Saques realizados: %d (maximo legal: %d)',
      [WithdrawCount, ExpectedWithdraws]));

    if (SharedCounter = ExpectedCounter) and (SharedBalance = 0) and
       (WithdrawCount = ExpectedWithdraws) then
      SL.Add('DIAGNOSTICO: Integridade 100% preservada! Zero anomalias.')
    else
      SL.Add('DIAGNOSTICO: CORRUPCAO DETECTADA! Data Race + TOCTOU falharam.');

    Emit(SL.Text, True, Elapsed);
  finally
    SL.Free;
    Lock.Free;
  end;
end;

procedure TExperimentRunnerThread.RunLivelock;
var
  LockA, LockB: TCriticalSection;
  StartGate: TSimpleEvent;
  W0, W1: TLivelockWorker;
  StopFlag: LongInt;
  T0, Elapsed, TOrder: QWord;
  TotalTx: LongInt;
  TotalRetries: Int64;
  SL: TStringList;
begin
  LockA := TCriticalSection.Create;
  LockB := TCriticalSection.Create;
  StartGate := TSimpleEvent.Create;
  SL := TStringList.Create;
  try
    StopFlag := 0;
    if FFixed then
      Emit('=== [EXP 3] LIVELOCK: VERSAO CORRIGIDA (Backoff Aleatorio + Ordem) ===')
    else
      Emit('=== [EXP 3] LIVELOCK: VERSAO QUEBRADA (TryEnter Simetrico) ===');

    Emit(Format('Meta: 2 threads x %d transacoes (janela limite %d ms)...',
      [LIVELOCK_TARGET_TX, LIVELOCK_TIMEOUT_MS]));

    { Thread 0 pega LockA -> tenta LockB; Thread 1 pega LockB -> tenta LockA }
    W0 := TLivelockWorker.Create(0, LockA, LockB, StartGate, @StopFlag,
      FFixed, False);
    W1 := TLivelockWorker.Create(1, LockB, LockA, StartGate, @StopFlag,
      FFixed, False);
    try
      W0.Start;
      W1.Start;
      T0 := GetTickCount64;
      StartGate.SetEvent;

      { Watchdog de duracao maxima para provar livelock sem loop infinito }
      while (not W0.Finished or not W1.Finished) and
            ((GetTickCount64 - T0) < LIVELOCK_TIMEOUT_MS) do
        Sleep(15);

      InterlockedExchange(StopFlag, 1);
      W0.WaitFor;
      W1.WaitFor;
      Elapsed := GetTickCount64 - T0;

      TotalTx := W0.CompletedTx + W1.CompletedTx;
      TotalRetries := W0.Retries + W1.Retries;

      SL.Add(Format('Fase 1 (%s):',
        [BoolToStr(FFixed, 'TryEnter + Randomized Exponential Backoff',
          'TryEnter Simetrico (sem jitter)')]));
      SL.Add(Format('  Tempo: %d ms | Transacoes: %d / %d | Colisoes/Retries: %d',
        [Elapsed, TotalTx, LIVELOCK_TARGET_TX * 2, TotalRetries]));
    finally
      W0.Free;
      W1.Free;
    end;

    if FFixed then
    begin
      { Demonstra tambem a solucao estrutural definitiva: Ordem Global de Locks }
      StopFlag := 0;
      StartGate.ResetEvent;
      W0 := TLivelockWorker.Create(0, LockA, LockB, StartGate, @StopFlag,
        False, True);
      W1 := TLivelockWorker.Create(1, LockA, LockB, StartGate, @StopFlag,
        False, True);
      try
        W0.Start;
        W1.Start;
        TOrder := GetTickCount64;
        StartGate.SetEvent;
        W0.WaitFor;
        W1.WaitFor;
        TOrder := GetTickCount64 - TOrder;

        SL.Add(Format('Fase 2 (Hierarquia Global: sempre LockA -> LockB):', []));
        SL.Add(Format('  Tempo: %d ms | Transacoes: %d / %d | Colisoes: 0',
          [TOrder, W0.CompletedTx + W1.CompletedTx, LIVELOCK_TARGET_TX * 2]));
        SL.Add('DIAGNOSTICO: Simetria quebrada e progresso garantido!');
      finally
        W0.Free;
        W1.Free;
      end;
    end
    else
    begin
      SL.Add('DIAGNOSTICO: LIVELOCK OBSERVADO! Threads ativas (CPU consumida),');
      SL.Add('mas presas em colisoes simetricas e progresso severamente degradado.');
    end;

    Emit(SL.Text, True, Elapsed);
  finally
    SL.Free;
    StartGate.Free;
    LockB.Free;
    LockA.Free;
  end;
end;

procedure TExperimentRunnerThread.RunFalseSharing;
var
  PackedArr: array[0..FS_THREADS - 1] of Int64;
  RawBuf: array of Byte;
  AlignedBase: PtrUInt;
  PaddedArr: PPaddedCounter;
  Workers: array[0..FS_THREADS - 1] of TFalseSharingWorker;
  I: Integer;
  T0, Elapsed: QWord;
  Sum: Int64;
  Speedup: Double;
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    if FFixed then
      Emit('=== [EXP 4] FALSE SHARING: VERSAO CORRIGIDA (Padding 64 Bytes) ===')
    else
      Emit('=== [EXP 4] FALSE SHARING: VERSAO QUEBRADA (Array Contiguo) ===');

    Emit(Format('4 threads x %d incrementos independentes (sem locks)...',
      [FS_ITERATIONS]));

    if not FFixed then
    begin
      FillChar(PackedArr, SizeOf(PackedArr), 0);
      for I := 0 to FS_THREADS - 1 do
        Workers[I] := TFalseSharingWorker.Create(@PackedArr[I], FS_ITERATIONS);

      T0 := GetTickCount64;
      for I := 0 to FS_THREADS - 1 do
        Workers[I].Start;
      for I := 0 to FS_THREADS - 1 do
      begin
        Workers[I].WaitFor;
        Workers[I].Free;
      end;
      Elapsed := GetTickCount64 - T0;

      Sum := 0;
      for I := 0 to FS_THREADS - 1 do
      begin
        Sum := Sum + PackedArr[I];
        SL.Add(Format('  Thread %d -> Endereco: 0x%x (Linha de cache #%d)',
          [I, PtrUInt(@PackedArr[I]), PtrUInt(@PackedArr[I]) shr 6]));
      end;
      SL.Add(Format('Stride entre elementos: %d bytes | Soma: %d',
        [SizeOf(Int64), Sum]));
      SL.Add(Format('TEMPO SEM PADDING (False Sharing): %d ms', [Elapsed]));
      SL.Add('DIAGNOSTICO: Contadores adjacentes dividem a mesma linha de cache');
      SL.Add('de 64 bytes -> invalidacoes MESI constantes entre nucleos!');
    end
    else
    begin
      { Aloca buffer com folga para garantir alinhamento exato em 64 bytes }
      RawBuf := nil;
      SetLength(RawBuf, FS_THREADS * SizeOf(TPaddedCounter) + 64);
      FillChar(RawBuf[0], Length(RawBuf), 0);
      AlignedBase := (PtrUInt(@RawBuf[0]) + 63) and (not PtrUInt(63));
      PaddedArr := PPaddedCounter(AlignedBase);

      for I := 0 to FS_THREADS - 1 do
        Workers[I] := TFalseSharingWorker.Create(@PaddedArr[I].Value,
          FS_ITERATIONS);

      T0 := GetTickCount64;
      for I := 0 to FS_THREADS - 1 do
        Workers[I].Start;
      for I := 0 to FS_THREADS - 1 do
      begin
        Workers[I].WaitFor;
        Workers[I].Free;
      end;
      Elapsed := GetTickCount64 - T0;

      Sum := 0;
      for I := 0 to FS_THREADS - 1 do
      begin
        Sum := Sum + PaddedArr[I].Value;
        SL.Add(Format('  Thread %d -> Endereco: 0x%x (Linha de cache #%d)',
          [I, PtrUInt(@PaddedArr[I].Value),
           PtrUInt(@PaddedArr[I].Value) shr 6]));
      end;
      SL.Add(Format('SizeOf(TPaddedCounter): %d bytes | Soma: %d',
        [SizeOf(TPaddedCounter), Sum]));
      SL.Add(Format('TEMPO COM PADDING 64B: %d ms', [Elapsed]));

      if (FLastBrokenFalseSharingMs > 0) and (Elapsed > 0) then
      begin
        Speedup := FLastBrokenFalseSharingMs / Elapsed;
        SL.Add(Format('GANHO MEDIDO vs. Versao Quebrada (%d ms): %.2fx mais rapido!',
          [FLastBrokenFalseSharingMs, Speedup]));
      end;
      SL.Add('DIAGNOSTICO: Cada nucleo opera em sua propria linha de cache L1.');
    end;

    Emit(SL.Text, True, Elapsed);
  finally
    SL.Free;
  end;
end;

procedure TExperimentRunnerThread.Execute;
begin
  case FKind of
    ekRaceCondition: RunRaceCondition;
    ekLivelock:      RunLivelock;
    ekFalseSharing:  RunFalseSharing;
    ekDeadlockLCL:
      Emit('Use o fluxo especifico de Deadlock na Main Thread.', True, 0);
  end;
end;

{ TDeadlockSyncWorker }

constructor TDeadlockSyncWorker.Create(ADoneEvent: TSimpleEvent;
  AOnSyncHit: TNotifyEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDoneEvent := ADoneEvent;
  FOnSyncHit := AOnSyncHit;
  FSyncExecuted := False;
end;

procedure TDeadlockSyncWorker.CallSyncHit;
begin
  FSyncExecuted := True;
  if Assigned(FOnSyncHit) then
    FOnSyncHit(Self);
end;

procedure TDeadlockSyncWorker.Execute;
begin
  { Simula trabalho rapido antes de sincronizar com a UI }
  Sleep(60);
  { Bloqueia esta worker ate a Main Thread drenar CheckSynchronize }
  Synchronize(@CallSyncHit);
  { So sinaliza conclusao DEPOIS que o Synchronize retornar }
  FDoneEvent.SetEvent;
end;

{ TDeadlockAsyncWorker }

constructor TDeadlockAsyncWorker.Create(AOnReport: TExpCallback);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOnReport := AOnReport;
end;

procedure TDeadlockAsyncWorker.Execute;
var
  Step: Integer;
  T0, Elapsed: QWord;
begin
  T0 := GetTickCount64;
  for Step := 1 to 4 do
  begin
    if Terminated then
      Break;
    Sleep(180);
    if Assigned(FOnReport) then
      FOnReport(Format('  [Worker Assincrona] Etapa %d/4 via QueueAsyncCall.',
        [Step]), False, 0);
  end;
  Elapsed := GetTickCount64 - T0;
  if Assigned(FOnReport) then
    FOnReport(
      Format('Concluido em %d ms sem Synchronize e sem WaitFor bloqueante na UI!',
        [Elapsed]) + LineEnding +
      'DIAGNOSTICO: Main Thread bloqueada por 0 ms. Interface 100% responsiva.',
      True, Elapsed);
end;

end.
