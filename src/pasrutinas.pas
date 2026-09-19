{
    This file is part of pasrutinas.

    Copyright (c) 2026 Germán Luis Aracil Boned
    Author: Germán Luis Aracil Boned <garacil@tucall.com>

    User-space lightweight threads for Free Pascal (Go-style goroutines):
    an M:N scheduler, channels, select, timers and epoll. Intended as an
    addition to the Free Pascal packages: FPC already has OS threads and
    callback event loops; it has no green threads.

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

    Modelled on golang/src/runtime (proc.go, runtime2.go, time.go,
    netpoll.go, netpoll_epoll.go, chan.go, stack.go). Names of the Go
    routines being mirrored are quoted next to each procedure.

      G  = pasrutina   (work item, a few KiB of its own stack)
      M  = OS thread   (pthread via BeginThread)
      P  = processor   (local run queue + the right to run Pascal code)

    Switching G does not enter the kernel: a TPasBuf is saved/restored
    (same layout as FPC jmp_buf: rbx,rbp,r12-r15,rsp,rip, see
    rtl/x86_64/setjumph.inc) via the RTL symbols FPC_SETJMP/FPC_LONGJMP.

    Free Pascal keeps its exception frame chain (ExceptAddrStack) and the
    raised object chain (ExceptObjectStack) in threadvars, i.e. per OS
    thread (rtl/inc/except.inc). Go keeps _defer/_panic in the g. This
    unit therefore saves and restores both chains per pasrutina on every
    switch; see "Exception state" in the implementation.

    Public prefix: Pas / PAS, never Go.

    Usage:
      uses cthreads, pasrutinas, paschan;
      Pas(@Proc);
      PASMAXPROCS(N);

 **********************************************************************}

{$mode objfpc}{$H+}
{$asmmode att}
{$S-}
{$Q-}
{$R-}
{$inline on}
{$IFDEF CPUx86_64}
{$ELSE}
  {$ERROR pasrutinas requires x86_64 (TPasBuf / FPC_SETJMP on amd64)}
{$ENDIF}
{$IFNDEF LINUX}
  {$ERROR pasrutinas requires Linux (epoll, eventfd, sigaltstack)}
{$ENDIF}

unit pasrutinas;

interface

uses
  SysUtils, BaseUnix;

const
  { Go starts at 2 KiB and grows through morestack. FPC has no stack
    growth, so a pasrutina gets a fixed mmap'ed stack (demand paged: an
    idle pasrutina dirties about one page) plus one PROT_NONE guard page. }
  PasStackDefault = 16 * 1024;
  PasStackGuard   = 4096;
  PasG0StackSize  = 64 * 1024;
  PasRunqSize     = 256;        { proc.go: len(p.runq) }
  PasMStackSize   = 256 * 1024;
  PasSignalStack  = 64 * 1024;  { runtime2.go: gsignal is 32 KiB }

type
  TPasProc    = procedure;
  TPasProcArg = procedure(Arg: Pointer);
  TPasMethod  = procedure of object;
  TPasrutina  = Pointer;

  { runtime.mutex (lock_futex.go): 0 unlocked, 1 locked, 2 locked with
    sleepers. Spins briefly, then sleeps in futex. Zero-initialised. }
  TPasLock = record
    key: LongInt;
  end;
  PPasLock = ^TPasLock;

  { sema.go semaRoot: counting semaphore with parked waiters. }
  TPasSema = record
    count: LongInt;
    nwait: LongInt;
    lock: TPasLock;
    head: Pointer;
    tail: Pointer;
  end;

  TPasWaitGroup = class
  private
    FCount: LongInt;
    FLock: TPasLock;
    FWaiters: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(Delta: LongInt);
    procedure Done;
    procedure Wait;
  end;

  { sync.Mutex (internal/sync/mutex.go): CAS fast path, spinning, normal
    and starvation modes, waiters parked on a semaphore. }
  TPasMutex = class
  private
    FState: LongInt;
    FSema: TPasSema;
    procedure LockSlow;
    procedure UnlockSlow(New: LongInt);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Lock;
    procedure Unlock;
  end;

  TPasRWMutex = class
  private
    FLock: TPasLock;
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
    FLock: TPasLock;
    FWaiters: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Wait(M: TPasMutex);
    procedure Signal;
    procedure Broadcast;
  end;

{ Spawning and scheduling. }
procedure Pas(Proc: TPasProc);
procedure Pas(Proc: TPasProcArg; Arg: Pointer);
procedure Pas(Method: TPasMethod);
procedure PasYield;                   { Gosched }
procedure PasExit;                    { Goexit }
procedure PasSleep(Ms: QWord);        { time.Sleep, millisecond API }
procedure PasSleepNs(Ns: Int64);      { time.Sleep, nanosecond API }
procedure PasPark;                    { gopark without unlock: use PasParkUnlock }
procedure PasReady(G: TPasrutina);    { goready }
function  PasParkUnlock(var CS: TRTLCriticalSection): Boolean;
function  PasCurrent: TPasrutina;
function  PasID: QWord;
function  NumPasrutinas: LongInt;
function  PASMAXPROCS(N: LongInt): LongInt;
procedure PasSetStackSize(Bytes: PtrUInt);
function  PasStackSize: PtrUInt;
procedure PasInit;
function  PasNow: Int64;              { nanotime: CLOCK_MONOTONIC in ns }

{ Blocking system calls: hand the P to another M while this OS thread is
  inside the kernel (entersyscall / exitsyscall). Cheap; nest-safe. }
procedure PasEnterSyscall;
procedure PasExitSyscall;

{ Poller: edge-triggered epoll. Try the non-blocking operation first;
  wait only after EAGAIN. A readiness notification that arrives while
  nobody waits is remembered (pdReady latch) so it cannot be lost.
  The fd is switched to O_NONBLOCK on first use. Call PasUnregisterFd
  before closing an fd that was ever waited on. }
procedure PasWaitRead(Fd: LongInt);
procedure PasWaitWrite(Fd: LongInt);
function  PasWaitReadTimeout(Fd: LongInt; Ms: LongInt): Boolean;
function  PasWaitWriteTimeout(Fd: LongInt; Ms: LongInt): Boolean;
procedure PasUnregisterFd(Fd: LongInt);

