unit uThreadSafeCache;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections;

type
  TCacheEntry = record
    Value: string;
    ExpiresAtMs: QWord;
  end;

  TCacheStats = record
    Hits: Int64;
    Misses: Int64;
    Puts: Int64;
    Evictions: Int64;
    ItemCount: Integer;
  end;

  TCacheMap = specialize TDictionary<string, TCacheEntry>;

  TThreadSafeTTLCache = class;

  { Thread de limpeza orientada a TSimpleEvent (zero busy-waiting) }
  TCacheCleanerThread = class(TThread)
  private
    FCache: TThreadSafeTTLCache;
    FStopEvent: TSimpleEvent;
    FIntervalMs: Cardinal;
  protected
    procedure Execute; override;
  public
    constructor Create(ACache: TThreadSafeTTLCache;
      AStopEvent: TSimpleEvent; AIntervalMs: Cardinal);
  end;

  { Cache em memoria thread-safe com TTL, MREW real e stats lock-free }
  TThreadSafeTTLCache = class
  private
    { IMPORTANTE: armazenado como classe concreta, sem misturar com
      IReadWriteSync, para evitar liberacao prematura por refcount. }
    FLock: TMultiReadExclusiveWriteSynchronizer;
    FMap: TCacheMap;
    FStopEvent: TSimpleEvent;
    FCleaner: TCacheCleanerThread;

    { Contadores 64-bit atualizados via Interlocked*64 (lock-free) }
    FHits: Int64;
    FMisses: Int64;
    FPuts: Int64;
    FEvictions: Int64;
  public
    constructor Create(ACleanupIntervalMs: Cardinal = 1500);
    destructor Destroy; override;

    procedure Put(const AKey, AValue: string; ATTLMs: QWord);
    function TryGet(const AKey: string; out AValue: string): Boolean;
    function Remove(const AKey: string): Boolean;
    function PurgeExpired: Integer;
    procedure Clear;
    function GetStats: TCacheStats;
    procedure ResetStats;
  end;

implementation

{ TCacheCleanerThread }

constructor TCacheCleanerThread.Create(ACache: TThreadSafeTTLCache;
  AStopEvent: TSimpleEvent; AIntervalMs: Cardinal);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCache := ACache;
  FStopEvent := AStopEvent;
  if AIntervalMs < 50 then
    FIntervalMs := 50
  else
    FIntervalMs := AIntervalMs;
end;

procedure TCacheCleanerThread.Execute;
var
  WaitRes: TWaitResult;
begin
  while not Terminated do
  begin
    { Dorme eficientemente no kernel; acorda na hora em SetEvent }
    WaitRes := FStopEvent.WaitFor(FIntervalMs);
    if Terminated or (WaitRes = wrSignaled) then
      Break;

    if WaitRes = wrTimeout then
      FCache.PurgeExpired;
  end;
end;

{ TThreadSafeTTLCache }

constructor TThreadSafeTTLCache.Create(ACleanupIntervalMs: Cardinal);
begin
  inherited Create;
  FLock := TMultiReadExclusiveWriteSynchronizer.Create;
  FMap := TCacheMap.Create;
  FStopEvent := TSimpleEvent.Create;

  FHits := 0;
  FMisses := 0;
  FPuts := 0;
  FEvictions := 0;

  FCleaner := TCacheCleanerThread.Create(Self, FStopEvent,
    ACleanupIntervalMs);
  FCleaner.Start;
end;

destructor TThreadSafeTTLCache.Destroy;
begin
  if Assigned(FCleaner) then
  begin
    FCleaner.Terminate;
    FStopEvent.SetEvent; // Acorda imediatamente sem esperar o intervalo
    FCleaner.WaitFor;
    FreeAndNil(FCleaner);
  end;

  FreeAndNil(FStopEvent);
  FreeAndNil(FMap);
  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TThreadSafeTTLCache.Put(const AKey, AValue: string;
  ATTLMs: QWord);
var
  Entry: TCacheEntry;
