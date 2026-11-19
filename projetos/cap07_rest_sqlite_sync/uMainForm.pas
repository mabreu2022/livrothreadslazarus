unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ComCtrls, ExtCtrls, Spin, DB, BufDataset, DBGrids,
  uSyncTypes, uSyncPrimitives, uSqliteRepo, uRestSyncWorker;

type
  { TMainForm }
  TMainForm = class(TForm)
    pnlTop: TPanel;
    lblBaseUrl: TLabel;
    edtBaseUrl: TEdit;
    lblDbPath: TLabel;
    edtDbPath: TEdit;
    lblConcurrency: TLabel;
    seConcurrency: TSpinEdit;
    btnStart: TButton;
    btnCancel: TButton;
    btnLoadSnapshot: TButton;
    pnlProgress: TPanel;
    pbGlobal: TProgressBar;
    lblStatus: TLabel;
    lblTransfer: TLabel;
    pcViews: TPageControl;
    tsListView: TTabSheet;
    tsDbGrid: TTabSheet;
    lvPosts: TListView;
    dbgPosts: TDBGrid;
    SplitterBottom: TSplitter;
    memLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnLoadSnapshotClick(Sender: TObject);
  private
    FCancel: TSyncCancellation;
    FRunner: TSyncBatchRunner;
    FPendingPackets: TThreadList;
    FBufDataset: TBufDataset;
    FDataSource: TDataSource;
    FClosing: LongInt;
    FClosePending: Boolean;
    FTotalJobs: Integer;
    FCompletedJobs: Integer;
    procedure InitListViewColumns;
    procedure InitLocalBufDataset;
    procedure SetRunningUiState(ARunning: Boolean);
    procedure AppendLogLine(const AText: string);
    procedure PopulateUiFromSnapshot(const ASnapshot: TPostDTOArray);
    procedure EnqueuePacketFromWorker(APacket: PSyncUiPacket);
    procedure ProcessPacketAsync(AData: PtrInt);
    procedure CancelRunningBatch;
    function BuildDefaultJobs: TSyncJobArray;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FCancel := TSyncCancellation.Create;
  FPendingPackets := TThreadList.Create;
  FRunner := nil;
  FClosing := 0;
  FClosePending := False;

  edtBaseUrl.Text := 'https://jsonplaceholder.typicode.com/posts';
  edtDbPath.Text :=
    IncludeTrailingPathDelimiter(ExtractFilePath(Application.ExeName)) +
    'sync_cache.sqlite3';
  seConcurrency.Value := 3;

  InitListViewColumns;
  InitLocalBufDataset;
  SetRunningUiState(False);
  lblStatus.Caption := 'Pronto para sincronizar endpoints REST -> SQLite WAL.';
  lblTransfer.Caption := 'Transferencia: 0 bytes';
end;

procedure TMainForm.InitListViewColumns;
var
  Col: TListColumn;
begin
  lvPosts.ViewStyle := vsReport;
  lvPosts.ReadOnly := True;
  lvPosts.RowSelect := True;
  lvPosts.Columns.Clear;

  Col := lvPosts.Columns.Add;
  Col.Caption := 'ID';
  Col.Width := 65;

  Col := lvPosts.Columns.Add;
  Col.Caption := 'User';
  Col.Width := 65;

  Col := lvPosts.Columns.Add;
  Col.Caption := 'Titulo';
  Col.Width := 340;

  Col := lvPosts.Columns.Add;
  Col.Caption := 'Latencia (ms)';
  Col.Width := 110;

  Col := lvPosts.Columns.Add;
  Col.Caption := 'Sincronizado em';
  Col.Width := 150;
end;

procedure TMainForm.InitLocalBufDataset;
begin
  { Dataset 100% residente na Main Thread — nunca tocado por workers }
  FBufDataset := TBufDataset.Create(Self);
  FBufDataset.FieldDefs.Add('external_id', ftInteger);
  FBufDataset.FieldDefs.Add('user_id', ftInteger);
  FBufDataset.FieldDefs.Add('title', ftString, 200);
  FBufDataset.FieldDefs.Add('latency_ms', ftLargeint);
  FBufDataset.FieldDefs.Add('synced_at', ftDateTime);
  FBufDataset.CreateDataset;

  FDataSource := TDataSource.Create(Self);
  FDataSource.DataSet := FBufDataset;
  dbgPosts.DataSource := FDataSource;
  dbgPosts.ReadOnly := True;
  dbgPosts.Options := dbgPosts.Options + [dgRowSelect, dgAlwaysShowSelection];
