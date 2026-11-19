unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, Spin, Math, uCancellation, uImagePipeline;

type
  PStatsMsg = ^TStatsMsg;
  TStatsMsg = record
    Stats: TPipelineStats;
    IsGenerator: Boolean;
  end;

  { TfrmPipelineMain }

  TfrmPipelineMain = class(TForm)
    btnSelectDir: TButton;
    btnGenerateSamples: TButton;
    btnStart: TButton;
    btnCancel: TButton;
    cbFilter: TComboBox;
    edtInputDir: TEdit;
    grpConfig: TGroupBox;
    grpPreview: TGroupBox;
    imgPreview: TImage;
    lblInputDir: TLabel;
    lblFilter: TLabel;
    lblWorkers: TLabel;
    lblQueueCap: TLabel;
    lblMetrics: TLabel;
    lblStatus: TLabel;
    memLog: TMemo;
    pbPipeline: TProgressBar;
    pnlBottom: TPanel;
    pnlMiddle: TPanel;
    dlgSelectDir: TSelectDirectoryDialog;
    seWorkers: TSpinEdit;
    seQueueCap: TSpinEdit;
    procedure btnCancelClick(Sender: TObject);
    procedure btnGenerateSamplesClick(Sender: TObject);
    procedure btnSelectDirClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FCTS: TCancellationTokenSource;
    FPipeline: TBatchImagePipeline;
    FGenerator: TSampleGeneratorThread;
    FPendingMsgs: TThreadList;
    FLastPreviewTick: QWord;
    FBusy: Boolean;
    procedure SetBusyState(ABusy: Boolean; const AStatus: string);
    procedure OnPipelineProgress(const AStats: TPipelineStats);
    procedure OnGeneratorProgress(const AStats: TPipelineStats);
    procedure PostStatsToUI(const AStats: TPipelineStats; AIsGenerator: Boolean);
    procedure HandleAsyncStats(Data: PtrInt);
    procedure CleanupFinishedJobs;
    procedure FreeOrphanMessages;
  public
  end;

var
  frmPipelineMain: TfrmPipelineMain;

implementation

{$R *.lfm}

{ TfrmPipelineMain }

procedure TfrmPipelineMain.FormCreate(Sender: TObject);
var
  DefaultInDir: string;
begin
  FPendingMsgs := TThreadList.Create;
  FCTS := TCancellationTokenSource.Create;
  FPipeline := nil;
  FGenerator := nil;
  FLastPreviewTick := 0;
  FBusy := False;

  DefaultInDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'entrada';
  edtInputDir.Text := DefaultInDir;

  cbFilter.ItemIndex := 2; { Box Blur 7x7 como padrao CPU-bound }
  seWorkers.Value := Max(1, Min(32, Integer(TThread.ProcessorCount)));
  seQueueCap.Value := 4;

  SetBusyState(False, 'Pronto. Gere imagens de teste ou escolha uma pasta.');
  memLog.Lines.Add('Motor de Processamento de Imagens em Lote - Cap. 6');
  memLog.Lines.Add(Format('CPUs logicas (TThread.ProcessorCount): %d',
    [TThread.ProcessorCount]));
  memLog.Lines.Add('Workers usam FPImage (TFPMemoryImage) 100% thread-safe.');
  memLog.Lines.Add('Preview na UI atualizado apenas na Main Thread.');
  memLog.Lines.Add(StringOfChar('-', 72));
end;

procedure TfrmPipelineMain.FormDestroy(Sender: TObject);
begin
  if Assigned(FCTS) then
    FCTS.Cancel('Aplicacao encerrada');

  if Assigned(FPipeline) then
  begin
    while not FPipeline.Finished do
      CheckSynchronize(20);
    FPipeline.WaitFor;
    FreeAndNil(FPipeline);
  end;

  if Assigned(FGenerator) then
  begin
    while not FGenerator.Finished do
      CheckSynchronize(20);
    FGenerator.WaitFor;
    FreeAndNil(FGenerator);
  end;

  Application.RemoveAsyncCalls(Self);
  FreeOrphanMessages;
  FreeAndNil(FPendingMsgs);
  FreeAndNil(FCTS);
end;

procedure TfrmPipelineMain.FreeOrphanMessages;
var
  List: TList;
  I: Integer;
begin
  if not Assigned(FPendingMsgs) then
    Exit;
  List := FPendingMsgs.LockList;
  try
    for I := 0 to List.Count - 1 do
      Dispose(PStatsMsg(List[I]));
    List.Clear;
  finally
    FPendingMsgs.UnlockList;
  end;
end;

procedure TfrmPipelineMain.CleanupFinishedJobs;
begin
  if Assigned(FPipeline) then
  begin
    FPipeline.WaitFor;
    FreeAndNil(FPipeline);
  end;
  if Assigned(FGenerator) then
  begin
    FGenerator.WaitFor;
    FreeAndNil(FGenerator);
  end;
end;

procedure TfrmPipelineMain.SetBusyState(ABusy: Boolean; const AStatus: string);
begin
  FBusy := ABusy;
  btnStart.Enabled := not ABusy;
  btnGenerateSamples.Enabled := not ABusy;
  btnSelectDir.Enabled := not ABusy;
  edtInputDir.Enabled := not ABusy;
  cbFilter.Enabled := not ABusy;
  seWorkers.Enabled := not ABusy;
  seQueueCap.Enabled := not ABusy;
  btnCancel.Enabled := ABusy;
  lblStatus.Caption := 'Status: ' + AStatus;
