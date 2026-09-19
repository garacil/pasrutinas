{
    This file is part of pasrutinas.

    Copyright (c) 2026 Germán Luis Aracil Boned
    Author: Germán Luis Aracil Boned <garacil@tucall.com>

    Go-style channels (chan.go hchan, select.go selectgo): send/recv park
    the pasrutina, not the OS thread.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

    TPasRawChan is the real implementation (untyped elements). TPasChan<T>
    is a thin generic wrapper so FPC 3.2 does not hit
    "Global Generic template references static symtable".

    A sudog lives on the stack of the waiting pasrutina (stacks are fixed,
    so unlike Go no cache is needed). Every dequeue claims the sudog with
    a CAS on the select's done word (chan.go waitq.dequeue), including
    Close, so exactly one party ever readies a parked pasrutina.

 **********************************************************************}

{$mode objfpc}{$H+}
{$S-}

unit paschan;

interface

uses
  SysUtils, pasrutinas;

type
  TPasWaitQ = record
    first, last: Pointer;
  end;

  TPasRawChan = class
  private
    FLock: TPasLock;
    FElemSize: SizeInt;
    FCap: SizeInt;
    FCount: SizeInt;
    FSendx: SizeInt;
    FRecvx: SizeInt;
    FBuf: Pointer;
    FClosed: Boolean;
    FRecvQ: TPasWaitQ;
    FSendQ: TPasWaitQ;
    procedure Enqueue(var Q: TPasWaitQ; Node: Pointer);
    function Dequeue(var Q: TPasWaitQ): Pointer;
    procedure Remove(var Q: TPasWaitQ; Node: Pointer);
    function Slot(Index: SizeInt): Pointer; inline;
  public
    constructor Create(AElemSize: SizeInt; ACapacity: SizeInt = 0);
    destructor Destroy; override;
    procedure Send(Src: Pointer);
    procedure Recv(Dst: Pointer);
    function TrySend(Src: Pointer): Boolean;
    function TryRecv(Dst: Pointer): Boolean;
    function RecvOk(Dst: Pointer): Boolean;
    procedure Close;
    function Closed: Boolean;
    function Len: SizeInt;
    function Cap: SizeInt;
    function LockPtr: PPasLock;
    { select support, FLock held by the caller }
    procedure RemoveWaiter(IsSend: Boolean; Node: Pointer);
    function TrySendLocked(Src: Pointer; out Wake: TPasrutina; out Ok: Boolean): Boolean;
    function TryRecvLocked(Dst: Pointer; out Wake: TPasrutina; out Ok: Boolean): Boolean;
    procedure EnqueueSudog(IsSend: Boolean; Node: Pointer);
  end;

  generic TPasChan<T> = class
  private
    FRaw: TPasRawChan;
  public
    constructor Create(ACapacity: SizeInt = 0);
    destructor Destroy; override;
    procedure Send(const V: T);
    function Recv: T;
    function TrySend(const V: T): Boolean;
    function TryRecv(out V: T): Boolean;
    function RecvOk(out V: T): Boolean;
    procedure Close;
    function Closed: Boolean;
    function Len: SizeInt;
    function Cap: SizeInt;
    function Raw: TPasRawChan;
  end;

const
  pasCaseSend    = 0;
  pasCaseRecv    = 1;
  pasCaseDefault = 2;

type
  { Ok is an output: True when a send or receive completed, False when a
    receive case was chosen because its channel is closed (Go: v, ok :=
    <-ch inside select). }
  TPasSelectCase = record
    Kind: LongInt;
    Chan: TPasRawChan;
    Elem: Pointer;
    Ok: Boolean;
  end;

{ select.go selectgo: returns the index of the chosen case, blocking
  unless a pasCaseDefault case is present. Raises on send to a closed
  channel like Go panics. }
function PasSelect(var Cases: array of TPasSelectCase): LongInt;

implementation

{$WARN 4055 OFF}

type
  PSudog = ^TSudog;
  { runtime2.go sudog }
  TSudog = record
    g: TPasrutina;
    elem: Pointer;
    next: PSudog;
    prev: PSudog;
    success: Boolean;
    isSelect: Boolean;
    selDone: PLongInt;
    selWinner: PLongInt;
    selIndex: LongInt;
  end;

procedure TPasRawChan.Enqueue(var Q: TPasWaitQ; Node: Pointer);
var
  n, l: PSudog;
