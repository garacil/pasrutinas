{
  paschan — Go-style channels (golang/src/runtime/chan.go, type hchan).

  Copyright (c) 2026 Germán Luis Aracil Boned
  Author: Germán Luis Aracil Boned <garacil@tucall.com>
  SPDX-License-Identifier: BSD-3-Clause

  Send/Recv park the pasrutina (G) without blocking the OS thread (M).
  The other side calls PasReady: a user-level event.

  TPasRawChan is the real implementation (untyped elements). TPasChan<T>
  is a thin generic wrapper so FPC 3.2 does not hit
  "Global Generic template references static symtable".
}

{$mode objfpc}{$H+}
{$S-}

unit paschan;

interface

uses
  SysUtils, pasrutinas;

type
  TPasRawChan = class
  private
    FLock: TRTLCriticalSection;
    FElemSize: SizeInt;
    FCap: SizeInt;
    FCount: SizeInt;
    FSendx: SizeInt;
    FRecvx: SizeInt;
    FBuf: Pointer;
    FClosed: Boolean;
    FRecvQ: Pointer;
    FSendQ: Pointer;
    procedure Enqueue(var Q: Pointer; Node: Pointer);
    function Dequeue(var Q: Pointer): Pointer;
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
    function LockPtr: PRTLCriticalSection;
    procedure RemoveWaiter(IsSend: Boolean; Node: Pointer);
    function TrySendLocked(Src: Pointer; out Wake: TPasrutina): Boolean;
    function TryRecvLocked(Dst: Pointer; out Wake: TPasrutina): Boolean;
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
  TPasSelectCase = record
    Kind: LongInt;
    Chan: TPasRawChan;
    Elem: Pointer;
  end;

function PasSelect(var Cases: array of TPasSelectCase): LongInt;

implementation

type
  PSudog = ^TSudog;
  TSudog = record
    g: TPasrutina;
    elem: Pointer;
    next: PSudog;
    success: Boolean;
    selDone: PLongInt;
    selWinner: PLongInt;
    selIndex: LongInt;
  end;

function ClaimSudog(sg: PSudog): Boolean;
begin
  if sg^.selDone = nil then
  begin
    Result := True;
    Exit;
  end;
  Result := InterlockedCompareExchange(sg^.selDone^, 1, 0) = 0;
  if Result and (sg^.selWinner <> nil) then
    sg^.selWinner^ := sg^.selIndex;
end;

procedure TPasRawChan.Enqueue(var Q: Pointer; Node: Pointer);
var
  n, p: PSudog;
begin
  n := PSudog(Node);
  n^.next := nil;
  if Q = nil then
  begin
    Q := n;
    Exit;
  end;
  p := PSudog(Q);
  while p^.next <> nil do
    p := p^.next;
  p^.next := n;
end;

function TPasRawChan.Dequeue(var Q: Pointer): Pointer;
var
  n: PSudog;
begin
  n := PSudog(Q);
  if n = nil then
  begin
    Result := nil;
    Exit;
  end;
  Q := n^.next;
  n^.next := nil;
  Result := n;
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
  FRecvQ := nil;
  FSendQ := nil;
  FBuf := nil;
  if FCap > 0 then
    FBuf := GetMem(FCap * FElemSize);
  InitCriticalSection(FLock);
  PasInit;
end;

destructor TPasRawChan.Destroy;
begin
  if FBuf <> nil then
    FreeMem(FBuf);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPasRawChan.Send(Src: Pointer);
var
  sg: PSudog;
begin
  EnterCriticalSection(FLock);
  if FClosed then
  begin
    LeaveCriticalSection(FLock);
    raise Exception.Create('paschan: send on closed channel');
  end;
  repeat
    sg := PSudog(Dequeue(FRecvQ));
  until (sg = nil) or ClaimSudog(sg);
  if sg <> nil then
  begin
    Move(Src^, sg^.elem^, FElemSize);
    sg^.success := True;
    LeaveCriticalSection(FLock);
    PasInternalReady(sg^.g);
    Exit;
  end;
  if FCount < FCap then
  begin
    Move(Src^, Slot(FSendx)^, FElemSize);
    Inc(FSendx);
    if FSendx = FCap then
      FSendx := 0;
    Inc(FCount);
    LeaveCriticalSection(FLock);
    Exit;
  end;
  New(sg);
  FillChar(sg^, SizeOf(TSudog), 0);
  sg^.g := PasCurrent;
  sg^.elem := Src;
  Enqueue(FSendQ, sg);
  PasInternalParkUnlock(FLock);
  if not sg^.success then
  begin
    Dispose(sg);
    raise Exception.Create('paschan: send on closed channel');
  end;
  Dispose(sg);
end;

