program bench;
{ Same four measurements as bench.go, for a side by side comparison:
  make bench }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

const
  NSpawn = 300000;
  NRoundTrips = 200000;
  NSleepers = 20000;
  NLockers = 8;
  NLocks = 100000;

var
  wg: TPasWaitGroup;
  ch: TIntChan;
  mu: TPasMutex;
  n: LongInt = 0;

procedure Trivial(Arg: Pointer);
begin
  TPasWaitGroup(Arg).Done;
end;

procedure Ponger(Arg: Pointer);
var
  k, x: LongInt;
begin
  for k := 1 to NRoundTrips do
  begin
    x := ch.Recv;
    ch.Send(x + 1);
  end;
  TPasWaitGroup(Arg).Done;
end;

procedure Sleeper(Arg: Pointer);
begin
  PasSleep(100 + (PasID mod 100));
  TPasWaitGroup(Arg).Done;
end;

procedure Locker(Arg: Pointer);
var
  k: LongInt;
begin
  for k := 1 to NLocks do
  begin
    mu.Lock;
    Inc(n);
    mu.Unlock;
  end;
  TPasWaitGroup(Arg).Done;
end;

var
  i, v: LongInt;
  t0: Int64;
begin
  PasInit;
  wg := TPasWaitGroup.Create;
  ch := TIntChan.Create(0);
  mu := TPasMutex.Create;
  try
    t0 := PasNow;
    wg.Add(NSpawn);
    for i := 1 to NSpawn do
      Pas(@Trivial, wg);
    wg.Wait;
    PasWriteLn('pasrutinas: %d trivial pasrutinas: %d ms', [NSpawn, (PasNow - t0) div 1000000]);

    t0 := PasNow;
    wg.Add(1);
    Pas(@Ponger, wg);
    v := 0;
    for i := 1 to NRoundTrips do
    begin
      ch.Send(i);
      v := ch.Recv;
    end;
    wg.Wait;
    PasWriteLn('pasrutinas: %d unbuffered round trips: %d ms (last=%d)', [NRoundTrips, (PasNow - t0) div 1000000, v]);

    t0 := PasNow;
    wg.Add(NSleepers);
    for i := 1 to NSleepers do
      Pas(@Sleeper, wg);
    wg.Wait;
    PasWriteLn('pasrutinas: %d sleepers of 100..199 ms: %d ms', [NSleepers, (PasNow - t0) div 1000000]);

    t0 := PasNow;
    wg.Add(NLockers);
    for i := 1 to NLockers do
      Pas(@Locker, wg);
    wg.Wait;
    PasWriteLn('pasrutinas: %dx%d mutex lock/unlock: %d ms (n=%d, PASMAXPROCS=%d)',
      [NLockers, NLocks, (PasNow - t0) div 1000000, n, PASMAXPROCS(0)]);
  finally
    mu.Free;
    ch.Free;
    wg.Free;
  end;
end.
