program cap06_threadpool_pipeline;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Forms,
  uMainForm,
  uCancellation,
  uBoundedQueue,
  uThreadPool,
  uImagePipeline;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TfrmPipelineMain, frmPipelineMain);
  Application.Run;
end.
