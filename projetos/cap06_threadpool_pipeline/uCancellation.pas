unit uCancellation;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  ECancellationRequested = class(Exception);

  ICancellationToken = interface
    ['{7E19C4A1-8E65-4F1D-A6B2-9B3C4E5D6F70}']
    function IsCancelled: Boolean;
    procedure ThrowIfCancelled;
    { Substitui Sleep(N): retorna True se cancelado durante a espera }
    function WaitOrCancelled(ATimeoutMs: Cardinal): Boolean;
    function GetReason: string;
    property Cancelled: Boolean read IsCancelled;
    property Reason: string read GetReason;
  end;

  { Fonte produtora do sinal de cancelamento (controlada pelo coordenador) }
  TCancellationTokenSource = class
  private
    FController: IInterface;
    function GetToken: ICancellationToken;
    function GetIsCancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel(const AReason: string = 'Operacao cancelada');
    procedure Reset;
    property Token: ICancellationToken read GetToken;
    property IsCancelled: Boolean read GetIsCancelled;
  end;

implementation

type
  ICancellationController = interface(ICancellationToken)
    ['{9B42D1E0-3A77-4C22-8F01-6A5E2C8D1B44}']
    procedure TriggerCancel(const AReason: string);
  end;

  TCancellationState = class(TInterfacedObject, ICancellationToken,
    ICancellationController)
  private
    FCancelled: LongInt;
    FEvent: TSimpleEvent;
    FLock: TCriticalSection;
    FReason: string;
  public
    constructor Create;
    destructor Destroy; override;
    function IsCancelled: Boolean;
    procedure ThrowIfCancelled;
    function WaitOrCancelled(ATimeoutMs: Cardinal): Boolean;
    function GetReason: string;
    procedure TriggerCancel(const AReason: string);
  end;

{ TCancellationState }

constructor TCancellationState.Create;
begin
  inherited Create;
  FCancelled := 0;
  FEvent := TSimpleEvent.Create;
  FLock := TCriticalSection.Create;
  FReason := '';
end;

destructor TCancellationState.Destroy;
begin
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

function TCancellationState.IsCancelled: Boolean;
begin
  Result := InterlockedCompareExchange(FCancelled, 0, 0) <> 0;
end;

procedure TCancellationState.ThrowIfCancelled;
begin
  if IsCancelled then
    raise ECancellationRequested.Create(GetReason);
end;

function TCancellationState.WaitOrCancelled(ATimeoutMs: Cardinal): Boolean;
var
  WaitRes: TWaitResult;
begin
  if IsCancelled then
    Exit(True);
  WaitRes := FEvent.WaitFor(ATimeoutMs);
  Result := (WaitRes = wrSignaled) or IsCancelled;
end;

function TCancellationState.GetReason: string;
begin
  FLock.Acquire;
  try
    Result := FReason;
  finally
    FLock.Release;
  end;
end;

procedure TCancellationState.TriggerCancel(const AReason: string);
begin
  FLock.Acquire;
  try
    if FCancelled = 0 then
      FReason := AReason;
    InterlockedExchange(FCancelled, 1);
    { Acorda imediatamente TODAS as threads em WaitOrCancelled }
    FEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

{ TCancellationTokenSource }

constructor TCancellationTokenSource.Create;
begin
  inherited Create;
  FController := TCancellationState.Create as ICancellationController;
end;

destructor TCancellationTokenSource.Destroy;
begin
  FController := nil;
  inherited Destroy;
end;

function TCancellationTokenSource.GetToken: ICancellationToken;
begin
  Result := FController as ICancellationToken;
end;

function TCancellationTokenSource.GetIsCancelled: Boolean;
begin
  Result := GetToken.IsCancelled;
end;

procedure TCancellationTokenSource.Cancel(const AReason: string);
begin
  (FController as ICancellationController).TriggerCancel(AReason);
end;

procedure TCancellationTokenSource.Reset;
begin
  { Cria um novo estado sem invalidar tokens antigos ainda em voo }
  FController := TCancellationState.Create as ICancellationController;
end;

end.
