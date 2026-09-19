program polldemo;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, BaseUnix, pasrutinas;

var
  fds: TFilDes;
  wg: TPasWaitGroup;

procedure Writer(Arg: Pointer);
var
  c: AnsiChar;
  n: Int64;
begin
  PasSleep(30);
  c := 'Z';
{$PUSH}{$NOTES OFF}{$HINTS OFF}
  n := FpWrite(fds[1], c, 1);
{$POP}
  if n <> 1 then
    Halt(1);
  TPasWaitGroup(Arg).Done;
end;

{ The poller is edge-triggered, as Go's netpoll: try the non-blocking
  read first and wait only on EAGAIN. PasWaitRead switches the fd to
  O_NONBLOCK and remembers a readiness edge that arrives while nobody
  waits, so this loop cannot lose data. }
procedure Reader(Arg: Pointer);
var
  c: AnsiChar;
  n: Int64;
begin
  c := #0;
  repeat
{$PUSH}{$NOTES OFF}{$HINTS OFF}
    n := FpRead(fds[0], c, 1);
{$POP}
    if n = 1 then
      Break;
    if (n < 0) and (fpgeterrno = ESysEAGAIN) then
      PasWaitRead(fds[0])
    else
      Halt(1);
  until False;
  PasWriteLn('read n=%d c=%s g=%d', [n, c, PasID]);
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  fds[0] := 0;
  fds[1] := 0;
  if FpPipe(fds) <> 0 then
  begin
    PasWriteLn('pipe failed');
    Halt(1);
  end;
  { register before use so the first read already sees O_NONBLOCK }
  PasWaitReadTimeout(fds[0], 1);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(2);
    Pas(@Reader, wg);
    Pas(@Writer, wg);
    wg.Wait;
    PasWriteLn('poll ok; live=%d', [NumPasrutinas]);
  finally
    wg.Free;
    PasUnregisterFd(fds[0]);
    FpClose(fds[0]);
    FpClose(fds[1]);
  end;
end.
