program test_exceptions;
{ Exceptions raised and caught after parking, uncaught exceptions
  reported by the trampoline, parking inside except and finally blocks:
  the RTL exception chains must follow the pasrutina. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas;

var
  wg: TPasWaitGroup;
  caught: LongInt = 0;
  nested: LongInt = 0;
  i: Integer;

procedure RaiseAfterPark(Arg: Pointer);
var
  k: Integer;
begin
  for k := 1 to 50 do
  begin
    PasSleep(1 + (PasID mod 3));
    try
      raise Exception.Create('boom');
    except
      on E: Exception do
        if E.Message = 'boom' then
          InterlockedIncrement(caught);
    end;
  end;
  TPasWaitGroup(Arg).Done;
end;

procedure ParkInsideHandlers(Arg: Pointer);
var
  k: Integer;
begin
  for k := 1 to 40 do
  begin
    try
      try
        PasSleep(1);
        raise Exception.Create('inner ' + IntToStr(k));
      finally
        PasSleep(1);
      end;
    except
      on E: Exception do
      begin
        PasSleep(1 + (k mod 2));
        if E.Message = 'inner ' + IntToStr(k) then
          InterlockedIncrement(nested);
        try
          raise Exception.Create('nested');
        except
          on E2: Exception do
            if E2.Message = 'nested' then
              PasYield;
        end;
      end;
    end;
  end;
  TPasWaitGroup(Arg).Done;
end;

procedure Uncaught(Arg: Pointer);
begin
  PasSleep(2);
  TPasWaitGroup(Arg).Done;
  raise Exception.Create('reported by the trampoline, this is expected');
end;

begin
  PasInit;
  wg := TPasWaitGroup.Create;
  try
    wg.Add(64);
    for i := 1 to 64 do
      Pas(@RaiseAfterPark, wg);
    wg.Wait;
    wg.Add(64);
    for i := 1 to 64 do
      Pas(@ParkInsideHandlers, wg);
    wg.Wait;
    wg.Add(8);
    for i := 1 to 8 do
      Pas(@Uncaught, wg);
    wg.Wait;
    PasSleep(20);
  finally
    wg.Free;
  end;
  PasWriteLn('caught=%d/%d nested=%d/%d', [caught, 64 * 50, nested, 64 * 40]);
  if (caught <> 64 * 50) or (nested <> 64 * 40) then
    Halt(1);
end.
