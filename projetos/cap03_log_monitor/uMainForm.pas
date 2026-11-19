unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs,
  StdCtrls, ExtCtrls, ComCtrls, Spin,
  uLogProducer;

type
  TMainForm = class(TForm)
    PanelTop: TPanel;
    RadioGroupMode: TRadioGroup;
    LblTotal: TLabel;
    SpinTotal: TSpinEdit;
    LblThrottle: TLabel;
    SpinThrottle: TSpinEdit;
    BtnStart: TButton;
    BtnStop: TButton;
    BtnTestUI: TButton;
    ProgressBarMain: TProgressBar;
    PanelMetrics: TPanel;
    LblStatus: TLabel;
    LblThroughput: TLabel;
    LblBatches: TLabel;
    LblLag: TLabel;
    MemoLogs: TMemo;
    TimerHeartbeat: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure BtnStartClick(Sender: TObject);
    procedure BtnStopClick(Sender: TObject);
    procedure BtnTestUIClick(Sender: TObject);
    procedure TimerHeartbeatTimer(Sender: TObject);
  private
    FQueue: TLogBatchQueue;
    FProducer: TLogProducerThread;
    FShuttingDown: LongInt;
    FRunning: Boolean;
    FTargetTotal: Int64;
    FProcessedCount: Int64;
    FBatchCount: Int64;
    FStartMs: QWord;
    FLastTickMs: QWord;
    FMaxUILagMs: QWord;
    FUIClicks: Integer;

    function IsShuttingDown: Boolean;
    procedure StopProducerGracefully;
    procedure ResetMetrics;
    procedure UpdateProgressVisual(AProcessed: Int64);
    function FormatLogLine(const AEntry: TLogEntry): string;
    procedure TrimMemoWindow(AMaxLines: Integer);

    { Callback chamado via TThread.Synchronize (modo ingenuo) }
    procedure HandleSingleLogSync(const AEntry: TLogEntry);

    { Callback invocado na worker thread para agendar QueueAsyncCall }
    procedure SignalBatchFromWorker(AForceFinal: Boolean);

    { Callback executado na Main Thread via Application.QueueAsyncCall }
    procedure HandleDrainQueueAsync(Data: PtrInt);

    { Callback de conclusao }
    procedure HandleProducerDone(ATotalProduced: Int64;
      AElapsedMs: QWord; AAborted: Boolean);
  public
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  CMaxVisibleLines = 250;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FQueue := TLogBatchQueue.Create;
  FProducer := nil;
  FShuttingDown := 0;
  FRunning := False;
  FLastTickMs := GetTickCount64;
  FMaxUILagMs := 0;
  FUIClicks := 0;
end;

function TMainForm.IsShuttingDown: Boolean;
begin
  Result := InterlockedExchangeAdd(FShuttingDown, 0) <> 0;
end;

destructor TMainForm.Destroy;
begin
  { Garantia defensiva: encerra thread e limpa callbacks pendentes }
  InterlockedExchange(FShuttingDown, 1);
  StopProducerGracefully;
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FQueue);
  inherited Destroy;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  InterlockedExchange(FShuttingDown, 1);
  StopProducerGracefully;
  Application.RemoveAsyncCalls(Self);
  CanClose := True;
end;

procedure TMainForm.StopProducerGracefully;
begin
  if Assigned(FProducer) then
  begin
    FProducer.Terminate;
    FProducer.WaitFor;
    FreeAndNil(FProducer);
  end;
  Application.RemoveAsyncCalls(Self);
  if Assigned(FQueue) then
    FQueue.Clear;
  FRunning := False;
end;

procedure TMainForm.ResetMetrics;
begin
  FProcessedCount := 0;
  FBatchCount := 0;
  FMaxUILagMs := 0;
  FUIClicks := 0;
  FStartMs := GetTickCount64;
  FLastTickMs := FStartMs;

  MemoLogs.Clear;
  ProgressBarMain.Position := 0;
  BtnTestUI.Caption := 'Testar Clique na UI (0)';
  LblThroughput.Caption := 'Vazao: 0 eventos/s | Tempo: 0 ms';
  LblBatches.Caption := 'Lotes drenados: 0 | Processados: 0';
  LblLag.Caption := 'Maior latencia do loop da UI: 0 ms';
end;

function TMainForm.FormatLogLine(const AEntry: TLogEntry): string;
begin
  Result := Format('[#%6.6d] [%s] %s',
    [AEntry.Seq, LogLevelToStr(AEntry.Level), AEntry.MessageText]);
end;

procedure TMainForm.TrimMemoWindow(AMaxLines: Integer);
begin
  while MemoLogs.Lines.Count > AMaxLines do
    MemoLogs.Lines.Delete(0);
end;

procedure TMainForm.UpdateProgressVisual(AProcessed: Int64);
var
  ElapsedMs: QWord;
  Rate: Double;
  PosVal: Integer;
begin
  if FTargetTotal > 0 then
    PosVal := Integer((AProcessed * 1000) div FTargetTotal)
  else
    PosVal := 0;
  if PosVal > 1000 then
    PosVal := 1000;
  ProgressBarMain.Position := PosVal;

  ElapsedMs := GetTickCount64 - FStartMs;
  if ElapsedMs = 0 then
    ElapsedMs := 1;
  Rate := (AProcessed * 1000.0) / ElapsedMs;

  LblThroughput.Caption := Format(
    'Vazao: %.0f eventos/s | Tempo: %d ms', [Rate, ElapsedMs]);
  LblBatches.Caption := Format(
    'Lotes drenados: %d | Processados: %d / %d',
    [FBatchCount, AProcessed, FTargetTotal]);
