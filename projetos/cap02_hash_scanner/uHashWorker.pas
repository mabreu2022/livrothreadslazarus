unit uHashWorker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uSha256;

const
  SCAN_RET_OK = 0;
  SCAN_RET_CANCELLED = 1;
  SCAN_RET_FATAL = 2;

type
  THashFileResult = record
    FilePath: string;
    FileSize: Int64;
    HashHex: string;
    DurationMs: QWord;
    ErrorMsg: string;
  end;

  THashPhaseEvent = procedure(const APhaseMsg: string;
    ATotalFiles: Integer) of object;
  THashFileDoneEvent = procedure(const AItem: THashFileResult;
    AIndex, ATotal: Integer) of object;

  { TDirectoryHashThread }
  TDirectoryHashThread = class(TThread)
  private
    FRootDir: string;
    FIncludeSubdirs: Boolean;
    FSimulateFatalErr: Boolean;
    FTotalFiles: Integer;
    FProcessedFiles: Integer;
    FTotalBytes: Int64;
    FElapsedMs: QWord;
    FWasCancelled: Boolean;
    { Snapshots sincronizados para entrega segura via Synchronize }
    FSyncPhaseMsg: string;
    FSyncItem: THashFileResult;
    FSyncIndex: Integer;
    FOnPhase: THashPhaseEvent;
    FOnFileDone: THashFileDoneEvent;
    function CheckAborted: Boolean;
    procedure CollectFiles(const ADir: string; AList: TStringList);
    procedure NotifyPhaseUI;
    procedure NotifyFileDoneUI;
    procedure EmitPhase(const AMsg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const ARootDir: string;
      AIncludeSubdirs, ASimulateFatalErr: Boolean);
    property OnPhase: THashPhaseEvent read FOnPhase write FOnPhase;
    property OnFileDone: THashFileDoneEvent
      read FOnFileDone write FOnFileDone;
    property TotalFiles: Integer read FTotalFiles;
    property ProcessedFiles: Integer read FProcessedFiles;
    property TotalBytes: Int64 read FTotalBytes;
    property ElapsedMs: QWord read FElapsedMs;
    property WasCancelled: Boolean read FWasCancelled;
    property ReturnValue;
  end;

implementation

{ TDirectoryHashThread }

constructor TDirectoryHashThread.Create(const ARootDir: string;
  AIncludeSubdirs, ASimulateFatalErr: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRootDir := IncludeTrailingPathDelimiter(ARootDir);
  FIncludeSubdirs := AIncludeSubdirs;
  FSimulateFatalErr := ASimulateFatalErr;
  ReturnValue := SCAN_RET_OK;
end;

function TDirectoryHashThread.CheckAborted: Boolean;
begin
  Result := Terminated;
end;

procedure TDirectoryHashThread.NotifyPhaseUI;
begin
  if Assigned(FOnPhase) then
    FOnPhase(FSyncPhaseMsg, FTotalFiles);
end;

procedure TDirectoryHashThread.NotifyFileDoneUI;
begin
  if Assigned(FOnFileDone) then
    FOnFileDone(FSyncItem, FSyncIndex, FTotalFiles);
end;

procedure TDirectoryHashThread.EmitPhase(const AMsg: string);
begin
  FSyncPhaseMsg := AMsg;
  Synchronize(@NotifyPhaseUI);
end;

procedure TDirectoryHashThread.CollectFiles(const ADir: string;
  AList: TStringList);
var
  SR: TSearchRec;
  FullPath: string;
begin
  if Terminated then
    Exit;

  if FindFirst(ADir + AllFilesMask, faAnyFile, SR) = 0 then
  try
    repeat
      if Terminated then
        Break;
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;

      FullPath := ADir + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        {$PUSH}{$WARN 5044 OFF}
        if FIncludeSubdirs and ((SR.Attr and faSymLink) = 0) then
        {$POP}
          CollectFiles(IncludeTrailingPathDelimiter(FullPath), AList);
      end
      else
        AList.Add(FullPath);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure TDirectoryHashThread.Execute;
var
  Files: TStringList;
  I: Integer;
  T0, FileT0: QWord;
  Item: THashFileResult;
  BytesRead: Int64;
  DigestHex: string;
begin
  { Limite de 15 bytes no Linux (TASK_COMM_LEN = 16 com #0) }
  NameThreadForDebugging('HashScannerWrk');
  T0 := GetTickCount64;
  Files := TStringList.Create;
  try
    EmitPhase('Enumerando arquivos em ' + FRootDir + '...');
    CollectFiles(FRootDir, Files);
    FTotalFiles := Files.Count;

    if Terminated then
    begin
      FWasCancelled := True;
      ReturnValue := SCAN_RET_CANCELLED;
      Exit;
    end;

    EmitPhase(Format('Calculando SHA-256 de %d arquivo(s)...',
      [FTotalFiles]));

    for I := 0 to Files.Count - 1 do
    begin
      if Terminated then
      begin
        FWasCancelled := True;
        ReturnValue := SCAN_RET_CANCELLED;
        Break;
      end;

      { Demonstracao didatica de excecao nao tratada -> FatalException }
      if FSimulateFatalErr and (I = 2) then
      begin
        ReturnValue := SCAN_RET_FATAL;
        raise EInvalidOperation.CreateFmt(
          'Erro fatal simulado no arquivo #%d (%s)',
          [I + 1, ExtractFileName(Files[I])]);
      end;

      Item.FilePath := Files[I];
      Item.FileSize := 0;
      Item.HashHex := '';
      Item.ErrorMsg := '';
      FileT0 := GetTickCount64;

      try
        if ComputeFileSHA256(Files[I], @CheckAborted, BytesRead,
          DigestHex) then
        begin
          Item.FileSize := BytesRead;
          Item.HashHex := DigestHex;
          Inc(FTotalBytes, BytesRead);
        end
        else
        begin
          FWasCancelled := True;
          ReturnValue := SCAN_RET_CANCELLED;
          Break;
        end;
      except
        on E: Exception do
          Item.ErrorMsg := E.ClassName + ': ' + E.Message;
      end;

      Item.DurationMs := GetTickCount64 - FileT0;
      Inc(FProcessedFiles);

      FSyncItem := Item;
      FSyncIndex := I + 1;
      Synchronize(@NotifyFileDoneUI);
    end;
  finally
    FElapsedMs := GetTickCount64 - T0;
    Files.Free;
  end;
end;

end.
