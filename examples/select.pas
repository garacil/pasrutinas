program selectdemo;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

var
  chA, chB: TIntChan;
  wg: TPasWaitGroup;

procedure ProdA(Arg: Pointer);
begin
  PasSleep(20);
  chA.Send(1);
  TPasWaitGroup(Arg).Done;
end;

procedure ProdB(Arg: Pointer);
begin
  PasSleep(5);
  chB.Send(2);
  TPasWaitGroup(Arg).Done;
end;

var
  cases: array[0..2] of TPasSelectCase;
  n, got: LongInt;
  i, idx: LongInt;
begin
  PasInit;
  chA := TIntChan.Create(0);
  chB := TIntChan.Create(0);
  wg := TPasWaitGroup.Create;
  try
    wg.Add(2);
    Pas(@ProdA, wg);
    Pas(@ProdB, wg);
    got := 0;
    for i := 1 to 2 do
    begin
      n := 0;
      cases[0].Kind := pasCaseRecv;
      cases[0].Chan := chA.Raw;
      cases[0].Elem := @n;
      cases[1].Kind := pasCaseRecv;
      cases[1].Chan := chB.Raw;
      cases[1].Elem := @n;
      cases[2].Kind := pasCaseDefault;
      cases[2].Chan := nil;
      cases[2].Elem := nil;
      repeat
        idx := PasSelect(cases);
        if idx = 2 then
          PasYield
        else
          Break;
      until False;
      WriteLn('select idx=', idx, ' value=', n);
      Inc(got);
    end;
    wg.Wait;
    WriteLn('got ', got, ' values; live=', NumPasrutinas);
  finally
    wg.Free;
    chA.Free;
    chB.Free;
  end;
end.
