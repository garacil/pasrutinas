program test_timers;
{ Timers: a satisfied wait-with-timeout must not fire later (stale
  timer), many concurrent sleeps must be accurate, and 20000 sleepers
  must not be quadratic. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, BaseUnix, pasrutinas;

var
  fds: TFilDes;
  wg: TPasWaitGroup;
  i: Integer;
  t0: Int64;
  slept: Int64 = 0;
  ok: LongInt = 1;

procedure Writer(Arg: Pointer);
var
  c: AnsiChar;
begin
  PasSleep(10);
  c := 'A';
{$PUSH}{$NOTES OFF}{$HINTS OFF}
  FpWrite(fds[1], c, 1);
{$POP}
  TPasWaitGroup(Arg).Done;
end;

procedure Reader(Arg: Pointer);
var
  c: AnsiChar;
  t: Int64;
begin
  c := #0;
  if not PasWaitReadTimeout(fds[0], 100) then
    InterlockedExchange(ok, 0);
{$PUSH}{$NOTES OFF}{$HINTS OFF}
  FpRead(fds[0], c, 1);
{$POP}
  t := PasNow;
  PasSleep(400);
  slept := (PasNow - t) div 1000000;
  TPasWaitGroup(Arg).Done;
end;

procedure Sleeper(Arg: Pointer);
var
  k: Integer;
begin
  for k := 1 to 100 do
    PasSleep(1);
  TPasWaitGroup(Arg).Done;
end;

procedure LongSleeper(Arg: Pointer);
begin
  PasSleep(100 + (PasID mod 100));
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  fds[0] := 0;
  fds[1] := 0;
  if FpPipe(fds) <> 0 then
    Halt(2);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(2);
    Pas(@Reader, wg);
    Pas(@Writer, wg);
    wg.Wait;
    PasWriteLn('after a satisfied 100 ms poll timeout, PasSleep(400) slept %d ms', [slept]);
    if (ok = 0) or (slept < 395) or (slept > 700) then
      Halt(1);

    t0 := PasNow;
    wg.Add(256);
    for i := 1 to 256 do
      Pas(@Sleeper, wg);
    wg.Wait;
    PasWriteLn('256 x 100 PasSleep(1): %d ms', [(PasNow - t0) div 1000000]);

    t0 := PasNow;
    wg.Add(20000);
    for i := 1 to 20000 do
      Pas(@LongSleeper, wg);
    wg.Wait;
    slept := (PasNow - t0) div 1000000;
    PasWriteLn('20000 sleepers of 100..199 ms: %d ms', [slept]);
    if slept > 1500 then
      Halt(1);
  finally
    wg.Free;
    PasUnregisterFd(fds[0]);
    FpClose(fds[0]);
    FpClose(fds[1]);
  end;
end.
