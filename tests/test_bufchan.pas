program test_bufchan;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, pasrutinas, paschan;

type
  TIntChan = specialize TPasChan<LongInt>;

var
  ch: TIntChan;
  i, v, n: LongInt;
  ok: Boolean;
begin
  PasInit;
  ch := TIntChan.Create(8);
  try
    for i := 1 to 8 do
      if not ch.TrySend(i) then
      begin
        WriteLn('FAIL TrySend ', i);
        Halt(1);
      end;
    if ch.TrySend(99) then
    begin
      WriteLn('FAIL TrySend on full buffer');
      Halt(1);
    end;
    n := 0;
    for i := 1 to 8 do
    begin
      if not ch.TryRecv(v) then
      begin
        WriteLn('FAIL TryRecv ', i);
        Halt(1);
      end;
      Inc(n, v);
    end;
    if ch.TryRecv(v) then
    begin
      WriteLn('FAIL TryRecv on empty');
      Halt(1);
    end;
    ch.Close;
    ok := ch.RecvOk(v);
    if ok then
    begin
      WriteLn('FAIL RecvOk on closed empty');
      Halt(1);
    end;
  finally
    ch.Free;
  end;
  if n <> 36 then
  begin
    WriteLn('FAIL bufchan sum=', n);
    Halt(1);
  end;
  WriteLn('ok bufchan sum=', n);
end.