end;

procedure TfrmPipelineMain.PostStatsToUI(const AStats: TPipelineStats;
  AIsGenerator: Boolean);
var
  Msg: PStatsMsg;
begin
  New(Msg);
  Msg^.Stats := AStats;
  Msg^.IsGenerator := AIsGenerator;
  FPendingMsgs.Add(Msg);
  Application.QueueAsyncCall(@HandleAsyncStats, PtrInt(Msg));
end;

procedure TfrmPipelineMain.OnPipelineProgress(const AStats: TPipelineStats);
begin
  PostStatsToUI(AStats, False);
end;

procedure TfrmPipelineMain.OnGeneratorProgress(const AStats: TPipelineStats);
begin
  PostStatsToUI(AStats, True);
end;

procedure TfrmPipelineMain.HandleAsyncStats(Data: PtrInt);
var
  Msg: PStatsMsg;
  S: TPipelineStats;
  Throughput: Double;
  NowTick: QWord;
begin
  Msg := PStatsMsg(Data);
  if Msg = nil then
    Exit;
  FPendingMsgs.Remove(Msg);
  try
    S := Msg^.Stats;

    if S.TotalFiles > 0 then
    begin
      pbPipeline.Max := S.TotalFiles;
      pbPipeline.Position := Min(S.TotalFiles, S.SavedCount);
    end;

    if S.ElapsedMs > 0 then
      Throughput := (S.SavedCount * 1000.0) / S.ElapsedMs
    else
      Throughput := 0.0;

    if Msg^.IsGenerator then
      lblMetrics.Caption := Format(
        'Gerador: %d / %d imagens | Tempo: %d ms',
        [S.SavedCount, S.TotalFiles, S.ElapsedMs])
    else
      lblMetrics.Caption := Format(
        'Lidas: %d | Proc: %d | Salvas: %d/%d | Erros: %d | ' +
        'Fila1: %d | Fila2: %d | Backpressure: %d | %d ms (%.1f img/s)',
        [S.ReadCount, S.ProcessedCount, S.SavedCount, S.TotalFiles,
         S.ErrorCount, S.Queue1Count, S.Queue2Count, S.BackpressureEvents,
         S.ElapsedMs, Throughput]);

    if S.LastLogLine <> '' then
      memLog.Lines.Add(S.LastLogLine);

    { Atualiza preview na Main Thread com throttling de 250 ms }
    NowTick := GetTickCount64;
    if (S.LastSavedFile <> '') and FileExists(S.LastSavedFile) and
       (S.Finished or ((NowTick - FLastPreviewTick) >= 250)) then
    begin
      FLastPreviewTick := NowTick;
      try
        imgPreview.Picture.LoadFromFile(S.LastSavedFile);
      except
        { Ignora falha transitoria de preview sem interromper fluxo }
      end;
    end;

    if S.Finished then
    begin
      CleanupFinishedJobs;
      if S.Cancelled then
        SetBusyState(False, Format('Cancelado apos %d ms.', [S.ElapsedMs]))
      else
        SetBusyState(False, Format('Concluido em %d ms (%.1f img/s).',
          [S.ElapsedMs, Throughput]));
      memLog.Lines.Add(StringOfChar('-', 72));
    end;
  finally
    Dispose(Msg);
  end;
end;

procedure TfrmPipelineMain.btnSelectDirClick(Sender: TObject);
begin
  if dlgSelectDir.Execute then
    edtInputDir.Text := dlgSelectDir.FileName;
end;

procedure TfrmPipelineMain.btnGenerateSamplesClick(Sender: TObject);
begin
  if FBusy then
    Exit;
  CleanupFinishedJobs;
  FCTS.Reset;
  pbPipeline.Position := 0;
  SetBusyState(True, 'Gerando 24 imagens sinteticas PNG (640x480)...');
  memLog.Lines.Add('Gerando 24 imagens de teste em: ' + edtInputDir.Text);

  FGenerator := TSampleGeneratorThread.Create(edtInputDir.Text, 24, 640, 480,
    FCTS.Token, @OnGeneratorProgress);
  FGenerator.Start;
end;

procedure TfrmPipelineMain.btnStartClick(Sender: TObject);
var
  InDir, OutDir: string;
begin
  if FBusy then
    Exit;
  InDir := Trim(edtInputDir.Text);
  if (InDir = '') or (not DirectoryExists(InDir)) then
  begin
    ShowMessage('Pasta de entrada nao existe. Clique em "Gerar 24 Imagens".');
    Exit;
  end;

  CleanupFinishedJobs;
  FCTS.Reset;
  pbPipeline.Position := 0;
  OutDir := IncludeTrailingPathDelimiter(InDir) + 'saida_processada';

  SetBusyState(True, Format('Processando com %d workers (fila=%d)...',
    [seWorkers.Value, seQueueCap.Value]));

  FPipeline := TBatchImagePipeline.Create(
    InDir, OutDir,
    TImageFilterKind(Max(0, cbFilter.ItemIndex)),
    seWorkers.Value,
    seQueueCap.Value,
    FCTS.Token,
    @OnPipelineProgress);
  FPipeline.Start;
end;

procedure TfrmPipelineMain.btnCancelClick(Sender: TObject);
begin
  if not FBusy then
    Exit;
  lblStatus.Caption := 'Status: Cancelando cooperativamente...';
  memLog.Lines.Add('>> Solicitacao de cancelamento enviada ao TokenSource.');
  FCTS.Cancel('Cancelado pelo usuario');
end;

end.
