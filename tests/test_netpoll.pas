program test_netpoll;
{ Edge-triggered poller: a byte that arrives while nobody waits must be
  remembered; timeouts return False; PasUnregisterFd wakes waiters. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, BaseUnix, pasrutinas;

var
  fds: TFilDes;
  wg: TPasWaitGroup;
  got: string = '';
  timedOut: Boolean = True;
  unregistered: Boolean = True;

procedure Writer(Arg: Pointer);
var
  c: AnsiChar;
begin
  c := 'A';
{$PUSH}{$NOTES OFF}{$HINTS OFF}
  FpWrite(fds[1], c, 1);
  PasSleep(50);
  c := 'B';
  FpWrite(fds[1], c, 1);
{$POP}
  TPasWaitGroup(Arg).Done;
end;

procedure Reader(Arg: Pointer);
var
  c: AnsiChar;
begin
  c := #0;
  PasWaitRead(fds[0]);
{$PUSH}{$NOTES OFF}{$HINTS OFF}
  FpRead(fds[0], c, 1);
  got := got + c;
  { B arrives while we sleep: the edge must be latched }
  PasSleep(150);
  PasWaitRead(fds[0]);
  FpRead(fds[0], c, 1);
{$POP}
  got := got + c;
  { nothing more: the timeout path }
  timedOut := not PasWaitReadTimeout(fds[0], 50);
  TPasWaitGroup(Arg).Done;
end;

procedure Unregister(Arg: Pointer);
begin
  PasSleep(30);
  PasUnregisterFd(fds[0]);
  TPasWaitGroup(Arg).Done;
end;

procedure WaitUntilUnregistered(Arg: Pointer);
begin
  unregistered := not PasWaitReadTimeout(fds[0], 2000);
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
    wg.Add(2);
    Pas(@WaitUntilUnregistered, wg);
    Pas(@Unregister, wg);
    wg.Wait;
  finally
    wg.Free;
    FpClose(fds[0]);
    FpClose(fds[1]);
  end;
  PasWriteLn('got=%s timeout=%s unregister-wakes=%s', [got, BoolToStr(timedOut, True), BoolToStr(unregistered, True)]);
  if (got <> 'AB') or not timedOut or not unregistered then
    Halt(1);
end.
