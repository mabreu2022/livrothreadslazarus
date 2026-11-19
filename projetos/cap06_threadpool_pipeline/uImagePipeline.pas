unit uImagePipeline;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, ZStream, FPImage, FPReadPNG, FPWritePNG,
  FPReadBMP, FPWriteBMP, uCancellation, uBoundedQueue, uThreadPool;

type
  TImageFilterKind = (
    ifkSepia,
    ifkGrayscale,
    ifkBoxBlur7x7,
    ifkSepiaVignette
  );

  PImagePacket = ^TImagePacket;
  TImagePacket = record
    Index: Integer;
    SourcePath: string;
    DestPath: string;
    Image: TFPMemoryImage;
  end;

  TImagePacketQueue = specialize TBoundedThreadQueue<PImagePacket>;

  TPipelineStats = record
    TotalFiles: LongInt;
    ReadCount: LongInt;
    ProcessedCount: LongInt;
    SavedCount: LongInt;
    ErrorCount: LongInt;
    Queue1Count: LongInt;
    Queue2Count: LongInt;
    BackpressureEvents: Int64;
    ElapsedMs: QWord;
    LastSavedFile: string;
    LastLogLine: string;
    Finished: Boolean;
    Cancelled: Boolean;
  end;

  TPipelineProgressEvent = procedure(const AStats: TPipelineStats) of object;

  { Motor completo de processamento em lote em 3 estagios com ThreadPool }
  TBatchImagePipeline = class(TThread)
  private
    FInputDir: string;
    FOutputDir: string;
    FFilter: TImageFilterKind;
    FWorkerCount: Integer;
    FQueueCapacity: Integer;
    FToken: ICancellationToken;
    FOnProgress: TPipelineProgressEvent;

    FQueue1: TImagePacketQueue;
    FQueue2: TImagePacketQueue;
    FTotalFiles: LongInt;
    FReadCount: LongInt;
    FProcessedCount: LongInt;
    FSavedCount: LongInt;
    FErrorCount: LongInt;
    FStartTick: QWord;
    FLastEmitTick: QWord;
    FLockEmit: TRTLCriticalSection;

    procedure EmitProgress(const ALogLine: string;
      const ALastFile: string = ''; AForce: Boolean = False;
      AFinished: Boolean = False);
    procedure LoadImageFile(const AFileName: string; AImg: TFPMemoryImage);
    procedure SaveImageFile(const AFileName: string; AImg: TFPMemoryImage);
    procedure ApplyFilter(APacket: PImagePacket;
      const AToken: ICancellationToken);
    procedure ApplySepia(AImg: TFPMemoryImage;
      const AToken: ICancellationToken);
    procedure ApplyGrayscale(AImg: TFPMemoryImage;
      const AToken: ICancellationToken);
    procedure ApplyBoxBlur7x7(APacket: PImagePacket;
      const AToken: ICancellationToken);
    procedure ApplySepiaVignette(AImg: TFPMemoryImage;
      const AToken: ICancellationToken);
    procedure Stage2WorkerTask(AData: Pointer;
      const AToken: ICancellationToken);
    procedure HandlePoolError(const AErrorClass, AErrorMsg: string;
      AData: Pointer);
    procedure DrainAndFreeQueue(AQueue: TImagePacketQueue);
    procedure FreePacket(var APacket: PImagePacket);
  protected
    procedure Execute; override;
  public
    constructor Create(const AInputDir, AOutputDir: string;
      AFilter: TImageFilterKind; AWorkerCount, AQueueCapacity: Integer;
      const AToken: ICancellationToken; AOnProgress: TPipelineProgressEvent);
    destructor Destroy; override;
  end;

  { Thread auxiliar para gerar lote sintetico de imagens PNG de teste }
  TSampleGeneratorThread = class(TThread)
  private
    FOutputDir: string;
    FCount: Integer;
    FWidth: Integer;
    FHeight: Integer;
    FToken: ICancellationToken;
    FOnProgress: TPipelineProgressEvent;
    FGenerated: LongInt;
    FStartTick: QWord;
    procedure GenerateOneTask(AData: Pointer;
      const AToken: ICancellationToken);
  protected
    procedure Execute; override;
  public
    constructor Create(const AOutputDir: string; ACount, AWidth,
      AHeight: Integer; const AToken: ICancellationToken;
      AOnProgress: TPipelineProgressEvent);
  end;

