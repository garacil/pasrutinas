# API

Two units: `pasrutinas` (scheduler, timers, poller, sync, exceptions)
and `paschan` (channels, select). `cthreads` must be the first unit of
the program. Every routine below names the Go function it mirrors.

## pasrutinas

### Spawning and scheduling

| Routine | Go | Notes |
|---|---|---|
| `procedure Pas(Proc: TPasProc)` | `go f()` | Spawns; the new pasrutina goes to the current P's `runnext` |
| `procedure Pas(Proc: TPasProcArg; Arg: Pointer)` | `go f(arg)` | `Arg` must outlive the pasrutina |
| `procedure Pas(Method: TPasMethod)` | `go obj.m()` | |
| `procedure PasYield` | `runtime.Gosched` | Global run queue |
| `procedure PasExit` | `runtime.Goexit` | Terminates the current pasrutina; `finally` blocks do not run |
| `procedure PasSleep(Ms: QWord)` | `time.Sleep` | Millisecond API; `0` yields |
| `procedure PasSleepNs(Ns: Int64)` | `time.Sleep` | Nanosecond API; the poller rounds to 1 ms |
| `function PasNow: Int64` | `nanotime` | `CLOCK_MONOTONIC` in ns |
| `function PasID: QWord` | goid | 1 is the main pasrutina, 0 outside pasrutinas |
| `function PasCurrent: TPasrutina` | `getg()` | Opaque handle for `PasReady` |
| `function NumPasrutinas: LongInt` | `runtime.NumGoroutine` | |
| `function PASMAXPROCS(N: LongInt): LongInt` | `runtime.GOMAXPROCS` | `N < 1` queries. Must be set before the first `Pas()`/`PasInit`; raises otherwise |
| `procedure PasSetStackSize(Bytes: PtrUInt)` | | Stack of pasrutinas created from now on. Default 16 KiB, minimum 4 KiB, rounded to pages |
| `function PasStackSize: PtrUInt` | | |
| `function PasStackAvail: PtrUInt` | | Bytes of stack left below the caller, 0 outside a pasrutina. For code about to recurse deeply or put a large buffer on the stack. Overflowing is survivable once (README, *Stacks*), but it costs that pasrutina |
| `procedure PasInit` | `schedinit` | Called implicitly by everything; explicit call optional |

### Parking

| Routine | Go | Notes |
|---|---|---|
| `procedure PasPark` | `gopark` | Raw park; racy unless the waker cannot run before the park, prefer `PasParkUnlock` |
| `procedure PasReady(G: TPasrutina)` | `goready` | Raises if `G` is not waiting |
| `function PasParkUnlock(var CS: TRTLCriticalSection): Boolean` | `goparkunlock` | Parks and releases `CS` once the pasrutina is off its OS thread |
| `procedure PasEnterSyscall` / `procedure PasExitSyscall` | `entersyscall` / `exitsyscall` | Wrap blocking system calls; `sysmon` hands the P to another OS thread after 10 ms |

### File descriptors

The poller is edge-triggered (`EPOLLET`) like Go's netpoll. The first
wait on an fd registers it and switches it to `O_NONBLOCK`. A readiness
notification that arrives while nobody waits is remembered, so the
correct pattern is: try the operation, wait on `EAGAIN`, retry.

| Routine | Go | Notes |
|---|---|---|
| `procedure PasWaitRead(Fd: LongInt)` | `pd.waitRead` | |
| `procedure PasWaitWrite(Fd: LongInt)` | `pd.waitWrite` | |
| `function PasWaitReadTimeout(Fd, Ms: LongInt): Boolean` | | `False` on timeout or after `PasUnregisterFd` |
| `function PasWaitWriteTimeout(Fd, Ms: LongInt): Boolean` | | |
| `procedure PasUnregisterFd(Fd: LongInt)` | `poll_runtime_pollClose` | `EPOLL_CTL_DEL`; wakes waiters with `False`. Call before closing an fd that was waited on |

### Output

| Routine | Notes |
|---|---|
| `procedure PasWriteLn(const S: AnsiString)` | One whole line per call, flushed, safe from any pasrutina or thread. The RTL's `WriteLn` keeps a buffer per OS thread and is not thread safe |
| `procedure PasWriteLn(const Fmt: AnsiString; const Args: array of const)` | `Format` then write |

### Synchronisation

All of these park the pasrutina, never the OS thread.

| Type | Go | Notes |
|---|---|---|
| `TPasWaitGroup`: `Add`, `Done`, `Wait` | `sync.WaitGroup` | |
| `TPasMutex`: `Lock`, `Unlock` | `sync.Mutex` | CAS fast path, spinning, normal and starvation modes |
| `TPasRWMutex`: `BeginRead`, `EndRead`, `Lock`, `Unlock` | `sync.RWMutex` | Writer preference |
| `TPasOnce`: `Do_(Proc)` | `sync.Once` | |
| `TPasCond`: `Wait(M)`, `Signal`, `Broadcast` | `sync.Cond` | |
| `TPasLock` with `PasLockAcquire`, `PasLockRelease` | `runtime.mutex` | Futex lock for short critical sections; blocks the OS thread, never hold it across a park |

### Exceptions

`raise`, `try/except` and `try/finally` work across parks: the RTL
exception chains (`ExceptAddrStack`, `ExceptObjectStack`) are saved and
restored per pasrutina on every switch. An uncaught exception is
reported on stderr as `pasrutina N: EClass: message` and ends that
pasrutina only. Runtime errors (`SIGSEGV`, `SIGBUS`, `SIGFPE`, `SIGILL`)
are delivered on a per-thread signal stack and arrive as the usual
`EAccessViolation`, `EDivByZero`, etc.

### Diagnostics

`PASRUTINAS_STATS=1` in the environment prints at exit: OS threads
created, M starts and stops, spinning episodes, steals, parks, futex
sleeps and poller wake-ups.

## paschan

```pascal
type
  TIntChan = specialize TPasChan<LongInt>;
var
  ch: TIntChan;
begin
  ch := TIntChan.Create(0);      { 0 = unbuffered, N = buffered }
  ch.Send(42);
  v := ch.Recv;
  if ch.RecvOk(v) then ...       { False once closed and drained }
  ch.TrySend(1); ch.TryRecv(v);  { never park }
  ch.Close;                      { receivers get zero + False, senders raise }
end;
```

`TPasRawChan` is the untyped implementation (`Create(ElemSize, Capacity)`,
`Send(Src)`, `Recv(Dst)`, ...); `TPasChan<T>.Raw` exposes it for
`PasSelect`.

### select

```pascal
var
  cases: array[0..1] of TPasSelectCase;
  n: LongInt;
begin
  cases[0].Kind := pasCaseRecv; cases[0].Chan := chA.Raw; cases[0].Elem := @n;
  cases[1].Kind := pasCaseSend; cases[1].Chan := chB.Raw; cases[1].Elem := @v;
  idx := PasSelect(cases);       { parks until one case is ready }
  if not cases[idx].Ok then ...  { receive on a closed channel }
end;
```

- Up to 16 cases. Add a case with `Kind = pasCaseDefault` for a
  non-blocking select: its index is returned when nothing is ready.
- `Ok` is an output: `True` when the send or receive completed, `False`
  when a receive case was chosen because its channel is closed.
- A send case on a closed channel raises, as Go panics.
- Channels are locked in address order and cases polled in random
  order; when parked, one sudog per case is queued and the first party
  to claim one (CAS on the select's done word) wins, like `selectgo`.
