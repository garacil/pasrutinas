program sleepdemo;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

type
  TSleepArg = record
    Ms: PtrInt;
    Wg: TPasWaitGroup;
  end;
  PSleepArg = ^TSleepArg;

procedure Sleeper(Arg: Pointer);
var
  a: PSleepArg;
begin
  a := PSleepArg(Arg);
  PasSleep(QWord(a^.Ms));
  PasWriteLn('woke after %d ms  g=%d', [a^.Ms, PasID]);
  a^.Wg.Done;
end;

var
  wg: TPasWaitGroup;
  a10, a30, a60: TSleepArg;
  t0: Int64;
begin
  PasInit;
  wg := TPasWaitGroup.Create;
  try
    a10.Ms := 10; a10.Wg := wg;
    a30.Ms := 30; a30.Wg := wg;
    a60.Ms := 60; a60.Wg := wg;
    t0 := PasNow;
    wg.Add(3);
    Pas(@Sleeper, @a10);
    Pas(@Sleeper, @a30);
    Pas(@Sleeper, @a60);
    wg.Wait;
    PasWriteLn('elapsed %d ms; live=%d', [(PasNow - t0) div 1000000, NumPasrutinas]);
  finally
    wg.Free;
  end;
end.
