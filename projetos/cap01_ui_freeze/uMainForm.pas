unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Forms, Controls, Graphics, Dialogs,
  ExtCtrls, StdCtrls, ComCtrls, Spin, Math, uCpuWorkload;

const
  HISTORY_LEN = 120;

type
  { TfrmUiFreezeBenchmark }
  TfrmUiFreezeBenchmark = class(TForm)
    btnCancelThread: TButton;
    btnInteractive: TButton;
    btnResetMetrics: TButton;
    btnRunProcMsg: TButton;
    btnRunSync: TButton;
    btnRunThread: TButton;
    edtScratch: TEdit;
    lblCpuInfo: TLabel;
    lblFps: TLabel;
    lblLimit: TLabel;
    lblMaxJitter: TLabel;
    lblReentrancy: TLabel;
    memLog: TMemo;
    pbHeartbeat: TPaintBox;
    pbProgress: TProgressBar;
    pnlControls: TPanel;
    pnlTop: TPanel;
    seLimit: TSpinEdit;
    tmrHeartbeat: TTimer;
    procedure btnCancelThreadClick(Sender: TObject);
    procedure btnInteractiveClick(Sender: TObject);
    procedure btnResetMetricsClick(Sender: TObject);
    procedure btnRunProcMsgClick(Sender: TObject);
    procedure btnRunSyncClick(Sender: TObject);
    procedure btnRunThreadClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure pbHeartbeatPaint(Sender: TObject);
    procedure tmrHeartbeatTimer(Sender: TObject);
  private
    FWorker: TPrimeWorkerThread;
    FClosing: Boolean;
    FLastTick: QWord;
    FMaxJitterMs: QWord;
    FFrameHistory: array[0..HISTORY_LEN - 1] of Word;
    FHistoryHead: Integer;
    FTicksThisSec: Integer;
    FLastFpsMark: QWord;
    FCurrentFps: Integer;
    FPhaseAngle: Double;
    FInteractiveClicks: Integer;
    FReentrancyDepth: Integer;
    FMaxReentrancy: Integer;
    FProcMsgRunId: Integer;
    FSharedAccumulator: Int64;
    procedure LogMsg(const AMsg: string);
    procedure UpdateMetricLabels;
    procedure HandleProcMsgStep(APercent: Integer);
    procedure HandleWorkerProgress(APercent, APrimesSoFar: Integer);
    procedure HandleWorkerTerminate(Sender: TObject);
    procedure DeferredFreeWorker(Data: PtrInt);
    procedure StopAndFreeWorker;
  end;

var
  frmUiFreezeBenchmark: TfrmUiFreezeBenchmark;

implementation

{$R *.lfm}

procedure TfrmUiFreezeBenchmark.FormCreate(Sender: TObject);
begin
  FClosing := False;
  FLastTick := GetTickCount64;
  FLastFpsMark := FLastTick;
  FMaxJitterMs := 0;
  FHistoryHead := 0;
  FillChar(FFrameHistory, SizeOf(FFrameHistory), 0);
  lblCpuInfo.Caption := Format('Nucleos Logicos: %d | MainTID: %d',
    [TThread.ProcessorCount, PtrUInt(MainThreadID)]);
  LogMsg('=== Benchmark de Responsividade LCL Pronto ===');
  LogMsg('Dica: clique em "2. ProcessMessages" 2x seguidas para');
  LogMsg('observar reentrancia, crescimento de pilha e corrupcao.');
end;

procedure TfrmUiFreezeBenchmark.FormCloseQuery(Sender: TObject;
  var CanClose: Boolean);
begin
  if FReentrancyDepth > 0 then
  begin
    LogMsg('[AVISO] Aguarde o retorno da pilha de ProcessMessages.');
    CanClose := False;
    Exit;
  end;
  FClosing := True;
  StopAndFreeWorker;
  CanClose := True;
end;

procedure TfrmUiFreezeBenchmark.FormDestroy(Sender: TObject);
begin
  FClosing := True;
  StopAndFreeWorker;
end;

procedure TfrmUiFreezeBenchmark.StopAndFreeWorker;
begin
  if Assigned(FWorker) then
  begin
    FWorker.Terminate;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

procedure TfrmUiFreezeBenchmark.LogMsg(const AMsg: string);
begin
  memLog.Lines.Add(Format('[%s] %s', [FormatDateTime('hh:nn:ss.zzz', Now),
    AMsg]));
end;

procedure TfrmUiFreezeBenchmark.UpdateMetricLabels;
begin
  lblFps.Caption := Format('Event Loop: %d ticks/s', [FCurrentFps]);
  lblMaxJitter.Caption := Format('Jitter Maximo: %d ms', [FMaxJitterMs]);
  if FMaxJitterMs > 100 then
    lblMaxJitter.Font.Color := clRed
  else if FMaxJitterMs > 40 then
    lblMaxJitter.Font.Color := $000080FF
  else
    lblMaxJitter.Font.Color := clGreen;

  lblReentrancy.Caption := Format('Reentrancia Atual/Max: %d / %d',
    [FReentrancyDepth, FMaxReentrancy]);
  if FMaxReentrancy > 1 then
    lblReentrancy.Font.Color := clRed
  else
    lblReentrancy.Font.Color := clWindowText;