{ Serialised text output: the RTL's WriteLn is not thread safe. }
procedure PasWriteLn(const S: AnsiString);
procedure PasWriteLn(const Fmt: AnsiString; const Args: array of const);

{ Runtime lock for user code that must not block the OS thread for long:
  cheaper than TRTLCriticalSection, never held across a park. }
procedure PasLockAcquire(var L: TPasLock);
procedure PasLockRelease(var L: TPasLock);

{ Internals used by paschan. Not a stable API. }
procedure PasInternalParkUnlock(var CS: TRTLCriticalSection);
procedure PasInternalParkUnlockLock(var L: TPasLock);
procedure PasInternalParkUnlockMany(const Locks: array of PPasLock);
procedure PasInternalReady(G: TPasrutina);

implementation

{ This unit is x86_64-only (see $ERROR above). Stack arithmetic is
  pointer/ordinal conversion by definition. }
{$WARN 4055 OFF}
{$WARN 4056 OFF}
{$POINTERMATH ON}

uses
  Linux;

type
  { rtl/x86_64/setjumph.inc: jmp_buf = packed record rbx,rbp,r12..r15,rsp,rip }
  TPasBuf = packed record
    rbx, rbp, r12, r13, r14, r15, rsp, rip: QWord;
  end;

  TParkKind = (pkNone, pkPark, pkYield, pkYieldLocal, pkExit, pkExitSyscall);

  TPasKind = (pskProc, pskProcArg, pskMethod);

  PG = ^TG;
  PM = ^TM;
  PPasP = ^TPasP;
  PPollDesc = ^TPollDesc;

  { runtime2.go: type g struct }
  TG = record
    sched: TPasBuf;
    stackLo: Pointer;
    stackHi: Pointer;
    stackMap: Pointer;
    stackMapLen: PtrUInt;
    stackSize: PtrUInt;
    status: LongInt;              { atomic: Gidle..Gdead }
    preempt: LongInt;             { set by sysmon, honoured at scheduling points }
    goid: QWord;
    m: PM;
    schedlink: PG;
    waitlink: PG;
    parkKind: TParkKind;
    unlockN: LongInt;
    unlocks: array[0..15] of PPasLock;
    unlockCS: PRTLCriticalSection;
    semTicket: LongInt;
    { poll park commit (netpollblockcommit) }
    parkPoll: PPollDesc;
    parkPollMode: LongInt;
    { timers: armed after the park commits (time.go resetForSleep) }
    timerSeq: LongInt;
    timerWhen: Int64;
    timerArm: Boolean;
    { RTL exception state, saved per pasrutina (Go: g._defer, g._panic) }
    exceptAddr: Pointer;
    exceptObj: Pointer;
    kind: TPasKind;
    fn: CodePointer;
    arg: Pointer;
    method: TMethod;
    isMain: Boolean;
    isG0: Boolean;
  end;

  { runtime2.go: type m struct }
  TM = record
    id: LongInt;
    g0: PG;
    curg: PG;
    p: PPasP;
    nextp: PPasP;
    oldp: PPasP;                  { P held before entersyscall }
    parkEvent: PRTLEvent;
    spinning: Boolean;
    rand: Cardinal;
    threadId: TThreadID;
    nextIdle: PM;                 { schedlink in sched.midle }
    alllink: PM;
    tvBase: Pointer;              { this thread's threadvar block }
    pStackBottom: PPointer;       { this thread's StackBottom threadvar }
    pStackLength: PPtrUInt;
    sigStack: Pointer;
    stopped: Boolean;
  end;

  { time.go: one heap per P. Entries are never deleted eagerly: (gp, seq)
    identifies the wait they belong to and stale ones are dropped when
    they surface (deltimer/modtimer semantics through seq). }
  TTimer = record
    when: Int64;
    gp: PG;
    seq: LongInt;
    pd: PPollDesc;
    mode: LongInt;
  end;
  PTimer = ^TTimer;

  { runtime2.go: type p struct + sysmontick }
  TPasP = record
    id: LongInt;
    status: LongInt;              { atomic: Pidle, Prunning, Psyscall }
    m: PM;
    runq: array[0..PasRunqSize - 1] of Pointer;
    runqhead: Cardinal;           { atomic }
    runqtail: Cardinal;           { atomic }
    runnext: Pointer;             { atomic }
    gFree: PG;
    gFreeN: LongInt;
    schedlink: PPasP;
    schedtick: Cardinal;
    syscalltick: Cardinal;
    { time.go: timers heap per P (4-ary in Go, binary here) }
    timers: PTimer;
    timersN: LongInt;
    timersCap: LongInt;
    timersLock: TPasLock;
    timer0When: Int64;            { atomic: earliest when, 0 = none }
    smSchedtick: Cardinal;
    smSchedwhen: Int64;
    smSyscalltick: Cardinal;
    smSyscallwhen: Int64;
  end;

  { netpoll.go: pollDesc. rg/wg hold pdNil, pdReady, pdWait or a G. }
  TPollDesc = record
    fd: LongInt;
    rg: Pointer;                  { atomic }
    wg: Pointer;                  { atomic }
    registered: Boolean;
  end;

  { rtl/inc/excepth.inc }
  PExceptAddr = ^TExceptAddr;
  TExceptAddr = record
    buf: Pointer;
    next: PExceptAddr;
    frametype: LongInt;
  end;

  TGList = record
    head, tail: PG;
    n: LongInt;
  end;

const
  Grunnable = 1;
  Grunning  = 2;
  Gsyscall  = 3;
  Gwaiting  = 4;
  Gdead     = 6;

  Pidle    = 0;
  Prunning = 1;
  Psyscall = 2;


  PollRead  = 1;
  PollWrite = 2;

  { unistd.h: _SC_NPROCESSORS_ONLN, _SC_PAGESIZE on Linux }
  SC_PAGESIZE         = 30;
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

  forcePreemptNs = 10 * 1000 * 1000;   { proc.go: forcePreemptNS }
  sysmonMinUs    = 20;                 { proc.go sysmon: 20us .. 10ms }
  sysmonMaxUs    = 10 * 1000;
  gFreeLocalMax  = 64;                 { proc.go gfput: 64 per P }
  gFreeGlobalMax = 1024;               { warm stacks kept resident }
  stackSlabCount = 64;                 { stacks reserved per mmap }
  { asm-generic/mman-common.h }
  MADV_DONTNEED      = 4;
  MADV_GUARD_INSTALL = 102;            { Linux 6.13+: guard without a VMA split }

  { lock_futex.go }
  lockUnlocked  = 0;
  lockLocked    = 1;
  lockSleeping  = 2;
  lockActiveSpin    = 4;               { active_spin }
  lockActiveSpinCnt = 30;              { active_spin_cnt: PAUSE iterations }
  lockPassiveSpin   = 1;               { passive_spin: sched_yield }
  FUTEX_PRIVATE_FLAG = 128;            { os_linux.go }
  FUTEX_WAIT_PRIVATE = 0 or FUTEX_PRIVATE_FLAG;
  FUTEX_WAKE_PRIVATE = 1 or FUTEX_PRIVATE_FLAG;

  { internal/sync/mutex.go }
  mutexLocked      = 1;
  mutexWoken       = 2;
  mutexStarving    = 4;
  mutexWaiterShift = 3;
  starvationThresholdNs = 1000000;

const
  pdNil: Pointer = nil;
  pdReady: Pointer = Pointer(1);
  pdWait: Pointer = Pointer(2);

{ Linux x86_64 epoll_event is packed: 4-byte events + 8-byte data. }
type
  TEpollEvent = packed record
    events: LongWord;
    data: Pointer;
  end;

  TStackT = record
    ss_sp: Pointer;
    ss_flags: LongInt;
    ss_size: PtrUInt;
  end;

function PasSave(var Buf: TPasBuf): LongInt; [external name 'FPC_SETJMP'];
procedure PasRestore(var Buf: TPasBuf; Value: LongInt); [external name 'FPC_LONGJMP'];

{ rtl/inc/except.inc: the only exported entry points that touch the
  threadvar exception chain. }
function fpc_PushExceptAddr(Ft: LongInt; _buf, _newaddr: Pointer): Pointer; external name 'FPC_PUSHEXCEPTADDR';
procedure fpc_PopAddrStack; external name 'FPC_POPADDRSTACK';

{ rtl/inc/thread.inc: fpc_threadvar_relocate_proc, nil until the first
  thread is created (then InitThreadVars installs CRelocateThreadvar). }
var
  fpc_threadvar_relocate_proc: TRelocateThreadVarHandler; external name 'FPC_THREADVAR_RELOCATE';

function libc_sysconf(Name: LongInt): PtrInt; cdecl; external 'c' name 'sysconf';
function libc_epoll_create1(flags: LongInt): LongInt; cdecl; external 'c' name 'epoll_create1';
function libc_epoll_ctl(epfd, op, fd: LongInt; event: Pointer): LongInt; cdecl; external 'c' name 'epoll_ctl';
function libc_epoll_wait(epfd: LongInt; events: Pointer; maxevents, timeout: LongInt): LongInt; cdecl; external 'c' name 'epoll_wait';
function libc_eventfd(initval: LongWord; flags: LongInt): LongInt; cdecl; external 'c' name 'eventfd';
function libc_write(fd: LongInt; buf: Pointer; count: PtrUInt): PtrInt; cdecl; external 'c' name 'write';
function libc_read(fd: LongInt; buf: Pointer; count: PtrUInt): PtrInt; cdecl; external 'c' name 'read';
function libc_close(fd: LongInt): LongInt; cdecl; external 'c' name 'close';
function libc_fcntl(fd, cmd: LongInt; arg: LongInt): LongInt; cdecl; external 'c' name 'fcntl';
function libc_usleep(usec: LongWord): LongInt; cdecl; external 'c' name 'usleep';
function libc_sigaltstack(ss, oss: Pointer): LongInt; cdecl; external 'c' name 'sigaltstack';
function libc_madvise(addr: Pointer; len: PtrUInt; advice: LongInt): LongInt; cdecl; external 'c' name 'madvise';

threadvar
  currentM: PM;

var
  initState: LongInt = 0;
  shuttingDown: LongInt = 0;
  defaultStack: PtrUInt = PasStackDefault;
  pageSize: PtrUInt = 4096;
  ncpu: LongInt = 1;
  nproc: LongInt = 0;
  allp: PPasP = nil;               { array [0..nproc-1] of TPasP, GetMem }
  allpArr: ^PPasP = nil;           { array [0..nproc-1] of PPasP }
  allm: PM = nil;

  { sched (runtime2.go: type schedt) }
  schedLock: TPasLock;
  globRunq: TGList;                { protected by schedLock }
  globRunqN: LongInt = 0;          { atomic mirror of globRunq.n }
  idleP: PPasP = nil;              { sched.pidle, protected by schedLock }
  nIdleP: LongInt = 0;             { atomic }
  idleM: PM = nil;                 { sched.midle, protected by schedLock }
  nIdleM: LongInt = 0;
  nM: LongInt = 0;
  nMStopped: LongInt = 0;
  nG: LongInt = 0;
  nSpinning: LongInt = 0;          { atomic: sched.nmspinning }
  needSpinning: LongInt = 0;       { atomic: sched.needspinning }
  lastPoll: Int64 = 0;             { atomic: 0 while an M blocks in netpoll }
  pollUntilGlobal: Int64 = 0;      { atomic: sched.pollUntil }
  nextGoid: Int64 = 1;
  gFreeGlobal: PG = nil;               { warm: pages still resident }
  gFreeGlobalN: LongInt = 0;
  gFreeCold: PG = nil;                 { cold: MADV_DONTNEED applied }
  gFreeColdN: LongInt = 0;
  guardWithMprotect: Boolean = False;  { kernel without MADV_GUARD_INSTALL }

  { stack slab: one PROT_NONE reservation, stacks are enabled one by one
    with mprotect (stack.go stackalloc carves spans the same way) }
  stackLock: TPasLock;
  slabNext: PtrUInt = 0;
  slabEnd: PtrUInt = 0;
  slabStride: PtrUInt = 0;

  { netpoll }
  epfd: LongInt = -1;
  eventFd: LongInt = -1;
  netpollWakeSig: LongInt = 0;     { atomic }
  netpollWaiters: LongInt = 0;     { atomic: netpollAnyWaiters }
  pollLock: TPasLock;
  pollDescs: ^PPollDesc = nil;     { indexed by fd, grows }
  pollDescsN: LongInt = 0;


  { exception state offsets inside the threadvar block, see PasInit }
  tvExcAddrOff: PtrUInt = 0;
  tvExcObjOff: PtrUInt = 0;
  tvExcMode: LongInt = 0;          { 0 = not found, 1 = offsets, 2 = push/pop fallback }

  outLock: TRTLCriticalSection;
  prevExitProc: CodePointer = nil;

  { PASRUTINAS_STATS=1 prints these at exit (like GODEBUG=schedtrace) }
  statMStart: LongInt = 0;
  statMNew: LongInt = 0;
  statNetpollBreak: LongInt = 0;
  statFutexSleep: LongInt = 0;
  statSpinning: LongInt = 0;
  statSteal: LongInt = 0;
  statPark: LongInt = 0;
  statStopM: LongInt = 0;

procedure G0Loop; forward;
procedure Schedule(mp: PM); forward;
function  FindRunnable(mp: PM): PG; forward;
procedure Execute(mp: PM; gp: PG); forward;
procedure RunqPut(pp: PPasP; gp: PG; Next: Boolean); forward;
function  RunqGet(pp: PPasP; out Inherit: Boolean): PG; forward;
function  RunqEmpty(pp: PPasP): Boolean; forward;
function  RunqSteal(pp, Victim: PPasP; StealRunNext: Boolean): PG; forward;
procedure GlobRunqPut(gp: PG); forward;
procedure GlobRunqPutBatch(var L: TGList); forward;
function  GlobRunqGet: PG; forward;
function  GlobRunqGetBatch(pp: PPasP): PG; forward;
procedure InjectGList(mp: PM; var L: TGList); forward;
procedure Ready(gp: PG; Next: Boolean); forward;
procedure Wakep; forward;
procedure StartM(pp: PPasP; Spinning: Boolean); forward;
procedure HandoffP(pp: PPasP); forward;
procedure StopM(mp: PM); forward;
procedure FinishPark(mp: PM); forward;
function  AllocG(StackSize: PtrUInt): PG; forward;
procedure FreeG(gp: PG); forward;
procedure RecycleG(mp: PM; gp: PG); forward;
function  GfGet(pp: PPasP): PG; forward;
procedure AcquireP(mp: PM; pp: PPasP); forward;
function  ReleaseP(mp: PM): PPasP; forward;
procedure PidlePut(pp: PPasP); forward;
function  PidleGet: PPasP; forward;
procedure MPut(mp: PM); forward;
function  MGet: PM; forward;
function  CheapRand(mp: PM): Cardinal; forward;
function  NowNs: Int64; forward;
procedure AddTimer(pp: PPasP; When: Int64; gp: PG; Seq: LongInt; pd: PPollDesc; Mode: LongInt); forward;
procedure FireTimers(pp: PPasP; Now: Int64; var L: TGList); forward;
procedure FireAllTimers(Now: Int64; var L: TGList); forward;
function  TimeSleepUntil: Int64; forward;
procedure NetpollInit; forward;
function  Netpoll(DelayNs: Int64): TGList; forward;
procedure NetpollBreak; forward;
function  NetpollUnblock(pd: PPollDesc; Mode: LongInt; IoReady: Boolean): PG; forward;
procedure SysmonStart; forward;
procedure SaveExceptState(mp: PM; gp: PG); forward;
procedure LoadExceptState(mp: PM; gp: PG); forward;

{*****************************************************************************
                          Runtime locks (lock_futex.go)
******************************************************************************}

{ asm_amd64.s procyieldAsm }
procedure ProcYield(Cycles: LongInt);
begin
  while Cycles > 0 do
  begin
    asm
      pause
    end;
    Dec(Cycles);
  end;
end;

{ sys_linux_amd64.s runtime·futex: raw syscall, no libc. FPC passes the
  first integer parameters in rdi, rsi, rdx on x86_64 Linux (SysV order);
  the kernel wants nr in rax, timeout in r10, uaddr2 in r8, val3 in r9. }
function FutexCall(Addr: PLongInt; Op: LongInt; Val: LongInt): PtrInt; assembler; nostackframe;
asm
  movq   $202, %rax
  xorq   %r10, %r10
  xorq   %r8, %r8
  xorq   %r9, %r9
  syscall
end;

{ os_linux.go futexsleep / futexwakeup }
procedure FutexSleep(Addr: PLongInt; Val: LongInt);
begin
  FutexCall(Addr, FUTEX_WAIT_PRIVATE, Val);
end;

procedure FutexWakeup(Addr: PLongInt; Cnt: LongInt);
begin
  FutexCall(Addr, FUTEX_WAKE_PRIVATE, Cnt);
end;

{ lock_futex.go lock2: xchg fast path; on contention spin with PAUSE,
  yield once, then record "sleeping" and wait in futex. Whoever saw a
  sleeper keeps writing 2 so the unlocker knows to wake. }
procedure LockAcquire(var L: TPasLock);
var
  v, wait, spin, i: LongInt;
begin
  v := InterlockedExchange(L.key, lockLocked);
  if v = lockUnlocked then
    Exit;
  wait := v;
  spin := 0;
  if ncpu > 1 then
    spin := lockActiveSpin;
  while True do
  begin
    for i := 1 to spin do
    begin
      while L.key = lockUnlocked do
        if InterlockedCompareExchange(L.key, wait, lockUnlocked) = lockUnlocked then
          Exit;
      ProcYield(lockActiveSpinCnt);
    end;
    for i := 1 to lockPassiveSpin do
    begin
      while L.key = lockUnlocked do
        if InterlockedCompareExchange(L.key, wait, lockUnlocked) = lockUnlocked then
          Exit;
      ThreadSwitch;
    end;
    v := InterlockedExchange(L.key, lockSleeping);
    if v = lockUnlocked then
      Exit;
    wait := lockSleeping;
    InterlockedIncrement(statFutexSleep);
    FutexSleep(@L.key, lockSleeping);
  end;
end;

{ lock_futex.go unlock2 }
procedure LockRelease(var L: TPasLock);
var
  v: LongInt;
begin
  v := InterlockedExchange(L.key, lockUnlocked);
  if v = lockUnlocked then
    raise Exception.Create('pasrutinas: unlock of unlocked lock');
  if v = lockSleeping then
    FutexWakeup(@L.key, 1);
end;

procedure PasLockAcquire(var L: TPasLock);
begin
  LockAcquire(L);
end;

procedure PasLockRelease(var L: TPasLock);
begin
  LockRelease(L);
end;

{*****************************************************************************
                       Exception state per pasrutina
******************************************************************************}

{ rtl/inc/except.inc keeps
    threadvar ExceptAddrStack: PExceptAddr;    (chain of try frames)
    threadvar ExceptObjectStack: PExceptObject; (chain of raised objects)
  fpc_RaiseException longjmps to ExceptAddrStack^.Buf and fpc_PopAddrStack
  halts with 255 when the chain is empty. Both must follow the pasrutina,
  exactly like g._defer and g._panic follow a goroutine.

  Mode 1: the threadvar block of a thread is contiguous
  (cthreads.pp CAllocateThreadVars) and every threadvar is addressed as
  fpc_threadvar_relocate_proc(offset). System unit threadvars come first
  (threadvr.inc init_all_unit_threadvars walks units in order), so both
  offsets are below the offset of this unit's own currentM. PasInit finds
  them by pushing a probe frame with FPC_PUSHEXCEPTADDR and raising a probe
  exception, then scanning the block for those addresses.

  Mode 2 (fallback if the scan fails, e.g. an RTL built with section
  threadvars): ExceptAddrStack is read and written through
  FPC_PUSHEXCEPTADDR / FPC_POPADDRSTACK, which link and unlink a frame we
  own. ExceptObjectStack cannot be written that way, so in mode 2 a
  pasrutina must not park inside an except handler. }

type
  EPasProbe = class(Exception);

function TVSlot(mp: PM; Off: PtrUInt): PPointer; inline;
begin
  Result := PPointer(PtrUInt(mp^.tvBase) + Off);
end;

function ChainGetPushPop: Pointer;
var
  probe: TExceptAddr;
begin
  fpc_PushExceptAddr(0, nil, @probe);   { probe.next := current head }
  Result := probe.next;
  fpc_PopAddrStack;                      { head := probe.next }
end;

procedure ChainSetPushPop(Head: Pointer);
var
  probe: TExceptAddr;
begin
  fpc_PushExceptAddr(0, nil, @probe);
  probe.next := PExceptAddr(Head);
  fpc_PopAddrStack;                      { head := Head }
end;

procedure SaveExceptState(mp: PM; gp: PG);
begin
  case tvExcMode of
    1:
      begin
        gp^.exceptAddr := TVSlot(mp, tvExcAddrOff)^;
        gp^.exceptObj := TVSlot(mp, tvExcObjOff)^;
        TVSlot(mp, tvExcAddrOff)^ := nil;
        TVSlot(mp, tvExcObjOff)^ := nil;
      end;
    2:
      begin
        gp^.exceptAddr := ChainGetPushPop;
        ChainSetPushPop(nil);
      end;
  end;
end;

procedure LoadExceptState(mp: PM; gp: PG);
begin
  case tvExcMode of
    1:
      begin
        TVSlot(mp, tvExcAddrOff)^ := gp^.exceptAddr;
        TVSlot(mp, tvExcObjOff)^ := gp^.exceptObj;
      end;
    2:
      ChainSetPushPop(gp^.exceptAddr);
  end;
end;

function ScanTV(Base, Limit: PtrUInt; Value: Pointer; out Off: PtrUInt): Boolean;
var
  o: PtrUInt;
begin
  Result := False;
  o := 0;
  while o + SizeOf(Pointer) <= Limit do
  begin
    if PPointer(Base + o)^ = Value then
    begin
      Off := o;
      Result := True;
      Exit;
    end;
    Inc(o, SizeOf(Pointer));
  end;
end;

procedure DiscoverExceptState;
var
  base, limit, offA, offO: PtrUInt;
  probe: TExceptAddr;
  found: Boolean;
begin
  tvExcMode := 2;
  if fpc_threadvar_relocate_proc = nil then
    Exit;
  base := PtrUInt(fpc_threadvar_relocate_proc(0));
  if PtrUInt(@currentM) <= base then
    Exit;
  limit := PtrUInt(@currentM) - base;
  if limit > 65536 then
    Exit;
  fpc_PushExceptAddr(0, nil, @probe);
  found := ScanTV(base, limit, @probe, offA);
  fpc_PopAddrStack;
  if not found then
    Exit;
  found := False;
  offO := 0;
  try
    raise EPasProbe.Create('probe');
  except
    on E: EPasProbe do
      found := ScanTV(base, limit, RaiseList, offO);
  end;
  if not found then
    Exit;
  tvExcAddrOff := offA;
  tvExcObjOff := offO;
  tvExcMode := 1;
end;

{*****************************************************************************
                              Stacks and Gs
******************************************************************************}

{ stack.go stackalloc: Go carves 2 KiB..32 KiB stacks out of spans and
  grows them by copying. Without morestack a pasrutina keeps one fixed
  mmap (MAP_NORESERVE, demand paged) plus a PROT_NONE guard page. Freed
  stacks are cached per P (gfput/gfget, 64 per P) and globally; above
  gFreeGlobalMax they are unmapped. }

function AllocStack(Size: PtrUInt; out Map: Pointer; out MapLen: PtrUInt;
  out Lo, Hi: Pointer): Boolean;
var
  total, guard: PtrUInt;
  p: Pointer;
begin
  guard := pageSize;
  if guard < PasStackGuard then
    guard := PasStackGuard;
  total := (Size + guard + pageSize - 1) and not (pageSize - 1);
  LockAcquire(stackLock);
  if (slabNext = 0) or (slabStride <> total) or (slabNext + total > slabEnd) then
  begin
    p := Fpmmap(nil, total * stackSlabCount, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS or MAP_NORESERVE, -1, 0);
    if (p = nil) or (p = MAP_FAILED) then
    begin
      LockRelease(stackLock);
      Result := False;
      Exit;
    end;
    slabNext := PtrUInt(p);
    slabEnd := slabNext + total * stackSlabCount;
    slabStride := total;
  end;
  p := Pointer(slabNext);
  Inc(slabNext, total);
  LockRelease(stackLock);
  { guard page: MADV_GUARD_INSTALL marks the PTEs without splitting the
    VMA (about 0.4 us); older kernels fall back to mprotect (a VMA per
    stack, about 2 us and 2 map entries per stack) }
  if (not guardWithMprotect) and (libc_madvise(p, guard, MADV_GUARD_INSTALL) = 0) then
    { guarded }
  else
  begin
    guardWithMprotect := True;
    if Fpmprotect(p, guard, PROT_NONE) <> 0 then
    begin
      Result := False;
      Exit;
    end;
  end;
  Map := p;
  MapLen := total;
  Lo := Pointer(PtrUInt(p) + guard);
  Hi := Pointer(PtrUInt(p) + total);
  Result := True;
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
  Result^.stackSize := StackSize;
  Result^.status := Gdead;
end;

procedure FreeG(gp: PG);
begin
  if gp = nil then
    Exit;
  if (not gp^.isMain) and (gp^.stackMap <> nil) then
    Fpmunmap(gp^.stackMap, gp^.stackMapLen);
  Dispose(gp);
end;

{ Drop the resident pages of a cached stack, keep the mapping: no VMA
  churn, the next user pays one page fault. schedLock held. }
procedure ColdG(gp: PG);
begin
  libc_madvise(gp^.stackLo, PtrUInt(gp^.stackHi) - PtrUInt(gp^.stackLo), MADV_DONTNEED);
  gp^.schedlink := gFreeCold;
  gFreeCold := gp;
  Inc(gFreeColdN);
end;

{ proc.go gfput }
procedure RecycleG(mp: PM; gp: PG);
var
  pp: PPasP;
  i: LongInt;
  h: PG;
begin
  gp^.status := Gdead;
  gp^.fn := nil;
  gp^.arg := nil;
  gp^.method.Code := nil;
  gp^.method.Data := nil;
  gp^.timerArm := False;
  gp^.parkPoll := nil;
  gp^.waitlink := nil;
  gp^.schedlink := nil;
  gp^.exceptAddr := nil;
  gp^.exceptObj := nil;
  gp^.preempt := 0;
  gp^.unlockN := 0;
  if gp^.isMain then
    Exit;
  if gp^.stackSize <> defaultStack then
  begin
    FreeG(gp);
    Exit;
  end;
  pp := mp^.p;
  if pp <> nil then
  begin
    gp^.schedlink := pp^.gFree;
    pp^.gFree := gp;
    Inc(pp^.gFreeN);
    if pp^.gFreeN < gFreeLocalMax then
      Exit;
    { move half to the global cache }
    LockAcquire(schedLock);
    for i := 1 to gFreeLocalMax div 2 do
    begin
      h := pp^.gFree;
      pp^.gFree := h^.schedlink;
      Dec(pp^.gFreeN);
      h^.schedlink := gFreeGlobal;
      gFreeGlobal := h;
      Inc(gFreeGlobalN);
    end;
    while gFreeGlobalN > gFreeGlobalMax do
    begin
      h := gFreeGlobal;
      gFreeGlobal := h^.schedlink;
      Dec(gFreeGlobalN);
      ColdG(h);
    end;
    LockRelease(schedLock);
    Exit;
  end;
  LockAcquire(schedLock);
  gp^.schedlink := gFreeGlobal;
  gFreeGlobal := gp;
  Inc(gFreeGlobalN);
  if gFreeGlobalN > gFreeGlobalMax then
  begin
    h := gFreeGlobal;
    gFreeGlobal := h^.schedlink;
    Dec(gFreeGlobalN);
    ColdG(h);
  end;
  LockRelease(schedLock);
end;

{ proc.go gfget }
function GfGet(pp: PPasP): PG;
var
  i: LongInt;
  h: PG;
begin
  if (pp <> nil) and (pp^.gFree = nil) and ((gFreeGlobal <> nil) or (gFreeCold <> nil)) then
  begin
    LockAcquire(schedLock);
    for i := 1 to gFreeLocalMax div 2 do
    begin
      h := gFreeGlobal;
      if h <> nil then
      begin
        gFreeGlobal := h^.schedlink;
        Dec(gFreeGlobalN);
      end
      else
      begin
        h := gFreeCold;
        if h = nil then
          Break;
        gFreeCold := h^.schedlink;
        Dec(gFreeColdN);
      end;
      h^.schedlink := pp^.gFree;
      pp^.gFree := h;
      Inc(pp^.gFreeN);
    end;
    LockRelease(schedLock);
  end;
  Result := nil;
  if pp <> nil then
  begin
    Result := pp^.gFree;
    if Result <> nil then
    begin
      pp^.gFree := Result^.schedlink;
      Dec(pp^.gFreeN);
      Result^.schedlink := nil;
    end;
  end;
  while (Result <> nil) and (Result^.stackSize <> defaultStack) do
  begin
    FreeG(Result);
    Result := nil;
    if pp <> nil then
    begin
      Result := pp^.gFree;
      if Result <> nil then
      begin
        pp^.gFree := Result^.schedlink;
        Dec(pp^.gFreeN);
        Result^.schedlink := nil;
      end;
    end;
  end;
  if Result = nil then
    Result := AllocG(defaultStack);
end;

{*****************************************************************************
                        Context switch and trampoline
******************************************************************************}

procedure InitBuf(out Buf: TPasBuf; SP, PC: Pointer);
begin
  Buf := Default(TPasBuf);
  Buf.rsp := PtrUInt(SP);
  Buf.rip := PtrUInt(PC);
end;

{ sys_x86.go gostartcall: enter Entry as if called, rsp = 8 mod 16 with a
  zero return address on top. }
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

{ StackBottom/StackLength are threadvars used by $S+ stack checks and the
  RTL; their per-thread addresses are cached in the M so a switch does
  not go through FPC_THREADVAR_RELOCATE. }
procedure ApplyUserStack(mp: PM; gp: PG); inline;
begin
  mp^.pStackBottom^ := gp^.stackLo;
  mp^.pStackLength^ := PtrUInt(gp^.stackHi) - PtrUInt(gp^.stackLo);
end;

{ One locked write per report: the RTL's WriteLn is not thread safe. }
procedure ReportUncaught(gp: PG; const Msg: AnsiString);
var
  line: AnsiString;
begin
  line := 'pasrutina ' + IntToStr(gp^.goid) + ': ' + Msg;
  EnterCriticalSection(outLock);
  try
    WriteLn(StdErr, line);
    Flush(StdErr);
  finally
    LeaveCriticalSection(outLock);
  end;
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
      ReportUncaught(gp, E.ClassName + ': ' + E.Message);
    else
      ReportUncaught(gp, 'unknown exception');
  end;
  PasExit;
end;

procedure SwitchToG0(mp: PM);
begin
  ApplyUserStack(mp, mp^.g0);
  PasRestore(mp^.g0^.sched, 1);
end;

{ proc.go gopark -> mcall(park_m): save into G.sched, jump to g0. }
procedure ParkWithM(mp: PM; Kind: TParkKind);
var
  gp: PG;
begin
  if mp = nil then
    raise Exception.Create('pasrutinas: park outside a pasrutina (missing uses cthreads, pasrutinas?)');
  gp := mp^.curg;
  if gp = nil then
    raise Exception.Create('pasrutinas: park on g0');
  gp^.parkKind := Kind;
  Inc(gp^.timerSeq);
  InterlockedIncrement(statPark);
  if PasSave(gp^.sched) = 0 then
    SwitchToG0(mp);
end;

procedure ParkWith(Kind: TParkKind);
begin
  ParkWithM(GetM, Kind);
end;

{*****************************************************************************
                                Run queues
******************************************************************************}

{ proc.go runqempty }
function RunqEmpty(pp: PPasP): Boolean;
var
  h, t: Cardinal;
  rn: Pointer;
begin
  repeat
    h := pp^.runqhead;
    t := pp^.runqtail;
    rn := pp^.runnext;
  until t = pp^.runqtail;
  Result := (h = t) and (rn = nil);
end;

{ proc.go runqputslow: move half of the local queue plus gp to the global
  queue. Elements are copied before the CAS on runqhead. }
function RunqPutSlow(pp: PPasP; gp: PG; h, t: Cardinal): Boolean;
var
  batch: array[0..PasRunqSize div 2] of PG;
  n, i: Cardinal;
  L: TGList;
begin
  n := (t - h) div 2;
  if n <> PasRunqSize div 2 then
    raise Exception.Create('pasrutinas: runqputslow: queue is not full');
  for i := 0 to n - 1 do
    batch[i] := PG(pp^.runq[(h + i) and (PasRunqSize - 1)]);
  if InterlockedCompareExchange(pp^.runqhead, h + n, h) <> h then
  begin
    Result := False;
    Exit;
  end;
  batch[n] := gp;
  for i := 0 to n - 1 do
    batch[i]^.schedlink := batch[i + 1];
  batch[n]^.schedlink := nil;
  L.head := batch[0];
  L.tail := batch[n];
  L.n := LongInt(n) + 1;
  LockAcquire(schedLock);
  GlobRunqPutBatch(L);
  LockRelease(schedLock);
  Result := True;
end;

{ proc.go runqput }
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
  while True do
  begin
    h := pp^.runqhead;
    t := pp^.runqtail;
    if t - h < PasRunqSize then
    begin
      pp^.runq[t and (PasRunqSize - 1)] := gp;
      InterlockedExchange(pp^.runqtail, t + 1);   { store-release }
      Exit;
    end;
    if RunqPutSlow(pp, gp, h, t) then
      Exit;
  end;
end;

{ proc.go runqget }
function RunqGet(pp: PPasP; out Inherit: Boolean): PG;
var
  h, t: Cardinal;
  next: PG;
begin
  Inherit := False;
  next := PG(InterlockedExchange(pp^.runnext, nil));
  if next <> nil then
  begin
    Inherit := True;
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

{ proc.go runqgrab: copy the batch first, then commit with a CAS on the
  victim's head; the owner can only overwrite slots once head moved. }
function RunqGrab(Victim: PPasP; var Batch: array of Pointer; BatchHead: Cardinal;
  StealRunNext: Boolean): Cardinal;
var
  h, t, n, i: Cardinal;
  next: PG;
begin
  while True do
  begin
    h := Victim^.runqhead;
    t := Victim^.runqtail;
    n := t - h;
    n := n - n div 2;
    if n = 0 then
    begin
      if StealRunNext then
      begin
        next := PG(Victim^.runnext);
        if next <> nil then
        begin
          if Victim^.status = Prunning then
            { the owner may be about to run it: back off (proc.go usleep(3)) }
            libc_usleep(3);
          if InterlockedCompareExchange(Victim^.runnext, nil, Pointer(next)) <> Pointer(next) then
            Continue;
          Batch[BatchHead and (PasRunqSize - 1)] := next;
          Result := 1;
          Exit;
        end;
      end;
      Result := 0;
      Exit;
    end;
    if n > PasRunqSize div 2 then
      Continue;   { inconsistent h and t }
    for i := 0 to n - 1 do
      Batch[(BatchHead + i) and (PasRunqSize - 1)] := Victim^.runq[(h + i) and (PasRunqSize - 1)];
    if InterlockedCompareExchange(Victim^.runqhead, h + n, h) = h then
    begin
      Result := n;
      Exit;
    end;
  end;
end;

{ proc.go runqsteal: grab into our own queue past runqtail, return one. }
function RunqSteal(pp, Victim: PPasP; StealRunNext: Boolean): PG;
var
  t, h, n: Cardinal;
begin
  t := pp^.runqtail;
  n := RunqGrab(Victim, pp^.runq, t, StealRunNext);
  if n = 0 then
  begin
    Result := nil;
    Exit;
  end;
  InterlockedIncrement(statSteal);
  Dec(n);
  Result := PG(pp^.runq[(t + n) and (PasRunqSize - 1)]);
  if n = 0 then
    Exit;
  h := pp^.runqhead;
  if t - h + n >= PasRunqSize then
    raise Exception.Create('pasrutinas: runqsteal: runq overflow');
  InterlockedExchange(pp^.runqtail, t + n);
end;

{ sched.runq: a gQueue under schedLock. }
procedure GlobRunqPut(gp: PG);
begin
  gp^.schedlink := nil;
  if globRunq.tail <> nil then
    globRunq.tail^.schedlink := gp
  else
    globRunq.head := gp;
  globRunq.tail := gp;
  Inc(globRunq.n);
  InterlockedExchange(globRunqN, globRunq.n);
end;

procedure GlobRunqPutBatch(var L: TGList);
begin
  if L.head = nil then
    Exit;
  if globRunq.tail <> nil then
    globRunq.tail^.schedlink := L.head
  else
    globRunq.head := L.head;
  globRunq.tail := L.tail;
  Inc(globRunq.n, L.n);
  InterlockedExchange(globRunqN, globRunq.n);
  L.head := nil;
  L.tail := nil;
  L.n := 0;
end;

function GlobRunqGet: PG;
begin
  Result := globRunq.head;
  if Result = nil then
    Exit;
  globRunq.head := Result^.schedlink;
  if globRunq.head = nil then
    globRunq.tail := nil;
  Result^.schedlink := nil;
  Dec(globRunq.n);
  InterlockedExchange(globRunqN, globRunq.n);
end;

{ proc.go globrunqgetbatch: one for us, up to n/gomaxprocs+1 more into
  the local queue (never enough to overflow it). }
function GlobRunqGetBatch(pp: PPasP): PG;
var
  n, room: LongInt;
  d: Cardinal;
  gp: PG;
begin
  Result := GlobRunqGet;
  if Result = nil then
    Exit;
  n := globRunq.n div nproc + 1;
  if n > globRunq.n then
    n := globRunq.n;
  d := pp^.runqtail - pp^.runqhead;
  room := PasRunqSize - LongInt(d) - 1;
  if n > room then
    n := room;
  while n > 0 do
  begin
    gp := GlobRunqGet;
    if gp = nil then
      Break;
    RunqPut(pp, gp, False);
    Dec(n);
  end;
end;

procedure GListPush(var L: TGList; gp: PG);
begin
  gp^.schedlink := nil;
  if L.tail <> nil then
    L.tail^.schedlink := gp
  else
    L.head := gp;
  L.tail := gp;
  Inc(L.n);
end;

function GListPop(var L: TGList): PG;
begin
  Result := L.head;
  if Result = nil then
    Exit;
  L.head := Result^.schedlink;
  if L.head = nil then
    L.tail := nil;
  Result^.schedlink := nil;
  Dec(L.n);
end;

{*****************************************************************************
                          P and M bookkeeping
******************************************************************************}

procedure AcquireP(mp: PM; pp: PPasP);
begin
  if mp^.p <> nil then
    raise Exception.Create('pasrutinas: acquirep: already in go');
  mp^.p := pp;
  pp^.m := mp;
  InterlockedExchange(pp^.status, Prunning);
end;

function ReleaseP(mp: PM): PPasP;
begin
  Result := mp^.p;
  if Result = nil then
    raise Exception.Create('pasrutinas: releasep: no p');
  mp^.p := nil;
  Result^.m := nil;
  InterlockedExchange(Result^.status, Pidle);
end;

{ sched.pidle, schedLock held }
procedure PidlePut(pp: PPasP);
begin
  if not RunqEmpty(pp) then
    raise Exception.Create('pasrutinas: pidleput: P has non-empty run queue');
  pp^.schedlink := idleP;
  idleP := pp;
  InterlockedIncrement(nIdleP);
end;

function PidleGet: PPasP;
begin
  Result := idleP;
  if Result <> nil then
  begin
    idleP := Result^.schedlink;
    Result^.schedlink := nil;
    InterlockedDecrement(nIdleP);
  end;
end;

{ sched.midle, schedLock held }
procedure MPut(mp: PM);
begin
  mp^.nextIdle := idleM;
  idleM := mp;
  Inc(nIdleM);
end;

function MGet: PM;
begin
  Result := idleM;
  if Result <> nil then
  begin
    idleM := Result^.nextIdle;
    Result^.nextIdle := nil;
    Dec(nIdleM);
  end;
end;

function CheapRand(mp: PM): Cardinal;
begin
  mp^.rand := mp^.rand * 1103515245 + 12345;
  Result := mp^.rand shr 8;
end;

procedure BecomeSpinning(mp: PM);
begin
  InterlockedIncrement(statSpinning);
  mp^.spinning := True;
  InterlockedIncrement(nSpinning);
  InterlockedExchange(needSpinning, 0);
end;

{ proc.go resetspinning }
procedure ResetSpinning(mp: PM);
begin
  mp^.spinning := False;
  if InterlockedDecrement(nSpinning) < 0 then
    raise Exception.Create('pasrutinas: resetspinning: negative nmspinning');
  Wakep;
end;

{ proc.go ready: Gwaiting -> Grunnable, local run queue, wakep. }
procedure Ready(gp: PG; Next: Boolean);
var
  mp: PM;
begin
  if InterlockedCompareExchange(gp^.status, Grunnable, Gwaiting) <> Gwaiting then
    raise Exception.Create('pasrutinas: ready: pasrutina is not waiting');
  mp := GetM;
  if (mp <> nil) and (mp^.p <> nil) then
    RunqPut(mp^.p, gp, Next)
  else
  begin
    LockAcquire(schedLock);
    GlobRunqPut(gp);
    LockRelease(schedLock);
  end;
  Wakep;
end;

{ proc.go wakep: start one spinning M if there is an idle P and no
  spinning M. Conservative on purpose (see the "Worker thread
  parking/unparking" comment at the top of proc.go). }
procedure Wakep;
var
  pp: PPasP;
begin
  if nSpinning <> 0 then
    Exit;
  if nIdleP = 0 then
  begin
    { no P to hand out: the next M to release its P becomes spinning }
    InterlockedExchange(needSpinning, 1);
    Exit;
  end;
  if InterlockedCompareExchange(nSpinning, 1, 0) <> 0 then
    Exit;
  LockAcquire(schedLock);
  pp := PidleGet;
  if pp = nil then
  begin
    { pidlegetSpinning: let the next M that releases its P become spinning }
    InterlockedExchange(needSpinning, 1);
    LockRelease(schedLock);
    if InterlockedDecrement(nSpinning) < 0 then
      raise Exception.Create('pasrutinas: wakep: negative nmspinning');
    Exit;
  end;
  LockRelease(schedLock);
  StartM(pp, True);
end;

function MStart(Parameter: Pointer): PtrInt; forward;
procedure SetupSignalStack(mp: PM); forward;

{ proc.go newm + mstart }
procedure NewM(pp: PPasP; Spinning: Boolean);
var
  mp: PM;
  tid: TThreadID;
begin
  New(mp);
  FillChar(mp^, SizeOf(TM), 0);
  mp^.id := InterlockedIncrement(nM);
  mp^.parkEvent := RTLEventCreate;
  mp^.nextp := pp;
  mp^.spinning := Spinning;
  mp^.rand := Cardinal(PtrUInt(mp) shr 4) xor Cardinal(NowNs);
  InterlockedIncrement(statMNew);
  LockAcquire(schedLock);
  mp^.alllink := allm;
  allm := mp;
  LockRelease(schedLock);
  tid := BeginThread(nil, PasMStackSize, @MStart, mp, 0, mp^.threadId);
  if tid = TThreadID(0) then
    raise Exception.Create('pasrutinas: failed to create new OS thread');
end;

{ proc.go startm: run pp on an idle M or a new one. With Spinning the
  caller has already incremented nSpinning. }
procedure StartM(pp: PPasP; Spinning: Boolean);
var
  mp: PM;
begin
  LockAcquire(schedLock);
  if pp = nil then
  begin
    if Spinning then
      raise Exception.Create('pasrutinas: startm: P required for spinning');
    pp := PidleGet;
    if pp = nil then
    begin
      LockRelease(schedLock);
      Exit;
    end;
  end;
  mp := MGet;
  if mp = nil then
  begin
    LockRelease(schedLock);
    NewM(pp, Spinning);
    Exit;
  end;
  LockRelease(schedLock);
  if mp^.spinning then
    raise Exception.Create('pasrutinas: startm: m is spinning');
  if mp^.nextp <> nil then
    raise Exception.Create('pasrutinas: startm: m has p');
  if Spinning and not RunqEmpty(pp) then
    raise Exception.Create('pasrutinas: startm: p has runnable gs');
  mp^.spinning := Spinning;
  mp^.nextp := pp;
  InterlockedIncrement(statMStart);
  RTLEventSetEvent(mp^.parkEvent);
end;

{ proc.go handoffp: pp was just released (status Pidle, no M) and is not
  on the idle list. Either give it to an M or park it, never both. }
procedure HandoffP(pp: PPasP);
begin
  if (not RunqEmpty(pp)) or (globRunqN > 0) then
  begin
    StartM(pp, False);
    Exit;
  end;
  if (nSpinning + nIdleP = 0) and (InterlockedCompareExchange(nSpinning, 1, 0) = 0) then
  begin
    InterlockedExchange(needSpinning, 0);
    StartM(pp, True);
    Exit;
  end;
  LockAcquire(schedLock);
  if globRunqN > 0 then
  begin
    LockRelease(schedLock);
    StartM(pp, False);
    Exit;
  end;
  { the last P and nobody blocked in netpoll: keep one M to poll }
  if (nIdleP = nproc - 1) and (lastPoll <> 0) then
  begin
    LockRelease(schedLock);
    StartM(pp, False);
    Exit;
  end;
  PidlePut(pp);
  LockRelease(schedLock);
end;

procedure StopForever(mp: PM);
begin
  mp^.stopped := True;
  InterlockedIncrement(nMStopped);
  while True do
    RTLEventWaitFor(mp^.parkEvent, 3600000);
end;

{ proc.go stopm + mPark: park until startm hands us a P. An idle M only
  leaves sched.midle through mget. }
procedure StopM(mp: PM);
begin
  if mp^.p <> nil then
    raise Exception.Create('pasrutinas: stopm holding p');
  if mp^.spinning then
    raise Exception.Create('pasrutinas: stopm spinning');
  LockAcquire(schedLock);
  MPut(mp);
  LockRelease(schedLock);
  InterlockedIncrement(statStopM);
  repeat
    RTLEventWaitFor(mp^.parkEvent);
    RTLEventResetEvent(mp^.parkEvent);
    if shuttingDown <> 0 then
      StopForever(mp);
  until mp^.nextp <> nil;
  AcquireP(mp, mp^.nextp);
  mp^.nextp := nil;
end;

{ proc.go injectglist: Gs readied by netpoll or timers from an M that may
  not hold a P. }
procedure InjectGList(mp: PM; var L: TGList);
var
  gp: PG;
  n, i: LongInt;
  globq: TGList;
begin
  if L.head = nil then
    Exit;
  gp := L.head;
  while gp <> nil do
  begin
    if InterlockedCompareExchange(gp^.status, Grunnable, Gwaiting) <> Gwaiting then
      raise Exception.Create('pasrutinas: injectglist: bad g status');
    gp := gp^.schedlink;
  end;
  if (mp = nil) or (mp^.p = nil) then
  begin
    n := L.n;
    LockAcquire(schedLock);
    GlobRunqPutBatch(L);
    LockRelease(schedLock);
    while (n > 0) and (nIdleP > 0) do
    begin
      StartM(nil, False);
      Dec(n);
    end;
    Exit;
  end;
  { with a P: hand as many as there are idle Ps to the global queue and
    start Ms for them, keep the rest local }
  globq := Default(TGList);
  n := 0;
  while (n < nIdleP) and (L.head <> nil) do
  begin
    GListPush(globq, GListPop(L));
    Inc(n);
  end;
  if globq.head <> nil then
  begin
    LockAcquire(schedLock);
    GlobRunqPutBatch(globq);
    LockRelease(schedLock);
    for i := 1 to n do
      StartM(nil, False);
  end;
  while L.head <> nil do
    RunqPut(mp^.p, GListPop(L), False);
end;

{*****************************************************************************
                                Scheduler
******************************************************************************}

{ proc.go stealWork: 4 rounds over a random permutation; runnext only on
  the last round. }
function StealWork(mp: PM; pp: PPasP; Now: Int64): PG;
var
  round, i, start: LongInt;
  victim: PPasP;
  list: TGList;
  inherit: Boolean;
begin
  for round := 0 to 3 do
  begin
    start := LongInt(CheapRand(mp) mod Cardinal(nproc));
    for i := 0 to nproc - 1 do
    begin
      victim := allpArr[(start + i) mod nproc];
      if victim = pp then
        Continue;
      { last round: run the timers of the other P too (they may be idle) }
      if (round = 3) and (victim^.timer0When <> 0) then
      begin
        if Now = 0 then
          Now := NowNs;
        list := Default(TGList);
        FireTimers(victim, Now, list);
        if list.head <> nil then
        begin
          InjectGList(mp, list);
          Result := RunqGet(pp, inherit);
          if Result <> nil then
            Exit;
        end;
      end;
      if RunqEmpty(victim) then
        Continue;
      Result := RunqSteal(pp, victim, round = 3);
      if Result <> nil then
        Exit;
    end;
  end;
  Result := nil;
end;

function AnyPHasWork: Boolean;
var
  i: LongInt;
begin
  for i := 0 to nproc - 1 do
    if not RunqEmpty(allpArr[i]) then
      Exit(True);
  Result := False;
end;

{ proc.go findRunnable }
function FindRunnable(mp: PM): PG;
var
  pp: PPasP;
  gp: PG;
  inherit, wasSpinning: Boolean;
  list: TGList;
  now, pollUntil, delay: Int64;
label
  top;
begin
top:
  pp := mp^.p;
  if shuttingDown <> 0 then
    StopForever(mp);
  now := 0;
  if pp^.timer0When <> 0 then
  begin
    now := NowNs;
    list := Default(TGList);
    FireTimers(pp, now, list);
    if list.head <> nil then
      InjectGList(mp, list);
  end;

  { fairness: check the global queue once in a while }
  if (pp^.schedtick mod 61 = 0) and (globRunqN > 0) then
  begin
    LockAcquire(schedLock);
    gp := GlobRunqGet;
    LockRelease(schedLock);
    if gp <> nil then
      Exit(gp);
  end;

  gp := RunqGet(pp, inherit);
  if gp <> nil then
    Exit(gp);

  if globRunqN > 0 then
  begin
    LockAcquire(schedLock);
    gp := GlobRunqGetBatch(pp);
    LockRelease(schedLock);
    if gp <> nil then
      Exit(gp);
  end;

  { non-blocking netpoll, only an optimisation before stealing; skipped
    when nobody waits on an fd or another M is blocked in netpoll }
  if (epfd >= 0) and (netpollWaiters > 0) and (lastPoll <> 0) then
  begin
    list := Netpoll(0);
    if list.head <> nil then
    begin
      gp := GListPop(list);
      InjectGList(mp, list);
      if InterlockedCompareExchange(gp^.status, Grunnable, Gwaiting) <> Gwaiting then
        raise Exception.Create('pasrutinas: findrunnable: bad g status from netpoll');
      Exit(gp);
    end;
  end;

  { spin and steal: limit spinning Ms to half of the busy Ps }
  if mp^.spinning or (2 * nSpinning < nproc - nIdleP) then
  begin
    if not mp^.spinning then
      BecomeSpinning(mp);
    gp := StealWork(mp, pp, now);
    if gp <> nil then
      Exit(gp);
  end;

  { nothing found: release the P }
  LockAcquire(schedLock);
  if globRunqN > 0 then
  begin
    gp := GlobRunqGetBatch(pp);
    LockRelease(schedLock);
    if gp <> nil then
      Exit(gp);
    goto top;
  end;
  if (not mp^.spinning) and (needSpinning = 1) then
  begin
    BecomeSpinning(mp);
    LockRelease(schedLock);
    goto top;
  end;
  if ReleaseP(mp) <> pp then
    raise Exception.Create('pasrutinas: findrunnable: wrong p');
  PidlePut(pp);
  LockRelease(schedLock);

  wasSpinning := mp^.spinning;
  if wasSpinning then
  begin
    mp^.spinning := False;
    if InterlockedDecrement(nSpinning) < 0 then
      raise Exception.Create('pasrutinas: findrunnable: negative nmspinning');
    { the last spinning M must recheck all sources of work }
    if (globRunqN > 0) or AnyPHasWork then
    begin
      LockAcquire(schedLock);
      pp := PidleGet;
      LockRelease(schedLock);
      if pp <> nil then
      begin
        AcquireP(mp, pp);
        BecomeSpinning(mp);
        goto top;
      end;
    end;
    pollUntil := TimeSleepUntil;
    if (pollUntil <> 0) and (pollUntil <= NowNs) then
    begin
      LockAcquire(schedLock);
      pp := PidleGet;
      LockRelease(schedLock);
      if pp <> nil then
      begin
        AcquireP(mp, pp);
        BecomeSpinning(mp);
        goto top;
      end;
    end;
  end;

  { block in netpoll until the next timer, but only one M at a time }
  pollUntil := TimeSleepUntil;
  if (epfd >= 0) and ((netpollWaiters > 0) or (pollUntil <> 0)) and
     (InterlockedExchange64(lastPoll, 0) <> 0) then
  begin
    InterlockedExchange64(pollUntilGlobal, pollUntil);
    if mp^.p <> nil then
      raise Exception.Create('pasrutinas: findrunnable: netpoll with p');
    if pollUntil = 0 then
      delay := -1
    else
    begin
      delay := pollUntil - NowNs;
      if delay < 0 then
        delay := 0;
    end;
    list := Netpoll(delay);
    now := NowNs;
    InterlockedExchange64(lastPoll, now);
    InterlockedExchange64(pollUntilGlobal, 0);
    if shuttingDown <> 0 then
      StopForever(mp);
    FireAllTimers(now, list);
    LockAcquire(schedLock);
    pp := PidleGet;
    LockRelease(schedLock);
    if pp = nil then
      InjectGList(mp, list)
    else
    begin
      AcquireP(mp, pp);
      if list.head <> nil then
      begin
        gp := GListPop(list);
        InjectGList(mp, list);
        if InterlockedCompareExchange(gp^.status, Grunnable, Gwaiting) <> Gwaiting then
          raise Exception.Create('pasrutinas: findrunnable: bad g status from netpoll');
        Exit(gp);
      end;
      if wasSpinning then
        BecomeSpinning(mp);
      goto top;
    end;
  end
  else if (pollUntil <> 0) and (epfd >= 0) then
  begin
    { another M is polling with a possibly later deadline: shorten it }
    if (pollUntilGlobal = 0) or (pollUntilGlobal > pollUntil) then
      NetpollBreak;
  end;
  StopM(mp);
  goto top;
end;

{ proc.go execute: Grunnable -> Grunning, restore RTL state, longjmp. }
procedure Execute(mp: PM; gp: PG);
begin
  if InterlockedCompareExchange(gp^.status, Grunning, Grunnable) <> Grunnable then
    raise Exception.Create('pasrutinas: execute: bad g status');
  mp^.curg := gp;
  gp^.m := mp;
  gp^.preempt := 0;
  Inc(mp^.p^.schedtick);
  LoadExceptState(mp, gp);
  ApplyUserStack(mp, gp);
  PasRestore(gp^.sched, 1);
end;

{ proc.go schedule }
procedure Schedule(mp: PM);
var
  gp: PG;
begin
  while True do
  begin
    if shuttingDown <> 0 then
      StopForever(mp);
    if mp^.p = nil then
      StopM(mp);
    gp := FindRunnable(mp);
    if mp^.spinning then
      ResetSpinning(mp);
    Execute(mp, gp);
  end;
end;

{ proc.go park_m / goexit0 / gosched_m / exitsyscall0: runs on g0 right
  after the switch away from curg. The park commits here, after the G is
  off its M, so a waker can never see a running G. }
procedure FinishPark(mp: PM);
var
  gp: PG;
  kind: TParkKind;
  i: LongInt;
  pd: PPollDesc;
  gpp: PPointer;
  pp: PPasP;
begin
  gp := mp^.curg;
  if gp = nil then
    Exit;
  kind := gp^.parkKind;
  gp^.parkKind := pkNone;
  SaveExceptState(mp, gp);
  case kind of
    pkPark:
      begin
        InterlockedExchange(gp^.status, Gwaiting);
        gp^.m := nil;
        mp^.curg := nil;
        for i := 0 to gp^.unlockN - 1 do
          LockRelease(gp^.unlocks[i]^);
        gp^.unlockN := 0;
        if gp^.unlockCS <> nil then
        begin
          LeaveCriticalSection(gp^.unlockCS^);
          gp^.unlockCS := nil;
        end;
        if gp^.parkPoll <> nil then
        begin
          { netpollblockcommit }
          pd := gp^.parkPoll;
          if gp^.parkPollMode = PollRead then
            gpp := @pd^.rg
          else
            gpp := @pd^.wg;
          if InterlockedCompareExchange(gpp^, Pointer(gp), pdWait) = pdWait then
            InterlockedIncrement(netpollWaiters)
          else
          begin
            { readiness raced with the park: run the G again at once }
            gp^.parkPoll := nil;
            gp^.timerArm := False;
            if InterlockedCompareExchange(gp^.status, Grunnable, Gwaiting) <> Gwaiting then
              raise Exception.Create('pasrutinas: park commit: bad g status');
            Execute(mp, gp);
          end;
        end;
        { time.go resetForSleep: arm only after the G is parked }
        if gp^.timerArm then
        begin
          gp^.timerArm := False;
          AddTimer(mp^.p, gp^.timerWhen, gp, gp^.timerSeq, gp^.parkPoll, gp^.parkPollMode);
        end;
      end;
    pkYield:
      begin
        InterlockedExchange(gp^.status, Grunnable);
        gp^.m := nil;
        mp^.curg := nil;
        LockAcquire(schedLock);
        GlobRunqPut(gp);
        LockRelease(schedLock);
      end;
    pkYieldLocal:
      begin
        { proc.go goyield: tail of the local queue }
        InterlockedExchange(gp^.status, Grunnable);
        gp^.m := nil;
        mp^.curg := nil;
        RunqPut(mp^.p, gp, False);
      end;
    pkExit:
      begin
        gp^.m := nil;
        mp^.curg := nil;
        InterlockedDecrement(nG);
        RecycleG(mp, gp);
      end;
    pkExitSyscall:
      begin
        gp^.m := nil;
        mp^.curg := nil;
        InterlockedExchange(gp^.status, Grunnable);
        LockAcquire(schedLock);
        pp := PidleGet;
        if pp = nil then
          GlobRunqPut(gp);
        LockRelease(schedLock);
        if pp <> nil then
        begin
          AcquireP(mp, pp);
          Execute(mp, gp);
        end;
      end;
    pkNone:
      ;
  end;
end;

procedure G0Loop;
var
  mp: PM;
begin
  mp := GetM;
  if PasSave(mp^.g0^.sched) = 0 then
    { first entry; every SwitchToG0 lands here. mp is not modified after
      the setjmp, so its value survives the longjmp (callee-saved
      registers are restored by FPC_LONGJMP) };
  FinishPark(mp);
  Schedule(mp);
end;

function MStart(Parameter: Pointer): PtrInt;
var
  mp: PM;
  g0: PG;
begin
  mp := PM(Parameter);
  currentM := mp;
  if fpc_threadvar_relocate_proc <> nil then
    mp^.tvBase := fpc_threadvar_relocate_proc(0);
  mp^.pStackBottom := @StackBottom;
  mp^.pStackLength := @StackLength;
  SetupSignalStack(mp);
  New(g0);
  FillChar(g0^, SizeOf(TG), 0);
  g0^.isG0 := True;
  g0^.status := Grunning;
  g0^.stackLo := StackBottom;
  g0^.stackHi := Pointer(PtrUInt(StackBottom) + StackLength);
  mp^.g0 := g0;
  if mp^.nextp <> nil then
  begin
    AcquireP(mp, mp^.nextp);
    mp^.nextp := nil;
  end;
  G0Loop;
  Result := 0;
end;

{ proc.go newproc }
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
  if pp = nil then
    raise Exception.Create('pasrutinas: Pas() between PasEnterSyscall and PasExitSyscall');
  gp := GfGet(pp);
  if gp = nil then
    raise Exception.Create('pasrutinas: out of memory for stack');
  gp^.kind := Kind;
  gp^.fn := Fn;
  gp^.arg := Arg;
  gp^.method := Method;
  gp^.goid := QWord(InterlockedIncrement64(nextGoid));
  gp^.parkKind := pkNone;
  gp^.unlockN := 0;
  gp^.timerArm := False;
  gp^.parkPoll := nil;
  gp^.exceptAddr := nil;
  gp^.exceptObj := nil;
  gp^.preempt := 0;
  SetupFreshStack(gp, @PasTrampoline);
  InterlockedExchange(gp^.status, Grunnable);
  InterlockedIncrement(nG);
  RunqPut(pp, gp, True);
  Wakep;
  { sysmon asked the running pasrutina to yield (cooperative preemption) }
  if mp^.curg^.preempt <> 0 then
  begin
    mp^.curg^.preempt := 0;
    ParkWith(pkYield);
  end;
end;

{*****************************************************************************
                                  Timers
******************************************************************************}

{ runtime nanotime: CLOCK_MONOTONIC }
function NowNs: Int64;
var
  ts: timespec;
begin
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := Int64(ts.tv_sec) * 1000000000 + Int64(ts.tv_nsec);
end;

procedure TimerSwap(pp: PPasP; a, b: LongInt); inline;
var
  t: TTimer;
begin
  t := pp^.timers[a];
  pp^.timers[a] := pp^.timers[b];
  pp^.timers[b] := t;
end;

procedure TimerSiftUp(pp: PPasP; i: LongInt);
var
  parent: LongInt;
begin
  while i > 0 do
  begin
    parent := (i - 1) div 2;
    if pp^.timers[parent].when <= pp^.timers[i].when then
      Break;
    TimerSwap(pp, parent, i);
    i := parent;
  end;
end;

procedure TimerSiftDown(pp: PPasP; i: LongInt);
var
  l, r, smallest: LongInt;
begin
  while True do
  begin
    l := 2 * i + 1;
    r := l + 1;
    smallest := i;
    if (l < pp^.timersN) and (pp^.timers[l].when < pp^.timers[smallest].when) then
      smallest := l;
    if (r < pp^.timersN) and (pp^.timers[r].when < pp^.timers[smallest].when) then
      smallest := r;
    if smallest = i then
      Break;
    TimerSwap(pp, i, smallest);
    i := smallest;
  end;
end;

{ proc.go wakeNetPoller: an M blocked in netpoll with a later deadline
  is interrupted; if nobody is polling, wake an M so someone will. }
procedure WakeNetPoller(When: Int64);
var
  pu: Int64;
begin
  if lastPoll = 0 then
  begin
    pu := pollUntilGlobal;
    if (pu = 0) or (pu > When) then
      NetpollBreak;
  end
  else
    Wakep;
end;

{ time.go (t *timer) maybeAdd: insert into this P's heap; wake the
  poller only when the new timer is earlier than everything it knows. }
procedure AddTimer(pp: PPasP; When: Int64; gp: PG; Seq: LongInt; pd: PPollDesc; Mode: LongInt);
var
  i: LongInt;
  old: Int64;
begin
  LockAcquire(pp^.timersLock);
  if pp^.timersN = pp^.timersCap then
  begin
    if pp^.timersCap = 0 then
      pp^.timersCap := 64
    else
      pp^.timersCap := pp^.timersCap * 2;
    ReAllocMem(pp^.timers, pp^.timersCap * SizeOf(TTimer));
  end;
  i := pp^.timersN;
  pp^.timers[i].when := When;
  pp^.timers[i].gp := gp;
  pp^.timers[i].seq := Seq;
  pp^.timers[i].pd := pd;
  pp^.timers[i].mode := Mode;
  Inc(pp^.timersN);
  TimerSiftUp(pp, i);
  old := pp^.timer0When;
  InterlockedExchange64(pp^.timer0When, pp^.timers[0].when);
  LockRelease(pp^.timersLock);
  if (old = 0) or (When < old) then
    WakeNetPoller(When);
end;

{ time.go timeSleepUntil: earliest timer over all Ps, 0 if none }
function TimeSleepUntil: Int64;
var
  i: LongInt;
  w: Int64;
begin
  Result := 0;
  for i := 0 to nproc - 1 do
  begin
    w := allpArr[i]^.timer0When;
    if (w <> 0) and ((Result = 0) or (w < Result)) then
      Result := w;
  end;
end;

{ time.go (ts *timers) check + run: pop due entries of one P. Entries
  whose (gp, seq) no longer match the pasrutina's current wait are
  stale. For a poll timeout the pollDesc word arbitrates against I/O
  readiness (netpollunblock with ioready = false). }
procedure FireTimers(pp: PPasP; Now: Int64; var L: TGList);
var
  t: TTimer;
  gp: PG;
  gpp: PPointer;
  w: Int64;
begin
  w := pp^.timer0When;
  if (w = 0) or (w > Now) then
    Exit;
  while True do
  begin
    LockAcquire(pp^.timersLock);
    if (pp^.timersN = 0) or (pp^.timers[0].when > Now) then
    begin
      if pp^.timersN = 0 then
        InterlockedExchange64(pp^.timer0When, 0)
      else
        InterlockedExchange64(pp^.timer0When, pp^.timers[0].when);
      LockRelease(pp^.timersLock);
      Exit;
    end;
    t := pp^.timers[0];
    Dec(pp^.timersN);
    pp^.timers[0] := pp^.timers[pp^.timersN];
    TimerSiftDown(pp, 0);
    if pp^.timersN = 0 then
      InterlockedExchange64(pp^.timer0When, 0)
    else
      InterlockedExchange64(pp^.timer0When, pp^.timers[0].when);
    LockRelease(pp^.timersLock);
    gp := t.gp;
    if gp^.timerSeq <> t.seq then
      Continue;
    if t.pd <> nil then
    begin
      if t.mode = PollRead then
        gpp := @t.pd^.rg
      else
        gpp := @t.pd^.wg;
      if InterlockedCompareExchange(gpp^, pdNil, Pointer(gp)) <> Pointer(gp) then
        Continue;
      InterlockedDecrement(netpollWaiters);
    end;
    if gp^.status <> Gwaiting then
      Continue;
    GListPush(L, gp);
  end;
end;

procedure FireAllTimers(Now: Int64; var L: TGList);
var
  i: LongInt;
begin
  for i := 0 to nproc - 1 do
    FireTimers(allpArr[i], Now, L);
end;

{*****************************************************************************
                                  Netpoll
******************************************************************************}

{ netpoll_epoll.go netpollinit }
procedure NetpollInit;
var
  ev: TEpollEvent;
begin
  epfd := libc_epoll_create1(EPOLL_CLOEXEC);
  if epfd < 0 then
    raise Exception.Create('pasrutinas: epoll_create1 failed');
  eventFd := libc_eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK);
  if eventFd < 0 then
    raise Exception.Create('pasrutinas: eventfd failed');
  ev := Default(TEpollEvent);
  ev.events := EPOLLIN;
  ev.data := nil;
  if libc_epoll_ctl(epfd, EPOLL_CTL_ADD, eventFd, @ev) <> 0 then
    raise Exception.Create('pasrutinas: epoll_ctl(eventfd) failed');
end;

{ netpoll_epoll.go netpollBreak: one write per sleep }
procedure NetpollBreak;
var
  one: QWord;
begin
  if eventFd < 0 then
    Exit;
  if InterlockedCompareExchange(netpollWakeSig, 1, 0) <> 0 then
    Exit;
  InterlockedIncrement(statNetpollBreak);
  one := 1;
  libc_write(eventFd, @one, SizeOf(one));
end;

{ netpoll.go netpollunblock }
function NetpollUnblock(pd: PPollDesc; Mode: LongInt; IoReady: Boolean): PG;
var
  gpp: PPointer;
  old, new: Pointer;
begin
  if Mode = PollRead then
    gpp := @pd^.rg
  else
    gpp := @pd^.wg;
  while True do
  begin
    old := gpp^;
    if old = pdReady then
      Exit(nil);
    if (old = pdNil) and not IoReady then
      Exit(nil);
    if IoReady then
      new := pdReady
    else
      new := pdNil;
    if InterlockedCompareExchange(gpp^, new, old) = old then
    begin
      if old = pdWait then
        old := pdNil;
      if PtrUInt(old) > PtrUInt(pdWait) then
      begin
        InterlockedDecrement(netpollWaiters);
        Exit(PG(old));
      end;
      Exit(nil);
    end;
  end;
end;

{ netpoll_epoll.go netpoll: DelayNs < 0 blocks, 0 polls, > 0 waits. }
function Netpoll(DelayNs: Int64): TGList;
var
  evs: array[0..127] of TEpollEvent;
  n, i, timeout: LongInt;
  pd: PPollDesc;
  one: QWord;
  mode: LongWord;
  gp: PG;
begin
  Result := Default(TGList);
  if epfd < 0 then
    Exit;
  if DelayNs < 0 then
    timeout := -1
  else if DelayNs = 0 then
    timeout := 0
  else if DelayNs < 1000000 then
    timeout := 1
  else if DelayNs > Int64(1000) * 1000000000 then
    timeout := 1000000
  else
    timeout := LongInt((DelayNs + 999999) div 1000000);
  n := libc_epoll_wait(epfd, @evs[0], Length(evs), timeout);
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
    if (mode and (EPOLLIN or EPOLLRDHUP or EPOLLHUP or EPOLLERR)) <> 0 then
    begin
      gp := NetpollUnblock(pd, PollRead, True);
      if gp <> nil then
        GListPush(Result, gp);
    end;
    if (mode and (EPOLLOUT or EPOLLHUP or EPOLLERR)) <> 0 then
    begin
      gp := NetpollUnblock(pd, PollWrite, True);
      if gp <> nil then
        GListPush(Result, gp);
    end;
  end;
end;

{ netpoll.go poll_runtime_pollOpen + netpoll_epoll.go netpollopen.
  Descriptors are indexed by fd and never freed (pollcache), so a late
  waker always finds valid memory. }
function GetPollDesc(Fd: LongInt): PPollDesc;
var
  ev: TEpollEvent;
  fl, newN: LongInt;
begin
  if Fd < 0 then
    raise Exception.Create('pasrutinas: invalid fd');
  LockAcquire(pollLock);
  if Fd >= pollDescsN then
  begin
    newN := pollDescsN * 2;
    if newN < 64 then
      newN := 64;
    if newN <= Fd then
      newN := Fd + 1;
    ReAllocMem(pollDescs, newN * SizeOf(PPollDesc));
    FillChar(pollDescs[pollDescsN], (newN - pollDescsN) * SizeOf(PPollDesc), 0);
    pollDescsN := newN;
  end;
  Result := pollDescs[Fd];
  if Result = nil then
  begin
    New(Result);
    FillChar(Result^, SizeOf(TPollDesc), 0);
    Result^.fd := Fd;
    pollDescs[Fd] := Result;
  end;
  if not Result^.registered then
  begin
    fl := libc_fcntl(Fd, F_GETFL, 0);
    if fl >= 0 then
      libc_fcntl(Fd, F_SETFL, fl or O_NONBLOCK);
    ev := Default(TEpollEvent);
    ev.events := EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET;
    ev.data := Result;
    if libc_epoll_ctl(epfd, EPOLL_CTL_ADD, Fd, @ev) <> 0 then
    begin
      if fpgeterrno <> ESysEEXIST then
      begin
        LockRelease(pollLock);
        raise Exception.CreateFmt('pasrutinas: epoll_ctl(ADD, %d) failed, errno %d', [Fd, fpgeterrno]);
      end;
    end;
    Result^.rg := pdNil;
    Result^.wg := pdNil;
    Result^.registered := True;
  end;
  LockRelease(pollLock);
end;

{ netpoll.go poll_runtime_pollUnblock + pollClose: drop the fd from
  epoll and fail the waiters (they return False). }
procedure PasUnregisterFd(Fd: LongInt);
var
  pd: PPollDesc;
  gp: PG;
  L: TGList;
begin
  if initState <> 2 then
    Exit;
  LockAcquire(pollLock);
  pd := nil;
  if (Fd >= 0) and (Fd < pollDescsN) then
    pd := pollDescs[Fd];
  if (pd <> nil) and pd^.registered then
  begin
    libc_epoll_ctl(epfd, EPOLL_CTL_DEL, Fd, nil);
    pd^.registered := False;
  end
  else
    pd := nil;
  LockRelease(pollLock);
  if pd = nil then
    Exit;
  L := Default(TGList);
  gp := NetpollUnblock(pd, PollRead, False);
  if gp <> nil then
    GListPush(L, gp);
  gp := NetpollUnblock(pd, PollWrite, False);
  if gp <> nil then
    GListPush(L, gp);
  InjectGList(GetM, L);
end;

{ netpoll.go netpollblock + poll_runtime_pollWait }
function WaitPoll(Fd, Mode: LongInt; TimeoutMs: LongInt): Boolean;
var
  mp: PM;
  gp: PG;
  pd: PPollDesc;
  gpp: PPointer;
  v, old: Pointer;
begin
  PasInit;
  mp := GetM;
  if (mp = nil) or (mp^.curg = nil) then
    raise Exception.Create('pasrutinas: PasWait* outside a pasrutina');
  gp := mp^.curg;
  pd := GetPollDesc(Fd);
  if Mode = PollRead then
    gpp := @pd^.rg
  else
    gpp := @pd^.wg;
  while True do
  begin
    { consume a pending notification }
    if InterlockedCompareExchange(gpp^, pdNil, pdReady) = pdReady then
      Exit(True);
    if InterlockedCompareExchange(gpp^, pdWait, pdNil) = pdNil then
      Break;
    v := gpp^;
    if (v <> pdReady) and (v <> pdNil) then
      raise Exception.Create('pasrutinas: double wait on the same fd');
  end;
  gp^.parkPoll := pd;
  gp^.parkPollMode := Mode;
  if TimeoutMs > 0 then
  begin
    gp^.timerArm := True;
    gp^.timerWhen := NowNs + Int64(TimeoutMs) * 1000000;
  end;
  ParkWith(pkPark);
  gp^.parkPoll := nil;
  old := InterlockedExchange(gpp^, pdNil);
  if PtrUInt(old) > PtrUInt(pdWait) then
    raise Exception.Create('pasrutinas: corrupted polldesc');
  Result := old = pdReady;
end;

{*****************************************************************************
                        System calls and sysmon
******************************************************************************}

{ proc.go entersyscall: the P goes to Psyscall; sysmon may retake it. }
procedure PasEnterSyscall;
var
  mp: PM;
  gp: PG;
  pp: PPasP;
begin
  mp := GetM;
  if (mp = nil) or (mp^.curg = nil) or (mp^.p = nil) then
    Exit;
  gp := mp^.curg;
  if gp^.status <> Grunning then
    Exit;
  pp := mp^.p;
  pp^.m := nil;
  mp^.oldp := pp;
  mp^.p := nil;
  InterlockedExchange(gp^.status, Gsyscall);
  Inc(pp^.syscalltick);
  InterlockedExchange(pp^.status, Psyscall);
end;

{ proc.go exitsyscall: fast path takes the old P back, then any idle P,
  otherwise the G goes to the global queue and the M stops. }
procedure PasExitSyscall;
var
  mp: PM;
  gp: PG;
  pp: PPasP;
begin
  mp := GetM;
  if (mp = nil) or (mp^.curg = nil) then
    Exit;
  gp := mp^.curg;
  if gp^.status <> Gsyscall then
    Exit;
  pp := mp^.oldp;
  mp^.oldp := nil;
  if (pp <> nil) and (InterlockedCompareExchange(pp^.status, Prunning, Psyscall) = Psyscall) then
  begin
    mp^.p := pp;
    pp^.m := mp;
    InterlockedExchange(gp^.status, Grunning);
    Exit;
  end;
  LockAcquire(schedLock);
  pp := PidleGet;
  LockRelease(schedLock);
  if pp <> nil then
  begin
    AcquireP(mp, pp);
    InterlockedExchange(gp^.status, Grunning);
    Exit;
  end;
  ParkWith(pkExitSyscall);
end;

{ proc.go retake: hand off Ps stuck in syscalls, flag long-running Gs. }
function Retake(Now: Int64): LongInt;
var
  i: LongInt;
  pp: PPasP;
  s: LongInt;
  t: Cardinal;
  mp: PM;
  gp: PG;
begin
  Result := 0;
  for i := 0 to nproc - 1 do
  begin
    pp := allpArr[i];
    s := pp^.status;
    if s = Psyscall then
    begin
      t := pp^.syscalltick;
      if pp^.smSyscalltick <> t then
      begin
        pp^.smSyscalltick := t;
        pp^.smSyscallwhen := Now;
        Continue;
      end;
      { no work and someone else can run it soon: leave it for 10 ms }
      if RunqEmpty(pp) and (nSpinning + nIdleP > 0) and
         (pp^.smSyscallwhen + forcePreemptNs > Now) then
        Continue;
      if InterlockedCompareExchange(pp^.status, Pidle, Psyscall) = Psyscall then
      begin
        Inc(Result);
        HandoffP(pp);
      end;
    end
    else if s = Prunning then
    begin
      t := pp^.schedtick;
      if pp^.smSchedtick <> t then
      begin
        pp^.smSchedtick := t;
        pp^.smSchedwhen := Now;
      end
      else if pp^.smSchedwhen + forcePreemptNs <= Now then
      begin
        mp := pp^.m;
        if mp <> nil then
        begin
          gp := mp^.curg;
          if gp <> nil then
            InterlockedExchange(gp^.preempt, 1);
        end;
      end;
    end;
  end;
end;

{ proc.go sysmon: an OS thread without a P. }
{$PUSH}{$WARN 5024 OFF}
function SysmonThread(Parameter: Pointer): PtrInt;
var
  delay, idle: LongInt;
  now, lp: Int64;
  list: TGList;
begin
  currentM := nil;
  idle := 0;
  delay := sysmonMinUs;
  while shuttingDown = 0 do
  begin
    if idle = 0 then
      delay := sysmonMinUs
    else if idle > 50 then
      delay := delay * 2;
    if delay > sysmonMaxUs then
      delay := sysmonMaxUs;
    libc_usleep(delay);
    if shuttingDown <> 0 then
      Break;
    now := NowNs;
    lp := lastPoll;
    if (lp <> 0) and (lp + 10 * 1000000 < now) then
    begin
      if netpollWaiters > 0 then
      begin
        InterlockedCompareExchange64(lastPoll, now, lp);
        list := Netpoll(0);
        if list.head <> nil then
        begin
          InjectGList(nil, list);
          idle := 0;
        end;
      end;
      if TimeSleepUntil <> 0 then
      begin
        list := Default(TGList);
        FireAllTimers(now, list);
        if list.head <> nil then
        begin
          InjectGList(nil, list);
          idle := 0;
        end;
      end;
    end;
    if Retake(now) <> 0 then
      idle := 0
    else
      Inc(idle);
  end;
  Result := 0;
end;
{$POP}

procedure SysmonStart;
var
  tid: TThreadID;
  dummy: TThreadID;
begin
  dummy := TThreadID(0);
  tid := BeginThread(nil, PasMStackSize, @SysmonThread, nil, 0, dummy);
  if tid = TThreadID(0) then
    raise Exception.Create('pasrutinas: cannot start sysmon thread');
end;

{*****************************************************************************
                       Signal stacks, init, shutdown
******************************************************************************}

{ runtime2.go gsignal / os_linux.go minitSignalStack: run signal
  handlers on a dedicated per-thread stack so a runtime error inside a
  small pasrutina stack does not hit the guard page. The RTL installs
  its handlers without SA_ONSTACK (rtl/linux/system.pp
  InstallDefaultSignalHandler); re-install them with the flag, keeping
  the restorer the kernel reported. }
procedure SetupSignalStack(mp: PM);
var
  ss: TStackT;
begin
  mp^.sigStack := GetMem(PasSignalStack);
  ss.ss_sp := mp^.sigStack;
  ss.ss_flags := 0;
  ss.ss_size := PasSignalStack;
  libc_sigaltstack(@ss, nil);
end;

procedure InstallOnStackHandlers;
const
  sigs: array[0..3] of LongInt = (SIGSEGV, SIGBUS, SIGFPE, SIGILL);
var
  i: LongInt;
  act: SigActionRec;
begin
  for i := 0 to High(sigs) do
  begin
    act := Default(SigActionRec);
    if FpSigAction(sigs[i], nil, @act) <> 0 then
      Continue;
    if (act.sa_flags and SA_ONSTACK) <> 0 then
      Continue;
    act.sa_flags := act.sa_flags or SA_ONSTACK;
    FpSigAction(sigs[i], @act, nil);
  end;
end;

{ Runs from ExitProc, i.e. before unit finalization and heap teardown
  (rtl/inc/system.inc InternalExit). Go returns from main.main straight
  into exit(0); here the Ms that are inside the scheduler park for good
  before the RTL destroys anything they use. Ms still running user code
  are abandoned, as goroutines are. }
{ Output, ErrOutput, StdOut and StdErr are threadvars; the RTL only
  flushes the exiting thread's copies (InternalExit -> SysFlushStdIO).
  Flush the buffers of every M that has stopped. }
procedure FlushAllStdIO;
var
  base: PtrUInt;
  offs: array[0..3] of PtrUInt;
  mp: PM;
  i: LongInt;
  t: PText;
begin
  if fpc_threadvar_relocate_proc = nil then
    Exit;
  base := PtrUInt(fpc_threadvar_relocate_proc(0));
  offs[0] := PtrUInt(@Output) - base;
  offs[1] := PtrUInt(@ErrOutput) - base;
  offs[2] := PtrUInt(@StdOut) - base;
  offs[3] := PtrUInt(@StdErr) - base;
  LockAcquire(schedLock);
  mp := allm;
  LockRelease(schedLock);
  while mp <> nil do
  begin
    if mp^.stopped and (mp^.tvBase <> nil) then
      for i := 0 to 3 do
      begin
        t := PText(PtrUInt(mp^.tvBase) + offs[i]);
        if TextRec(t^).Mode = fmOutput then
          Flush(t^);
      end;
    mp := mp^.alllink;
  end;
end;

procedure PasShutdownProc;
var
  mp, self: PM;
  deadline: Int64;
  target: LongInt;
begin
  if initState = 2 then
  begin
    InterlockedExchange(shuttingDown, 1);
    self := GetM;
    NetpollBreak;
    LockAcquire(schedLock);
    mp := allm;
    LockRelease(schedLock);
    while mp <> nil do
    begin
      RTLEventSetEvent(mp^.parkEvent);
      mp := mp^.alllink;
    end;
    target := nM;
    if self <> nil then
      Dec(target);
    deadline := NowNs + 200 * 1000000;
    while (nMStopped < target) and (NowNs < deadline) do
    begin
      libc_usleep(500);
      InterlockedExchange(netpollWakeSig, 0);
      NetpollBreak;
    end;
    FlushAllStdIO;
    if GetEnvironmentVariable('PASRUTINAS_STATS') = '1' then
      PasWriteLn('pasrutinas stats: M=%d newM=%d mstart=%d stopm=%d spinning=%d steal=%d park=%d futexsleep=%d netpollbreak=%d',
        [nM, statMNew, statMStart, statStopM, statSpinning, statSteal, statPark, statFutexSleep, statNetpollBreak]);
  end;
  if prevExitProc <> nil then
    TProcedure(prevExitProc)();
end;

{ proc.go schedinit + procresize + mstart for the main thread. }
procedure InitRuntime;
var
  i: LongInt;
  pp: PPasP;
  mp: PM;
  g0, mainG: PG;
  ps: PtrInt;
begin
  ps := libc_sysconf(SC_PAGESIZE);
  if ps > 0 then
    pageSize := PtrUInt(ps);
  if nproc <= 0 then
  begin
    nproc := LongInt(libc_sysconf(SC_NPROCESSORS_ONLN));
    if nproc <= 0 then
      nproc := LongInt(GetCPUCount);
    if nproc <= 0 then
      nproc := 1;
  end;
  ncpu := LongInt(libc_sysconf(SC_NPROCESSORS_ONLN));
  if ncpu <= 0 then
    ncpu := 1;

  allp := GetMem(nproc * SizeOf(TPasP));
  FillChar(allp^, nproc * SizeOf(TPasP), 0);
  allpArr := GetMem(nproc * SizeOf(PPasP));
  for i := 0 to nproc - 1 do
  begin
    pp := @allp[i];
    pp^.id := i;
    pp^.status := Pidle;
    allpArr[i] := pp;
  end;

  New(mp);
  FillChar(mp^, SizeOf(TM), 0);
  mp^.id := 0;
  InterlockedIncrement(nM);
  mp^.parkEvent := RTLEventCreate;
  mp^.rand := $9E3779B9;
  allm := mp;
  currentM := mp;

  New(g0);
  FillChar(g0^, SizeOf(TG), 0);
  g0^.isG0 := True;
  g0^.status := Grunning;
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

  AcquireP(mp, allpArr[0]);
  LockAcquire(schedLock);
  for i := 1 to nproc - 1 do
    PidlePut(allpArr[i]);
  LockRelease(schedLock);

  NetpollInit;
  InterlockedExchange64(lastPoll, NowNs);

  { The first BeginThread makes the RTL multi-threaded: threadvars move
    to per-thread blocks (threadvr.inc InitThreadVars copies the main
    thread's values, so currentM survives) and the heap takes its lock.
    Only after that can the exception state be located. }
  SysmonStart;
  if fpc_threadvar_relocate_proc <> nil then
    mp^.tvBase := fpc_threadvar_relocate_proc(0);
  mp^.pStackBottom := @StackBottom;
  mp^.pStackLength := @StackLength;
  DiscoverExceptState;
  InstallOnStackHandlers;
  SetupSignalStack(mp);

  prevExitProc := ExitProc;
  ExitProc := @PasShutdownProc;
end;

procedure PasInit;
begin
  if initState = 2 then
    Exit;
  if InterlockedCompareExchange(initState, 1, 0) = 0 then
  begin
    InitRuntime;
    InterlockedExchange(initState, 2);
  end
  else
    while initState <> 2 do
      ThreadSwitch;
end;

{*****************************************************************************
                                Public API
******************************************************************************}

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

{ time.go timeSleep: the timer is armed by FinishPark once the G is
  parked (resetForSleep). }
procedure PasSleepNs(Ns: Int64);
var
  mp: PM;
  gp: PG;
begin
  PasInit;
  if Ns <= 0 then
  begin
    PasYield;
    Exit;
  end;
  mp := GetM;
  if (mp = nil) or (mp^.curg = nil) then
    raise Exception.Create('pasrutinas: PasSleep outside a pasrutina');
  gp := mp^.curg;
  gp^.parkPoll := nil;
  gp^.timerArm := True;
  gp^.timerWhen := NowNs + Ns;
  ParkWith(pkPark);
end;

procedure PasSleep(Ms: QWord);
begin
  PasSleepNs(Int64(Ms) * 1000000);
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
  Ready(PG(G), True);
end;

procedure PasInternalReady(G: TPasrutina);
begin
  PasReady(G);
end;

procedure PasInternalParkUnlock(var CS: TRTLCriticalSection);
var
  mp: PM;
begin
  mp := GetM;
  mp^.curg^.unlockCS := @CS;
  ParkWithM(mp, pkPark);
end;

procedure PasInternalParkUnlockLock(var L: TPasLock);
var
  mp: PM;
begin
  mp := GetM;
  mp^.curg^.unlocks[0] := @L;
  mp^.curg^.unlockN := 1;
  ParkWithM(mp, pkPark);
end;

function PasParkUnlock(var CS: TRTLCriticalSection): Boolean;
begin
  PasInternalParkUnlock(CS);
  Result := True;
end;

procedure PasInternalParkUnlockMany(const Locks: array of PPasLock);
var
  mp: PM;
  gp: PG;
  i, n: LongInt;
begin
  mp := GetM;
  gp := mp^.curg;
  n := Length(Locks);
  if n > 16 then
    n := 16;
  gp^.unlockN := 0;
  for i := 0 to n - 1 do
    if Locks[i] <> nil then
    begin
      gp^.unlocks[gp^.unlockN] := Locks[i];
      Inc(gp^.unlockN);
    end;
  ParkWithM(mp, pkPark);
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

function PasWaitWriteTimeout(Fd: LongInt; Ms: LongInt): Boolean;
begin
  Result := WaitPoll(Fd, PollWrite, Ms);
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

function PasNow: Int64;
begin
  Result := NowNs;
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
  if initState <> 0 then
  begin
    if N <> nproc then
      raise Exception.Create('PASMAXPROCS: must be set before the first Pas()/PasInit');
    Exit;
  end;
  nproc := N;
end;

procedure PasSetStackSize(Bytes: PtrUInt);
begin
  if Bytes < 4096 then
    Bytes := 4096;
  defaultStack := (Bytes + 4095) and not PtrUInt(4095);
end;

function PasStackSize: PtrUInt;
begin
  Result := defaultStack;
end;

{ Output is a threadvar Text (rtl/inc/systemh.inc): each OS thread has
  its own buffer, flushed per line only on a tty (text.inc OpenStdIO
  sets FlushFunc for devices). One locked WriteLn plus Flush makes a
  line a single write(2) like os.Stdout.Write in Go. }
procedure PasWriteLn(const S: AnsiString);
begin
  EnterCriticalSection(outLock);
  PasEnterSyscall;
  try
    WriteLn(S);
    Flush(Output);
  finally
    LeaveCriticalSection(outLock);
    PasExitSyscall;
  end;
end;

procedure PasWriteLn(const Fmt: AnsiString; const Args: array of const);
begin
  PasWriteLn(Format(Fmt, Args));
end;

{*****************************************************************************
                       sync: WaitGroup, Mutex, RWMutex, Once, Cond
******************************************************************************}

{ sema.go: a semaphore is a count plus a queue of parked pasrutinas.
  Waiters enqueue under the root lock and park releasing it, so a
  releaser can only dequeue a G that is already Gwaiting. }

{ sema.go cansemacquire }
function CanSemAcquire(var S: TPasSema): Boolean;
var
  v: LongInt;
begin
  while True do
  begin
    v := S.count;
    if v = 0 then
      Exit(False);
    if InterlockedCompareExchange(S.count, v - 1, v) = v then
      Exit(True);
  end;
end;

procedure SemQueue(var S: TPasSema; gp: PG; Lifo: Boolean);
begin
  gp^.waitlink := nil;
  if S.head = nil then
  begin
    S.head := gp;
    S.tail := gp;
    Exit;
  end;
  if Lifo then
  begin
    gp^.waitlink := PG(S.head);
    S.head := gp;
  end
  else
  begin
    PG(S.tail)^.waitlink := gp;
    S.tail := gp;
  end;
end;

function SemDequeue(var S: TPasSema): PG;
begin
  Result := PG(S.head);
  if Result = nil then
    Exit;
  S.head := Result^.waitlink;
  if S.head = nil then
    S.tail := nil;
  Result^.waitlink := nil;
end;

{ sema.go semacquire1 }
procedure SemAcquire(var S: TPasSema; Lifo: Boolean);
var
  mp: PM;
  gp: PG;
begin
  if CanSemAcquire(S) then
    Exit;
  mp := GetM;
  if (mp = nil) or (mp^.curg = nil) then
    raise Exception.Create('pasrutinas: semacquire outside a pasrutina');
  gp := mp^.curg;
  mp := nil;
  gp^.semTicket := 0;
  while True do
  begin
    LockAcquire(S.lock);
    InterlockedIncrement(S.nwait);
    if CanSemAcquire(S) then
    begin
      InterlockedDecrement(S.nwait);
      LockRelease(S.lock);
      Break;
    end;
    SemQueue(S, gp, Lifo);
    gp^.unlocks[0] := @S.lock;
    gp^.unlockN := 1;
    { the M can change across a park: never reuse mp after one }
    ParkWithM(GetM, pkPark);
    if (gp^.semTicket <> 0) or CanSemAcquire(S) then
      Break;
  end;
end;

{ sema.go semrelease1: with Handoff the count is passed straight to the
  waiter (ticket) and the releaser yields so it runs at once. }
procedure SemRelease(var S: TPasSema; Handoff: Boolean);
var
  gp: PG;
  mp: PM;
begin
  InterlockedIncrement(S.count);
  if S.nwait = 0 then
    Exit;
  LockAcquire(S.lock);
  if S.nwait = 0 then
  begin
    LockRelease(S.lock);
    Exit;
  end;
  gp := SemDequeue(S);
  if gp <> nil then
    InterlockedDecrement(S.nwait);
  LockRelease(S.lock);
  if gp = nil then
    Exit;
  if Handoff and CanSemAcquire(S) then
    gp^.semTicket := 1;
  Ready(gp, True);
  if gp^.semTicket = 1 then
  begin
    mp := GetM;
    if (mp <> nil) and (mp^.curg <> nil) and (mp^.p <> nil) then
      ParkWithM(mp, pkYieldLocal);
  end;
end;

{ TPasWaitGroup: sync.WaitGroup semantics on a counter + parked waiters. }

constructor TPasWaitGroup.Create;
begin
  inherited Create;
  FCount := 0;
  FWaiters := nil;
  FLock.key := 0;
end;

destructor TPasWaitGroup.Destroy;
begin
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
  LockAcquire(FLock);
  w := PG(FWaiters);
  FWaiters := nil;
  LockRelease(FLock);
  while w <> nil do
  begin
    nx := w^.waitlink;
    w^.waitlink := nil;
    Ready(w, True);
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
  LockAcquire(FLock);
  if FCount = 0 then
  begin
    LockRelease(FLock);
    Exit;
  end;
  gp^.waitlink := PG(FWaiters);
  FWaiters := gp;
  PasInternalParkUnlockLock(FLock);
end;

{ TPasMutex: internal/sync/mutex.go }

constructor TPasMutex.Create;
begin
  inherited Create;
  FState := 0;
  FSema := Default(TPasSema);
end;

destructor TPasMutex.Destroy;
begin
  inherited Destroy;
end;

{ proc.go internal_sync_runtime_canSpin }
function MutexCanSpin(Iter: LongInt): Boolean;
var
  mp: PM;
begin
  if (Iter >= lockActiveSpin) or (ncpu <= 1) or (nproc <= nIdleP + nSpinning + 1) then
    Exit(False);
  mp := GetM;
  if (mp = nil) or (mp^.p = nil) or not RunqEmpty(mp^.p) then
    Exit(False);
  Result := True;
end;

procedure TPasMutex.Lock;
begin
  if InterlockedCompareExchange(FState, mutexLocked, 0) = 0 then
    Exit;
  LockSlow;
end;

procedure TPasMutex.LockSlow;
var
  waitStartTime: Int64;
  starving, awoke, lifo: Boolean;
  iter, old, new, delta: LongInt;
begin
  waitStartTime := 0;
  starving := False;
  awoke := False;
  iter := 0;
  old := FState;
  while True do
  begin
    { spin while locked, not starving, and spinning makes sense }
    if ((old and (mutexLocked or mutexStarving)) = mutexLocked) and MutexCanSpin(iter) then
    begin
      if (not awoke) and ((old and mutexWoken) = 0) and ((old shr mutexWaiterShift) <> 0) and
         (InterlockedCompareExchange(FState, old or mutexWoken, old) = old) then
        awoke := True;
      ProcYield(lockActiveSpinCnt);
      Inc(iter);
      old := FState;
      Continue;
    end;
    new := old;
    if (old and mutexStarving) = 0 then
      new := new or mutexLocked;
    if (old and (mutexLocked or mutexStarving)) <> 0 then
      new := new + (1 shl mutexWaiterShift);
    if starving and ((old and mutexLocked) <> 0) then
      new := new or mutexStarving;
    if awoke then
    begin
      if (new and mutexWoken) = 0 then
        raise Exception.Create('TPasMutex: inconsistent mutex state');
      new := new and not mutexWoken;
    end;
    if InterlockedCompareExchange(FState, new, old) = old then
    begin
      if (old and (mutexLocked or mutexStarving)) = 0 then
        Break;
      lifo := waitStartTime <> 0;
      if waitStartTime = 0 then
        waitStartTime := NowNs;
      SemAcquire(FSema, lifo);
      starving := starving or (NowNs - waitStartTime > starvationThresholdNs);
      old := FState;
      if (old and mutexStarving) <> 0 then
      begin
        { handed off directly: fix up the state ourselves }
        if ((old and (mutexLocked or mutexWoken)) <> 0) or ((old shr mutexWaiterShift) = 0) then
          raise Exception.Create('TPasMutex: inconsistent mutex state');
        delta := mutexLocked - (1 shl mutexWaiterShift);
        if (not starving) or ((old shr mutexWaiterShift) = 1) then
          delta := delta - mutexStarving;
        InterlockedExchangeAdd(FState, delta);
        Break;
      end;
      awoke := True;
      iter := 0;
    end
    else
      old := FState;
  end;
end;

procedure TPasMutex.Unlock;
var
  new: LongInt;
begin
  new := InterlockedExchangeAdd(FState, -mutexLocked) - mutexLocked;
  if new <> 0 then
    UnlockSlow(new);
end;

procedure TPasMutex.UnlockSlow(New: LongInt);
var
  old, n: LongInt;
begin
  if ((New + mutexLocked) and mutexLocked) = 0 then
    raise Exception.Create('TPasMutex: unlock of unlocked mutex');
  if (New and mutexStarving) = 0 then
  begin
    old := New;
    while True do
    begin
      if ((old shr mutexWaiterShift) = 0) or ((old and (mutexLocked or mutexWoken or mutexStarving)) <> 0) then
        Exit;
      n := (old - (1 shl mutexWaiterShift)) or mutexWoken;
      if InterlockedCompareExchange(FState, n, old) = old then
      begin
        SemRelease(FSema, False);
        Exit;
      end;
      old := FState;
    end;
  end
  else
    SemRelease(FSema, True);
end;

{ TPasRWMutex: writer preference, readers batched. }

constructor TPasRWMutex.Create;
begin
  inherited Create;
  FReaders := 0;
  FWriter := False;
  FReadWaiters := nil;
  FWriteWaiters := nil;
  FLock.key := 0;
end;

destructor TPasRWMutex.Destroy;
begin
  inherited Destroy;
end;

procedure TPasRWMutex.BeginRead;
var
  gp: PG;
begin
  PasInit;
  LockAcquire(FLock);
  if FWriter or (FWriteWaiters <> nil) then
  begin
    gp := PG(PasCurrent);
    gp^.waitlink := PG(FReadWaiters);
    FReadWaiters := gp;
    PasInternalParkUnlockLock(FLock);
    Exit;
  end;
  Inc(FReaders);
  LockRelease(FLock);
end;

procedure TPasRWMutex.EndRead;
var
  w: PG;
begin
  LockAcquire(FLock);
  Dec(FReaders);
  if (FReaders = 0) and (FWriteWaiters <> nil) then
  begin
    w := PG(FWriteWaiters);
    FWriteWaiters := w^.waitlink;
    w^.waitlink := nil;
    FWriter := True;
    LockRelease(FLock);
    Ready(w, True);
    Exit;
  end;
  LockRelease(FLock);
end;

procedure TPasRWMutex.Lock;
var
  gp: PG;
begin
  PasInit;
  LockAcquire(FLock);
  if (FReaders > 0) or FWriter then
  begin
    gp := PG(PasCurrent);
    gp^.waitlink := PG(FWriteWaiters);
    FWriteWaiters := gp;
    PasInternalParkUnlockLock(FLock);
    Exit;
  end;
  FWriter := True;
  LockRelease(FLock);
end;

procedure TPasRWMutex.Unlock;
var
  w, nx: PG;
begin
  LockAcquire(FLock);
  FWriter := False;
  if FWriteWaiters <> nil then
  begin
    w := PG(FWriteWaiters);
    FWriteWaiters := w^.waitlink;
    w^.waitlink := nil;
    FWriter := True;
    LockRelease(FLock);
    Ready(w, True);
    Exit;
  end;
  w := PG(FReadWaiters);
  FReadWaiters := nil;
  nx := w;
  while nx <> nil do
  begin
    Inc(FReaders);
    nx := nx^.waitlink;
  end;
  LockRelease(FLock);
  while w <> nil do
  begin
    nx := w^.waitlink;
    w^.waitlink := nil;
    Ready(w, False);
    w := nx;
  end;
end;

{ TPasOnce: sync.Once }

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
  if InterlockedCompareExchange(FDone, 0, 0) <> 0 then
    Exit;
  FMu.Lock;
  try
    if FDone = 0 then
    begin
      Proc();
      InterlockedExchange(FDone, 1);
    end;
  finally
    FMu.Unlock;
  end;
end;

{ TPasCond: sync.Cond }

constructor TPasCond.Create;
begin
  inherited Create;
  FWaiters := nil;
  FLock.key := 0;
end;

destructor TPasCond.Destroy;
begin
  inherited Destroy;
end;

procedure TPasCond.Wait(M: TPasMutex);
var
  gp: PG;
begin
  PasInit;
  gp := PG(PasCurrent);
  LockAcquire(FLock);
  gp^.waitlink := PG(FWaiters);
  FWaiters := gp;
  M.Unlock;
  PasInternalParkUnlockLock(FLock);
  M.Lock;
end;

procedure TPasCond.Signal;
var
  w: PG;
begin
  LockAcquire(FLock);
  w := PG(FWaiters);
  if w <> nil then
  begin
    FWaiters := w^.waitlink;
    w^.waitlink := nil;
  end;
  LockRelease(FLock);
  if w <> nil then
    Ready(w, True);
end;

procedure TPasCond.Broadcast;
var
  w, nx: PG;
begin
  LockAcquire(FLock);
  w := PG(FWaiters);
  FWaiters := nil;
  LockRelease(FLock);
  while w <> nil do
  begin
    nx := w^.waitlink;
    w^.waitlink := nil;
    Ready(w, False);
    w := nx;
  end;
end;

initialization
  InitCriticalSection(outLock);

end.
