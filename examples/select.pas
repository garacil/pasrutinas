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
  chA.Close;
  TPasWaitGroup(Arg).Done;
end;

procedure ProdB(Arg: Pointer);
begin
  PasSleep(5);
  chB.Send(2);
  TPasWaitGroup(Arg).Done;
end;

var
  cases: array[0..1] of TPasSelectCase;
  n, got: LongInt;
  idx: LongInt;
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
    { a blocking select, like Go's: no default case, parks until a case
      is ready. Ok=False on a receive case means "channel closed". }
    repeat
      n := 0;
      cases[0].Kind := pasCaseRecv;
      cases[0].Chan := chA.Raw;
      cases[0].Elem := @n;
      cases[1].Kind := pasCaseRecv;
      cases[1].Chan := chB.Raw;
      cases[1].Elem := @n;
      idx := PasSelect(cases);
      if cases[idx].Ok then
      begin
        PasWriteLn('select idx=%d value=%d', [idx, n]);
        Inc(got);
      end
      else
        PasWriteLn('select idx=%d closed', [idx]);
    until not cases[idx].Ok;
    wg.Wait;
    PasWriteLn('got %d values; live=%d', [got, NumPasrutinas]);
  finally
    wg.Free;
    chA.Free;
    chB.Free;
  end;
end.
