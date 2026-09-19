program mutexdemo;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

var
  mu: TPasMutex;
  wg: TPasWaitGroup;
  n: LongInt;

procedure Worker(Arg: Pointer);
var
  i: LongInt;
begin
  for i := 1 to 1000 do
  begin
    mu.Lock;
    Inc(n);
    mu.Unlock;
  end;
  TPasWaitGroup(Arg).Done;
end;

var
  i: LongInt;
begin
  PasInit;
  n := 0;
  mu := TPasMutex.Create;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(8);
    for i := 1 to 8 do
      Pas(@Worker, wg);
    wg.Wait;
    WriteLn('counter=', n, ' (expected 8000)');
  finally
    wg.Free;
    mu.Free;
  end;
end.