end;

procedure TfrmUiFreezeBenchmark.tmrHeartbeatTimer(Sender: TObject);
var
  NowTick, Delta: QWord;
begin
  NowTick := GetTickCount64;
  Delta := NowTick - FLastTick;
  FLastTick := NowTick;

  if Delta > FMaxJitterMs then
    FMaxJitterMs := Delta;

  if Delta > High(Word) then
    FFrameHistory[FHistoryHead] := High(Word)
  else
    FFrameHistory[FHistoryHead] := Word(Delta);
  FHistoryHead := (FHistoryHead + 1) mod HISTORY_LEN;

  Inc(FTicksThisSec);
  if (NowTick - FLastFpsMark) >= 1000 then
  begin
    FCurrentFps := FTicksThisSec;
    FTicksThisSec := 0;
    FLastFpsMark := NowTick;
  end;

  FPhaseAngle := FPhaseAngle + 0.14;
  if FPhaseAngle > 2 * Pi then
    FPhaseAngle := FPhaseAngle - 2 * Pi;

  UpdateMetricLabels;
  pbHeartbeat.Invalidate;
end;

procedure TfrmUiFreezeBenchmark.pbHeartbeatPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, CX, CY, R, I, Idx, BarX, BarH, GraphLeft, GraphW: Integer;
  ValMs: Word;
begin
  C := pbHeartbeat.Canvas;
  W := pbHeartbeat.Width;
  H := pbHeartbeat.Height;

  C.Brush.Color := $00241A0F;
  C.FillRect(0, 0, W, H);

  { Radar giratorio: congela instantaneamente em UI Freeze }
  R := Min(46, (H div 2) - 14);
  CX := R + 18;
  CY := H div 2;
  C.Pen.Color := $00775533;
  C.Pen.Width := 2;
  C.Brush.Style := bsClear;
  C.Ellipse(CX - R, CY - R, CX + R, CY + R);

  C.Pen.Color := $00D79E20;
  C.Pen.Width := 3;
  C.MoveTo(CX, CY);
  C.LineTo(CX + Round(Cos(FPhaseAngle) * (R - 4)),
           CY + Round(Sin(FPhaseAngle) * (R - 4)));

  { Grafico de latencia (jitter) dos ultimos 120 ticks }
  GraphLeft := CX + R + 22;
  GraphW := W - GraphLeft - 12;
  if GraphW < 40 then
    Exit;

  C.Pen.Width := 1;
  C.Pen.Color := $00554433;
  C.Rectangle(GraphLeft, 12, W - 12, H - 12);

  for I := 0 to HISTORY_LEN - 1 do
  begin
    Idx := (FHistoryHead + I) mod HISTORY_LEN;
    ValMs := FFrameHistory[Idx];
    BarX := GraphLeft + 2 + (I * (GraphW - 4)) div HISTORY_LEN;
    BarH := Min(H - 28, Round((Min(ValMs, 250) / 250.0) * (H - 28)));
    if ValMs > 80 then
      C.Pen.Color := clRed
    else if ValMs > 32 then
      C.Pen.Color := $0000A5FF
    else
      C.Pen.Color := $0088CC22;
    C.MoveTo(BarX, H - 14);
    C.LineTo(BarX, H - 14 - BarH);
  end;

  C.Font.Color := clWhite;
  C.Brush.Style := bsClear;
  C.TextOut(GraphLeft + 8, 16, 'Latencia do Event Loop (escala 0..250 ms)');
end;

procedure TfrmUiFreezeBenchmark.btnResetMetricsClick(Sender: TObject);
begin
  FMaxJitterMs := 0;
  FMaxReentrancy := 0;
  FInteractiveClicks := 0;
  btnInteractive.Caption := 'Testar Clique (0)';
  FillChar(FFrameHistory, SizeOf(FFrameHistory), 0);
  UpdateMetricLabels;
  pbHeartbeat.Invalidate;
  LogMsg('Metricas zeradas.');
end;

procedure TfrmUiFreezeBenchmark.btnInteractiveClick(Sender: TObject);
begin
  Inc(FInteractiveClicks);
  btnInteractive.Caption := Format('Testar Clique (%d)', [FInteractiveClicks]);
end;

procedure TfrmUiFreezeBenchmark.btnRunSyncClick(Sender: TObject);
var
  Stats: TWorkloadStats;
begin
  FMaxJitterMs := 0;
  pbProgress.Position := 0;
  LogMsg(Format('[MODO 1 - SINCRONO] Iniciando ate %d na Main Thread...',
    [seLimit.Value]));
  Application.ProcessMessages; { apenas para exibir a linha de log antes }

  Stats := CountPrimesSync(seLimit.Value);

  pbProgress.Position := 100;
  LogMsg(Format('[MODO 1 - FIM] Primos=%d | Tempo=%d ms | UI congelou!',
    [Stats.PrimesFound, Stats.ElapsedMs]));
