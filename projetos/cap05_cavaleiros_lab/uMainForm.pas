unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, SyncObjs, uExperiments;

type
  PAsyncMsg = ^TAsyncMsg;
  TAsyncMsg = record
    Text: string;
    Finished: Boolean;
    ElapsedMs: QWord;
    Kind: TExperimentKind;
    Fixed: Boolean;
  end;

  { TfrmMain }

  TfrmMain = class(TForm)
    btnRunBroken: TButton;
    btnRunFixed: TButton;
    btnClearLog: TButton;
    lblStatus: TLabel;
    lblHeartbeat: TLabel;
    memLog: TMemo;
    pnlTop: TPanel;
    pnlButtons: TPanel;
    pbProgress: TProgressBar;
    rgExperiment: TRadioGroup;
    tmrHeartbeat: TTimer;
    procedure btnClearLogClick(Sender: TObject);
    procedure btnRunBrokenClick(Sender: TObject);
    procedure btnRunFixedClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure tmrHeartbeatTimer(Sender: TObject);
  private
    FRunning: Boolean;
    FRunner: TExperimentRunnerThread;
    FAsyncWorker: TDeadlockAsyncWorker;
    FCurrentKind: TExperimentKind;
    FCurrentFixed: Boolean;
    FLastBrokenFalseSharingMs: QWord;
    FHeartbeatTicks: QWord;
    FPendingMsgs: TThreadList;
    procedure SetRunningState(ARunning: Boolean; const AStatus: string);
    procedure LogLine(const AMsg: string);
    procedure OnWorkerReport(const AText: string; AFinished: Boolean;
      AElapsedMs: QWord);
    procedure HandleAsyncReport(Data: PtrInt);
    procedure RunDeadlockBrokenDemo;
    procedure OnDeadlockSyncHit(Sender: TObject);
    procedure CleanupFinishedThreads;
    procedure FreeOrphanMessages;
  public
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

{ TfrmMain }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FPendingMsgs := TThreadList.Create;
  FRunning := False;
  FRunner := nil;
  FAsyncWorker := nil;
  FLastBrokenFalseSharingMs := 0;
  FHeartbeatTicks := 0;
  rgExperiment.ItemIndex := 0;
  SetRunningState(False, 'Pronto. Selecione um experimento acima.');
  LogLine('Laboratorio de Anomalias Concorrentes - FPC 3.2.2+ / Lazarus LCL');
  LogLine(Format('Nucleos logicos detectados (TThread.ProcessorCount): %d',
    [TThread.ProcessorCount]));
  LogLine('Dica: Observe o Heartbeat da UI no canto superior direito.');
  LogLine(StringOfChar('-', 72));
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  tmrHeartbeat.Enabled := False;
  if Assigned(FRunner) then
  begin
    FRunner.Terminate;
    while not FRunner.Finished do
      CheckSynchronize(20);
    FRunner.WaitFor;
    FreeAndNil(FRunner);
  end;
  if Assigned(FAsyncWorker) then
  begin
    FAsyncWorker.Terminate;
    while not FAsyncWorker.Finished do
      CheckSynchronize(20);
    FAsyncWorker.WaitFor;
    FreeAndNil(FAsyncWorker);
  end;
  { Remove callbacks ainda na fila da LCL antes de destruir Self }
  Application.RemoveAsyncCalls(Self);
  FreeOrphanMessages;
  FreeAndNil(FPendingMsgs);
end;

procedure TfrmMain.FreeOrphanMessages;
var
  List: TList;
  I: Integer;
begin
  if not Assigned(FPendingMsgs) then
    Exit;
  List := FPendingMsgs.LockList;
  try
    for I := 0 to List.Count - 1 do
      Dispose(PAsyncMsg(List[I]));
    List.Clear;
  finally
    FPendingMsgs.UnlockList;
  end;
end;

procedure TfrmMain.tmrHeartbeatTimer(Sender: TObject);
begin
  Inc(FHeartbeatTicks);
  lblHeartbeat.Caption := Format('UI Heartbeat: %d ticks (Responsiva)',
    [FHeartbeatTicks]);
end;

procedure TfrmMain.SetRunningState(ARunning: Boolean; const AStatus: string);
begin
  FRunning := ARunning;
  btnRunBroken.Enabled := not ARunning;
  btnRunFixed.Enabled := not ARunning;
  rgExperiment.Enabled := not ARunning;
  lblStatus.Caption := 'Status: ' + AStatus;
  if ARunning then
    pbProgress.Style := pbstMarquee
  else
  begin
    pbProgress.Style := pbstNormal;
    pbProgress.Position := 0;
  end;
end;

procedure TfrmMain.LogLine(const AMsg: string);
begin
  memLog.Lines.Add(AMsg);
end;

procedure TfrmMain.CleanupFinishedThreads;
begin
  if Assigned(FRunner) then
  begin
    FRunner.WaitFor;
    FreeAndNil(FRunner);
  end;
  if Assigned(FAsyncWorker) then
  begin
    FAsyncWorker.WaitFor;
    FreeAndNil(FAsyncWorker);
  end;
end;

procedure TfrmMain.OnWorkerReport(const AText: string; AFinished: Boolean;
  AElapsedMs: QWord);
var
  Msg: PAsyncMsg;
begin
  { Chamado a partir de Worker Threads: transfere DTO via QueueAsyncCall }
  New(Msg);
  Msg^.Text := AText;
  Msg^.Finished := AFinished;
  Msg^.ElapsedMs := AElapsedMs;
  Msg^.Kind := FCurrentKind;
  Msg^.Fixed := FCurrentFixed;
  FPendingMsgs.Add(Msg);
  Application.QueueAsyncCall(@HandleAsyncReport, PtrInt(Msg));
