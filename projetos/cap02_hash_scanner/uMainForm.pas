unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, ComCtrls, uSha256, uHashWorker;

type
  { TfrmHashScanner }
  TfrmHashScanner = class(TForm)
    btnBrowse: TButton;
    btnCancel: TButton;
    btnSelfTest: TButton;
    btnStart: TButton;
    chkSimulateFatal: TCheckBox;
    chkSubdirs: TCheckBox;
    dlgSelectDir: TSelectDirectoryDialog;
    edtDirectory: TEdit;
    lblDir: TLabel;
    lblStatus: TLabel;
    lblSummary: TLabel;
    lblSysInfo: TLabel;
    lvResults: TListView;
    pbScan: TProgressBar;
    pnlBottom: TPanel;
    pnlTop: TPanel;
    procedure btnBrowseClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnSelfTestClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FWorker: TDirectoryHashThread;
    FClosing: Boolean;
    procedure SetScanningUI(ARunning: Boolean);
    procedure HandlePhase(const APhaseMsg: string; ATotalFiles: Integer);
    procedure HandleFileDone(const AItem: THashFileResult;
      AIndex, ATotal: Integer);
    procedure HandleWorkerTerminate(Sender: TObject);
    procedure DeferredFreeWorker(Data: PtrInt);
    procedure StopAndFreeWorker;
  end;

var
  frmHashScanner: TfrmHashScanner;

implementation

{$R *.lfm}

procedure TfrmHashScanner.FormCreate(Sender: TObject);
var
  HeapStatus: string;
begin
  FClosing := False;
  edtDirectory.Text := ExtractFileDir(ParamStr(0));

  {$IF DECLARED(UseHeapTrace)}
  if UseHeapTrace then
    HeapStatus := 'ATIVO (-gh)'
  else
    HeapStatus := 'INATIVO';
  {$ELSE}
  HeapStatus := 'DESLIGADO';
  {$ENDIF}

  lblSysInfo.Caption := Format('CPUs: %d | MainTID: %d | HeapTrc: %s',
    [TThread.ProcessorCount, PtrUInt(MainThreadID), HeapStatus]);
end;

procedure TfrmHashScanner.FormCloseQuery(Sender: TObject;
  var CanClose: Boolean);
begin
  if Assigned(FWorker) and (not FWorker.Finished) then
  begin
    FClosing := True;
    lblStatus.Caption := 'Cancelando varredura com seguranca...';
    btnCancel.Enabled := False;
    btnStart.Enabled := False;
    Application.ProcessMessages;
    StopAndFreeWorker;
  end
  else
  begin
    FClosing := True;
    StopAndFreeWorker;
  end;
  CanClose := True;
end;

procedure TfrmHashScanner.FormDestroy(Sender: TObject);
begin
  FClosing := True;
  StopAndFreeWorker;
end;

procedure TfrmHashScanner.StopAndFreeWorker;
begin
  if Assigned(FWorker) then
  begin
    FWorker.Terminate;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

procedure TfrmHashScanner.SetScanningUI(ARunning: Boolean);
begin
  btnStart.Enabled := not ARunning;
  btnBrowse.Enabled := not ARunning;
  edtDirectory.Enabled := not ARunning;
  chkSubdirs.Enabled := not ARunning;
  chkSimulateFatal.Enabled := not ARunning;
  btnCancel.Enabled := ARunning;
end;

procedure TfrmHashScanner.btnBrowseClick(Sender: TObject);
begin
  dlgSelectDir.FileName := edtDirectory.Text;
  if dlgSelectDir.Execute then
    edtDirectory.Text := dlgSelectDir.FileName;
end;

procedure TfrmHashScanner.btnSelfTestClick(Sender: TObject);
begin
  if SHA256SelfTest then
    ShowMessage('Autoteste SHA-256 (vetores NIST FIPS 180-4): OK!')
  else
    MessageDlg('Falha no autoteste SHA-256!', mtError, [mbOK], 0);
end;

procedure TfrmHashScanner.btnStartClick(Sender: TObject);
var
  TargetDir: string;
begin
  TargetDir := Trim(edtDirectory.Text);
  if not DirectoryExists(TargetDir) then
  begin
    MessageDlg('Diretorio invalido: ' + TargetDir, mtWarning, [mbOK], 0);
    Exit;
  end;

  if Assigned(FWorker) then
    StopAndFreeWorker;

  lvResults.Items.Clear;
  pbScan.Position := 0;
  pbScan.Max := 100;
  lblSummary.Caption := 'Varredura em andamento...';
  SetScanningUI(True);

  { Padrao seguro: Create(True) -> configurar eventos -> Start }
  FWorker := TDirectoryHashThread.Create(
    TargetDir, chkSubdirs.Checked, chkSimulateFatal.Checked);
  FWorker.OnPhase := @HandlePhase;
  FWorker.OnFileDone := @HandleFileDone;
  FWorker.OnTerminate := @HandleWorkerTerminate;
  FWorker.Start;
