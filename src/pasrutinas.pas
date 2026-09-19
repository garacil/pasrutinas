{
  pasrutinas — Go goroutines ported to Free Pascal.

  Copyright (c) 2026 Germán Luis Aracil Boned
  Author: Germán Luis Aracil Boned <garacil@tucall.com>
  SPDX-License-Identifier: BSD-3-Clause

  Copied from golang/src/runtime (HACKING.md, runtime2.go, proc.go,
  asm_amd64.s, stack.go, chan.go):

    G  = pasrutina   (work item, a few KiB of its own stack)
    M  = OS thread   (pthread / BeginThread)
    P  = processor   (local run queue + the right to run Pascal code)

  Switching G does not enter the kernel: a TPasBuf is saved/restored
  (same layout as FPC jmp_buf: rbx,rbp,r12-r15,rsp,rip) via the RTL
  symbols FPC_SETJMP / FPC_LONGJMP.

  Public prefix: Pas / PAS, never Go.

  Usage:
    uses cthreads, pasrutinas, paschan;
    Pas(@Proc);
    PASMAXPROCS(N);
}

{$mode objfpc}{$H+}
{$asmmode att}
{$S-}
{$Q-}
{$R-}
{$IFDEF CPUx86_64}
{$ELSE}
  {$ERROR pasrutinas requires x86_64 (TPasBuf / FPC_SETJMP on amd64)}
{$ENDIF}

unit pasrutinas;

interface

uses
  SysUtils, BaseUnix;

const
  { Go starts at 2 KiB and grows. Without compiler morestack, 16 KiB
    demand-paged (mmap, not pre-touched) is the compromise: an idle
    pasrutina dirties ~1 page of RSS. }
  PasStackDefault = 16 * 1024;
  PasStackGuard   = 4096;
  PasG0StackSize  = 64 * 1024;
  PasRunqSize     = 256;
  PasMStackSize   = 128 * 1024;

type
  TPasProc    = procedure;
  TPasProcArg = procedure(Arg: Pointer);
  TPasMethod  = procedure of object;
  TPasrutina  = Pointer;

  TPasWaitGroup = class
  private
    FCount: LongInt;
    FLock: TRTLCriticalSection;
    FWaiters: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(Delta: LongInt);
    procedure Done;
    procedure Wait;
  end;

  TPasMutex = class
  private
    FLocked: LongInt;
    FLock: TRTLCriticalSection;
    FWaiters: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Lock;
    procedure Unlock;
  end;

  TPasRWMutex = class
  private
    FLock: TRTLCriticalSection;
    FReaders: LongInt;
    FWriter: Boolean;
    FReadWaiters: Pointer;
    FWriteWaiters: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginRead;
    procedure EndRead;
    procedure Lock;
    procedure Unlock;
  end;

  TPasOnce = class
  private
    FDone: LongInt;
    FMu: TPasMutex;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Do_(Proc: TPasProc);
  end;

  TPasCond = class
  private
    FLock: TRTLCriticalSection;
    FWaiters: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Wait(M: TPasMutex);
    procedure Signal;
    procedure Broadcast;
  end;

procedure Pas(Proc: TPasProc);
procedure Pas(Proc: TPasProcArg; Arg: Pointer);
procedure Pas(Method: TPasMethod);
procedure PasYield;
procedure PasExit;
procedure PasSleep(Ms: QWord);
procedure PasPark;
procedure PasReady(G: TPasrutina);
function  PasParkUnlock(var CS: TRTLCriticalSection): Boolean;
function  PasCurrent: TPasrutina;
function  PasID: QWord;
function  NumPasrutinas: LongInt;
function  PASMAXPROCS(N: LongInt): LongInt;
procedure PasSetStackSize(Bytes: PtrUInt);
function  PasStackSize: PtrUInt;
procedure PasInit;
procedure PasWaitRead(Fd: LongInt);
procedure PasWaitWrite(Fd: LongInt);
function  PasWaitReadTimeout(Fd: LongInt; Ms: LongInt): Boolean;

{ Internals used by paschan. Not a stable API. }
procedure PasInternalParkUnlock(var CS: TRTLCriticalSection);
procedure PasInternalParkUnlockMany(const Locks: array of PRTLCriticalSection);
procedure PasInternalReady(G: TPasrutina);

implementation

uses
  unixtype;

type
  TPasBuf = packed record
    rbx, rbp, r12, r13, r14, r15, rsp, rip: QWord;
  end;
  PPasBuf = ^TPasBuf;

  TParkKind = (pkNone, pkPark, pkYield, pkExit);

  TPasKind = (pskProc, pskProcArg, pskMethod);

  PG = ^TG;
  PM = ^TM;
  PPasP = ^TPasP;

  TG = record
    sched: TPasBuf;
    stackLo: Pointer;
    stackHi: Pointer;
    stackMap: Pointer;
    stackMapLen: PtrUInt;
    status: LongInt;
    goid: QWord;
    m: PM;
    schedlink: PG;
    waitlink: PG;
    parkKind: TParkKind;
    unlockCS: PRTLCriticalSection;
    unlockN: LongInt;
    unlocks: array[0..15] of PRTLCriticalSection;
    pollLink: PG;
    pollDesc: Pointer;
    pollMode: LongInt;
    kind: TPasKind;
    fn: CodePointer;
    arg: Pointer;
    method: TMethod;
    timerWhen: QWord;
    timerActive: Boolean;
    isMain: Boolean;
    isG0: Boolean;
  end;

  TM = record
    id: LongInt;
    g0: PG;
    curg: PG;
    p: PPasP;
    nextp: PPasP;
    parkEvent: PRTLEvent;
    spinning: Boolean;
    blocked: Boolean;
    rand: Cardinal;
    threadId: TThreadID;
    nextIdle: PM;
    alllink: PM;
  end;

  TPasP = record
    id: LongInt;
    status: LongInt;
    m: PM;
    runq: array[0..PasRunqSize - 1] of Pointer;
    runqhead: Cardinal;
    runqtail: Cardinal;
    runnext: Pointer;
    gFree: PG;
    schedlink: PPasP;
  end;

  TTimer = record
    when: QWord;
    gp: PG;
    next: Pointer;
  end;
  PTimer = ^TTimer;