end;

procedure TfrmMain.HandleAsyncReport(Data: PtrInt);
var
  Msg: PAsyncMsg;
begin
  Msg := PAsyncMsg(Data);
  if Msg = nil then
    Exit;
  FPendingMsgs.Remove(Msg);
  try
    LogLine(Msg^.Text);
    if Msg^.Finished then
    begin
      if (Msg^.Kind = ekFalseSharing) and (not Msg^.Fixed) then
        FLastBrokenFalseSharingMs := Msg^.ElapsedMs;
      LogLine(StringOfChar('-', 72));
      CleanupFinishedThreads;
      SetRunningState(False, Format('Concluido em %d ms.', [Msg^.ElapsedMs]));
    end;
  finally
    Dispose(Msg);
  end;
end;

procedure TfrmMain.OnDeadlockSyncHit(Sender: TObject);
begin
  LogLine('  [Synchronize executado na Main Thread] Callback concluido!');
end;

procedure TfrmMain.RunDeadlockBrokenDemo;
const
  WATCHDOG_MS = 2500;
var
  DoneEvent: TSimpleEvent;
  Worker: TDeadlockSyncWorker;
  WaitRes: TWaitResult;
  T0, BlockedMs, RecoveryT0, RecoveryMs: QWord;
begin
  LogLine('=== [EXP 2] DEADLOCK LCL: VERSAO QUEBRADA (Com Watchdog 2500 ms) ===');
  LogLine('Main Thread vai bloquear em DoneEvent.WaitFor(2500) enquanto');
  LogLine('a Worker Thread aguarda Main Thread executar Synchronize...');
  LogLine('Observe o UI Heartbeat congelando durante o impasse!');
  SetRunningState(True, 'Simulando Deadlock (Watchdog 2,5 s)...');
  { Garante pintura da mensagem no Memo antes de bloquear a Main Thread }
  Application.ProcessMessages;

  DoneEvent := TSimpleEvent.Create;
  Worker := TDeadlockSyncWorker.Create(DoneEvent, @OnDeadlockSyncHit);
  try
    T0 := GetTickCount64;
    Worker.Start;

    { ERRO PROVOCADO: Espera bloqueante na Main Thread sem CheckSynchronize! }
    WaitRes := DoneEvent.WaitFor(WATCHDOG_MS);
    BlockedMs := GetTickCount64 - T0;

    if WaitRes = wrTimeout then
    begin
      LogLine(Format('! WATCHDOG DISPAROU apos %d ms: DEADLOCK CIRCULAR CONFIRMADO!',
        [BlockedMs]));
      LogLine('  Ciclo: Main Thread espera DoneEvent -> Worker espera Synchronize');
      LogLine('  -> Synchronize espera Main Thread voltar ao Event Loop.');
      LogLine('Iniciando recuperacao limpa drenando CheckSynchronize(20)...');

      RecoveryT0 := GetTickCount64;
      while not Worker.Finished do
        CheckSynchronize(20);
      Worker.WaitFor;
      RecoveryMs := GetTickCount64 - RecoveryT0;

      LogLine(Format('Recuperacao concluida em %d ms (SyncExecuted=%s).',
        [RecoveryMs, BoolToStr(Worker.SyncExecuted, True)]));
      LogLine('DIAGNOSTICO: Sem o Watchdog, o processo travaria para sempre.');
    end
    else
    begin
      Worker.WaitFor;
      LogLine('Worker concluiu antes do watchdog.');
    end;
    LogLine(StringOfChar('-', 72));
  finally
    Worker.Free;
    DoneEvent.Free;
    SetRunningState(False, 'Deadlock demonstrado e recuperado pelo Watchdog.');
  end;
end;

procedure TfrmMain.btnRunBrokenClick(Sender: TObject);
begin
  if FRunning then
    Exit;
  CleanupFinishedThreads;
  FCurrentKind := TExperimentKind(rgExperiment.ItemIndex);
  FCurrentFixed := False;

  if FCurrentKind = ekDeadlockLCL then
  begin
    RunDeadlockBrokenDemo;
    Exit;
  end;

  SetRunningState(True, 'Executando versao quebrada...');
  FRunner := TExperimentRunnerThread.Create(FCurrentKind, False,
    FLastBrokenFalseSharingMs, @OnWorkerReport);
  FRunner.Start;
end;

procedure TfrmMain.btnRunFixedClick(Sender: TObject);
begin
  if FRunning then
    Exit;
  CleanupFinishedThreads;
  FCurrentKind := TExperimentKind(rgExperiment.ItemIndex);
  FCurrentFixed := True;

  if FCurrentKind = ekDeadlockLCL then
  begin
    LogLine('=== [EXP 2] DEADLOCK LCL: VERSAO CORRIGIDA (QueueAsyncCall) ===');
    LogLine('Main Thread dispara Worker e retorna imediatamente (0 ms bloqueio).');
    SetRunningState(True, 'Executando Worker 100% assincrono...');
    FAsyncWorker := TDeadlockAsyncWorker.Create(@OnWorkerReport);
    FAsyncWorker.Start;
    Exit;
  end;

  SetRunningState(True, 'Executando versao corrigida...');
  FRunner := TExperimentRunnerThread.Create(FCurrentKind, True,
    FLastBrokenFalseSharingMs, @OnWorkerReport);
  FRunner.Start;
end;

procedure TfrmMain.btnClearLogClick(Sender: TObject);
begin
  memLog.Clear;
end;

end.
