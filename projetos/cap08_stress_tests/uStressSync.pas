unit uStressSync;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  { Barreira de largada simultanea: solta N threads no mesmo instante }
  TStartBarrier = class
  private
    FRemaining: LongInt;
    FGoEvent: TEvent;
  public
    constructor Create(AParticipantCount: Integer);
    destructor Destroy; override;
    function ArriveAndWait(ATimeoutMs: Cardinal = 5000): Boolean;
  end;

  { Watchdog anti-deadlock para testes de estresse e pipelines de CI }
  TDeadlockWatchdog = class(TThread)
  private
    FTimeoutMs: Cardinal;
    FDoneEvent: TEvent;
    FTimedOut: LongInt;
    FOnTimeout: TNotifyEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(ATimeoutMs: Cardinal; AOnTimeout: TNotifyEvent = nil);
    destructor Destroy; override;
    procedure SignalCompleted;
    function TimedOut: Boolean; inline;
  end;

  { Cronometro leve baseado em GetTickCount64 para medir contencao }
  TContentionTimer = record
    StartTick: QWord;
    procedure Start;
    function ElapsedMs: QWord;
  end;

implementation

{ TStartBarrier }

constructor TStartBarrier.Create(AParticipantCount: Integer);
begin
  inherited Create;
  if AParticipantCount <= 0 then
    raise EArgumentException.Create('AParticipantCount deve ser positivo.');
  FRemaining := AParticipantCount;
  FGoEvent := TEvent.Create(nil, True, False, '');
end;

destructor TStartBarrier.Destroy;
begin
  FGoEvent.Free;
  inherited Destroy;
end;

function TStartBarrier.ArriveAndWait(ATimeoutMs: Cardinal): Boolean;
begin
  if InterlockedDecrement(FRemaining) <= 0 then
  begin
    FGoEvent.SetEvent;
    Exit(True);
  end;
  Result := FGoEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

{ TDeadlockWatchdog }

constructor TDeadlockWatchdog.Create(ATimeoutMs: Cardinal;
  AOnTimeout: TNotifyEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FTimeoutMs := ATimeoutMs;
  FTimedOut := 0;
  FOnTimeout := AOnTimeout;
  FDoneEvent := TEvent.Create(nil, True, False, '');
end;

destructor TDeadlockWatchdog.Destroy;
begin
  SignalCompleted;
  WaitFor;
  FDoneEvent.Free;
  inherited Destroy;
end;

procedure TDeadlockWatchdog.SignalCompleted;
begin
  Terminate;
  if Assigned(FDoneEvent) then
    FDoneEvent.SetEvent;
end;

function TDeadlockWatchdog.TimedOut: Boolean;
begin
  Result := InterlockedCompareExchange(FTimedOut, 0, 0) <> 0;
end;

procedure TDeadlockWatchdog.Execute;
begin
  TThread.NameThreadForDebugging('DeadlockWatchdog');
  if FDoneEvent.WaitFor(FTimeoutMs) = wrTimeout then
  begin
    if not Terminated then
    begin
      InterlockedExchange(FTimedOut, 1);
      if Assigned(FOnTimeout) then
        FOnTimeout(Self);
    end;
  end;
end;

{ TContentionTimer }

procedure TContentionTimer.Start;
begin
  StartTick := GetTickCount64;
end;

function TContentionTimer.ElapsedMs: QWord;
begin
  Result := GetTickCount64 - StartTick;
end;

end.
