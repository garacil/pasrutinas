program test_spawn;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

const
  N = 200;

var
  wg: TPasWaitGroup;
  count: LongInt;

procedure Worker(Arg: Pointer);
begin
  InterlockedIncrement(count);
  TPasWaitGroup(Arg).Done;
end;

var
  i: LongInt;
begin
  PasInit;
  count := 0;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(N);
    for i := 1 to N do
      Pas(@Worker, wg);
    wg.Wait;
  finally
    wg.Free;
  end;
  if count <> N then
  begin
    WriteLn('FAIL spawn count=', count, ' expected=', N);
    Halt(1);
  end;
  WriteLn('ok spawn ', count);
end.
