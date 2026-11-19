program cap07_rest_sqlite_sync;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces,
  Forms,
  SysUtils,
  uSyncTypes,
  uSyncPrimitives,
  uSqliteRepo,
  uRestSyncWorker,
  uMainForm;

{$R *.res}

begin
  {$IF DECLARED(UseHeapTrace)}
  GlobalSkipIfNoLeaks := True;
  {$ENDIF}
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