const
  Gidle     = 0;
  Grunnable = 1;
  Grunning  = 2;
  Gwaiting  = 3;
  Gdead     = 4;

  Pidle    = 0;
  Prunning = 1;

function PasSave(var Buf: TPasBuf): LongInt; [external name 'FPC_SETJMP'];
procedure PasRestore(var Buf: TPasBuf; Value: LongInt); [external name 'FPC_LONGJMP'];

function libc_sysconf(Name: LongInt): PtrInt; cdecl; external 'c' name 'sysconf';
function libc_epoll_create1(flags: LongInt): LongInt; cdecl; external 'c' name 'epoll_create1';
function libc_epoll_ctl(epfd, op, fd: LongInt; event: Pointer): LongInt; cdecl; external 'c' name 'epoll_ctl';
function libc_epoll_wait(epfd: LongInt; events: Pointer; maxevents, timeout: LongInt): LongInt; cdecl; external 'c' name 'epoll_wait';
function libc_eventfd(initval: LongWord; flags: LongInt): LongInt; cdecl; external 'c' name 'eventfd';
function libc_write(fd: LongInt; buf: Pointer; count: PtrUInt): PtrInt; cdecl; external 'c' name 'write';
function libc_read(fd: LongInt; buf: Pointer; count: PtrUInt): PtrInt; cdecl; external 'c' name 'read';
function libc_close(fd: LongInt): LongInt; cdecl; external 'c' name 'close';
function libc_fcntl(fd, cmd: LongInt; arg: LongInt): LongInt; cdecl; external 'c' name 'fcntl';

const
  { unistd.h: _SC_NPROCESSORS_ONLN on Linux }
  SC_NPROCESSORS_ONLN = 84;
  EPOLLIN     = $001;
  EPOLLOUT    = $004;
  EPOLLERR    = $008;
  EPOLLHUP    = $010;
  EPOLLRDHUP  = $2000;
  EPOLLET     = LongWord($80000000);
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CLOEXEC = $80000;
  EFD_CLOEXEC   = $80000;
  EFD_NONBLOCK  = $800;
  F_GETFL = 3;
  F_SETFL = 4;
  O_NONBLOCK = 2048;
  PollRead = 1;
  PollWrite = 2;

{ Linux x86_64 epoll_event is packed: 4-byte events + 8-byte data = 12 bytes. }
type
  TEpollEvent = packed record
    events: LongWord;
    data: Pointer;
  end;
  PEpollEvent = ^TEpollEvent;

  PPollDesc = ^TPollDesc;
  TPollDesc = record
    fd: LongInt;
    readers: Pointer;
    writers: Pointer;
    next: PPollDesc;
  end;
{$packrecords default}

threadvar
  currentM: PM;

var
  initState: LongInt = 0;
  defaultStack: PtrUInt = PasStackDefault;
  nproc: LongInt = 0;
  allp: array of PPasP;
  allm: PM = nil;

  schedLock: TRTLCriticalSection;
  globRunqHead: PG = nil;
  globRunqTail: PG = nil;
  globRunqN: LongInt = 0;
  idleP: PPasP = nil;
  idleM: PM = nil;
  nIdleP: LongInt = 0;
  nIdleM: LongInt = 0;
  nM: LongInt = 0;
  nG: LongInt = 0;
  nSpinning: LongInt = 0;
  nextGoid: Int64 = 1;
  gFreeGlobal: PG = nil;
  epfd: LongInt = -1;
  eventFd: LongInt = -1;
  pollList: PPollDesc = nil;
  pollLock: TRTLCriticalSection;
  netpollWakeSig: LongInt = 0;
  timersHead: PTimer = nil;


procedure G0Loop; forward;
procedure Schedule; forward;
function  FindRunnable: PG; forward;
procedure Execute(gp: PG); forward;
procedure RunqPut(pp: PPasP; gp: PG; Next: Boolean); forward;
function  RunqGet(pp: PPasP): PG; forward;
function  RunqSteal(pp, Victim: PPasP): PG; forward;
procedure GlobRunqPut(gp: PG); forward;
function  GlobRunqGet: PG; forward;
procedure ReadyLocked(gp: PG); forward;
procedure Wakep; forward;
procedure StartM(pp: PPasP); forward;
procedure ParkM; forward;
procedure FinishPark; forward;
function  AllocG(StackSize: PtrUInt): PG; forward;
procedure FreeG(gp: PG); forward;
procedure RecycleG(gp: PG); forward;
function  GfGet(pp: PPasP): PG; forward;
procedure BindP(mp: PM; pp: PPasP); forward;
procedure UnbindP(mp: PM); forward;
function  CheapRand(mp: PM): Cardinal; forward;
function  NowMs: QWord; forward;
procedure AddTimer(gp: PG; Ms: QWord); forward;
procedure FireTimers; forward;
function  NextTimerMs: LongInt; forward;
procedure NetpollInit; forward;
procedure Netpoll(TimeoutMs: LongInt); forward;
procedure NetpollBreak; forward;

procedure InitBuf(out Buf: TPasBuf; SP, PC: Pointer);
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Buf.rsp := PtrUInt(SP);
  Buf.rip := PtrUInt(PC);
end;

procedure SetupFreshStack(gp: PG; Entry: CodePointer);
var
  sp: PtrUInt;
begin
  sp := PtrUInt(gp^.stackHi) and not PtrUInt(15);
  Dec(sp, 8);
  PQWord(sp)^ := 0;
  InitBuf(gp^.sched, Pointer(sp), Pointer(Entry));
end;

function GetM: PM; inline;
begin
  Result := currentM;
end;

procedure PasTrampoline;
var
  gp: PG;
  meth: TMethod;
begin
  gp := GetM^.curg;
  try
    case gp^.kind of
      pskProc:
        TPasProc(gp^.fn)();
      pskProcArg:
        TPasProcArg(gp^.fn)(gp^.arg);
      pskMethod:
        begin
          meth := gp^.method;
          TPasMethod(meth)();
        end;
    end;
  except
    on E: Exception do
      Writeln(StdErr, 'pasrutina ', gp^.goid, ': ', E.ClassName, ': ', E.Message);
  end;
  PasExit;