function TPasRawChan.RecvOk(Dst: Pointer): Boolean;
var
  sg: PSudog;
begin
  Result := True;
  EnterCriticalSection(FLock);
  repeat
    sg := PSudog(Dequeue(FSendQ));
  until (sg = nil) or ClaimSudog(sg);
  if sg <> nil then
  begin
    Move(sg^.elem^, Dst^, FElemSize);
    sg^.success := True;
    LeaveCriticalSection(FLock);
    PasInternalReady(sg^.g);
    Exit;
  end;
  if FCount > 0 then
  begin
    Move(Slot(FRecvx)^, Dst^, FElemSize);
    Inc(FRecvx);
    if FRecvx = FCap then
      FRecvx := 0;
    Dec(FCount);
    repeat
      sg := PSudog(Dequeue(FSendQ));
    until (sg = nil) or ClaimSudog(sg);
    if sg <> nil then
    begin
      Move(sg^.elem^, Slot(FSendx)^, FElemSize);
      Inc(FSendx);
      if FSendx = FCap then
        FSendx := 0;
      Inc(FCount);
      sg^.success := True;
      LeaveCriticalSection(FLock);
      PasInternalReady(sg^.g);
      Exit;
    end;
    LeaveCriticalSection(FLock);
    Exit;
  end;
  if FClosed then
  begin
    LeaveCriticalSection(FLock);
    FillChar(Dst^, FElemSize, 0);
    Result := False;
    Exit;
  end;
  New(sg);
  FillChar(sg^, SizeOf(TSudog), 0);
  sg^.g := PasCurrent;
  sg^.elem := Dst;
  Enqueue(FRecvQ, sg);
  PasInternalParkUnlock(FLock);
  Result := sg^.success;
  if not Result then
    FillChar(Dst^, FElemSize, 0);
  Dispose(sg);
end;

procedure TPasRawChan.Recv(Dst: Pointer);
begin
  RecvOk(Dst);
end;

function TPasRawChan.TrySend(Src: Pointer): Boolean;
var
  sg: PSudog;
begin
  Result := False;
  EnterCriticalSection(FLock);
  if FClosed then
  begin
    LeaveCriticalSection(FLock);
    Exit;
  end;
  repeat
    sg := PSudog(Dequeue(FRecvQ));
  until (sg = nil) or ClaimSudog(sg);
  if sg <> nil then
  begin
    Move(Src^, sg^.elem^, FElemSize);
    sg^.success := True;
    LeaveCriticalSection(FLock);
    PasInternalReady(sg^.g);
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
    LeaveCriticalSection(FLock);
    Result := True;
    Exit;
  end;
  LeaveCriticalSection(FLock);
end;

function TPasRawChan.TryRecv(Dst: Pointer): Boolean;
var
  sg: PSudog;
begin
  Result := False;
  EnterCriticalSection(FLock);
  repeat
    sg := PSudog(Dequeue(FSendQ));
  until (sg = nil) or ClaimSudog(sg);
  if sg <> nil then
  begin
    Move(sg^.elem^, Dst^, FElemSize);
    sg^.success := True;
    LeaveCriticalSection(FLock);
    PasInternalReady(sg^.g);
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
    LeaveCriticalSection(FLock);
    Result := True;
    Exit;
  end;
  LeaveCriticalSection(FLock);
  FillChar(Dst^, FElemSize, 0);
end;

procedure TPasRawChan.Close;
var
  sg: PSudog;
begin
  EnterCriticalSection(FLock);
  if FClosed then
  begin
    LeaveCriticalSection(FLock);
    raise Exception.Create('paschan: close of closed channel');
  end;
  FClosed := True;
  while True do
  begin
    sg := PSudog(Dequeue(FRecvQ));
    if sg = nil then
      Break;
    sg^.success := False;
    PasInternalReady(sg^.g);
  end;
  while True do
  begin
    sg := PSudog(Dequeue(FSendQ));
    if sg = nil then
      Break;
    sg^.success := False;
    PasInternalReady(sg^.g);
  end;
  LeaveCriticalSection(FLock);
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

function TPasRawChan.LockPtr: PRTLCriticalSection;
begin
  Result := @FLock;
end;

function TPasRawChan.TrySendLocked(Src: Pointer; out Wake: TPasrutina): Boolean;
var
  sg: PSudog;
begin
  Result := False;
  Wake := nil;
  if FClosed then
    Exit;
  repeat
    sg := PSudog(Dequeue(FRecvQ));
  until (sg = nil) or ClaimSudog(sg);
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

function TPasRawChan.TryRecvLocked(Dst: Pointer; out Wake: TPasrutina): Boolean;
var
  sg: PSudog;
