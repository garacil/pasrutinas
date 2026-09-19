program test_sleep;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

var
  wg: TPasWaitGroup;
  t0, t1, elapsed: QWord;

procedure Sleeper(Arg: Pointer);
begin
  PasSleep(40);
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  wg := TPasWaitGroup.Create;
  try
    t0 := GetTickCount64;
    wg.Add(1);
    Pas(@Sleeper, wg);
    wg.Wait;
    t1 := GetTickCount64;
  finally
    wg.Free;
  end;
  elapsed := t1 - t0;
  if elapsed < 30 then
  begin
    WriteLn('FAIL sleep too short ', elapsed, ' ms');
    Halt(1);
  end;
  if elapsed > 2000 then
  begin
    WriteLn('FAIL sleep too long ', elapsed, ' ms');
    Halt(1);
  end;
  WriteLn('ok sleep ', elapsed, ' ms');
end.