end;

procedure ApplyUserStack(gp: PG);
begin
  StackBottom := gp^.stackLo;
  StackLength := PtrUInt(gp^.stackHi) - PtrUInt(gp^.stackLo);
end;

procedure G0Loop;
var
  mp: PM;
begin
  mp := GetM;
  if PasSave(mp^.g0^.sched) = 0 then
    { first entry: the crafted longjmp lands here };
  FinishPark;
  Schedule;
end;

procedure FinishPark;
var
  mp: PM;
  gp: PG;
  kind: TParkKind;
  cs: PRTLCriticalSection;
  i: LongInt;
begin
  mp := GetM;
  gp := mp^.curg;
  if gp = nil then
    Exit;
  kind := gp^.parkKind;
  gp^.parkKind := pkNone;
  cs := gp^.unlockCS;
  gp^.unlockCS := nil;
  case kind of
    pkPark:
      begin
        gp^.status := Gwaiting;
        gp^.m := nil;
        mp^.curg := nil;
        if cs <> nil then
          LeaveCriticalSection(cs^);
        for i := 0 to gp^.unlockN - 1 do
          if gp^.unlocks[i] <> nil then
            LeaveCriticalSection(gp^.unlocks[i]^);
        gp^.unlockN := 0;
      end;
    pkYield:
      begin
        gp^.status := Grunnable;
        gp^.m := nil;
        mp^.curg := nil;
        if mp^.p <> nil then
          RunqPut(mp^.p, gp, False)
        else
          GlobRunqPut(gp);
      end;
    pkExit:
      begin
        gp^.m := nil;
        mp^.curg := nil;
        InterlockedDecrement(nG);
        RecycleG(gp);
      end;
    pkNone:
      ;
  end;
end;

procedure SwitchToG0;
var
  mp: PM;
begin
  mp := GetM;
  ApplyUserStack(mp^.g0);
  PasRestore(mp^.g0^.sched, 1);
end;

procedure ParkWith(Kind: TParkKind);
var
  mp: PM;
  gp: PG;
begin
  mp := GetM;
  if mp = nil then
    raise Exception.Create('pasrutinas: PasPark outside a pasrutina (missing uses cthreads, pasrutinas?)');
  gp := mp^.curg;
  if gp = nil then
    raise Exception.Create('pasrutinas: park on g0');
  gp^.parkKind := Kind;
  if PasSave(gp^.sched) = 0 then
    SwitchToG0;
end;

procedure Execute(gp: PG);
var
  mp: PM;
begin
  mp := GetM;
  mp^.curg := gp;
  gp^.m := mp;
  gp^.status := Grunning;
  ApplyUserStack(gp);
  PasRestore(gp^.sched, 1);
end;

procedure Schedule;
var
  gp: PG;
begin
  while True do
  begin
    gp := FindRunnable;
    if gp <> nil then
      Execute(gp);
    ParkM;
  end;
end;

procedure GlobRunqPut(gp: PG);
begin
  gp^.schedlink := nil;
  if globRunqTail <> nil then
    globRunqTail^.schedlink := gp
  else
    globRunqHead := gp;
  globRunqTail := gp;
  Inc(globRunqN);
end;

function GlobRunqGet: PG;
begin
  Result := globRunqHead;
  if Result = nil then
    Exit;
  globRunqHead := Result^.schedlink;
  if globRunqHead = nil then
    globRunqTail := nil;
  Result^.schedlink := nil;
  Dec(globRunqN);
end;

procedure RunqPut(pp: PPasP; gp: PG; Next: Boolean);
var
  h, t: Cardinal;
  old: PG;
begin
  if Next then
  begin
    old := PG(InterlockedExchange(pp^.runnext, Pointer(gp)));
    if old = nil then
      Exit;
    gp := old;
  end;
  h := pp^.runqhead;
  t := pp^.runqtail;
  if t - h < PasRunqSize then
  begin
    pp^.runq[t and (PasRunqSize - 1)] := gp;
    ReadWriteBarrier;
    pp^.runqtail := t + 1;
    Exit;
  end;
  EnterCriticalSection(schedLock);
  GlobRunqPut(gp);
  LeaveCriticalSection(schedLock);
end;

function RunqGet(pp: PPasP): PG;
var
  h, t: Cardinal;
  next: PG;
begin
  next := PG(InterlockedExchange(pp^.runnext, nil));
  if next <> nil then
  begin
    Result := next;
    Exit;
  end;
  while True do
  begin
    h := pp^.runqhead;
    t := pp^.runqtail;
    if t = h then
    begin
      Result := nil;
      Exit;
    end;
    Result := PG(pp^.runq[h and (PasRunqSize - 1)]);
    if InterlockedCompareExchange(pp^.runqhead, h + 1, h) = h then
      Exit;
  end;
end;

function RunqSteal(pp, Victim: PPasP): PG;
var
  h, t, n, i: Cardinal;
begin
  Result := nil;
  if Victim = nil then
    Exit;
  h := Victim^.runqhead;
  t := Victim^.runqtail;
  n := t - h;
  if n = 0 then
  begin
    Result := PG(InterlockedExchange(Victim^.runnext, nil));
    Exit;
  end;
  n := n - n div 2;
  if n = 0 then
    Exit;
  if InterlockedCompareExchange(Victim^.runqhead, h + n, h) <> h then
    Exit;
  for i := 0 to n - 1 do
    RunqPut(pp, PG(Victim^.runq[(h + i) and (PasRunqSize - 1)]), False);
  Result := RunqGet(pp);
end;

function CheapRand(mp: PM): Cardinal;
begin
  mp^.rand := mp^.rand * 1103515245 + 12345;
  Result := mp^.rand;
end;

procedure BindP(mp: PM; pp: PPasP);
begin
  mp^.p := pp;
  pp^.m := mp;
  pp^.status := Prunning;
end;

procedure UnbindP(mp: PM);
var
  pp: PPasP;
begin
  pp := mp^.p;
  if pp = nil then
    Exit;
  pp^.m := nil;
  pp^.status := Pidle;
  mp^.p := nil;
  EnterCriticalSection(schedLock);
  pp^.schedlink := idleP;
  idleP := pp;
  Inc(nIdleP);
  LeaveCriticalSection(schedLock);
