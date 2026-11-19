unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs,
  StdCtrls, ExtCtrls, Spin,
  uThreadSafeCache, uCacheWorkers;

type
  TMainForm = class(TForm)
    PanelConfig: TPanel;
    LblReaders: TLabel;
    SpinReaders: TSpinEdit;
    LblWriters: TLabel;
    SpinWriters: TSpinEdit;
    LblPermits: TLabel;
    SpinPermits: TSpinEdit;
    LblTTL: TLabel;
    SpinTTL: TSpinEdit;
    LblCleanup: TLabel;
    SpinCleanup: TSpinEdit;
    BtnStartStress: TButton;
    BtnStopStress: TButton;
    BtnPurgeNow: TButton;
    BtnClearCache: TButton;
    PanelManual: TPanel;
    LblKey: TLabel;
    EditKey: TEdit;
    LblVal: TLabel;
    EditValue: TEdit;
    BtnPutManual: TButton;
    BtnGetManual: TButton;
    PanelStats: TPanel;
    LblStatsTitle: TLabel;
    LblCacheCounts: TLabel;
    LblCacheWrites: TLabel;
    LblSemaphoreStats: TLabel;
    LblOpsRate: TLabel;
    MemoEvents: TMemo;
    TimerStats: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure BtnStartStressClick(Sender: TObject);
    procedure BtnStopStressClick(Sender: TObject);
    procedure BtnPurgeNowClick(Sender: TObject);
    procedure BtnClearCacheClick(Sender: TObject);
    procedure BtnPutManualClick(Sender: TObject);
    procedure BtnGetManualClick(Sender: TObject);
    procedure TimerStatsTimer(Sender: TObject);
  private
    FCache: TThreadSafeTTLCache;
    FController: TCacheStressController;
    FLastSampleMs: QWord;
    FLastReadOps: Int64;
    FLastWriteOps: Int64;

    procedure AppendLog(const AMsg: string);
    procedure RecreateEngine;
    procedure ShutdownEngine;
    procedure RefreshStatsDisplay;
  public
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  CKeySpace = 40;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FCache := nil;
  FController := nil;
  FLastSampleMs := GetTickCount64;
  FLastReadOps := 0;
  FLastWriteOps := 0;
  RecreateEngine;
  AppendLog('Cache inicializado com MREW real e limpeza via TSimpleEvent.');
end;

destructor TMainForm.Destroy;
begin
  ShutdownEngine;
  inherited Destroy;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  TimerStats.Enabled := False;
  ShutdownEngine;
  CanClose := True;
end;

procedure TMainForm.AppendLog(const AMsg: string);
begin
  MemoEvents.Lines.Add(Format('[%s] %s',
    [FormatDateTime('hh:nn:ss.zzz', Now), AMsg]));
  while MemoEvents.Lines.Count > 200 do
    MemoEvents.Lines.Delete(0);
end;

procedure TMainForm.ShutdownEngine;
begin
  if Assigned(FController) then
  begin
    FController.StopWorkers;
    FreeAndNil(FController);
  end;
  FreeAndNil(FCache);
end;

procedure TMainForm.RecreateEngine;
begin
  ShutdownEngine;
  FCache := TThreadSafeTTLCache.Create(Cardinal(SpinCleanup.Value));
  FController := TCacheStressController.Create(
    FCache, SpinPermits.Value, CKeySpace, QWord(SpinTTL.Value));
  FLastSampleMs := GetTickCount64;
  FLastReadOps := 0;
  FLastWriteOps := 0;
end;

procedure TMainForm.BtnStartStressClick(Sender: TObject);
begin
  RecreateEngine;
  FController.StartWorkers(SpinReaders.Value, SpinWriters.Value);

  BtnStartStress.Enabled := False;
  BtnStopStress.Enabled := True;
  SpinReaders.Enabled := False;
  SpinWriters.Enabled := False;
  SpinPermits.Enabled := False;
  SpinTTL.Enabled := False;
  SpinCleanup.Enabled := False;

  AppendLog(Format(
    'Carga iniciada: %d leitores, %d escritores, semaforo=%d slots, ' +
    'TTL=%d ms, limpeza=%d ms.',
    [SpinReaders.Value, SpinWriters.Value, SpinPermits.Value,
     SpinTTL.Value, SpinCleanup.Value]));
end;

