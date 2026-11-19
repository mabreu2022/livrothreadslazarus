unit uCpuWorkload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TWorkloadStats = record
    Limit: Integer;
    PrimesFound: Integer;
    ElapsedMs: QWord;
    Cancelled: Boolean;
  end;

  TProgressStepProc = procedure(APercent: Integer) of object;
  TWorkerProgressEvent = procedure(APercent, APrimesSoFar: Integer) of object;

  { TPrimeWorkerThread }
  TPrimeWorkerThread = class(TThread)
  private
    FLimit: Integer;
    FStats: TWorkloadStats;
    FLastPercent: Integer;
    FLastPrimes: Integer;
    FOnProgress: TWorkerProgressEvent;
    procedure NotifyProgressUI;
  protected
    procedure Execute; override;
  public
    constructor Create(ALimit: Integer; AOnProgress: TWorkerProgressEvent);
    property Stats: TWorkloadStats read FStats;
  end;

function IsPrimeNumber(N: Integer): Boolean;
function CountPrimesSync(ALimit: Integer): TWorkloadStats;
function CountPrimesWithCallback(ALimit: Integer;
  AStepInterval: Integer;
  AStepCallback: TProgressStepProc): TWorkloadStats;

implementation

function IsPrimeNumber(N: Integer): Boolean;
var
  Divisor, LimitRoot: Integer;
begin
  if N < 2 then
    Exit(False);
  if (N = 2) or (N = 3) then
    Exit(True);
  if (N mod 2 = 0) or (N mod 3 = 0) then
    Exit(False);

  LimitRoot := Trunc(Sqrt(N));
  Divisor := 5;
  while Divisor <= LimitRoot do
  begin
    if (N mod Divisor = 0) or (N mod (Divisor + 2) = 0) then
      Exit(False);
    Inc(Divisor, 6);
  end;
  Result := True;
end;

function CountPrimesSync(ALimit: Integer): TWorkloadStats;
var
  I, Count: Integer;
  T0: QWord;
begin
  T0 := GetTickCount64;
  Count := 0;
  for I := 2 to ALimit do
    if IsPrimeNumber(I) then
      Inc(Count);

  Result.Limit := ALimit;
  Result.PrimesFound := Count;
  Result.ElapsedMs := GetTickCount64 - T0;
  Result.Cancelled := False;
end;

function CountPrimesWithCallback(ALimit: Integer;
  AStepInterval: Integer;
  AStepCallback: TProgressStepProc): TWorkloadStats;
var
  I, Count, Pct: Integer;
  T0: QWord;
begin
  if AStepInterval < 1 then
    AStepInterval := 1000;

  T0 := GetTickCount64;
  Count := 0;
  for I := 2 to ALimit do
  begin
    if IsPrimeNumber(I) then
      Inc(Count);

    if (I mod AStepInterval = 0) and Assigned(AStepCallback) then
    begin
      Pct := Round((I / ALimit) * 100);
      AStepCallback(Pct);
    end;
  end;

  Result.Limit := ALimit;
  Result.PrimesFound := Count;
  Result.ElapsedMs := GetTickCount64 - T0;
  Result.Cancelled := False;
end;

{ TPrimeWorkerThread }

constructor TPrimeWorkerThread.Create(ALimit: Integer;
  AOnProgress: TWorkerProgressEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLimit := ALimit;
  FOnProgress := AOnProgress;
end;

procedure TPrimeWorkerThread.NotifyProgressUI;
begin
  if Assigned(FOnProgress) then
    FOnProgress(FLastPercent, FLastPrimes);
end;

procedure TPrimeWorkerThread.Execute;
var
  I, Count, Pct, LastReportedPct: Integer;
  T0: QWord;
begin
  NameThreadForDebugging('PrimeBenchWrk');
  T0 := GetTickCount64;
  Count := 0;
  LastReportedPct := -1;

  for I := 2 to FLimit do
  begin
    if Terminated then
      Break;

    if IsPrimeNumber(I) then
      Inc(Count);

    if (I and $3FFF) = 0 then
    begin
      Pct := Round((I / FLimit) * 100);
      if Pct <> LastReportedPct then
      begin
        LastReportedPct := Pct;
        FLastPercent := Pct;
        FLastPrimes := Count;
        Queue(@NotifyProgressUI);
      end;
    end;
  end;

  FStats.Limit := FLimit;
  FStats.PrimesFound := Count;
  FStats.ElapsedMs := GetTickCount64 - T0;
  FStats.Cancelled := Terminated;

  if not Terminated then
  begin
    FLastPercent := 100;
    FLastPrimes := Count;
    Queue(@NotifyProgressUI);
  end;
end;

end.