end;

procedure Wakep;
var
  pp: PPasP;
begin
  if nIdleP = 0 then
    Exit;
  if nSpinning <> 0 then
    Exit;
  EnterCriticalSection(schedLock);
  pp := idleP;
  if pp = nil then
  begin
    LeaveCriticalSection(schedLock);
    Exit;
  end;
  idleP := pp^.schedlink;
  Dec(nIdleP);
  LeaveCriticalSection(schedLock);
  StartM(pp);
  NetpollBreak;
end;

function MStart(Parameter: Pointer): PtrInt;
var
  mp: PM;
  g0: PG;
begin
  mp := PM(Parameter);
  currentM := mp;
  New(g0);
  FillChar(g0^, SizeOf(TG), 0);
  g0^.isG0 := True;
  g0^.status := Grunning;
  g0^.stackLo := StackBottom;
  g0^.stackHi := Pointer(PtrUInt(StackBottom) + StackLength);
  mp^.g0 := g0;
  if mp^.nextp <> nil then
  begin
    BindP(mp, mp^.nextp);
    mp^.nextp := nil;
  end;
  G0Loop;
  Result := 0;
end;

procedure StartM(pp: PPasP);
var
  mp: PM;
  tid: TThreadID;
begin
  EnterCriticalSection(schedLock);
  mp := idleM;
  if mp <> nil then
  begin
    idleM := mp^.nextIdle;
    Dec(nIdleM);
    mp^.blocked := False;
    mp^.nextp := pp;
    LeaveCriticalSection(schedLock);
    RTLEventSetEvent(mp^.parkEvent);
    NetpollBreak;
    Exit;
  end;
  LeaveCriticalSection(schedLock);

  if not IsMultiThread then
  begin
    EnterCriticalSection(schedLock);
    pp^.schedlink := idleP;
    idleP := pp;
    Inc(nIdleP);
    LeaveCriticalSection(schedLock);
    Exit;
  end;

  New(mp);
  FillChar(mp^, SizeOf(TM), 0);
  mp^.id := InterlockedIncrement(nM);
  mp^.parkEvent := RTLEventCreate;
  mp^.nextp := pp;
  mp^.rand := Cardinal(PtrUInt(mp) xor GetTickCount64);
  mp^.alllink := allm;
  allm := mp;
  tid := BeginThread(nil, PasMStackSize, @MStart, mp, 0, mp^.threadId);
  if tid = TThreadID(0) then
  begin
    EnterCriticalSection(schedLock);
    pp^.schedlink := idleP;
    idleP := pp;
    Inc(nIdleP);
    LeaveCriticalSection(schedLock);
  end;
end;

function PHasWork(pp: PPasP): Boolean;
begin
  Result := False;
  if pp = nil then
    Exit;
  if pp^.runnext <> nil then
    Exit(True);
  if pp^.runqhead <> pp^.runqtail then
    Exit(True);
  Result := False;
end;

function AnyRunnable: Boolean;
var
  i: LongInt;
begin
  if globRunqN > 0 then
    Exit(True);
  for i := 0 to nproc - 1 do
    if PHasWork(allp[i]) then
      Exit(True);
  Result := False;
end;

function HasRunnable: Boolean;
var
  mp: PM;
begin
  FireTimers;
  mp := GetM;
  if PHasWork(mp^.p) then
    Exit(True);
  if globRunqN > 0 then
    Exit(True);
  Result := False;
end;

procedure ParkM;
var
  mp, prev: PM;
  pp: PPasP;
  waitMs: LongInt;
begin
  mp := GetM;
  if HasRunnable then
    Exit;
  if AnyRunnable then
  begin
    ThreadSwitch;
    Exit;
  end;
  waitMs := NextTimerMs;
  pp := mp^.p;
  UnbindP(mp);
  if (pp <> nil) and (PHasWork(pp) or (globRunqN > 0)) then
  begin
    StartM(pp);
    pp := nil;
  end;
  mp^.blocked := True;
  EnterCriticalSection(schedLock);
  mp^.nextIdle := idleM;
  idleM := mp;
  Inc(nIdleM);
  LeaveCriticalSection(schedLock);
  if epfd >= 0 then
    Netpoll(waitMs)
  else if waitMs < 0 then
    RTLEventWaitFor(mp^.parkEvent)
  else
    RTLEventWaitFor(mp^.parkEvent, waitMs);
  RTLEventResetEvent(mp^.parkEvent);
  EnterCriticalSection(schedLock);
  if idleM = mp then
  begin
    idleM := mp^.nextIdle;
    Dec(nIdleM);
  end
  else
  begin
    prev := idleM;
    while (prev <> nil) and (prev^.nextIdle <> mp) do
      prev := prev^.nextIdle;
    if prev <> nil then
    begin
      prev^.nextIdle := mp^.nextIdle;
      Dec(nIdleM);
    end;
  end;
  LeaveCriticalSection(schedLock);
  mp^.blocked := False;
  if mp^.p = nil then
  begin
    if mp^.nextp <> nil then
    begin
      BindP(mp, mp^.nextp);
      mp^.nextp := nil;
    end
    else
    begin
      EnterCriticalSection(schedLock);
      if idleP <> nil then
      begin
        BindP(mp, idleP);
        idleP := idleP^.schedlink;
        Dec(nIdleP);
      end;
      LeaveCriticalSection(schedLock);
    end;
  end;
end;

function AllocStack(Size: PtrUInt; out Map: Pointer; out MapLen: PtrUInt;
  out Lo, Hi: Pointer): Boolean;
var
  total: PtrUInt;
  p: Pointer;
