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
  WriteLn('woke after ', a^.Ms, ' ms  g=', PasID);
  a^.Wg.Done;
end;

var
  wg: TPasWaitGroup;
  a10, a30, a60: TSleepArg;
  t0, t1: QWord;
begin
  PasInit;
  wg := TPasWaitGroup.Create;
  try
    a10.Ms := 10; a10.Wg := wg;
    a30.Ms := 30; a30.Wg := wg;
    a60.Ms := 60; a60.Wg := wg;
    t0 := GetTickCount64;
    wg.Add(3);
    Pas(@Sleeper, @a10);
    Pas(@Sleeper, @a30);
    Pas(@Sleeper, @a60);
    wg.Wait;
    t1 := GetTickCount64;
    WriteLn('elapsed ', t1 - t0, ' ms; live=', NumPasrutinas);
  finally
    wg.Free;
  end;
end.
