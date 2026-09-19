program test_select;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

var
  chA, chB: TIntChan;
  wg: TPasWaitGroup;
  gotA, gotB: LongInt;

procedure SendA(Arg: Pointer);
begin
  PasSleep(15);
  chA.Send(11);
  TPasWaitGroup(Arg).Done;
end;

procedure SendB(Arg: Pointer);
begin
  PasSleep(5);
  chB.Send(22);
  TPasWaitGroup(Arg).Done;
end;

var
  cases: array[0..1] of TPasSelectCase;
  n, idx, i: LongInt;
begin
  PasInit;
  gotA := 0;
  gotB := 0;
  chA := TIntChan.Create(0);
  chB := TIntChan.Create(0);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(2);
    Pas(@SendA, wg);
    Pas(@SendB, wg);
    for i := 1 to 2 do
    begin
      n := 0;
      cases[0].Kind := pasCaseRecv;
      cases[0].Chan := chA.Raw;
      cases[0].Elem := @n;
      cases[1].Kind := pasCaseRecv;
      cases[1].Chan := chB.Raw;
      cases[1].Elem := @n;
      idx := PasSelect(cases);
      if idx = 0 then
        gotA := n
      else if idx = 1 then
        gotB := n
      else
      begin
        WriteLn('FAIL select idx=', idx);
        Halt(1);
      end;
    end;
    wg.Wait;
  finally
    wg.Free;
    chA.Free;
    chB.Free;
  end;
  if (gotA <> 11) or (gotB <> 22) then
  begin
    WriteLn('FAIL select gotA=', gotA, ' gotB=', gotB);
    Halt(1);
  end;
  WriteLn('ok select A=', gotA, ' B=', gotB);
end.