begin
  total := Size + PasStackGuard;
  total := (total + 4095) and not PtrUInt(4095);
  p := Fpmmap(nil, total, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if (p = nil) or (p = MAP_FAILED) then
  begin
    Result := False;
    Exit;
  end;
  if Fpmprotect(p, PasStackGuard, PROT_NONE) <> 0 then
    { no guard page: continue; overflow would hit heap, worse but usable };
  Map := p;
  MapLen := total;
  Lo := Pointer(PtrUInt(p) + PasStackGuard);
  Hi := Pointer(PtrUInt(p) + total);
  Result := True;
end;

procedure FreeStack(Map: Pointer; MapLen: PtrUInt);
begin
  if Map <> nil then
    Fpmunmap(Map, MapLen);
end;

function AllocG(StackSize: PtrUInt): PG;
begin
  New(Result);
  FillChar(Result^, SizeOf(TG), 0);
  if not AllocStack(StackSize, Result^.stackMap, Result^.stackMapLen,
    Result^.stackLo, Result^.stackHi) then
  begin
    Dispose(Result);
    Result := nil;
    Exit;
  end;
  Result^.status := Gdead;
end;

procedure FreeG(gp: PG);
begin
  if gp = nil then
    Exit;
  if not gp^.isMain then
    FreeStack(gp^.stackMap, gp^.stackMapLen);
  Dispose(gp);
end;

procedure RecycleG(gp: PG);
var
  mp: PM;
  pp: PPasP;
begin
  gp^.status := Gdead;
  gp^.fn := nil;
  gp^.arg := nil;
  gp^.method.Code := nil;
  gp^.method.Data := nil;
  gp^.timerActive := False;
  gp^.waitlink := nil;
  gp^.schedlink := nil;
  mp := GetM;
  pp := nil;
  if mp <> nil then
    pp := mp^.p;
  if (pp <> nil) and (not gp^.isMain) then
  begin
    gp^.schedlink := pp^.gFree;
    pp^.gFree := gp;
  end
  else if not gp^.isMain then
  begin
    EnterCriticalSection(schedLock);
    gp^.schedlink := gFreeGlobal;
    gFreeGlobal := gp;
    LeaveCriticalSection(schedLock);
  end;
end;

function GfGet(pp: PPasP): PG;
begin
  Result := nil;
  if pp <> nil then
  begin
    Result := pp^.gFree;
    if Result <> nil then
    begin
      pp^.gFree := Result^.schedlink;
      Result^.schedlink := nil;
      Exit;
    end;
  end;
  EnterCriticalSection(schedLock);
  Result := gFreeGlobal;
  if Result <> nil then
  begin
    gFreeGlobal := Result^.schedlink;
    Result^.schedlink := nil;
  end;
  LeaveCriticalSection(schedLock);
  if Result = nil then
    Result := AllocG(defaultStack);
end;

function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

procedure AddTimer(gp: PG; Ms: QWord);
var
  t, prev, cur: PTimer;
begin
  New(t);
  t^.when := NowMs + Ms;
  t^.gp := gp;
  gp^.timerWhen := t^.when;
  gp^.timerActive := True;
  EnterCriticalSection(schedLock);
  prev := nil;
  cur := timersHead;
  while (cur <> nil) and (cur^.when <= t^.when) do
  begin
    prev := cur;
    cur := PTimer(cur^.next);
  end;
  t^.next := cur;
  if prev = nil then
    timersHead := t
  else
    prev^.next := t;
  LeaveCriticalSection(schedLock);
end;

procedure FireTimers;
var
  now: QWord;
  t: PTimer;
  gp: PG;
begin
  now := NowMs;
  while True do
  begin
    EnterCriticalSection(schedLock);
    t := timersHead;
    if (t = nil) or (t^.when > now) then
    begin
      LeaveCriticalSection(schedLock);
      Exit;
    end;
    timersHead := PTimer(t^.next);
    gp := t^.gp;
    LeaveCriticalSection(schedLock);
    Dispose(t);
    if gp^.timerActive then
    begin
      gp^.timerActive := False;
      if gp^.status = Gwaiting then
        ReadyLocked(gp);
    end;
  end;
end;

function NextTimerMs: LongInt;
var
  now, when: QWord;
begin
  EnterCriticalSection(schedLock);
  if timersHead = nil then
  begin
    LeaveCriticalSection(schedLock);
    Result := -1;
    Exit;
  end;
  when := timersHead^.when;
  LeaveCriticalSection(schedLock);
  now := NowMs;
  if when <= now then
    Result := 0
  else if when - now > 2147483647 then
    Result := 2147483647
  else
    Result := LongInt(when - now);
end;

procedure NetpollInit;
var
  ev: TEpollEvent;
begin
  epfd := libc_epoll_create1(EPOLL_CLOEXEC);
  if epfd < 0 then
    Exit;
  eventFd := libc_eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK);
  if eventFd < 0 then
  begin
    libc_close(epfd);
    epfd := -1;
    Exit;
  end;
  FillChar(ev, SizeOf(ev), 0);
  ev.events := EPOLLIN;
  ev.data := nil;
  if libc_epoll_ctl(epfd, EPOLL_CTL_ADD, eventFd, @ev) <> 0 then
  begin
    libc_close(eventFd);
    libc_close(epfd);
    epfd := -1;
    eventFd := -1;
  end;
end;

procedure NetpollBreak;
var
  one: QWord;
begin
  if eventFd < 0 then
    Exit;
  if InterlockedCompareExchange(netpollWakeSig, 1, 0) <> 0 then
    Exit;
  one := 1;
  libc_write(eventFd, @one, SizeOf(one));
end;

procedure ReadyPollList(var Head: Pointer);
var
  gp, nx: PG;
begin
  gp := PG(Head);
  Head := nil;
  while gp <> nil do
  begin
    nx := gp^.pollLink;
    gp^.pollLink := nil;
    gp^.pollDesc := nil;
    gp^.timerActive := False;
    if gp^.status = Gwaiting then
      ReadyLocked(gp);
    gp := nx;
  end;
end;

procedure Netpoll(TimeoutMs: LongInt);
var
  evs: array[0..63] of TEpollEvent;
  n, i: LongInt;
  pd: PPollDesc;
  one: QWord;
  mode: LongWord;
