unit uSyncPrimitives;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, SyncObjs;

type
  { Token cooperativo de cancelamento baseado em TEvent + flag atomica }
  TSyncCancellation = class
  private
    FCancelled: LongInt;
    FEvent: TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel;
    procedure Reset;
    function IsCancelled: Boolean; inline;
    function WaitForCancel(ATimeoutMs: Cardinal): Boolean;
  end;

  { Semaforo contador portavel para FPC 3.2.2 (TCriticalSection + TEvent) }
  TCountingSemaphore = class
  private
    FLock: TCriticalSection;
    FHasPermits: TEvent;
    FCount: Integer;
    FMaxCount: Integer;
  public
    constructor Create(AInitialCount, AMaxCount: Integer);
    destructor Destroy; override;
    function Acquire(ATimeoutMs: Cardinal;
      ACancel: TSyncCancellation = nil): Boolean;
    procedure Release;
    function AvailableCount: Integer;
  end;

  { Limitador simples de taxa (espacamento minimo entre requisicoes) }
  TLocalRateLimiter = class
  private
    FLock: TCriticalSection;
    FMinIntervalMs: QWord;
    FNextAllowedTick: QWord;
  public
    constructor Create(AMinIntervalMs: QWord);
    destructor Destroy; override;
    function WaitSlot(ACancel: TSyncCancellation): Boolean;
  end;

implementation

{ TSyncCancellation }

constructor TSyncCancellation.Create;
begin
  inherited Create;
  FCancelled := 0;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TSyncCancellation.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

procedure TSyncCancellation.Cancel;
begin
  if InterlockedExchange(FCancelled, 1) = 0 then
    FEvent.SetEvent;
end;

procedure TSyncCancellation.Reset;
begin
  InterlockedExchange(FCancelled, 0);
  FEvent.ResetEvent;
end;

function TSyncCancellation.IsCancelled: Boolean;
begin
  Result := InterlockedCompareExchange(FCancelled, 0, 0) <> 0;
end;

function TSyncCancellation.WaitForCancel(ATimeoutMs: Cardinal): Boolean;
begin
  if IsCancelled then
    Exit(True);
  Result := FEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

{ TCountingSemaphore }

constructor TCountingSemaphore.Create(AInitialCount, AMaxCount: Integer);
begin
  inherited Create;
  if AMaxCount <= 0 then
    raise EArgumentException.Create('AMaxCount deve ser positivo.');
  if (AInitialCount < 0) or (AInitialCount > AMaxCount) then
    raise EArgumentException.Create('AInitialCount fora do intervalo.');

  FCount := AInitialCount;
  FMaxCount := AMaxCount;
  FLock := TCriticalSection.Create;
  FHasPermits := TEvent.Create(nil, True, FCount > 0, '');
end;

destructor TCountingSemaphore.Destroy;
begin
  FHasPermits.Free;
  FLock.Free;
  inherited Destroy;
end;

function TCountingSemaphore.Acquire(ATimeoutMs: Cardinal;
  ACancel: TSyncCancellation): Boolean;
var
  StartTick, Elapsed, Remain, StepMs: QWord;
begin
  StartTick := GetTickCount64;
  while True do
  begin
    if Assigned(ACancel) and ACancel.IsCancelled then
      Exit(False);

    FLock.Acquire;
    try
      if FCount > 0 then
      begin
        Dec(FCount);
        if FCount = 0 then
          FHasPermits.ResetEvent;
        Exit(True);
      end;
    finally
      FLock.Release;
    end;

    if ATimeoutMs = 0 then
      Exit(False);

    if ATimeoutMs = INFINITE then
      StepMs := 50
    else
    begin
      Elapsed := GetTickCount64 - StartTick;
      if Elapsed >= ATimeoutMs then
        Exit(False);
      Remain := ATimeoutMs - Elapsed;
      if Remain > 50 then
        StepMs := 50
      else
        StepMs := Remain;
    end;

    FHasPermits.WaitFor(Cardinal(StepMs));
  end;
end;

procedure TCountingSemaphore.Release;
begin
  FLock.Acquire;
  try
    if FCount >= FMaxCount then
      raise ESyncObjectException.Create('Semaforo excedeu FMaxCount.');
    Inc(FCount);
    FHasPermits.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TCountingSemaphore.AvailableCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

{ TLocalRateLimiter }

constructor TLocalRateLimiter.Create(AMinIntervalMs: QWord);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMinIntervalMs := AMinIntervalMs;
  FNextAllowedTick := 0;
end;

destructor TLocalRateLimiter.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TLocalRateLimiter.WaitSlot(ACancel: TSyncCancellation): Boolean;
var
  NowTick, WaitMs: QWord;
begin
  if FMinIntervalMs = 0 then
    Exit(not (Assigned(ACancel) and ACancel.IsCancelled));

  FLock.Acquire;
  try
    NowTick := GetTickCount64;
    if NowTick >= FNextAllowedTick then
    begin
      FNextAllowedTick := NowTick + FMinIntervalMs;
      WaitMs := 0;
    end
    else
    begin
      WaitMs := FNextAllowedTick - NowTick;
      FNextAllowedTick := FNextAllowedTick + FMinIntervalMs;
    end;
  finally
    FLock.Release;
  end;

  if WaitMs = 0 then
    Exit(not (Assigned(ACancel) and ACancel.IsCancelled));

  if Assigned(ACancel) then
    Result := not ACancel.WaitForCancel(Cardinal(WaitMs))
  else
  begin
    Sleep(Cardinal(WaitMs));
    Result := True;
  end;
end;

end.