end;

procedure TfrmUiFreezeBenchmark.HandleProcMsgStep(APercent: Integer);
begin
  pbProgress.Position := APercent;
  Inc(FSharedAccumulator);
  { PERIGO: re-entra no Event Loop sem concluir o frame atual! }
  Application.ProcessMessages;
end;

procedure TfrmUiFreezeBenchmark.btnRunProcMsgClick(Sender: TObject);
var
  StackProbe: Byte;
  MyRunId: Integer;
  ExpectedSteps, ActualDelta: Int64;
  BeforeAcc: Int64;
  Stats: TWorkloadStats;
begin
  StackProbe := 0;
  Inc(FProcMsgRunId);
  MyRunId := FProcMsgRunId;
  Inc(FReentrancyDepth);
  if FReentrancyDepth > FMaxReentrancy then
    FMaxReentrancy := FReentrancyDepth;
  UpdateMetricLabels;

  BeforeAcc := FSharedAccumulator;
  ExpectedSteps := seLimit.Value div 5000;

  LogMsg(Format(
    '[MODO 2 - ENTRADA #%d] Depth=%d | StackAddr=$%x | Acc=%d',
    [MyRunId, FReentrancyDepth, PtrUInt(@StackProbe), BeforeAcc]));
  try
    Stats := CountPrimesWithCallback(seLimit.Value, 5000,
      @HandleProcMsgStep);
    ActualDelta := FSharedAccumulator - BeforeAcc;
    LogMsg(Format(
      '[MODO 2 - SAIDA #%d] Primos=%d | Tempo=%d ms | ' +
      'DeltaAcc=%d (esperado=%d)%s',
      [MyRunId, Stats.PrimesFound, Stats.ElapsedMs,
       ActualDelta, ExpectedSteps,
       IfThen(ActualDelta <> ExpectedSteps, ' << CORROMPIDO!', '')]));
  finally
    Dec(FReentrancyDepth);
    UpdateMetricLabels;
  end;
end;

procedure TfrmUiFreezeBenchmark.btnRunThreadClick(Sender: TObject);
begin
  if Assigned(FWorker) then
    StopAndFreeWorker;

  FMaxJitterMs := 0;
  pbProgress.Position := 0;
  btnRunThread.Enabled := False;
  btnRunSync.Enabled := False;
  btnCancelThread.Enabled := True;

  LogMsg(Format('[MODO 3 - TTHREAD] Iniciando worker ate %d...',
    [seLimit.Value]));

  FWorker := TPrimeWorkerThread.Create(seLimit.Value,
    @HandleWorkerProgress);
  FWorker.OnTerminate := @HandleWorkerTerminate;
  FWorker.Start;
end;

procedure TfrmUiFreezeBenchmark.btnCancelThreadClick(Sender: TObject);
begin
  if Assigned(FWorker) then
  begin
    btnCancelThread.Enabled := False;
    LogMsg('[MODO 3 - TTHREAD] Solicitando cancelamento cooperativo...');
    FWorker.Terminate;
  end;
end;

procedure TfrmUiFreezeBenchmark.HandleWorkerProgress(
  APercent, APrimesSoFar: Integer);
begin
  if FClosing then
    Exit;
  pbProgress.Position := APercent;
  btnCancelThread.Caption := Format('Cancelar (%d)', [APrimesSoFar]);
end;

procedure TfrmUiFreezeBenchmark.HandleWorkerTerminate(Sender: TObject);
var
  Stats: TWorkloadStats;
begin
  if FClosing or (Sender <> FWorker) then
    Exit;

  Stats := FWorker.Stats;
  btnRunThread.Enabled := True;
  btnRunSync.Enabled := True;
  btnCancelThread.Enabled := False;
  btnCancelThread.Caption := 'Cancelar Thread';

  if Assigned(FWorker.FatalException) then
    LogMsg('[MODO 3 - ERRO FATAL] ' +
      Exception(FWorker.FatalException).Message)
  else if Stats.Cancelled then
    LogMsg(Format('[MODO 3 - CANCELADO] Parcial=%d primos em %d ms | ' +
      'JitterMax=%d ms',
      [Stats.PrimesFound, Stats.ElapsedMs, FMaxJitterMs]))
  else
    LogMsg(Format('[MODO 3 - FIM] Primos=%d | Tempo=%d ms | ' +
      'JitterMax=%d ms (UI 100%% fluida!)',
      [Stats.PrimesFound, Stats.ElapsedMs, FMaxJitterMs]));

  Application.QueueAsyncCall(@DeferredFreeWorker, PtrInt(FWorker));
end;

procedure TfrmUiFreezeBenchmark.DeferredFreeWorker(Data: PtrInt);
begin
  if Assigned(FWorker) and (PtrInt(FWorker) = Data) then
  begin
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

end.
