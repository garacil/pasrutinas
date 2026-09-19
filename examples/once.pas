program oncedemo;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

var
  once: TPasOnce;
  wg: TPasWaitGroup;

procedure InitOnce;
begin
  WriteLn('init once from pasrutina ', PasID);
end;

procedure Worker(Arg: Pointer);
begin
  once.Do_(@InitOnce);
  TPasWaitGroup(Arg).Done;
end;

var
  i: LongInt;
begin
  PasInit;
  once := TPasOnce.Create;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(16);
    for i := 1 to 16 do
      Pas(@Worker, wg);
    wg.Wait;
    WriteLn('done live=', NumPasrutinas);
  finally
    wg.Free;
    once.Free;
  end;
end.
