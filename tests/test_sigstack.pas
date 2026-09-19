program test_sigstack;
{ A runtime error (SIGSEGV -> EAccessViolation) inside an 8 KiB
  pasrutina stack is delivered on the signal stack and can be caught. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas;

var
  wg: TPasWaitGroup;
  i: Integer;
  survived: LongInt = 0;

procedure Crash(Arg: Pointer);
var
  p: PLongInt;
begin
  PasSleep(1);
  p := nil;
  try
    p^ := 1;
  except
    on E: EAccessViolation do
      InterlockedIncrement(survived);
  end;
  TPasWaitGroup(Arg).Done;
end;

begin
  PasInit;
  PasSetStackSize(8 * 1024);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(16);
    for i := 1 to 16 do
      Pas(@Crash, wg);
    wg.Wait;
  finally
    wg.Free;
  end;
  PasWriteLn('access violations caught=%d/16', [survived]);
  if survived <> 16 then
    Halt(1);
end.