begin
  n := PSudog(Node);
  n^.next := nil;
  n^.prev := nil;
  l := PSudog(Q.last);
  if l = nil then
  begin
    Q.first := n;
    Q.last := n;
    Exit;
  end;
  n^.prev := l;
  l^.next := n;
  Q.last := n;
end;

{ chan.go waitq.dequeue: a sudog that belongs to a select is claimed with
  a CAS on the select's done word; if another case already won, skip. }
function TPasRawChan.Dequeue(var Q: TPasWaitQ): Pointer;
var
  sg, y: PSudog;
begin
  while True do
  begin
    sg := PSudog(Q.first);
    if sg = nil then
      Exit(nil);
    y := sg^.next;
    if y = nil then
    begin
      Q.first := nil;
      Q.last := nil;
    end
    else
    begin
      y^.prev := nil;
      Q.first := y;
      sg^.next := nil;
    end;
    if sg^.isSelect then
    begin
      if InterlockedCompareExchange(sg^.selDone^, 1, 0) <> 0 then
        Continue;
      sg^.selWinner^ := sg^.selIndex;
    end;
    Exit(sg);
  end;
end;

{ chan.go waitq.dequeueSudoG }
procedure TPasRawChan.Remove(var Q: TPasWaitQ; Node: Pointer);
var
  sg, x, y: PSudog;
begin
  sg := PSudog(Node);
  x := sg^.prev;
  y := sg^.next;
  if x <> nil then
  begin
    if y <> nil then
    begin
      x^.next := y;
      y^.prev := x;
      sg^.next := nil;
      sg^.prev := nil;
      Exit;
    end;
    x^.next := nil;
    Q.last := x;
    sg^.prev := nil;
    Exit;
  end;
  if y <> nil then
  begin
    y^.prev := nil;
    Q.first := y;
    sg^.next := nil;
    Exit;
  end;
  if Q.first = sg then
  begin
    Q.first := nil;
    Q.last := nil;
  end;
end;

function TPasRawChan.Slot(Index: SizeInt): Pointer;
begin
  Result := Pointer(PtrUInt(FBuf) + PtrUInt(Index) * PtrUInt(FElemSize));
end;

constructor TPasRawChan.Create(AElemSize: SizeInt; ACapacity: SizeInt);
begin
  inherited Create;
  if AElemSize < 1 then
    AElemSize := 1;
  if ACapacity < 0 then
    ACapacity := 0;
  FElemSize := AElemSize;
  FCap := ACapacity;
  FCount := 0;
  FSendx := 0;
  FRecvx := 0;
  FClosed := False;
  FRecvQ.first := nil;
  FRecvQ.last := nil;
  FSendQ.first := nil;
  FSendQ.last := nil;
  FBuf := nil;
  if FCap > 0 then
    FBuf := GetMem(FCap * FElemSize);
  FLock.key := 0;
  PasInit;
end;

destructor TPasRawChan.Destroy;
begin
  if FBuf <> nil then
    FreeMem(FBuf);
  inherited Destroy;
end;

{ chan.go chansend }
procedure TPasRawChan.Send(Src: Pointer);
var
  sg: PSudog;
  mine: TSudog;
  wake: TPasrutina;
begin
  PasLockAcquire(FLock);
  if FClosed then
  begin
    PasLockRelease(FLock);
    raise Exception.Create('paschan: send on closed channel');
  end;
  sg := PSudog(Dequeue(FRecvQ));
  if sg <> nil then
  begin
    Move(Src^, sg^.elem^, FElemSize);
    sg^.success := True;
    wake := sg^.g;
    PasLockRelease(FLock);
    PasInternalReady(wake);
    Exit;
  end;
  if FCount < FCap then
  begin
    Move(Src^, Slot(FSendx)^, FElemSize);
    Inc(FSendx);
    if FSendx = FCap then
      FSendx := 0;
    Inc(FCount);
    PasLockRelease(FLock);
    Exit;
  end;
  mine := Default(TSudog);
  mine.g := PasCurrent;
  mine.elem := Src;
  Enqueue(FSendQ, @mine);
  PasInternalParkUnlockLock(FLock);
  if not mine.success then
    raise Exception.Create('paschan: send on closed channel');
end;

{ chan.go chanrecv }
function TPasRawChan.RecvOk(Dst: Pointer): Boolean;
var
  sg: PSudog;
  mine: TSudog;
  wake: TPasrutina;
begin
  Result := True;
  PasLockAcquire(FLock);
  sg := PSudog(Dequeue(FSendQ));
  if sg <> nil then
  begin
    if FCount > 0 then
    begin
      { buffered and full: take the head, refill the tail from the sender }
      Move(Slot(FRecvx)^, Dst^, FElemSize);
      Move(sg^.elem^, Slot(FRecvx)^, FElemSize);
      Inc(FRecvx);
      if FRecvx = FCap then
        FRecvx := 0;
      FSendx := FRecvx;
    end
    else
      Move(sg^.elem^, Dst^, FElemSize);
    sg^.success := True;
    wake := sg^.g;
    PasLockRelease(FLock);
    PasInternalReady(wake);
    Exit;
  end;
  if FCount > 0 then
  begin
    Move(Slot(FRecvx)^, Dst^, FElemSize);
    Inc(FRecvx);
    if FRecvx = FCap then
      FRecvx := 0;
    Dec(FCount);
    PasLockRelease(FLock);
    Exit;
  end;
  if FClosed then
  begin
    PasLockRelease(FLock);
    FillChar(Dst^, FElemSize, 0);
    Result := False;
    Exit;
  end;
  mine := Default(TSudog);
  mine.g := PasCurrent;
  mine.elem := Dst;
  Enqueue(FRecvQ, @mine);
  PasInternalParkUnlockLock(FLock);
  Result := mine.success;
  if not Result then
    FillChar(Dst^, FElemSize, 0);
end;

procedure TPasRawChan.Recv(Dst: Pointer);
begin
  RecvOk(Dst);
end;

function TPasRawChan.TrySend(Src: Pointer): Boolean;
var
  wake: TPasrutina;
  ok: Boolean;
begin
  PasLockAcquire(FLock);
  Result := TrySendLocked(Src, wake, ok);
  PasLockRelease(FLock);
  if Result and not ok then
    raise Exception.Create('paschan: send on closed channel');
  if wake <> nil then
    PasInternalReady(wake);
end;

function TPasRawChan.TryRecv(Dst: Pointer): Boolean;
var
  wake: TPasrutina;
  ok: Boolean;
begin
  PasLockAcquire(FLock);
  Result := TryRecvLocked(Dst, wake, ok);
  PasLockRelease(FLock);
  if wake <> nil then
    PasInternalReady(wake);
  if Result and not ok then
    Result := False;
  if not Result then
    FillChar(Dst^, FElemSize, 0);
end;

{ chan.go closechan: release all readers (ok=false) and writers (they
  raise). Selects are claimed by Dequeue like everywhere else. }
procedure TPasRawChan.Close;
var
  sg: PSudog;
  list: array of TPasrutina;
  n, i: LongInt;
begin
  PasLockAcquire(FLock);
  if FClosed then
  begin
    PasLockRelease(FLock);
    raise Exception.Create('paschan: close of closed channel');
  end;
  FClosed := True;
  n := 0;
  list := nil;
  SetLength(list, 16);
  while True do
  begin
    sg := PSudog(Dequeue(FRecvQ));
    if sg = nil then
      Break;
    if sg^.elem <> nil then
      FillChar(sg^.elem^, FElemSize, 0);
    sg^.success := False;
    if n = Length(list) then
      SetLength(list, n * 2);
    list[n] := sg^.g;
    Inc(n);
  end;
  while True do
  begin
    sg := PSudog(Dequeue(FSendQ));
    if sg = nil then
      Break;
    sg^.success := False;
    if n = Length(list) then
      SetLength(list, n * 2);
    list[n] := sg^.g;
    Inc(n);
  end;
  PasLockRelease(FLock);
  for i := 0 to n - 1 do
    PasInternalReady(list[i]);
end;

function TPasRawChan.Closed: Boolean;
begin
  Result := FClosed;
end;

function TPasRawChan.Len: SizeInt;
begin
  Result := FCount;
end;

function TPasRawChan.Cap: SizeInt;
begin
  Result := FCap;
end;

function TPasRawChan.LockPtr: PPasLock;
begin
  Result := @FLock;
end;

{ Result: the case can complete now. Ok: False means "closed". }
function TPasRawChan.TrySendLocked(Src: Pointer; out Wake: TPasrutina; out Ok: Boolean): Boolean;
var
  sg: PSudog;
begin
  Result := False;
  Wake := nil;
  Ok := True;
  if FClosed then
  begin
    Ok := False;
    Result := True;
    Exit;
  end;
  sg := PSudog(Dequeue(FRecvQ));
  if sg <> nil then
  begin
    Move(Src^, sg^.elem^, FElemSize);
    sg^.success := True;
    Wake := sg^.g;
    Result := True;
    Exit;
  end;
  if FCount < FCap then
  begin
    Move(Src^, Slot(FSendx)^, FElemSize);
    Inc(FSendx);
    if FSendx = FCap then
      FSendx := 0;
    Inc(FCount);
    Result := True;
  end;
end;

function TPasRawChan.TryRecvLocked(Dst: Pointer; out Wake: TPasrutina; out Ok: Boolean): Boolean;
var
  sg: PSudog;
begin
  Result := False;
  Wake := nil;
  Ok := True;
  sg := PSudog(Dequeue(FSendQ));
  if sg <> nil then
  begin
    if FCount > 0 then
    begin
      Move(Slot(FRecvx)^, Dst^, FElemSize);
      Move(sg^.elem^, Slot(FRecvx)^, FElemSize);
      Inc(FRecvx);
      if FRecvx = FCap then
        FRecvx := 0;
      FSendx := FRecvx;
    end
    else
      Move(sg^.elem^, Dst^, FElemSize);
    sg^.success := True;
    Wake := sg^.g;
    Result := True;
    Exit;
  end;
  if FCount > 0 then
  begin
    Move(Slot(FRecvx)^, Dst^, FElemSize);
    Inc(FRecvx);
    if FRecvx = FCap then
      FRecvx := 0;
    Dec(FCount);
    Result := True;
    Exit;
  end;
  if FClosed then
  begin
    FillChar(Dst^, FElemSize, 0);
    Ok := False;
    Result := True;
  end;
end;

procedure TPasRawChan.EnqueueSudog(IsSend: Boolean; Node: Pointer);
begin
  if IsSend then
    Enqueue(FSendQ, Node)
  else
    Enqueue(FRecvQ, Node);
end;

procedure TPasRawChan.RemoveWaiter(IsSend: Boolean; Node: Pointer);
begin
  if IsSend then
    Remove(FSendQ, Node)
  else
    Remove(FRecvQ, Node);
end;

constructor TPasChan.Create(ACapacity: SizeInt);
begin
  inherited Create;
  FRaw := TPasRawChan.Create(SizeOf(T), ACapacity);
end;

destructor TPasChan.Destroy;
begin
  FRaw.Free;
  inherited Destroy;
end;

procedure TPasChan.Send(const V: T);
begin
  FRaw.Send(@V);
end;

function TPasChan.Recv: T;
begin
  FRaw.Recv(@Result);
end;

function TPasChan.TrySend(const V: T): Boolean;
begin
  Result := FRaw.TrySend(@V);
end;

function TPasChan.TryRecv(out V: T): Boolean;
begin
  Result := FRaw.TryRecv(@V);
end;

function TPasChan.RecvOk(out V: T): Boolean;
begin
  Result := FRaw.RecvOk(@V);
end;

function TPasChan.Raw: TPasRawChan;
begin
  Result := FRaw;
end;

procedure TPasChan.Close;
begin
  FRaw.Close;
end;

function TPasChan.Closed: Boolean;
begin
  Result := FRaw.Closed;
end;

function TPasChan.Len: SizeInt;
begin
  Result := FRaw.Len;
end;

function TPasChan.Cap: SizeInt;
begin
  Result := FRaw.Cap;
end;

type
  TSelectLockArr = array[0..15] of PPasLock;

{ select.go selectgo: lock all channels in address order, poll the cases
  in a random order, otherwise enqueue one sudog per case and park. The
  first party to claim a sudog (CAS on done) wins and writes winner. }
function PasSelect(var Cases: array of TPasSelectCase): LongInt;
var
  n, i, j, defi, chosen: LongInt;
  order: array[0..15] of LongInt;
  locks: TSelectLockArr;
  nlocks, li: LongInt;
  sgs: array[0..15] of TSudog;
  used: array[0..15] of Boolean;
  done, winner: LongInt;
  tmp: LongInt;
  ch: TPasRawChan;
  seed: Cardinal;
  wake: TPasrutina;
  ok: Boolean;
begin
  PasInit;
  n := Length(Cases);
  if n > 16 then
    raise Exception.Create('PasSelect: at most 16 cases');
  locks := Default(TSelectLockArr);
  defi := -1;
  for i := 0 to n - 1 do
  begin
    order[i] := i;
    used[i] := False;
    Cases[i].Ok := False;
    if Cases[i].Kind = pasCaseDefault then
      defi := i;
  end;
  seed := Cardinal(PasID) xor Cardinal(PasNow);
  for i := n - 1 downto 1 do
  begin
    seed := seed * 1103515245 + 12345;
    j := LongInt((seed shr 8) mod Cardinal(i + 1));
    tmp := order[i];
    order[i] := order[j];
    order[j] := tmp;
  end;

  { lock order: by address, once per distinct channel }
  nlocks := 0;
  for i := 0 to n - 1 do
  begin
    ch := Cases[i].Chan;
    if (Cases[i].Kind = pasCaseDefault) or (ch = nil) then
      Continue;
    for li := 0 to nlocks - 1 do
      if locks[li] = ch.LockPtr then
      begin
        ch := nil;
        Break;
      end;
    if ch = nil then
      Continue;
    li := 0;
    while (li < nlocks) and (PtrUInt(locks[li]) < PtrUInt(ch.LockPtr)) do
      Inc(li);
    for j := nlocks downto li + 1 do
      locks[j] := locks[j - 1];
    locks[li] := ch.LockPtr;
    Inc(nlocks);
  end;

  for i := 0 to nlocks - 1 do
    PasLockAcquire(locks[i]^);

  { pass 1: look for something already waiting }
  chosen := -1;
  wake := nil;
  ok := True;
  for i := 0 to n - 1 do
  begin
    j := order[i];
    ch := Cases[j].Chan;
    if ch = nil then
      Continue;
    case Cases[j].Kind of
      pasCaseSend:
        if ch.TrySendLocked(Cases[j].Elem, wake, ok) then
        begin
          chosen := j;
          Break;
        end;
      pasCaseRecv:
        if ch.TryRecvLocked(Cases[j].Elem, wake, ok) then
        begin
          chosen := j;
          Break;
        end;
    end;
  end;

  if chosen >= 0 then
  begin
    for i := nlocks - 1 downto 0 do
      PasLockRelease(locks[i]^);
    if wake <> nil then
      PasInternalReady(wake);
    Cases[chosen].Ok := ok;
    if (Cases[chosen].Kind = pasCaseSend) and not ok then
      raise Exception.Create('paschan: send on closed channel');
    Result := chosen;
    Exit;
  end;

  if defi >= 0 then
  begin
    for i := nlocks - 1 downto 0 do
      PasLockRelease(locks[i]^);
    Result := defi;
    Exit;
  end;

  if nlocks = 0 then
  begin
    { a select with no channel cases blocks forever }
    PasPark;
    Result := -1;
    Exit;
  end;

  { pass 2: enqueue on all channels and park }
  done := 0;
  winner := -1;
  for i := 0 to n - 1 do
  begin
    ch := Cases[i].Chan;
    if (ch = nil) or (Cases[i].Kind = pasCaseDefault) then
      Continue;
    sgs[i] := Default(TSudog);
    sgs[i].g := PasCurrent;
    sgs[i].elem := Cases[i].Elem;
    sgs[i].isSelect := True;
    sgs[i].selDone := @done;
    sgs[i].selWinner := @winner;
    sgs[i].selIndex := i;
    used[i] := True;
    ch.EnqueueSudog(Cases[i].Kind = pasCaseSend, @sgs[i]);
  end;

  PasInternalParkUnlockMany(locks);

  { pass 3: dequeue the losers under all locks, read the winner }
  for i := 0 to nlocks - 1 do
    PasLockAcquire(locks[i]^);
  for i := 0 to n - 1 do
  begin
    if not used[i] then
      Continue;
    if i = winner then
      Continue;
    ch := Cases[i].Chan;
    ch.RemoveWaiter(Cases[i].Kind = pasCaseSend, @sgs[i]);
  end;
  for i := nlocks - 1 downto 0 do
    PasLockRelease(locks[i]^);

  if winner < 0 then
    raise Exception.Create('paschan: select woke without a winner');
  Cases[winner].Ok := sgs[winner].success;
  if (Cases[winner].Kind = pasCaseSend) and not sgs[winner].success then
    raise Exception.Create('paschan: send on closed channel');
  Result := winner;
end;

end.
