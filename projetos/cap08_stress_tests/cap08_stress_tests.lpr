program cap08_stress_tests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Classes,
  SysUtils,
  consoletestrunner,
  uStressSync,
  uConcurrentStructures,
  uStressTests;

type
  TStressTestRunner = class(TTestRunner)
  protected
    procedure AppendLongOpts; override;
    procedure WriteCustomHelp; override;
  end;

procedure TStressTestRunner.AppendLongOpts;
begin
  inherited AppendLongOpts;
  LongOpts.Add('heaplog:');
end;

procedure TStressTestRunner.WriteCustomHelp;
begin
  inherited WriteCustomHelp;
  WriteLn('  --heaplog=<arq>  Redireciona relatorio do HeapTrc');
end;

var
  App: TStressTestRunner;
  I: Integer;
  Arg, HeapLogPath: string;
begin
  HeapLogPath := '';
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if Copy(Arg, 1, 10) = '--heaplog=' then
      HeapLogPath := Copy(Arg, 11, MaxInt);
  end;

  {$IF DECLARED(UseHeapTrace)}
  GlobalSkipIfNoLeaks := False;
  HaltOnNotReleased := True;
  if HeapLogPath <> '' then
  begin
    if FileExists(HeapLogPath) then
      DeleteFile(HeapLogPath);
    SetHeapTraceOutput(HeapLogPath);
  end;
  {$ENDIF}

  DefaultFormat := fPlain;
  DefaultRunAllTests := True;

  App := TStressTestRunner.Create(nil);
  try
    App.Title := 'Suite de Testes de Estresse Concorrente (Cap. 8)';
    App.Initialize;
    App.Run;
  finally
    App.Free;
  end;
end.
