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

procedure Reader(Arg: Pointer);
var
  c: AnsiChar;
  n: Int64;
begin
  c := #0;
  PasWaitRead(fds[0]);
{$PUSH}{$NOTES OFF}{$HINTS OFF}
  n := FpRead(fds[0], c, 1);
{$POP}
  WriteLn('read n=', n, ' c=', c, ' g=', PasID);
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  fds[0] := 0;
  fds[1] := 0;
  if FpPipe(fds) <> 0 then
  begin
    WriteLn('pipe failed');
    Halt(1);
  end;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(2);
    Pas(@Reader, wg);
    Pas(@Writer, wg);
    wg.Wait;
    WriteLn('poll ok; live=', NumPasrutinas);
  finally
    wg.Free;
    FpClose(fds[0]);
    FpClose(fds[1]);
  end;
end.