end;

procedure TMainForm.SetRunningUiState(ARunning: Boolean);
begin
  btnStart.Enabled := not ARunning;
  btnLoadSnapshot.Enabled := not ARunning;
  btnCancel.Enabled := ARunning;
  edtBaseUrl.Enabled := not ARunning;
  edtDbPath.Enabled := not ARunning;
  seConcurrency.Enabled := not ARunning;
end;

procedure TMainForm.AppendLogLine(const AText: string);
const
  MAX_LOG_LINES = 300;
begin
  memLog.Lines.BeginUpdate;
  try
    if memLog.Lines.Count >= MAX_LOG_LINES then
      memLog.Lines.Delete(0);
    memLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + ' | ' + AText);
  finally
    memLog.Lines.EndUpdate;
  end;
end;

procedure TMainForm.PopulateUiFromSnapshot(const ASnapshot: TPostDTOArray);
var
  I: Integer;
  Item: TListItem;
begin
  { 1. Atualiza TListView a partir do snapshot imutavel de DTOs }
  lvPosts.Items.BeginUpdate;
  try
    lvPosts.Items.Clear;
    for I := 0 to High(ASnapshot) do
    begin
      Item := lvPosts.Items.Add;
      Item.Caption := IntToStr(ASnapshot[I].ExternalId);
      Item.SubItems.Add(IntToStr(ASnapshot[I].UserId));
      Item.SubItems.Add(ASnapshot[I].Title);
      Item.SubItems.Add(IntToStr(ASnapshot[I].LatencyMs));
      Item.SubItems.Add(
        FormatDateTime('yyyy-mm-dd hh:nn:ss', ASnapshot[I].SyncedAt));
    end;
  finally
    lvPosts.Items.EndUpdate;
  end;

  { 2. Copia os mesmos DTOs para TBufDataset local da Main Thread }
  FBufDataset.DisableControls;
  try
    FBufDataset.Close;
    FBufDataset.CreateDataset;
    for I := 0 to High(ASnapshot) do
    begin
      FBufDataset.Append;
      FBufDataset.FieldByName('external_id').AsInteger :=
        ASnapshot[I].ExternalId;
      FBufDataset.FieldByName('user_id').AsInteger := ASnapshot[I].UserId;
      FBufDataset.FieldByName('title').AsString :=
        Copy(ASnapshot[I].Title, 1, 200);
      FBufDataset.FieldByName('latency_ms').AsLargeInt :=
        Int64(ASnapshot[I].LatencyMs);
      FBufDataset.FieldByName('synced_at').AsDateTime :=
        ASnapshot[I].SyncedAt;
      FBufDataset.Post;
    end;
    if not FBufDataset.IsEmpty then
      FBufDataset.First;
  finally
    FBufDataset.EnableControls;
  end;
end;

procedure TMainForm.EnqueuePacketFromWorker(APacket: PSyncUiPacket);
begin
  if InterlockedCompareExchange(FClosing, 0, 0) <> 0 then
  begin
    DisposeSyncPacket(APacket);
    Exit;
  end;

  FPendingPackets.Add(APacket);
  Application.QueueAsyncCall(@ProcessPacketAsync, PtrInt(APacket));
end;

procedure TMainForm.ProcessPacketAsync(AData: PtrInt);
var
  Pkg: PSyncUiPacket;
begin
  Pkg := PSyncUiPacket(AData);
  if Pkg = nil then
    Exit;

  FPendingPackets.Remove(Pkg);
  try
    case Pkg^.Kind of
      sekLog:
        AppendLogLine(Pkg^.MessageText);

      sekProgress:
        begin
          if Pkg^.ContentLength > 0 then
            lblTransfer.Caption := Format(
              'Job #%d (%s): %d / %d bytes',
              [Pkg^.JobIndex, Pkg^.MessageText,
               Pkg^.BytesReceived, Pkg^.ContentLength])
          else
            lblTransfer.Caption := Format(
              'Job #%d (%s): %d bytes recebidos',
              [Pkg^.JobIndex, Pkg^.MessageText, Pkg^.BytesReceived]);
        end;

      sekJobDone:
        begin
          Inc(FCompletedJobs);
          pbGlobal.Position := FCompletedJobs;
          lblStatus.Caption := Format(
            'Progresso: %d / %d endpoints concluidos',
            [FCompletedJobs, FTotalJobs]);
        end;

      sekBatchFinished:
        begin
          if Assigned(FRunner) then
          begin
            FRunner.WaitFor;
            FreeAndNil(FRunner);
          end;
          PopulateUiFromSnapshot(Pkg^.Snapshot);
          lblStatus.Caption := Pkg^.MessageText;
          AppendLogLine('=== ' + Pkg^.MessageText + ' ===');
          SetRunningUiState(False);
          if FClosePending then
            Close;
        end;
    end;
  finally
    DisposeSyncPacket(Pkg);
  end;
