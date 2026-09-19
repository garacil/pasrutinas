program test_once;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

var
  once: TPasOnce;
  wg: TPasWaitGroup;
  hits: LongInt;

procedure Body;
begin
  InterlockedIncrement(hits);
end;

procedure Worker(Arg: Pointer);
begin
  once.Do_(@Body);
  TPasWaitGroup(Arg).Done;
end;

var
  i: LongInt;
begin
  PasInit;
  hits := 0;
  once := TPasOnce.Create;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(32);
    for i := 1 to 32 do
      Pas(@Worker, wg);
    wg.Wait;
  finally
    wg.Free;
    once.Free;
  end;
  if hits <> 1 then
  begin
    WriteLn('FAIL once hits=', hits, ' expected=1');
    Halt(1);
  end;
  WriteLn('ok once hits=', hits);
end.