procedure TMainForm.BtnStopStressClick(Sender: TObject);
begin
  if Assigned(FController) then
    FController.StopWorkers;

  BtnStartStress.Enabled := True;
  BtnStopStress.Enabled := False;
  SpinReaders.Enabled := True;
  SpinWriters.Enabled := True;
  SpinPermits.Enabled := True;
  SpinTTL.Enabled := True;
  SpinCleanup.Enabled := True;

  RefreshStatsDisplay;
  AppendLog('Threads de carga paradas graciosamente (zero deadlock).');
end;

procedure TMainForm.BtnPurgeNowClick(Sender: TObject);
var
  Removed: Integer;
begin
  if not Assigned(FCache) then
    Exit;
  Removed := FCache.PurgeExpired;
  AppendLog(Format('Purga manual executada: %d item(ns) expirado(s).',
    [Removed]));
  RefreshStatsDisplay;
end;

procedure TMainForm.BtnClearCacheClick(Sender: TObject);
begin
  if not Assigned(FCache) then
    Exit;
  FCache.Clear;
  FCache.ResetStats;
  AppendLog('Cache e contadores limpos.');
  RefreshStatsDisplay;
end;

procedure TMainForm.BtnPutManualClick(Sender: TObject);
begin
  if not Assigned(FCache) then
    Exit;
  FCache.Put(EditKey.Text, EditValue.Text, QWord(SpinTTL.Value));
  AppendLog(Format('Put("%s", "%s", TTL=%d ms).',
    [EditKey.Text, EditValue.Text, SpinTTL.Value]));
  RefreshStatsDisplay;
end;

procedure TMainForm.BtnGetManualClick(Sender: TObject);
var
  Val: string;
begin
  if not Assigned(FCache) then
    Exit;
  if FCache.TryGet(EditKey.Text, Val) then
    AppendLog(Format('TryGet("%s") -> HIT: "%s"', [EditKey.Text, Val]))
  else
    AppendLog(Format('TryGet("%s") -> MISS (ausente ou expirado)',
      [EditKey.Text]));
  RefreshStatsDisplay;
end;

procedure TMainForm.RefreshStatsDisplay;
var
  Stats: TCacheStats;
  Met: TStressMetrics;
  TotalLookups: Int64;
  HitRate: Double;
  NowMs, DeltaMs: QWord;
  ReadRate, WriteRate: Double;
begin
  if (not Assigned(FCache)) or (not Assigned(FController)) then
    Exit;

  Stats := FCache.GetStats;
  Met := FController.GetMetrics;

  TotalLookups := Stats.Hits + Stats.Misses;
  if TotalLookups > 0 then
    HitRate := (Stats.Hits * 100.0) / TotalLookups
  else
    HitRate := 0.0;

  LblCacheCounts.Caption := Format(
    'Hits: %d | Misses: %d | Taxa de Acerto: %.1f%%',
    [Stats.Hits, Stats.Misses, HitRate]);
  LblCacheWrites.Caption := Format(
    'Puts: %d | Expirados (TTL): %d | Itens ativos: %d',
    [Stats.Puts, Stats.Evictions, Stats.ItemCount]);
  LblSemaphoreStats.Caption := Format(
    'Semaforo Origem -> Ativos: %d | Pico: %d / Limite: %d | ' +
    'Acquires: %d | Timeouts: %d',
    [Met.ActiveOriginSlots, Met.PeakOriginSlots, Met.MaxOriginSlots,
     Met.OriginAcquires, Met.OriginTimeouts]);

  NowMs := GetTickCount64;
  DeltaMs := NowMs - FLastSampleMs;
  if DeltaMs >= 200 then
  begin
    ReadRate := ((Met.TotalReadOps - FLastReadOps) * 1000.0) / DeltaMs;
    WriteRate := ((Met.TotalWriteOps - FLastWriteOps) * 1000.0) / DeltaMs;
    LblOpsRate.Caption := Format(
      'Leituras/s: %.0f | Escritas/s: %.0f', [ReadRate, WriteRate]);
    FLastSampleMs := NowMs;
    FLastReadOps := Met.TotalReadOps;
    FLastWriteOps := Met.TotalWriteOps;
  end;
end;

procedure TMainForm.TimerStatsTimer(Sender: TObject);
begin
  RefreshStatsDisplay;
end;

end.