begin
  if epfd < 0 then
    Exit;
  n := libc_epoll_wait(epfd, @evs[0], Length(evs), TimeoutMs);
  if n <= 0 then
    Exit;
  for i := 0 to n - 1 do
  begin
    if evs[i].data = nil then
    begin
      libc_read(eventFd, @one, SizeOf(one));
      InterlockedExchange(netpollWakeSig, 0);
      Continue;
    end;
    pd := PPollDesc(evs[i].data);
    mode := evs[i].events;
    EnterCriticalSection(pollLock);
    if (mode and (EPOLLIN or EPOLLRDHUP or EPOLLHUP or EPOLLERR)) <> 0 then
      ReadyPollList(pd^.readers);
    if (mode and (EPOLLOUT or EPOLLHUP or EPOLLERR)) <> 0 then
      ReadyPollList(pd^.writers);
    LeaveCriticalSection(pollLock);
  end;
end;

function GetPollDesc(Fd: LongInt): PPollDesc;
var
  ev: TEpollEvent;
  fl: LongInt;
begin
  EnterCriticalSection(pollLock);
  Result := pollList;
  while Result <> nil do
  begin
    if Result^.fd = Fd then
    begin
      LeaveCriticalSection(pollLock);
      Exit;
    end;
    Result := Result^.next;
  end;
  New(Result);
  FillChar(Result^, SizeOf(TPollDesc), 0);
  Result^.fd := Fd;
  Result^.next := pollList;
  pollList := Result;
  LeaveCriticalSection(pollLock);
  fl := libc_fcntl(Fd, F_GETFL, 0);
  if fl >= 0 then
    libc_fcntl(Fd, F_SETFL, fl or O_NONBLOCK);
  FillChar(ev, SizeOf(ev), 0);
  ev.events := EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET;
  ev.data := Result;
  libc_epoll_ctl(epfd, EPOLL_CTL_ADD, Fd, @ev);
end;

procedure EnqueuePoll(var Head: Pointer; gp: PG);
begin
  gp^.pollLink := PG(Head);
  Head := gp;
end;

procedure RemovePoll(var Head: Pointer; gp: PG);
var
  p, prev: PG;
begin
  prev := nil;
  p := PG(Head);
  while p <> nil do
  begin
    if p = gp then
    begin
      if prev = nil then
        Head := p^.pollLink
      else
        prev^.pollLink := p^.pollLink;
      p^.pollLink := nil;
      Exit;
    end;
    prev := p;
    p := p^.pollLink;
  end;
end;

function WaitPoll(Fd, Mode: LongInt; TimeoutMs: LongInt): Boolean;
var
  pd: PPollDesc;
  gp: PG;
begin
  PasInit;
  if epfd < 0 then
    raise Exception.Create('pasrutinas: epoll unavailable');
  pd := GetPollDesc(Fd);
  gp := GetM^.curg;
  gp^.pollDesc := pd;
  gp^.pollMode := Mode;
  EnterCriticalSection(pollLock);
  if Mode = PollRead then
    EnqueuePoll(pd^.readers, gp)
  else
    EnqueuePoll(pd^.writers, gp);
  if TimeoutMs > 0 then
    AddTimer(gp, QWord(TimeoutMs));
  PasInternalParkUnlock(pollLock);
  Result := gp^.pollDesc = nil;
  if not Result then
  begin
    EnterCriticalSection(pollLock);
    if Mode = PollRead then
      RemovePoll(pd^.readers, gp)
    else
      RemovePoll(pd^.writers, gp);
    gp^.pollDesc := nil;
    LeaveCriticalSection(pollLock);
  end;
end;

procedure ReadyLocked(gp: PG);
var
  mp: PM;
begin
  if gp^.status = Grunnable then
    Exit;
  gp^.status := Grunnable;
  mp := GetM;
  if (mp <> nil) and (mp^.p <> nil) then
    RunqPut(mp^.p, gp, True)
  else
  begin
    EnterCriticalSection(schedLock);
    GlobRunqPut(gp);
    LeaveCriticalSection(schedLock);
  end;
  Wakep;
end;

function FindRunnable: PG;
var
  mp: PM;
  pp, victim: PPasP;
  i, n, start: LongInt;
begin
  Result := nil;
  mp := GetM;
  FireTimers;
  Netpoll(0);
  pp := mp^.p;
  if pp <> nil then
  begin
    Result := RunqGet(pp);
    if Result <> nil then
      Exit;
  end;
  EnterCriticalSection(schedLock);
  Result := GlobRunqGet;
  LeaveCriticalSection(schedLock);
  if Result <> nil then
    Exit;
  if pp = nil then
    Exit;
  n := nproc;
  if n <= 1 then
    Exit;
  start := LongInt(CheapRand(mp) mod Cardinal(n));
  for i := 0 to n - 1 do
  begin
    victim := allp[(start + i) mod n];
    if victim = pp then
      Continue;
    Result := RunqSteal(pp, victim);
    if Result <> nil then
      Exit;
  end;
end;

procedure NewPas(Kind: TPasKind; Fn: CodePointer; Arg: Pointer; const Method: TMethod);
var
  mp: PM;
  pp: PPasP;
  gp: PG;
begin
  PasInit;
  mp := GetM;
  if mp = nil then
    raise Exception.Create('pasrutinas: Pas() must run inside a pasrutina');
  pp := mp^.p;
  gp := GfGet(pp);
  if gp = nil then
    raise Exception.Create('pasrutinas: out of memory for stack');
  gp^.kind := Kind;
  gp^.fn := Fn;
  gp^.arg := Arg;
  gp^.method := Method;
  gp^.goid := QWord(InterlockedIncrement64(nextGoid));
  gp^.parkKind := pkNone;
  gp^.unlockCS := nil;
  gp^.timerActive := False;
  SetupFreshStack(gp, @PasTrampoline);
  gp^.status := Grunnable;
  InterlockedIncrement(nG);
  if pp <> nil then
    RunqPut(pp, gp, True)
  else
  begin
    EnterCriticalSection(schedLock);
    GlobRunqPut(gp);
    LeaveCriticalSection(schedLock);
  end;
  Wakep;
end;

procedure InitMainM;
var
  i: LongInt;
  pp: PPasP;
  mainG, g0: PG;
  mp: PM;
