program test_chan;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

var
  ch: TIntChan;
  wg: TPasWaitGroup;
  sum: LongInt;

procedure Producer(Arg: Pointer);
var
  i: LongInt;
begin
  for i := 1 to 50 do
    ch.Send(i);
  TPasWaitGroup(Arg).Done;
end;

procedure Consumer(Arg: Pointer);
var
  i, v: LongInt;
begin
  for i := 1 to 50 do
  begin
    v := ch.Recv;
    InterlockedExchangeAdd(sum, v);
  end;
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  sum := 0;
  ch := TIntChan.Create(0);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(2);
    Pas(@Producer, wg);
    Pas(@Consumer, wg);
    wg.Wait;
  finally
    wg.Free;
    ch.Free;
  end;
  { 1+...+50 = 1275 }
  if sum <> 1275 then
  begin
    WriteLn('FAIL chan sum=', sum, ' expected=1275');
    Halt(1);
  end;
  WriteLn('ok chan sum=', sum);
end.
