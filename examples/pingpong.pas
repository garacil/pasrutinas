program pingpong;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

type
  TPingArg = record
    Ch: TIntChan;
    Wg: TPasWaitGroup;
  end;
  PPingArg = ^TPingArg;

procedure Ping(Arg: Pointer);
var
  a: PPingArg;
  n, i: LongInt;
begin
  a := PPingArg(Arg);
  for i := 1 to 10 do
  begin
    a^.Ch.Send(i);
    n := a^.Ch.Recv;
    WriteLn('ping got ', n, '  g=', PasID);
  end;
  a^.Wg.Done;
end;

procedure Pong(Arg: Pointer);
var
  a: PPingArg;
  n, i: LongInt;
begin
  a := PPingArg(Arg);
  for i := 1 to 10 do
  begin
    n := a^.Ch.Recv;
    WriteLn('pong got ', n, '  g=', PasID);
    a^.Ch.Send(n + 100);
  end;
  a^.Wg.Done;
end;

var
  ch: TIntChan;
  wg: TPasWaitGroup;
  pingArg, pongArg: TPingArg;
begin
  PasInit;
  ch := TIntChan.Create(0);
  wg := TPasWaitGroup.Create;
  try
    pingArg.Ch := ch;
    pingArg.Wg := wg;
    pongArg.Ch := ch;
    pongArg.Wg := wg;
    wg.Add(2);
    Pas(@Ping, @pingArg);
    Pas(@Pong, @pongArg);
    wg.Wait;
    WriteLn('done, pasrutinas=', NumPasrutinas);
  finally
    wg.Free;
    ch.Free;
  end;
end.