begin
  if nproc <= 0 then
  begin
    nproc := LongInt(libc_sysconf(SC_NPROCESSORS_ONLN));
    if nproc <= 0 then
      nproc := LongInt(GetCPUCount);
    if nproc <= 0 then
      nproc := 1;
  end;
  InitCriticalSection(schedLock);
  SetLength(allp, nproc);
  for i := 0 to nproc - 1 do
  begin
    New(pp);
    FillChar(pp^, SizeOf(TPasP), 0);
    pp^.id := i;
    pp^.status := Pidle;
    allp[i] := pp;
  end;
  for i := 1 to nproc - 1 do
  begin
    allp[i]^.schedlink := idleP;
    idleP := allp[i];
    Inc(nIdleP);
  end;

  New(mp);
  FillChar(mp^, SizeOf(TM), 0);
  mp^.id := 0;
  mp^.parkEvent := RTLEventCreate;
  mp^.rand := $9E3779B9;
  InterlockedIncrement(nM);
  allm := mp;
  currentM := mp;

  New(g0);
  FillChar(g0^, SizeOf(TG), 0);
  g0^.isG0 := True;
  if not AllocStack(PasG0StackSize, g0^.stackMap, g0^.stackMapLen,
    g0^.stackLo, g0^.stackHi) then
    raise Exception.Create('pasrutinas: could not reserve g0 stack');
  SetupFreshStack(g0, @G0Loop);
  mp^.g0 := g0;

  New(mainG);
  FillChar(mainG^, SizeOf(TG), 0);
  mainG^.isMain := True;
  mainG^.status := Grunning;
  mainG^.goid := 1;
  nextGoid := 1;
  mainG^.stackLo := StackBottom;
  mainG^.stackHi := Pointer(PtrUInt(StackBottom) + StackLength);
  mainG^.m := mp;
  mp^.curg := mainG;
  InterlockedIncrement(nG);

  BindP(mp, allp[0]);
  InitCriticalSection(pollLock);
  NetpollInit;
end;

procedure PasInit;
begin
  if initState = 2 then
    Exit;
  if InterlockedCompareExchange(initState, 1, 0) = 0 then
  begin
    InitMainM;
    WriteBarrier;
    InterlockedExchange(initState, 2);
  end
  else
    while initState <> 2 do
      ThreadSwitch;
end;

procedure Pas(Proc: TPasProc);
var
  dummy: TMethod;
begin
  dummy.Code := nil;
  dummy.Data := nil;
  NewPas(pskProc, CodePointer(Proc), nil, dummy);
end;

procedure Pas(Proc: TPasProcArg; Arg: Pointer);
var
  dummy: TMethod;
begin
  dummy.Code := nil;
  dummy.Data := nil;
  NewPas(pskProcArg, CodePointer(Proc), Arg, dummy);
end;

procedure Pas(Method: TPasMethod);
begin
  NewPas(pskMethod, nil, nil, TMethod(Method));
end;

procedure PasYield;
begin
  PasInit;
  ParkWith(pkYield);
end;

procedure PasExit;
begin
  ParkWith(pkExit);
end;

procedure PasSleep(Ms: QWord);
var
  gp: PG;
begin
  PasInit;
  if Ms = 0 then
  begin
    PasYield;
    Exit;
  end;
  gp := GetM^.curg;
  AddTimer(gp, Ms);
  ParkWith(pkPark);
end;

procedure PasPark;
begin
  PasInit;
  ParkWith(pkPark);
end;

procedure PasReady(G: TPasrutina);
begin
  if G = nil then
    Exit;
  ReadyLocked(PG(G));
end;

procedure PasInternalReady(G: TPasrutina);
begin
  PasReady(G);
end;

function PasParkUnlock(var CS: TRTLCriticalSection): Boolean;
begin
  PasInternalParkUnlock(CS);
  Result := True;
end;

procedure PasInternalParkUnlock(var CS: TRTLCriticalSection);
var
  gp: PG;
begin
  gp := GetM^.curg;
  gp^.unlockCS := @CS;
  ParkWith(pkPark);
end;

procedure PasInternalParkUnlockMany(const Locks: array of PRTLCriticalSection);
var
  gp: PG;
  i, n: LongInt;
begin
  gp := GetM^.curg;
  n := Length(Locks);
  if n > 16 then
    n := 16;
  gp^.unlockN := n;
  for i := 0 to n - 1 do
    gp^.unlocks[i] := Locks[i];
  ParkWith(pkPark);
end;

procedure PasWaitRead(Fd: LongInt);
begin
  WaitPoll(Fd, PollRead, -1);
end;

procedure PasWaitWrite(Fd: LongInt);
begin
  WaitPoll(Fd, PollWrite, -1);
end;

function PasWaitReadTimeout(Fd: LongInt; Ms: LongInt): Boolean;
begin
  Result := WaitPoll(Fd, PollRead, Ms);
end;

function PasCurrent: TPasrutina;
var
  mp: PM;
begin
  mp := GetM;
  if mp = nil then
    Result := nil
  else
    Result := mp^.curg;
end;

function PasID: QWord;
var
  gp: PG;
begin
  gp := PG(PasCurrent);
  if gp = nil then
    Result := 0
  else
    Result := gp^.goid;
end;

function NumPasrutinas: LongInt;
begin
  Result := nG;
end;

function PASMAXPROCS(N: LongInt): LongInt;
begin
  Result := nproc;
  if Result = 0 then
  begin
    Result := LongInt(GetCPUCount);
    if Result <= 0 then
      Result := 1;
  end;
  if N < 1 then
    Exit;
  if initState = 2 then
    Exit;
  nproc := N;
end;

procedure PasSetStackSize(Bytes: PtrUInt);
begin
  if Bytes < 4096 then
    Bytes := 4096;
  defaultStack := Bytes;
end;

function PasStackSize: PtrUInt;
begin
  Result := defaultStack;
end;

{ TPasWaitGroup }

type
  PWaitNode = PG;

constructor TPasWaitGroup.Create;
begin
  inherited Create;
  FCount := 0;
  FWaiters := nil;
  InitCriticalSection(FLock);
end;

destructor TPasWaitGroup.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPasWaitGroup.Add(Delta: LongInt);
var
  n: LongInt;
  w, nx: PG;
