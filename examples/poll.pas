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
begin
  PasSleep(30);
  c := 'Z';
  FpWrite(fds[1], c, 1);
  TPasWaitGroup(Arg).Done;
end;

procedure Reader(Arg: Pointer);
var
  c: AnsiChar;
  n: ssize_t;
begin
  PasWaitRead(fds[0]);
  n := FpRead(fds[0], c, 1);
  WriteLn('read n=', n, ' c=', c, ' g=', PasID);
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
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
