program test_waitgroup;
{ Wait-then-Free: once Wait returns, the WaitGroup must be free to die.

  A writer pasrutina calls Done while a driver calls Wait and then Free, both
  released at the same instant from different Ms -- the teardown shape of any
  server that waits for a connection's second pasrutina before freeing what
  the two share. Before the fix, Wait could return on a lock-free
  FCount = 0 while Done was still about to take the WaitGroup's lock, and
  that Done then ran on freed memory.

  The object's fields are poisoned just before Free, so a late Done finds its
  lock word non-zero and sleeps in futex for ever -- it never reaches
  Finished. If the memory was reused instead, the late Done decrements a
  newer WaitGroup and that one's own Done raises "negative counter". Either
  way the test fails; a correct WaitGroup gives Finished = Spawned and no
  exception. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas;

type
  PPair = ^TPair;
  TPair = record
    WG: TPasWaitGroup;
    Started, Go: LongInt;
  end;

var
  Spawned, Finished, Failures, Pairs: Int64;
  Stop, Drivers: LongInt;

{ Both spins yield now and then. Nothing preempts a pasrutina, so a writer
  spinning on a P whose run queue holds its own driver would wait for ever. }
procedure Writer(Arg: Pointer);
var
  P: PPair;
  spins: Int64;
begin
  P := PPair(Arg);
  InterLockedExchange(P^.Started, 1);
  spins := 0;
  while InterLockedExchangeAdd(P^.Go, 0) = 0 do
  begin
    Inc(spins);
    if spins > 2000000 then
    begin
      PasYield;
      spins := 0;
    end;
  end;
  try
    P^.WG.Done;
  except
    InterLockedIncrement64(Failures);
  end;
  InterLockedIncrement64(Finished);
end;

{ Arg is the count of drivers still running. }
procedure Driver(Arg: Pointer);
var
  P: PPair;
  spins: Int64;
begin
  try
    while InterLockedExchangeAdd(Stop, 0) = 0 do
    begin
      New(P);
      P^.Started := 0;
      P^.Go := 0;
      P^.WG := TPasWaitGroup.Create;
      P^.WG.Add(1);
      InterLockedIncrement64(Spawned);
      Pas(@Writer, P);
      spins := 0;
      while InterLockedExchangeAdd(P^.Started, 0) = 0 do
      begin
        Inc(spins);
        if spins > 2000000 then
        begin
          PasYield;
          spins := 0;
        end;
      end;
      InterLockedExchange(P^.Go, 1);
      P^.WG.Wait;
      { count, lock and waiters sit after the VMT, in bytes 8..23 }
      FillChar((PByte(Pointer(P^.WG)) + 8)^, 16, $AB);
      P^.WG.Free;
      Dispose(P);
      InterLockedIncrement64(Pairs);
    end;
  except
    InterLockedIncrement64(Failures);
  end;
  InterLockedDecrement(PLongInt(Arg)^);
end;

var
  i, n: Integer;
begin
  PasInit;
  { Half the Ps drive; the other half are free to run the writers. }
  n := PASMAXPROCS(-1) div 2;
  if n < 2 then
    n := 2;
  if n > 8 then
    n := 8;
  Drivers := n;
  for i := 1 to n do
    Pas(@Driver, @Drivers);
  PasSleep(3000);
  InterLockedExchange(Stop, 1);
  for i := 1 to 50 do
  begin
    if (InterLockedExchangeAdd(Drivers, 0) = 0) and
       (InterLockedExchangeAdd64(Finished, 0) = InterLockedExchangeAdd64(Spawned, 0)) then
      Break;
    PasSleep(100);
  end;
  if (Failures <> 0) or (Drivers <> 0) or (Finished <> Spawned) then
  begin
    WriteLn('FAIL waitgroup pairs=', Pairs, ' spawned=', Spawned, ' finished=', Finished,
      ' failures=', Failures, ' drivers left=', Drivers);
    Halt(1);
  end;
  WriteLn('ok waitgroup pairs=', Pairs, ' drivers=', n);
end.
