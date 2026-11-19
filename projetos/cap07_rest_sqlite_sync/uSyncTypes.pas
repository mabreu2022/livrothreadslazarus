unit uSyncTypes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TPostDTO = record
    ExternalId: Integer;
    UserId: Integer;
    Title: string;
    Body: string;
    SourceUrl: string;
    LatencyMs: QWord;
    SyncedAt: TDateTime;
  end;

  TPostDTOArray = array of TPostDTO;

  TSyncJob = record
    JobIndex: Integer;
    EndpointUrl: string;
    LabelText: string;
  end;

  TSyncJobArray = array of TSyncJob;

  TSyncEventKind = (
    sekProgress,
    sekLog,
    sekJobDone,
    sekBatchFinished
  );

  PSyncUiPacket = ^TSyncUiPacket;
  TSyncUiPacket = record
    Kind: TSyncEventKind;
    JobIndex: Integer;
    BytesReceived: Int64;
    ContentLength: Int64;
    RecordsSaved: Integer;
    Success: Boolean;
    MessageText: string;
    Snapshot: TPostDTOArray;
  end;

  TSyncPacketCallback = procedure(APacket: PSyncUiPacket) of object;

function NewSyncPacket(AKind: TSyncEventKind): PSyncUiPacket;
procedure DisposeSyncPacket(APacket: PSyncUiPacket);

implementation

function NewSyncPacket(AKind: TSyncEventKind): PSyncUiPacket;
begin
  New(Result);
  Result^ := Default(TSyncUiPacket);
  Result^.Kind := AKind;
end;

procedure DisposeSyncPacket(APacket: PSyncUiPacket);
begin
  if APacket <> nil then
  begin
    APacket^.MessageText := '';
    SetLength(APacket^.Snapshot, 0);
    Dispose(APacket);
  end;
end;

end.
