program hola;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas;

procedure Saluda(Arg: Pointer);
begin
  WriteLn('hello from pasrutina ', PasID);
  TPasWaitGroup(Arg).Done;
end;

var
  wg: TPasWaitGroup;
  i: Integer;
begin
  PasInit;
  WriteLn('main pasrutina ', PasID, ' PASMAXPROCS=', PASMAXPROCS(0));
  wg := TPasWaitGroup.Create;
  try
    wg.Add(8);
    for i := 1 to 8 do
      Pas(@Saluda, wg);
    wg.Wait;
  finally
    wg.Free;
  end;
  WriteLn('done. live pasrutinas=', NumPasrutinas);
end.
