unit uBoundedQueue;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, uCancellation;

const
  QUEUE_CANCEL_SLICE_MS = 25;

type
  { Fila concorrente limitada (Ring Buffer) com backpressure e shutdown limpo }
  generic TBoundedThreadQueue<T> = class
  private
    FBuffer: array of T;
    FCapacity: Integer;
    FHead: Integer;
    FTail: Integer;
    FCount: Integer;
    FCompleted: Boolean;
    FAborted: Boolean;
    FLock: TCriticalSection;
    FNotEmptyEvent: TSimpleEvent;
    FNotFullEvent: TSimpleEvent;
    FTotalEnqueued: Int64;
    FTotalDequeued: Int64;
    FBackpressureWaits: Int64;
    function GetCount: Integer;
    function GetIsCompleted: Boolean;
    function GetBackpressureWaits: Int64;
    function GetTotalEnqueued: Int64;
    function GetTotalDequeued: Int64;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;

    { Insere item; bloqueia se fila cheia (backpressure). False se fechada }
    function Enqueue(const AItem: T;
      const AToken: ICancellationToken = nil): Boolean;

    { Retira item; bloqueia se fila vazia. False quando vazia + Completed }
    function TryDequeue(out AItem: T;
      const AToken: ICancellationToken = nil): Boolean;

    { Retirada nao bloqueante (util para drenagem de limpeza no shutdown) }
    function TryDequeueNoWait(out AItem: T): Boolean;

    { Sinaliza fim das producoes; consumidores drenam itens restantes }
    procedure CompleteAdding;

    { Acorda imediatamente todas as threads e interrompe novas esperas }
    procedure Abort;

    property Capacity: Integer read FCapacity;
    property Count: Integer read GetCount;
    property IsCompleted: Boolean read GetIsCompleted;
    property BackpressureWaits: Int64 read GetBackpressureWaits;
    property TotalEnqueued: Int64 read GetTotalEnqueued;
    property TotalDequeued: Int64 read GetTotalDequeued;
  end;

implementation

{ TBoundedThreadQueue<T> }

constructor TBoundedThreadQueue.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity < 1 then
    raise EArgumentOutOfRangeException.Create(
      'Capacidade da TBoundedThreadQueue deve ser >= 1');
  FCapacity := ACapacity;
  SetLength(FBuffer, FCapacity);
  FHead := 0;
  FTail := 0;
  FCount := 0;
  FCompleted := False;
  FAborted := False;
  FTotalEnqueued := 0;
  FTotalDequeued := 0;
  FBackpressureWaits := 0;

  FLock := TCriticalSection.Create;
  FNotEmptyEvent := TSimpleEvent.Create;
  FNotFullEvent := TSimpleEvent.Create;
  { Inicialmente a fila nao esta cheia, portanto produtores podem inserir }
  FNotFullEvent.SetEvent;
end;

destructor TBoundedThreadQueue.Destroy;
begin
  Abort;
  FNotFullEvent.Free;
  FNotEmptyEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

function TBoundedThreadQueue.Enqueue(const AItem: T;
  const AToken: ICancellationToken): Boolean;
var
  WaitMs: Cardinal;
begin
  if Assigned(AToken) then
    WaitMs := QUEUE_CANCEL_SLICE_MS
  else
    WaitMs := INFINITE;

  while True do
  begin
    if Assigned(AToken) and AToken.IsCancelled then
      Exit(False);

    FLock.Acquire;
    try
      if FCompleted or FAborted then
        Exit(False);

      if FCount < FCapacity then
      begin
        FBuffer[FTail] := AItem;
        FTail := (FTail + 1) mod FCapacity;
        Inc(FCount);
        Inc(FTotalEnqueued);

        if FCount = 1 then
          FNotEmptyEvent.SetEvent;
        if FCount = FCapacity then
          FNotFullEvent.ResetEvent;

        Exit(True);
      end;

      { Fila cheia: registra evento de backpressure antes de aguardar }
      Inc(FBackpressureWaits);
      FNotFullEvent.ResetEvent;
    finally
      FLock.Release;
    end;

    { Aguarda fora do lock para nao bloquear consumidores }
    FNotFullEvent.WaitFor(WaitMs);
  end;
end;

function TBoundedThreadQueue.TryDequeue(out AItem: T;
  const AToken: ICancellationToken): Boolean;
var
  WaitMs: Cardinal;
begin
  AItem := Default(T);
  if Assigned(AToken) then
    WaitMs := QUEUE_CANCEL_SLICE_MS
  else
    WaitMs := INFINITE;

  while True do
  begin
    if Assigned(AToken) and AToken.IsCancelled then
      Exit(False);

    FLock.Acquire;
    try
      if FAborted then
        Exit(False);

      if FCount > 0 then
      begin
        AItem := FBuffer[FHead];
        { Zera slot para liberar referencias de tipos gerenciados }
        FBuffer[FHead] := Default(T);
        FHead := (FHead + 1) mod FCapacity;
        Dec(FCount);
        Inc(FTotalDequeued);

        if FCount = FCapacity - 1 then
          FNotFullEvent.SetEvent;
        if (FCount = 0) and (not FCompleted) and (not FAborted) then
          FNotEmptyEvent.ResetEvent;

        Exit(True);
      end;

      if FCompleted then
        Exit(False);

      FNotEmptyEvent.ResetEvent;
    finally
      FLock.Release;
    end;

    { Aguarda novos itens fora do lock }
    FNotEmptyEvent.WaitFor(WaitMs);
  end;
end;

function TBoundedThreadQueue.TryDequeueNoWait(out AItem: T): Boolean;
begin
  AItem := Default(T);
  FLock.Acquire;
  try
    if FCount = 0 then
      Exit(False);
    AItem := FBuffer[FHead];
    FBuffer[FHead] := Default(T);
    FHead := (FHead + 1) mod FCapacity;
    Dec(FCount);
    Inc(FTotalDequeued);
    if FCount = FCapacity - 1 then
      FNotFullEvent.SetEvent;
    if (FCount = 0) and (not FCompleted) and (not FAborted) then
      FNotEmptyEvent.ResetEvent;
    Result := True;
  finally
    FLock.Release;
  end;
end;

procedure TBoundedThreadQueue.CompleteAdding;
begin
  FLock.Acquire;
  try
    FCompleted := True;
    FNotEmptyEvent.SetEvent;
    FNotFullEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TBoundedThreadQueue.Abort;
begin
  FLock.Acquire;
  try
    FAborted := True;
    FCompleted := True;
    FNotEmptyEvent.SetEvent;
    FNotFullEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.GetCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.GetIsCompleted: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCompleted;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.GetBackpressureWaits: Int64;
begin
  FLock.Acquire;
  try
    Result := FBackpressureWaits;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.GetTotalEnqueued: Int64;
begin
  FLock.Acquire;
  try
    Result := FTotalEnqueued;
  finally
    FLock.Release;
  end;
end;

function TBoundedThreadQueue.GetTotalDequeued: Int64;
begin
  FLock.Acquire;
  try
    Result := FTotalDequeued;
  finally
    FLock.Release;
  end;
end;

end.
