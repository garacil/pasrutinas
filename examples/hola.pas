program hola;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

procedure Saluda(Arg: Pointer);
begin
  { PasWriteLn: one whole line per call from any pasrutina; the RTL's
    WriteLn keeps a buffer per OS thread and is not thread safe }
  PasWriteLn('hello from pasrutina %d', [PasID]);
  TPasWaitGroup(Arg).Done;
end;

var
  wg: TPasWaitGroup;
  i: Integer;
begin
  PasInit;
  PasWriteLn('main pasrutina %d PASMAXPROCS=%d', [PasID, PASMAXPROCS(0)]);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(8);
    for i := 1 to 8 do
      Pas(@Saluda, wg);
    wg.Wait;
  finally
    wg.Free;
  end;
  PasWriteLn('done. live pasrutinas=%d', [NumPasrutinas]);
end.
