program test_mn;
{ The scheduler must really be M:N: CPU-bound pasrutinas run in
  parallel on several OS threads. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, Classes, pasrutinas;

const
  N = 8;
  BurnMs = 200;

var
  wg: TPasWaitGroup;
  i: Integer;
  t0, elapsed: Int64;
  sl: TStringList;
  s: string;
  threads: LongInt;

procedure Burn(Arg: Pointer);
var
  t: Int64;
  x: QWord;
begin
  t := PasNow;
  x := 0;
  while PasNow - t < BurnMs * 1000000 do
    Inc(x);
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  if PASMAXPROCS(0) < 2 then
  begin
    PasWriteLn('test_mn: skipped, single CPU');
    Exit;
  end;
  wg := TPasWaitGroup.Create;
  try
    t0 := PasNow;
    wg.Add(N);
    for i := 1 to N do
      Pas(@Burn, wg);
    wg.Wait;
    elapsed := (PasNow - t0) div 1000000;
  finally
    wg.Free;
  end;
  threads := 0;
  sl := TStringList.Create;
  try
    sl.LoadFromFile('/proc/self/status');
    for s in sl do
      if Pos('Threads:', s) = 1 then
        threads := StrToIntDef(Trim(Copy(s, 9, 10)), 0);
  finally
    sl.Free;
  end;
  PasWriteLn('%d CPU-bound pasrutinas x %d ms took %d ms on %d OS threads',
    [N, BurnMs, elapsed, threads]);
  if threads < 3 then
    Halt(1);
  if elapsed > BurnMs * N div 2 then
    Halt(1);
end.