end;

procedure TMainForm.BtnStartClick(Sender: TObject);
var
  Mode: TDispatchMode;
begin
  if FRunning then
    Exit;

  StopProducerGracefully;
  ResetMetrics;

  FTargetTotal := SpinTotal.Value;
  if RadioGroupMode.ItemIndex = 0 then
    Mode := dmNaiveSync
  else
    Mode := dmBatchedAsync;

  FRunning := True;
  BtnStart.Enabled := False;
  BtnStop.Enabled := True;
  RadioGroupMode.Enabled := False;
  SpinTotal.Enabled := False;
  SpinThrottle.Enabled := False;
  LblStatus.Caption := 'Status: Executando benchmark...';

  FProducer := TLogProducerThread.Create(
    Mode,
    FTargetTotal,
    QWord(SpinThrottle.Value),
    FQueue,
    @HandleSingleLogSync,
    @SignalBatchFromWorker,
    @HandleProducerDone
  );
  FProducer.Start;
end;

procedure TMainForm.BtnStopClick(Sender: TObject);
begin
  if not FRunning then
    Exit;
  LblStatus.Caption := 'Status: Cancelando graciosamente...';
  if Assigned(FProducer) then
    FProducer.Terminate;
end;

procedure TMainForm.BtnTestUIClick(Sender: TObject);
begin
  Inc(FUIClicks);
  BtnTestUI.Caption := Format('Testar Clique na UI (%d)', [FUIClicks]);
end;

procedure TMainForm.TimerHeartbeatTimer(Sender: TObject);
var
  NowMs, DeltaMs: QWord;
begin
  NowMs := GetTickCount64;
  DeltaMs := NowMs - FLastTickMs;
  FLastTickMs := NowMs;

  if FRunning and (DeltaMs > FMaxUILagMs) then
  begin
    FMaxUILagMs := DeltaMs;
    LblLag.Caption := Format(
      'Maior latencia do loop da UI: %d ms (alvo ~50 ms)',
      [FMaxUILagMs]);
  end;
end;

procedure TMainForm.HandleSingleLogSync(const AEntry: TLogEntry);
begin
  if IsShuttingDown then
    Exit;

  Inc(FProcessedCount);
  Inc(FBatchCount);
  MemoLogs.Lines.Add(FormatLogLine(AEntry));
  TrimMemoWindow(CMaxVisibleLines);
  UpdateProgressVisual(FProcessedCount);
end;

procedure TMainForm.SignalBatchFromWorker(AForceFinal: Boolean);
begin
  { Executado na WORKER THREAD: nunca tocar em controles LCL aqui! }
  if IsShuttingDown then
    Exit;

  if AForceFinal or FQueue.TryClaimSignal then
    Application.QueueAsyncCall(@HandleDrainQueueAsync, Ord(AForceFinal));
end;

procedure TMainForm.HandleDrainQueueAsync(Data: PtrInt);
var
  LocalBatch: TList;
  Count, StartIdx, I: Integer;
  Entry: PLogEntry;
  IsFinalFlush: Boolean;
begin
  if IsShuttingDown then
    Exit;

  IsFinalFlush := Data <> 0;

  { Libera o sinal ANTES de drenar para nao perder novos eventos }
  FQueue.ResetSignal;

  LocalBatch := TList.Create;
  try
    Count := FQueue.DrainTo(LocalBatch);
    if Count = 0 then
    begin
      if IsFinalFlush then
        UpdateProgressVisual(FProcessedCount);
      Exit;
    end;

    Inc(FBatchCount);
    Inc(FProcessedCount, Count);

    { Renderiza apenas a cauda recente para evitar sobrecarga no TMemo }
    if Count > CMaxVisibleLines then
      StartIdx := Count - CMaxVisibleLines
    else
      StartIdx := 0;

    MemoLogs.Lines.BeginUpdate;
    try
      if Count >= CMaxVisibleLines then
        MemoLogs.Lines.Clear;
      for I := StartIdx to Count - 1 do
      begin
        Entry := PLogEntry(LocalBatch[I]);
        MemoLogs.Lines.Add(FormatLogLine(Entry^));
      end;
      TrimMemoWindow(CMaxVisibleLines);
    finally
      MemoLogs.Lines.EndUpdate;
    end;

    UpdateProgressVisual(FProcessedCount);
  finally
    FreeLogEntryList(LocalBatch);
    LocalBatch.Free;
  end;
end;

procedure TMainForm.HandleProducerDone(ATotalProduced: Int64;
  AElapsedMs: QWord; AAborted: Boolean);
var
  Rate: Double;
begin
  if IsShuttingDown then
    Exit;

  { Garante dreno final de qualquer residuo pendente na fila }
  HandleDrainQueueAsync(1);

  FRunning := False;
  BtnStart.Enabled := True;
  BtnStop.Enabled := False;
  RadioGroupMode.Enabled := True;
  SpinTotal.Enabled := True;
  SpinThrottle.Enabled := True;

  Rate := (ATotalProduced * 1000.0) / AElapsedMs;
  LblThroughput.Caption := Format(
    'Vazao final: %.0f eventos/s | Tempo: %d ms',
    [Rate, AElapsedMs]);
  LblLag.Caption := Format(
    'Maior latencia do loop da UI: %d ms (alvo ~50 ms)',
    [FMaxUILagMs]);

  if AAborted then
    LblStatus.Caption := Format(
      'Status: Abortado em %d eventos.', [ATotalProduced])
  else
    LblStatus.Caption := Format(
      'Status: Concluido (%d eventos em %d ms).',
      [ATotalProduced, AElapsedMs]);
end;

end.
