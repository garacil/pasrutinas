program miles;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

const
  N = 50000;

procedure Worker(Arg: Pointer);
begin
  TPasWaitGroup(Arg).Done;
end;

var
  wg: TPasWaitGroup;
  i: LongInt;
  t0, t1: QWord;
begin
  PasInit;
  PasSetStackSize(8 * 1024);
  WriteLn('spawning ', N, ' pasrutinas; stack=', PasStackSize,
    ' PASMAXPROCS=', PASMAXPROCS(0));
  wg := TPasWaitGroup.Create;
  try
    t0 := GetTickCount64;
    wg.Add(N);
    for i := 1 to N do
      Pas(@Worker, wg);
    wg.Wait;
    t1 := GetTickCount64;
    WriteLn('ok in ', t1 - t0, ' ms; live=', NumPasrutinas);
  finally
    wg.Free;
  end;
end.
