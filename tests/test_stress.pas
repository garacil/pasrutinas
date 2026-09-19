program test_stress;
{ Volume: 300000 trivial pasrutinas, 1000000 yielding ones, 20000
  parked at once (2 VMAs each: stays under a default vm.max_map_count
  of 65530), memory must be recycled. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas;

var
  wg, gate: TPasWaitGroup;
  i: Integer;
  t0: Int64;
  sum: Int64 = 0;

procedure Trivial(Arg: Pointer);
begin
  TPasWaitGroup(Arg).Done;
end;

procedure Yielding(Arg: Pointer);
begin
  InterlockedIncrement64(sum);
  PasYield;
  TPasWaitGroup(Arg).Done;
end;

procedure Parked(Arg: Pointer);
begin
  gate.Wait;
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  wg := TPasWaitGroup.Create;
  gate := TPasWaitGroup.Create;
  try
    t0 := PasNow;
    wg.Add(300000);
    for i := 1 to 300000 do
      Pas(@Trivial, wg);
    wg.Wait;
    PasWriteLn('300000 trivial pasrutinas: %d ms', [(PasNow - t0) div 1000000]);

    t0 := PasNow;
    wg.Add(1000000);
    for i := 1 to 1000000 do
      Pas(@Yielding, wg);
    wg.Wait;
    PasWriteLn('1000000 yielding pasrutinas: %d ms sum=%d', [(PasNow - t0) div 1000000, sum]);
    if sum <> 1000000 then
      Halt(1);

    gate.Add(1);
    wg.Add(20000);
    for i := 1 to 20000 do
      Pas(@Parked, wg);
    PasSleep(100);
    PasWriteLn('parked at once: %d', [NumPasrutinas - 1]);
    if NumPasrutinas - 1 <> 20000 then
      Halt(1);
    gate.Done;
    wg.Wait;
    PasWriteLn('live after release: %d', [NumPasrutinas]);
    if NumPasrutinas <> 1 then
      Halt(1);
  finally
    gate.Free;
    wg.Free;
  end;
end.
