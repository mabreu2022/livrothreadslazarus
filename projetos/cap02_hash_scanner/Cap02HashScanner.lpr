program Cap02HashScanner;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Forms,
  SysUtils,
  uMainForm;

{$R *.res}

begin
  {$IF DECLARED(UseHeapTrace)}
  if UseHeapTrace then
    SetHeapTraceOutput(ChangeFileExt(ParamStr(0), '.heaptrc.log'));
  {$ENDIF}
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TfrmHashScanner, frmHashScanner);
  Application.Run;
end.
