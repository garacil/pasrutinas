program test_mutex;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

const
  N = 40;
  Inner = 100;

var
  mu: TPasMutex;
  wg: TPasWaitGroup;
  counter: LongInt;

procedure Worker(Arg: Pointer);
var
  i: LongInt;
begin
  for i := 1 to Inner do
  begin
    mu.Lock;
    Inc(counter);
    mu.Unlock;
  end;
  TPasWaitGroup(Arg).Done;
end;

var
  i: LongInt;
begin
  PasInit;
  counter := 0;
  mu := TPasMutex.Create;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(N);
    for i := 1 to N do
      Pas(@Worker, wg);
    wg.Wait;
  finally
    wg.Free;
    mu.Free;
  end;
  if counter <> N * Inner then
  begin
    WriteLn('FAIL mutex counter=', counter, ' expected=', N * Inner);
    Halt(1);
  end;
  WriteLn('ok mutex ', counter);
end.
