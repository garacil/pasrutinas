program test_selclose;
{ select on a channel that gets closed picks that case with Ok=False;
  a select send on a closed channel raises. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

var
  chA, chB: TIntChan;
  cases: array[0..1] of TPasSelectCase;
  n, idx: LongInt;
  raised: Boolean;

procedure Closer(Arg: Pointer);
begin
  PasSleep(10);
  TIntChan(Arg).Close;
end;

begin
  PasInit;
  chA := TIntChan.Create(0);
  chB := TIntChan.Create(0);
  try
    Pas(@Closer, chA);
    n := -99;
    cases[0].Kind := pasCaseRecv;
    cases[0].Chan := chA.Raw;
    cases[0].Elem := @n;
    cases[1].Kind := pasCaseRecv;
    cases[1].Chan := chB.Raw;
    cases[1].Elem := @n;
    idx := PasSelect(cases);
    PasWriteLn('select after close: idx=%d ok=%s value=%d', [idx, BoolToStr(cases[0].Ok, True), n]);
    if (idx <> 0) or cases[0].Ok or (n <> 0) then
      Halt(1);

    raised := False;
    n := 5;
    cases[0].Kind := pasCaseSend;
    try
      PasSelect(cases);
    except
      on E: Exception do
        raised := True;
    end;
    PasWriteLn('select send on closed channel raised=%s', [BoolToStr(raised, True)]);
    if not raised then
      Halt(1);
  finally
    chA.Free;
    chB.Free;
  end;
end.