implementation

type
  TStage1ReaderThread = class(TThread)
  private
    FOwner: TBatchImagePipeline;
    FFiles: TStringList;
    FOutputDir: string;
    FQueue1: TImagePacketQueue;
    FToken: ICancellationToken;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TBatchImagePipeline; AFiles: TStringList;
      const AOutputDir: string; AQueue1: TImagePacketQueue;
      const AToken: ICancellationToken);
  end;

  TStage3SaverThread = class(TThread)
  private
    FOwner: TBatchImagePipeline;
    FQueue2: TImagePacketQueue;
    FToken: ICancellationToken;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TBatchImagePipeline; AQueue2: TImagePacketQueue;
      const AToken: ICancellationToken);
  end;

function ClampWord(AVal: Integer): Word; inline;
begin
  if AVal < 0 then
    Result := 0
  else if AVal > 65535 then
    Result := 65535
  else
    Result := Word(AVal);
end;

{ TStage1ReaderThread }

constructor TStage1ReaderThread.Create(AOwner: TBatchImagePipeline;
  AFiles: TStringList; const AOutputDir: string; AQueue1: TImagePacketQueue;
  const AToken: ICancellationToken);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FFiles := AFiles;
  FOutputDir := AOutputDir;
  FQueue1 := AQueue1;
  FToken := AToken;
end;

procedure TStage1ReaderThread.Execute;
var
  I: Integer;
  Pkt: PImagePacket;
  SrcFile, OutName: string;
begin
  try
    for I := 0 to FFiles.Count - 1 do
    begin
      if FToken.IsCancelled then
        Break;

      SrcFile := FFiles[I];
      OutName := IncludeTrailingPathDelimiter(FOutputDir) +
        ChangeFileExt(ExtractFileName(SrcFile), '_out.png');

      New(Pkt);
      Pkt^.Index := I + 1;
      Pkt^.SourcePath := SrcFile;
      Pkt^.DestPath := OutName;
      Pkt^.Image := TFPMemoryImage.Create(0, 0);
      try
        FOwner.LoadImageFile(SrcFile, Pkt^.Image);
        InterlockedIncrement(FOwner.FReadCount);

        { Backpressure: bloqueia aqui se Queue1 atingir capacidade maxima }
        if not FQueue1.Enqueue(Pkt, FToken) then
        begin
          FOwner.FreePacket(Pkt);
          Break;
        end;
        Pkt := nil; { Propriedade transferida para a fila }
        FOwner.EmitProgress('', '', False, False);
      except
        on E: Exception do
        begin
          FOwner.FreePacket(Pkt);
          InterlockedIncrement(FOwner.FErrorCount);
          FOwner.EmitProgress(Format('[ERRO Estagio 1] %s: %s',
            [ExtractFileName(SrcFile), E.Message]), '', True, False);
        end;
      end;
    end;
  finally
    FQueue1.CompleteAdding;
  end;
end;

{ TStage3SaverThread }

constructor TStage3SaverThread.Create(AOwner: TBatchImagePipeline;
  AQueue2: TImagePacketQueue; const AToken: ICancellationToken);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FQueue2 := AQueue2;
  FToken := AToken;
end;

procedure TStage3SaverThread.Execute;
var
  Pkt: PImagePacket;
  SavedPath: string;
