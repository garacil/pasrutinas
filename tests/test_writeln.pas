program test_writeln;
{ PasWriteLn from 32 pasrutinas on many OS threads: every line must
  come out whole (checked by make check with awk). }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas;

var
  wg: TPasWaitGroup;
  i: Integer;

procedure Writer(Arg: Pointer);
var
  k: Integer;
begin
  for k := 1 to 500 do
    PasWriteLn(StringOfChar(AnsiChar(Ord('a') + (PasID mod 26)), 120));
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(32);
    for i := 1 to 32 do
      Pas(@Writer, wg);
    wg.Wait;
  finally
    wg.Free;
  end;
end.
