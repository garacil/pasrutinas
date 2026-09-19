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
  t0: Int64;
begin
  PasInit;
  { 8 KiB is enough for a trivial body; anything that formats strings or
    raises needs the 16 KiB default }
  PasSetStackSize(8 * 1024);
  PasWriteLn('spawning %d pasrutinas; stack=%d PASMAXPROCS=%d',
    [N, PasStackSize, PASMAXPROCS(0)]);
  wg := TPasWaitGroup.Create;
  try
    t0 := PasNow;
    wg.Add(N);
    for i := 1 to N do
      Pas(@Worker, wg);
    wg.Wait;
    PasWriteLn('ok in %d ms; live=%d', [(PasNow - t0) div 1000000, NumPasrutinas]);
  finally
    wg.Free;
  end;
end.
