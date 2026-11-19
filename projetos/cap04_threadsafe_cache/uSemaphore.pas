unit uSemaphore;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, SyncObjs;

type
  { Semaforo contador portatil para FPC 3.2.2+ (Windows, Linux, macOS).
    SyncObjs no FPC 3.2.2 nao fornece TSemaphore; esta implementacao usa
    TCriticalSection + TEvent (ManualReset=True), eliminando lost wakeups. }
  TCountingSemaphore = class
  private
    FLock: TCriticalSection;
    FEvent: TEvent;
    FCount: Integer;
    FMaxCount: Integer;
    FCanceled: Boolean;
  public
    constructor Create(AInitialCount, AMaxCount: Integer);
    destructor Destroy; override;

    function Acquire(ATimeoutMs: Cardinal = INFINITE): TWaitResult;
    procedure Release(AReleaseCount: Integer = 1);
    procedure CancelWaiters;
    procedure ResetCancel;
    function CurrentCount: Integer;

    property MaxCount: Integer read FMaxCount;
  end;

implementation

{ TCountingSemaphore }

constructor TCountingSemaphore.Create(AInitialCount, AMaxCount: Integer);
begin
  inherited Create;
  if AMaxCount <= 0 then
    raise ESyncObjectException.Create('MaxCount deve ser maior que zero.');
  if (AInitialCount < 0) or (AInitialCount > AMaxCount) then
    raise ESyncObjectException.Create(
      'InitialCount deve estar entre 0 e MaxCount.');

  FMaxCount := AMaxCount;
  FCount := AInitialCount;
  FCanceled := False;
  FLock := TCriticalSection.Create;
  { ManualReset = True: sinalizado enquanto FCount > 0 ou FCanceled }
  FEvent := TEvent.Create(nil, True, AInitialCount > 0, '');
end;

destructor TCountingSemaphore.Destroy;
begin
  CancelWaiters;
  FreeAndNil(FEvent);
  FreeAndNil(FLock);
  inherited Destroy;
end;

function TCountingSemaphore.Acquire(ATimeoutMs: Cardinal): TWaitResult;
var
  DeadlineMs, NowMs: QWord;
  WaitMs: Cardinal;
begin
  if (ATimeoutMs <> INFINITE) and (ATimeoutMs > 0) then
    DeadlineMs := GetTickCount64 + ATimeoutMs
  else
    DeadlineMs := 0;

  while True do
  begin
    FLock.Acquire;
    try
      if FCanceled then
        Exit(wrAbandoned);

      if FCount > 0 then
      begin
        Dec(FCount);
        if FCount = 0 then
          FEvent.ResetEvent;
        Exit(wrSignaled);
      end;

      { Sem permissoes disponiveis: garante evento nao sinalizado }
      FEvent.ResetEvent;
    finally
      FLock.Release;
    end;

    if ATimeoutMs = 0 then
      Exit(wrTimeout);

    if ATimeoutMs = INFINITE then
      WaitMs := INFINITE
    else
    begin
      NowMs := GetTickCount64;
      if NowMs >= DeadlineMs then
        Exit(wrTimeout);
      WaitMs := Cardinal(DeadlineMs - NowMs);
    end;

    Result := FEvent.WaitFor(WaitMs);
    if Result <> wrSignaled then
      Exit;
    { Acordou: volta ao laco para disputar FCount sob FLock }
  end;
end;

procedure TCountingSemaphore.Release(AReleaseCount: Integer);
begin
  if AReleaseCount <= 0 then
    raise ESyncObjectException.Create(
      'ReleaseCount deve ser maior que zero.');

  FLock.Acquire;
  try
    if FCount + AReleaseCount > FMaxCount then
      raise ESyncObjectException.CreateFmt(
        'Overflow no semaforo: %d + %d excede MaxCount (%d).',
        [FCount, AReleaseCount, FMaxCount]);

    Inc(FCount, AReleaseCount);
    FEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TCountingSemaphore.CancelWaiters;
begin
  FLock.Acquire;
  try
    FCanceled := True;
    FEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TCountingSemaphore.ResetCancel;
begin
  FLock.Acquire;
  try
    FCanceled := False;
    if FCount > 0 then
      FEvent.SetEvent
    else
      FEvent.ResetEvent;
  finally
    FLock.Release;
  end;
end;

function TCountingSemaphore.CurrentCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

end.