begin
  Result := False;
  Wake := nil;
  repeat
    sg := PSudog(Dequeue(FSendQ));
  until (sg = nil) or ClaimSudog(sg);
  if sg <> nil then
  begin
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
    FillChar(Dst^, FElemSize, 0);
end;

procedure TPasRawChan.EnqueueSudog(IsSend: Boolean; Node: Pointer);
begin
  if IsSend then
    Enqueue(FSendQ, Node)
  else
    Enqueue(FRecvQ, Node);
end;

procedure TPasRawChan.RemoveWaiter(IsSend: Boolean; Node: Pointer);
var
  q: PPointer;
  p, prev: PSudog;
begin
  if IsSend then
    q := @FSendQ
  else
    q := @FRecvQ;
  prev := nil;
  p := PSudog(q^);
  while p <> nil do
  begin
    if p = PSudog(Node) then
    begin
      if prev = nil then
        q^ := p^.next
      else
        prev^.next := p^.next;
      p^.next := nil;
      Exit;
    end;
    prev := p;
    p := p^.next;
  end;
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

function PasSelect(var Cases: array of TPasSelectCase): LongInt;
var
  n, i, j, defi, chosen: LongInt;
  order: array[0..15] of LongInt;
  locks: array[0..15] of PRTLCriticalSection;
  nlocks, li: LongInt;
  sgs: array[0..15] of PSudog;
  done, winner: LongInt;
  tmp: LongInt;
  ch: TPasRawChan;
  seed: Cardinal;
  wake: TPasrutina;
begin
  PasInit;
  n := Length(Cases);
  if n > 16 then
    n := 16;
  FillChar(locks, SizeOf(locks), 0);
  defi := -1;
  for i := 0 to n - 1 do
  begin
    order[i] := i;
    sgs[i] := nil;
    if Cases[i].Kind = pasCaseDefault then
      defi := i;
  end;
  seed := Cardinal(PasID) xor Cardinal(GetTickCount64);
  for i := n - 1 downto 1 do
  begin
    seed := seed * 1103515245 + 12345;
    j := LongInt(seed mod Cardinal(i + 1));
    tmp := order[i];
    order[i] := order[j];
    order[j] := tmp;
  end;

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
    EnterCriticalSection(locks[i]^);

  chosen := -1;
  wake := nil;
  for i := 0 to n - 1 do
  begin
    j := order[i];
    ch := Cases[j].Chan;
    case Cases[j].Kind of
      pasCaseSend:
        if (ch <> nil) and ch.TrySendLocked(Cases[j].Elem, wake) then
        begin
          chosen := j;
          Break;
        end;
      pasCaseRecv:
        if (ch <> nil) and ch.TryRecvLocked(Cases[j].Elem, wake) then
        begin
          chosen := j;
          Break;
        end;
    end;
  end;

  if chosen >= 0 then
  begin
    for i := nlocks - 1 downto 0 do
      LeaveCriticalSection(locks[i]^);
    if wake <> nil then
      PasInternalReady(wake);
    Result := chosen;
    Exit;
  end;

  if defi >= 0 then
  begin
    for i := nlocks - 1 downto 0 do
      LeaveCriticalSection(locks[i]^);
    Result := defi;
    Exit;
  end;

  if nlocks = 0 then
  begin
    PasPark;
    Result := -1;
    Exit;
  end;

  done := 0;
  winner := -1;
  for i := 0 to n - 1 do
  begin
    ch := Cases[i].Chan;
    if (ch = nil) or (Cases[i].Kind = pasCaseDefault) then
      Continue;
    New(sgs[i]);
    FillChar(sgs[i]^, SizeOf(TSudog), 0);
    sgs[i]^.g := PasCurrent;
    sgs[i]^.elem := Cases[i].Elem;
    sgs[i]^.selDone := @done;
    sgs[i]^.selWinner := @winner;
    sgs[i]^.selIndex := i;
    ch.EnqueueSudog(Cases[i].Kind = pasCaseSend, sgs[i]);
  end;

  FillChar(locks[nlocks], SizeOf(PRTLCriticalSection) * (16 - nlocks), 0);
  PasInternalParkUnlockMany(locks);

  for i := 0 to nlocks - 1 do
    EnterCriticalSection(locks[i]^);
  for i := 0 to n - 1 do
  begin
    if sgs[i] = nil then
      Continue;
    ch := Cases[i].Chan;
    if Cases[i].Kind = pasCaseSend then
      ch.RemoveWaiter(True, sgs[i])
    else
      ch.RemoveWaiter(False, sgs[i]);
    Dispose(sgs[i]);
  end;
  for i := nlocks - 1 downto 0 do
    LeaveCriticalSection(locks[i]^);

  Result := winner;
end;

end.