end;

procedure TfrmHashScanner.btnCancelClick(Sender: TObject);
begin
  if Assigned(FWorker) then
  begin
    btnCancel.Enabled := False;
    lblStatus.Caption := 'Solicitando cancelamento cooperativo...';
    FWorker.Terminate;
  end;
end;

procedure TfrmHashScanner.HandlePhase(const APhaseMsg: string;
  ATotalFiles: Integer);
begin
  if FClosing then
    Exit;
  lblStatus.Caption := APhaseMsg;
  if ATotalFiles > 0 then
    pbScan.Max := ATotalFiles;
end;

procedure TfrmHashScanner.HandleFileDone(const AItem: THashFileResult;
  AIndex, ATotal: Integer);
var
  LI: TListItem;
begin
  if FClosing then
    Exit;

  LI := lvResults.Items.Add;
  LI.Caption := ExtractRelativePath(
    IncludeTrailingPathDelimiter(edtDirectory.Text), AItem.FilePath);
  LI.SubItems.Add(IntToStr(AItem.FileSize));
  if AItem.ErrorMsg = '' then
  begin
    LI.SubItems.Add(AItem.HashHex);
    LI.SubItems.Add(IntToStr(AItem.DurationMs));
    LI.SubItems.Add('OK');
  end
  else
  begin
    LI.SubItems.Add('-');
    LI.SubItems.Add(IntToStr(AItem.DurationMs));
    LI.SubItems.Add(AItem.ErrorMsg);
  end;

  pbScan.Position := AIndex;
  lblStatus.Caption := Format('Processados %d de %d arquivo(s)...',
    [AIndex, ATotal]);
end;

procedure TfrmHashScanner.HandleWorkerTerminate(Sender: TObject);
var
  ExObj: TObject;
  ThroughputMBs: Double;
  StatusStr: string;
begin
  if FClosing or (Sender <> FWorker) then
    Exit;

  SetScanningUI(False);

  if FWorker.ElapsedMs > 0 then
    ThroughputMBs := (FWorker.TotalBytes / (1024.0 * 1024.0)) /
                     (FWorker.ElapsedMs / 1000.0)
  else
    ThroughputMBs := 0.0;

  { Verificacao obrigatoria de FatalException antes de ler resultados }
  ExObj := FWorker.FatalException;
  if Assigned(ExObj) then
  begin
    if ExObj is Exception then
      StatusStr := Format('ERRO FATAL (%s): %s',
        [ExObj.ClassName, Exception(ExObj).Message])
    else
      StatusStr := 'ERRO FATAL desconhecido: ' + ExObj.ClassName;

    lblStatus.Caption := StatusStr;
    lblSummary.Caption := Format(
      'Abortado por FatalException | Arq: %d/%d | ReturnValue=%d',
      [FWorker.ProcessedFiles, FWorker.TotalFiles, FWorker.ReturnValue]);
    MessageDlg(StatusStr, mtError, [mbOK], 0);
  end
  else if FWorker.WasCancelled then
  begin
    lblStatus.Caption := 'Varredura cancelada de forma graciosa.';
    lblSummary.Caption := Format(
      'Cancelado: %d/%d arquivos | %.2f MB em %d ms | Ret=%d',
      [FWorker.ProcessedFiles, FWorker.TotalFiles,
       FWorker.TotalBytes / (1024.0 * 1024.0),
       FWorker.ElapsedMs, FWorker.ReturnValue]);
  end
  else
  begin
    lblStatus.Caption := 'Varredura concluida com sucesso.';
    lblSummary.Caption := Format(
      'Concluido: %d arquivos | %.2f MB em %d ms (%.1f MB/s) | Ret=%d',
      [FWorker.ProcessedFiles,
       FWorker.TotalBytes / (1024.0 * 1024.0),
       FWorker.ElapsedMs, ThroughputMBs, FWorker.ReturnValue]);
  end;

  { Nunca chame Free ou WaitFor diretamente dentro de OnTerminate! }
  Application.QueueAsyncCall(@DeferredFreeWorker, PtrInt(FWorker));
end;

procedure TfrmHashScanner.DeferredFreeWorker(Data: PtrInt);
begin
  if Assigned(FWorker) and (PtrInt(FWorker) = Data) then
  begin
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

end.