end;

function TMainForm.BuildDefaultJobs: TSyncJobArray;
const
  USER_BATCH_COUNT = 8;
var
  I: Integer;
  BaseUrl: string;
begin
  Result := nil;
  BaseUrl := Trim(edtBaseUrl.Text);
  SetLength(Result, USER_BATCH_COUNT);
  for I := 0 to USER_BATCH_COUNT - 1 do
  begin
    Result[I].JobIndex := I + 1;
    Result[I].LabelText := Format('userId=%d', [I + 1]);
    Result[I].EndpointUrl := Format('%s?userId=%d', [BaseUrl, I + 1]);
  end;
end;

procedure TMainForm.btnStartClick(Sender: TObject);
var
  Jobs: TSyncJobArray;
begin
  if Assigned(FRunner) then
    Exit;

  Jobs := BuildDefaultJobs;
  FTotalJobs := Length(Jobs);
  FCompletedJobs := 0;
  pbGlobal.Min := 0;
  pbGlobal.Max := FTotalJobs;
  pbGlobal.Position := 0;

  FCancel.Reset;
  SetRunningUiState(True);
  lblStatus.Caption := Format(
    'Sincronizando %d endpoints (max %d simultaneos)...',
    [FTotalJobs, seConcurrency.Value]);
  AppendLogLine('Iniciando lote REST -> SQLite WAL: ' + edtDbPath.Text);

  FRunner := TSyncBatchRunner.Create(
    Jobs,
    Trim(edtDbPath.Text),
    seConcurrency.Value,
    FCancel,
    @EnqueuePacketFromWorker
  );
  FRunner.Start;
end;

procedure TMainForm.CancelRunningBatch;
begin
  if not Assigned(FRunner) then
    Exit;
  btnCancel.Enabled := False;
  lblStatus.Caption := 'Cancelando requisicoes HTTP ativas...';
  AppendLogLine('Solicitado cancelamento cooperativo + HTTP.Terminate');
  FCancel.Cancel;
  FRunner.AbortAllHttp;
end;

procedure TMainForm.btnCancelClick(Sender: TObject);
begin
  CancelRunningBatch;
end;

procedure TMainForm.btnLoadSnapshotClick(Sender: TObject);
var
  Snapshot: TPostDTOArray;
begin
  try
    Snapshot := LoadSnapshotFromDatabase(Trim(edtDbPath.Text), 500);
    PopulateUiFromSnapshot(Snapshot);
    lblStatus.Caption := Format(
      'Snapshot local carregado: %d registros.', [Length(Snapshot)]);
  except
    on E: Exception do
      ShowMessage('Erro ao ler snapshot SQLite: ' + E.Message);
  end;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if Assigned(FRunner) then
  begin
    CanClose := False;
    if not FClosePending then
    begin
      FClosePending := True;
      CancelRunningBatch;
    end;
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
var
  LockedList: TList;
  I: Integer;
begin
  InterlockedExchange(FClosing, 1);

  if Assigned(FRunner) then
  begin
    FCancel.Cancel;
    FRunner.AbortAllHttp;
    FRunner.WaitFor;
    FreeAndNil(FRunner);
  end;

  { Remove chamadas pendentes na fila da LCL e libera pacotes orfaos }
  Application.RemoveAsyncCalls(Self);
  LockedList := FPendingPackets.LockList;
  try
    for I := 0 to LockedList.Count - 1 do
      DisposeSyncPacket(PSyncUiPacket(LockedList[I]));
    LockedList.Clear;
  finally
    FPendingPackets.UnlockList;
  end;

  FreeAndNil(FPendingPackets);
  FreeAndNil(FCancel);
end;

end.