begin
  PasInit;
  n := InterlockedExchangeAdd(FCount, Delta) + Delta;
  if n < 0 then
    raise Exception.Create('TPasWaitGroup.Add: negative counter');
  if (n > 0) or (Delta >= 0) then
    Exit;
  EnterCriticalSection(FLock);
  w := PG(FWaiters);
  FWaiters := nil;
  LeaveCriticalSection(FLock);
  while w <> nil do
  begin
    nx := w^.waitlink;
    w^.waitlink := nil;
    PasReady(w);
    w := nx;
  end;
end;

procedure TPasWaitGroup.Done;
begin
  Add(-1);
end;

procedure TPasWaitGroup.Wait;
var
  gp: PG;
begin
  PasInit;
  if FCount = 0 then
    Exit;
  gp := PG(PasCurrent);
  EnterCriticalSection(FLock);
  if FCount = 0 then
  begin
    LeaveCriticalSection(FLock);
    Exit;
  end;
  gp^.waitlink := PG(FWaiters);
  FWaiters := gp;
  PasInternalParkUnlock(FLock);
end;

{ TPasMutex }

constructor TPasMutex.Create;
begin
  inherited Create;
  FLocked := 0;
  FWaiters := nil;
  InitCriticalSection(FLock);
end;

destructor TPasMutex.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPasMutex.Lock;
var
  gp: PG;
begin
  PasInit;
  EnterCriticalSection(FLock);
  if FLocked = 0 then
  begin
    FLocked := 1;
    LeaveCriticalSection(FLock);
    Exit;
  end;
  gp := PG(PasCurrent);
  gp^.waitlink := PG(FWaiters);
  FWaiters := gp;
  PasInternalParkUnlock(FLock);
end;

procedure TPasMutex.Unlock;
var
  w: PG;
begin
  EnterCriticalSection(FLock);
  w := PG(FWaiters);
  if w <> nil then
  begin
    FWaiters := w^.waitlink;
    w^.waitlink := nil;
    LeaveCriticalSection(FLock);
    PasReady(w);
    Exit;
  end;
  FLocked := 0;
  LeaveCriticalSection(FLock);
end;

{ TPasRWMutex }

constructor TPasRWMutex.Create;
begin
  inherited Create;
  FReaders := 0;
  FWriter := False;
  FReadWaiters := nil;
  FWriteWaiters := nil;
  InitCriticalSection(FLock);
end;

destructor TPasRWMutex.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPasRWMutex.BeginRead;
var
  gp: PG;
begin
  PasInit;
  EnterCriticalSection(FLock);
  if FWriter or (FWriteWaiters <> nil) then
  begin
    gp := PG(PasCurrent);
    gp^.waitlink := PG(FReadWaiters);
    FReadWaiters := gp;
    PasInternalParkUnlock(FLock);
    Exit;
  end;
  Inc(FReaders);
  LeaveCriticalSection(FLock);
end;

procedure TPasRWMutex.EndRead;
var
  w: PG;
begin
  EnterCriticalSection(FLock);
  Dec(FReaders);
  if (FReaders = 0) and (FWriteWaiters <> nil) then
  begin
    w := PG(FWriteWaiters);
    FWriteWaiters := w^.waitlink;
    w^.waitlink := nil;
    FWriter := True;
    LeaveCriticalSection(FLock);
    PasReady(w);
    Exit;
  end;
  LeaveCriticalSection(FLock);
end;

procedure TPasRWMutex.Lock;
var
  gp: PG;
begin
  PasInit;
  EnterCriticalSection(FLock);
  if (FReaders > 0) or FWriter then
  begin
    gp := PG(PasCurrent);
    gp^.waitlink := PG(FWriteWaiters);
    FWriteWaiters := gp;
    PasInternalParkUnlock(FLock);
    Exit;
  end;
  FWriter := True;
  LeaveCriticalSection(FLock);
end;

procedure TPasRWMutex.Unlock;
var
  w, nx: PG;
begin
  EnterCriticalSection(FLock);
  FWriter := False;
  if FWriteWaiters <> nil then
  begin
    w := PG(FWriteWaiters);
    FWriteWaiters := w^.waitlink;
    w^.waitlink := nil;
    FWriter := True;
    LeaveCriticalSection(FLock);
    PasReady(w);
    Exit;
  end;
  w := PG(FReadWaiters);
  FReadWaiters := nil;
  while w <> nil do
  begin
    nx := w^.waitlink;
    w^.waitlink := nil;
    Inc(FReaders);
    PasReady(w);
    w := nx;
  end;
  LeaveCriticalSection(FLock);
end;

{ TPasOnce }

constructor TPasOnce.Create;
begin
  inherited Create;
  FDone := 0;
  FMu := TPasMutex.Create;
end;

destructor TPasOnce.Destroy;
begin
  FMu.Free;
  inherited Destroy;
end;

procedure TPasOnce.Do_(Proc: TPasProc);
begin
  if FDone <> 0 then
    Exit;
  FMu.Lock;
  try
    if FDone = 0 then
    begin
      Proc();
      FDone := 1;
    end;
  finally
    FMu.Unlock;
  end;
end;

{ TPasCond }

constructor TPasCond.Create;
begin
  inherited Create;
  FWaiters := nil;
  InitCriticalSection(FLock);
end;

destructor TPasCond.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPasCond.Wait(M: TPasMutex);
var
  gp: PG;
begin
  PasInit;
  gp := PG(PasCurrent);
  EnterCriticalSection(FLock);
  gp^.waitlink := PG(FWaiters);
  FWaiters := gp;
  M.Unlock;
  PasInternalParkUnlock(FLock);
  M.Lock;
end;

procedure TPasCond.Signal;
var
  w: PG;
begin
  EnterCriticalSection(FLock);
  w := PG(FWaiters);
  if w <> nil then
  begin
    FWaiters := w^.waitlink;
    w^.waitlink := nil;
  end;
  LeaveCriticalSection(FLock);
  if w <> nil then
    PasReady(w);
end;

procedure TPasCond.Broadcast;
var
  w, nx: PG;
begin
  EnterCriticalSection(FLock);
  w := PG(FWaiters);
  FWaiters := nil;
  LeaveCriticalSection(FLock);
  while w <> nil do
  begin
    nx := w^.waitlink;
    w^.waitlink := nil;
    PasReady(w);
    w := nx;
  end;
end;

end.