begin
  while FQueue2.TryDequeue(Pkt, FToken) do
  begin
    try
      try
        if not FToken.IsCancelled then
        begin
          FOwner.SaveImageFile(Pkt^.DestPath, Pkt^.Image);
          SavedPath := Pkt^.DestPath;
          InterlockedIncrement(FOwner.FSavedCount);
          FOwner.EmitProgress('', SavedPath, False, False);
        end;
      except
        on E: Exception do
        begin
          InterlockedIncrement(FOwner.FErrorCount);
          FOwner.EmitProgress(Format('[ERRO Estagio 3] %s: %s',
            [ExtractFileName(Pkt^.DestPath), E.Message]), '', True, False);
        end;
      end;
    finally
      FOwner.FreePacket(Pkt);
    end;
  end;
end;

{ TBatchImagePipeline }

constructor TBatchImagePipeline.Create(const AInputDir, AOutputDir: string;
  AFilter: TImageFilterKind; AWorkerCount, AQueueCapacity: Integer;
  const AToken: ICancellationToken; AOnProgress: TPipelineProgressEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FInputDir := IncludeTrailingPathDelimiter(AInputDir);
  FOutputDir := IncludeTrailingPathDelimiter(AOutputDir);
  FFilter := AFilter;
  FWorkerCount := Max(1, AWorkerCount);
  FQueueCapacity := Max(1, AQueueCapacity);
  FToken := AToken;
  FOnProgress := AOnProgress;
  FQueue1 := nil;
  FQueue2 := nil;
  FTotalFiles := 0;
  FReadCount := 0;
  FProcessedCount := 0;
  FSavedCount := 0;
  FErrorCount := 0;
  FLastEmitTick := 0;
  InitCriticalSection(FLockEmit);
end;

destructor TBatchImagePipeline.Destroy;
begin
  DoneCriticalSection(FLockEmit);
  inherited Destroy;
end;

procedure TBatchImagePipeline.FreePacket(var APacket: PImagePacket);
begin
  if APacket <> nil then
  begin
    FreeAndNil(APacket^.Image);
    Dispose(APacket);
    APacket := nil;
  end;
end;

procedure TBatchImagePipeline.DrainAndFreeQueue(AQueue: TImagePacketQueue);
var
  Pkt: PImagePacket;
begin
  if AQueue = nil then
    Exit;
  while AQueue.TryDequeueNoWait(Pkt) do
    FreePacket(Pkt);
end;

procedure TBatchImagePipeline.EmitProgress(const ALogLine: string;
  const ALastFile: string; AForce: Boolean; AFinished: Boolean);
var
  NowTick: QWord;
  Stats: TPipelineStats;
begin
  if not Assigned(FOnProgress) then
    Exit;

  EnterCriticalSection(FLockEmit);
  try
    NowTick := GetTickCount64;
    { Throttling: atualiza UI no maximo a cada 60 ms, exceto forcar/fim }
    if (not AForce) and (not AFinished) and
       ((NowTick - FLastEmitTick) < 60) then
      Exit;
    FLastEmitTick := NowTick;
  finally
    LeaveCriticalSection(FLockEmit);
  end;

  Stats.TotalFiles := FTotalFiles;
  Stats.ReadCount := InterlockedCompareExchange(FReadCount, 0, 0);
  Stats.ProcessedCount := InterlockedCompareExchange(FProcessedCount, 0, 0);
  Stats.SavedCount := InterlockedCompareExchange(FSavedCount, 0, 0);
  Stats.ErrorCount := InterlockedCompareExchange(FErrorCount, 0, 0);
  if Assigned(FQueue1) then
    Stats.Queue1Count := FQueue1.Count
  else
    Stats.Queue1Count := 0;
  if Assigned(FQueue2) then
    Stats.Queue2Count := FQueue2.Count
  else
    Stats.Queue2Count := 0;
  Stats.BackpressureEvents := 0;
  if Assigned(FQueue1) then
    Stats.BackpressureEvents := Stats.BackpressureEvents +
      FQueue1.BackpressureWaits;
  if Assigned(FQueue2) then
    Stats.BackpressureEvents := Stats.BackpressureEvents +
      FQueue2.BackpressureWaits;
  Stats.ElapsedMs := GetTickCount64 - FStartTick;
  Stats.LastSavedFile := ALastFile;
  Stats.LastLogLine := ALogLine;
  Stats.Finished := AFinished;
  Stats.Cancelled := Assigned(FToken) and FToken.IsCancelled;

  FOnProgress(Stats);
end;

procedure TBatchImagePipeline.LoadImageFile(const AFileName: string;
  AImg: TFPMemoryImage);
var
  Ext: string;
  Reader: TFPCustomImageReader;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  if Ext = '.png' then
    Reader := TFPReaderPNG.Create
  else if Ext = '.bmp' then
    Reader := TFPReaderBMP.Create
  else
    raise Exception.CreateFmt('Formato nao suportado: %s', [Ext]);

  try
    AImg.LoadFromFile(AFileName, Reader);
  finally
    Reader.Free;
  end;
end;

procedure TBatchImagePipeline.SaveImageFile(const AFileName: string;
  AImg: TFPMemoryImage);
var
  Writer: TFPWriterPNG;
begin
  Writer := TFPWriterPNG.Create;
  try
    Writer.UseAlpha := False;
    { clnone evita que compressao DEFLATE em 1 thread gargale o Estagio 3 }
    Writer.CompressionLevel := clnone;
    AImg.SaveToFile(AFileName, Writer);
  finally
    Writer.Free;
  end;
end;

procedure TBatchImagePipeline.ApplySepia(AImg: TFPMemoryImage;
  const AToken: ICancellationToken);
var
  X, Y: Integer;
  C: TFPColor;
  NR, NG, NB: Integer;
begin
  for Y := 0 to AImg.Height - 1 do
  begin
    if ((Y and 15) = 0) and AToken.IsCancelled then
      AToken.ThrowIfCancelled;
    for X := 0 to AImg.Width - 1 do
    begin
      C := AImg.Colors[X, Y];
      NR := (C.Red * 402 + C.Green * 787 + C.Blue * 194) shr 10;
      NG := (C.Red * 357 + C.Green * 702 + C.Blue * 172) shr 10;
      NB := (C.Red * 279 + C.Green * 547 + C.Blue * 134) shr 10;
      C.Red := ClampWord(NR);
      C.Green := ClampWord(NG);
      C.Blue := ClampWord(NB);
      AImg.Colors[X, Y] := C;
    end;
  end;
end;

procedure TBatchImagePipeline.ApplyGrayscale(AImg: TFPMemoryImage;
  const AToken: ICancellationToken);
var
  X, Y: Integer;
  C: TFPColor;
  Gray: Word;
begin
  for Y := 0 to AImg.Height - 1 do
  begin
    if ((Y and 15) = 0) and AToken.IsCancelled then
      AToken.ThrowIfCancelled;
    for X := 0 to AImg.Width - 1 do
    begin
      C := AImg.Colors[X, Y];
      { Luma Rec. 709: 0.2126 R + 0.7152 G + 0.0722 B }
      Gray := ClampWord((C.Red * 218 + C.Green * 732 + C.Blue * 74) shr 10);
      C.Red := Gray;
      C.Green := Gray;
      C.Blue := Gray;
      AImg.Colors[X, Y] := C;
    end;
  end;
end;

procedure TBatchImagePipeline.ApplyBoxBlur7x7(APacket: PImagePacket;
  const AToken: ICancellationToken);
var
  Src, Dst: TFPMemoryImage;
  W, H, X, Y, KX, KY, SX, SY: Integer;
  SumR, SumG, SumB: Int64;
  Count: Integer;
  C: TFPColor;
begin
  Src := APacket^.Image;
  W := Src.Width;
  H := Src.Height;
  Dst := TFPMemoryImage.Create(W, H);
  try
    for Y := 0 to H - 1 do
    begin
      if ((Y and 7) = 0) and AToken.IsCancelled then
        AToken.ThrowIfCancelled;
      for X := 0 to W - 1 do
      begin
        SumR := 0;
        SumG := 0;
        SumB := 0;
        Count := 0;
        for KY := -3 to 3 do
        begin
          SY := Y + KY;
          if (SY < 0) or (SY >= H) then
            Continue;
          for KX := -3 to 3 do
          begin
            SX := X + KX;
            if (SX < 0) or (SX >= W) then
              Continue;
            C := Src.Colors[SX, SY];
            Inc(SumR, C.Red);
            Inc(SumG, C.Green);
            Inc(SumB, C.Blue);
            Inc(Count);
          end;
        end;
        C.Red := Word(SumR div Count);
        C.Green := Word(SumG div Count);
        C.Blue := Word(SumB div Count);
        C.Alpha := 65535;
        Dst.Colors[X, Y] := C;
      end;
    end;
    APacket^.Image := Dst;
    Dst := nil;
    Src.Free;
  finally
    Dst.Free;
  end;
end;

procedure TBatchImagePipeline.ApplySepiaVignette(AImg: TFPMemoryImage;
  const AToken: ICancellationToken);
var
  X, Y, W, H: Integer;
  CX, CY, MaxDistSq, DX, DY, Factor: Double;
  C: TFPColor;
  NR, NG, NB: Integer;
begin
  W := AImg.Width;
  H := AImg.Height;
  CX := W * 0.5;
  CY := H * 0.5;
  MaxDistSq := CX * CX + CY * CY;
  if MaxDistSq < 1.0 then
    MaxDistSq := 1.0;

  for Y := 0 to H - 1 do
  begin
    if ((Y and 15) = 0) and AToken.IsCancelled then
      AToken.ThrowIfCancelled;
    DY := Y - CY;
    for X := 0 to W - 1 do
    begin
      DX := X - CX;
      Factor := 1.0 - 0.65 * ((DX * DX + DY * DY) / MaxDistSq);
      if Factor < 0.25 then
        Factor := 0.25;
      C := AImg.Colors[X, Y];
      NR := Round(((C.Red * 402 + C.Green * 787 + C.Blue * 194) shr 10) * Factor);
      NG := Round(((C.Red * 357 + C.Green * 702 + C.Blue * 172) shr 10) * Factor);
      NB := Round(((C.Red * 279 + C.Green * 547 + C.Blue * 134) shr 10) * Factor);
      C.Red := ClampWord(NR);
      C.Green := ClampWord(NG);
      C.Blue := ClampWord(NB);
      AImg.Colors[X, Y] := C;
    end;
  end;
end;

procedure TBatchImagePipeline.ApplyFilter(APacket: PImagePacket;
  const AToken: ICancellationToken);
begin
  case FFilter of
    ifkSepia:         ApplySepia(APacket^.Image, AToken);
    ifkGrayscale:     ApplyGrayscale(APacket^.Image, AToken);
    ifkBoxBlur7x7:    ApplyBoxBlur7x7(APacket, AToken);
    ifkSepiaVignette: ApplySepiaVignette(APacket^.Image, AToken);
  end;
end;

procedure TBatchImagePipeline.Stage2WorkerTask(AData: Pointer;
  const AToken: ICancellationToken);
var
  Pkt: PImagePacket;
begin
  if AData <> nil then ; { Parametro reservado }
  while FQueue1.TryDequeue(Pkt, AToken) do
  begin
    try
      ApplyFilter(Pkt, AToken);
      InterlockedIncrement(FProcessedCount);
      if not FQueue2.Enqueue(Pkt, AToken) then
      begin
        FreePacket(Pkt);
        Break;
      end;
      Pkt := nil; { Propriedade transferida para Estagio 3 }
      EmitProgress('', '', False, False);
    except
      on E: ECancellationRequested do
      begin
        FreePacket(Pkt);
        raise;
      end;
      on E: Exception do
      begin
        FreePacket(Pkt);
        InterlockedIncrement(FErrorCount);
        EmitProgress(Format('[ERRO Estagio 2] %s', [E.Message]), '', True, False);
      end;
    end;
  end;
end;

procedure TBatchImagePipeline.HandlePoolError(const AErrorClass,
  AErrorMsg: string; AData: Pointer);
begin
  if AData <> nil then ;
  InterlockedIncrement(FErrorCount);
  EmitProgress(Format('[Pool Error %s] %s', [AErrorClass, AErrorMsg]),
    '', True, False);
end;

procedure TBatchImagePipeline.Execute;
var
  Files: TStringList;
  SR: TSearchRec;
  Ext: string;
  Pool: TThreadPool;
  Stage2Barrier: TCountdownEvent;
  Reader: TStage1ReaderThread;
  Saver: TStage3SaverThread;
  I: Integer;
begin
  FStartTick := GetTickCount64;
  Files := TStringList.Create;
  try
    if FindFirst(FInputDir + '*.*', faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Attr and faDirectory) = 0 then
          begin
            Ext := LowerCase(ExtractFileExt(SR.Name));
            if (Ext = '.png') or (Ext = '.bmp') then
              Files.Add(FInputDir + SR.Name);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    Files.Sort;
    FTotalFiles := Files.Count;

    if FTotalFiles = 0 then
    begin
      EmitProgress('Nenhuma imagem PNG/BMP encontrada na pasta de entrada.',
        '', True, True);
      Exit;
    end;

    ForceDirectories(FOutputDir);
    EmitProgress(Format('Iniciando Pipeline: %d imagens | %d workers | fila=%d',
      [FTotalFiles, FWorkerCount, FQueueCapacity]), '', True, False);

    FQueue1 := TImagePacketQueue.Create(FQueueCapacity);
    FQueue2 := TImagePacketQueue.Create(FQueueCapacity);
    Pool := TThreadPool.Create(FWorkerCount, Max(16, FWorkerCount * 2));
    Pool.OnTaskError := @HandlePoolError;
    Stage2Barrier := TCountdownEvent.Create(FWorkerCount);
    Reader := TStage1ReaderThread.Create(Self, Files, FOutputDir,
      FQueue1, FToken);
    Saver := TStage3SaverThread.Create(Self, FQueue2, FToken);
    try
      { Inicia consumidores antes do produtor para maximizar fluidez }
      Saver.Start;
      for I := 1 to FWorkerCount do
        Pool.Submit(@Stage2WorkerTask, nil, FToken, Stage2Barrier);
      Reader.Start;

      { Aguarda conclusao ordenada: Estagio 1 -> Estagio 2 -> Estagio 3 }
      Reader.WaitFor;
      Stage2Barrier.Wait;

      if FToken.IsCancelled then
        FQueue2.Abort
      else
        FQueue2.CompleteAdding;

      Saver.WaitFor;
      Pool.Shutdown(True);

      { Garantia zero-leak: libera qualquer pacote retido em cancelamento }
      DrainAndFreeQueue(FQueue1);
      DrainAndFreeQueue(FQueue2);

      if FToken.IsCancelled then
        EmitProgress('Pipeline cancelado cooperativamente sem vazamentos.',
          '', True, True)
      else
        EmitProgress(Format('Concluido! %d imagens salvas em %s',
          [FSavedCount, FOutputDir]), '', True, True);
    finally
      Saver.Free;
      Reader.Free;
      Stage2Barrier.Free;
      Pool.Free;
      FreeAndNil(FQueue2);
      FreeAndNil(FQueue1);
    end;
  finally
    Files.Free;
  end;
end;

{ TSampleGeneratorThread }

constructor TSampleGeneratorThread.Create(const AOutputDir: string;
  ACount, AWidth, AHeight: Integer; const AToken: ICancellationToken;
  AOnProgress: TPipelineProgressEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOutputDir := IncludeTrailingPathDelimiter(AOutputDir);
  FCount := Max(1, ACount);
  FWidth := Max(64, AWidth);
  FHeight := Max(64, AHeight);
  FToken := AToken;
  FOnProgress := AOnProgress;
  FGenerated := 0;
end;

procedure TSampleGeneratorThread.GenerateOneTask(AData: Pointer;
  const AToken: ICancellationToken);
var
  Idx, X, Y, R, G, B: Integer;
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  C: TFPColor;
  OutFile: string;
  Dist, CX, CY: Double;
  DoneCount: LongInt;
  Stats: TPipelineStats;
begin
  Idx := PtrInt(AData);
  Img := TFPMemoryImage.Create(FWidth, FHeight);
  Writer := TFPWriterPNG.Create;
  try
    CX := FWidth * (0.3 + 0.4 * ((Idx mod 5) / 4.0));
    CY := FHeight * (0.3 + 0.4 * (((Idx * 3) mod 5) / 4.0));
    for Y := 0 to FHeight - 1 do
    begin
      if ((Y and 31) = 0) and AToken.IsCancelled then
        AToken.ThrowIfCancelled;
      for X := 0 to FWidth - 1 do
      begin
        Dist := Sqrt(Sqr(X - CX) + Sqr(Y - CY));
        R := ((X * 255) div FWidth + Idx * 23) and 255;
        G := ((Y * 255) div FHeight + Round(Sin(Dist * 0.06) * 80) + 128) and 255;
        B := (Round(Cos(Dist * 0.04 + Idx) * 127) + 128) and 255;
        C.Red := Word(R * 257);
        C.Green := Word(G * 257);
        C.Blue := Word(B * 257);
        C.Alpha := 65535;
        Img.Colors[X, Y] := C;
      end;
    end;

    OutFile := Format('%ssample_%.3d.png', [FOutputDir, Idx]);
    Writer.UseAlpha := False;
    Writer.CompressionLevel := clnone;
    Img.SaveToFile(OutFile, Writer);

    DoneCount := InterlockedIncrement(FGenerated);
    if Assigned(FOnProgress) then
    begin
      Stats := Default(TPipelineStats);
      Stats.TotalFiles := FCount;
      Stats.SavedCount := DoneCount;
      Stats.ElapsedMs := GetTickCount64 - FStartTick;
      Stats.LastSavedFile := OutFile;
      Stats.Finished := False;
      FOnProgress(Stats);
    end;
  finally
    Writer.Free;
    Img.Free;
  end;
end;

procedure TSampleGeneratorThread.Execute;
var
  Pool: TThreadPool;
  Barrier: TCountdownEvent;
  I: Integer;
  Stats: TPipelineStats;
begin
  FStartTick := GetTickCount64;
  ForceDirectories(FOutputDir);
  Pool := TThreadPool.Create(Max(2, Integer(TThread.ProcessorCount)), 64);
  Barrier := TCountdownEvent.Create(FCount);
  try
    for I := 1 to FCount do
      Pool.Submit(@GenerateOneTask, Pointer(PtrInt(I)), FToken, Barrier);
    Barrier.Wait;
    Pool.Shutdown(True);
  finally
    Barrier.Free;
    Pool.Free;
  end;

  if Assigned(FOnProgress) then
  begin
    Stats := Default(TPipelineStats);
    Stats.TotalFiles := FCount;
    Stats.SavedCount := FGenerated;
    Stats.ElapsedMs := GetTickCount64 - FStartTick;
    Stats.LastLogLine := Format('Geradas %d imagens de teste (640x480) em %s',
      [FGenerated, FOutputDir]);
    Stats.Finished := True;
    Stats.Cancelled := FToken.IsCancelled;
    FOnProgress(Stats);
  end;
end;

end.