begin
  Entry.Value := AValue;
  Entry.ExpiresAtMs := GetTickCount64 + ATTLMs;

  FLock.BeginWrite;
  try
    FMap.AddOrSetValue(AKey, Entry);
  finally
    FLock.EndWrite;
  end;

  InterlockedIncrement64(FPuts);
end;

function TThreadSafeTTLCache.TryGet(const AKey: string;
  out AValue: string): Boolean;
var
  Entry: TCacheEntry;
  NowMs: QWord;
begin
  Result := False;
  AValue := '';
  NowMs := GetTickCount64;

  { Leituras concorrentes: varias threads entram juntas aqui }
  FLock.BeginRead;
  try
    if FMap.TryGetValue(AKey, Entry) and (NowMs < Entry.ExpiresAtMs) then
    begin
      AValue := Entry.Value;
      Result := True;
    end;
  finally
    FLock.EndRead;
  end;

  if Result then
    InterlockedIncrement64(FHits)
  else
    InterlockedIncrement64(FMisses);
end;

function TThreadSafeTTLCache.Remove(const AKey: string): Boolean;
begin
  FLock.BeginWrite;
  try
    Result := FMap.ContainsKey(AKey);
    if Result then
      FMap.Remove(AKey);
  finally
    FLock.EndWrite;
  end;
end;

function TThreadSafeTTLCache.PurgeExpired: Integer;
var
  NowMs: QWord;
  ExpiredKeys: array of string;
  ExpiredCount, Cap, I: Integer;
  Pair: specialize TPair<string, TCacheEntry>;
  Entry: TCacheEntry;
begin
  Result := 0;
  NowMs := GetTickCount64;
  ExpiredKeys := nil;
  ExpiredCount := 0;
  Cap := 0;

  { Fase 1: varredura sob lock de leitura (nao bloqueia outros leitores) }
  FLock.BeginRead;
  try
    for Pair in FMap do
    begin
      if NowMs >= Pair.Value.ExpiresAtMs then
      begin
        if ExpiredCount = Cap then
        begin
          if Cap = 0 then
            Cap := 16
          else
            Cap := Cap * 2;
          SetLength(ExpiredKeys, Cap);
        end;
        ExpiredKeys[ExpiredCount] := Pair.Key;
        Inc(ExpiredCount);
      end;
    end;
  finally
    FLock.EndRead;
  end;

  if ExpiredCount = 0 then
    Exit;

  { Fase 2: lock de escrita separado (evita TMREWException de upgrade) }
  NowMs := GetTickCount64;
  FLock.BeginWrite;
  try
    for I := 0 to ExpiredCount - 1 do
    begin
      { Revalida TTL: outra thread pode ter renovado a chave no intervalo }
      if FMap.TryGetValue(ExpiredKeys[I], Entry) and
         (NowMs >= Entry.ExpiresAtMs) then
      begin
        FMap.Remove(ExpiredKeys[I]);
        Inc(Result);
      end;
    end;
  finally
    FLock.EndWrite;
  end;

  if Result > 0 then
    InterlockedExchangeAdd64(FEvictions, Result);
end;

procedure TThreadSafeTTLCache.Clear;
begin
  FLock.BeginWrite;
  try
    FMap.Clear;
  finally
    FLock.EndWrite;
  end;
end;

function TThreadSafeTTLCache.GetStats: TCacheStats;
begin
  Result.Hits := InterlockedExchangeAdd64(FHits, 0);
  Result.Misses := InterlockedExchangeAdd64(FMisses, 0);
  Result.Puts := InterlockedExchangeAdd64(FPuts, 0);
  Result.Evictions := InterlockedExchangeAdd64(FEvictions, 0);

  FLock.BeginRead;
  try
    Result.ItemCount := FMap.Count;
  finally
    FLock.EndRead;
  end;
end;

procedure TThreadSafeTTLCache.ResetStats;
begin
  InterlockedExchange64(FHits, 0);
  InterlockedExchange64(FMisses, 0);
  InterlockedExchange64(FPuts, 0);
  InterlockedExchange64(FEvictions, 0);
end;

end.
