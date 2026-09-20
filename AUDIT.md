# Technical audit of pasrutinas

Author: Germán Luis Aracil Boned  
Dates: audit 2026-09-19, fixes 2026-09-20  
Scope: `src/pasrutinas.pas`, `src/paschan.pas`, `examples/`, `tests/`, `Makefile`, `fpmake.pp`.  
References checked against source:

- Free Pascal 3.2.2 RTL in `/usr/lib/fpc/src/rtl` (`inc/except.inc`,
  `inc/excepth.inc`, `inc/objpash.inc`, `inc/systemh.inc`, `inc/system.inc`,
  `inc/thread.inc`, `inc/threadvr.inc`, `inc/text.inc`, `x86_64/setjump.inc`,
  `unix/cthreads.pp`, `unix/sysutils.pp`, `linux/system.pp`, `linux/ossysc.inc`).
- Go runtime in `golang/src/runtime` (commit `a448594`, Go 1.28 development
  tree) and `internal/sync/mutex.go` from the installed Go 1.27.1.
- Test machine: Linux 7.2.6, 32 CPUs, FPC 3.2.2, `Makefile` flags
  (`-O2 -Sewnh -vwnh -gl`).

The document has two parts: the audit of the original code (sections 1
to 4) and the state after the fixes (sections 5 and 6).

---

## 1. Executive summary of the audit

1. **The 8 examples compiled cleanly and passed**, but the original runtime
   **was not M:N, it was 1:N**: `StartM` tested `IsMultiThread` before
   `BeginThread`, and `cthreads` only sets that variable to `True` inside
   the first `BeginThread` (`unix/cthreads.pp:414-419`). No OS thread was
   ever created. 8 CPU-bound pasrutinas of 300 ms took 2400 ms with
   `Threads: 1`.
2. **With threads enabled** (removing that check) the examples failed almost
   every time: `mutex` 30/30, `pingpong` 29/30, `select` 29/30.
3. **Exceptions were broken even in 1:N**: the RTL keeps the chain of `try`
   frames in a `threadvar` and `raise` longjmps over it
   (`inc/except.inc:21-27,184`); `fpc_PopAddrStack` halts with 255 on an
   empty chain (`:196-207`). Interleaving pasrutinas mixes the chain: 64
   pasrutinas doing `PasSleep` + `raise`/`except` produced a cascade of
   `EAccessViolation` and a hang.
4. Other verified failures: `PasSleep(2000)` slept 290 ms because of a
   stale timer; `PasWaitRead` hung when the data arrived before the wait
   (edge-triggered epoll without a latch); `PasSelect` returned `-1` when
   a channel was closed; 2 000 000 spawns ended in `EOutOfMemory`;
   300 000 spawns left 1.3 GB of RSS.

## 2. Was it the best way to implement goroutines?

The architecture (G/M/P, local run queues with stealing, park/ready,
sudog, select with ordered locks, epoll) was the right one and is Go's.
What failed was that the pieces that make the design correct under
concurrency had been copied halfway, and that an FPC-specific problem
(per-thread exception state) was not solved.

| Go mechanism | Original state | Current state |
|---|---|---|
| `handoffp` / `pidleput`: a released P is handed over or parked, never both | `UnbindP` put it on `idleP` and then `StartM(pp)` handed it over | `HandoffP` copied from `proc.go:3147` |
| `runqgrab`: copy the batch before the CAS | `RunqSteal` read after the CAS | `RunqGrab` copied from `proc.go:7720` |
| Spinning Ms (`proc.go:37-67`) | `nSpinning` was never incremented | `BecomeSpinning`, `ResetSpinning`, `needSpinning` |
| `resetForSleep` (`time.go:372`): arm the timer after parking | Armed before; `FireTimers` dropped a G still `Grunning` | Armed in `FinishPark` |
| `deltimer`/`modtimer`, heap per P | Global O(n) list; never deleted | Heap per P, entries keyed by `(G, seq)` |
| `pdReady` (`netpoll.go:51-68`) | No latch: lost edge | State machine `pdNil/pdReady/pdWait/G` |
| One M in `netpoll` (`sched.lastpoll`) | Every idle M in the same `epoll_wait` | One poller, the rest in `stopm` |
| `closechan` claims sudogs (`chan.go:864`) | `Close` without `ClaimSudog` | `Dequeue` always claims |
| `_defer`/`_panic` in the `g` | RTL chains per thread | Saved and restored per pasrutina |
| `gsignal` + `sigaltstack` | RTL handlers without `SA_ONSTACK` | Signal stack per M |
| `exit(0)` when `main` returns | RTL finalisation with live Ms | `ExitProc` that parks the Ms and flushes their buffers |
| `sysmon`/`retake`, `entersyscall` | Nothing | `PasEnterSyscall`/`PasExitSyscall`, `sysmon` thread |
| `sync.Mutex` with spinning and starvation mode | Direct hand-off: one context switch per `Unlock` | Ported from `internal/sync/mutex.go` on top of `sema.go` |
| `runtime.mutex` on futex | pthread critical sections | `TPasLock` (`lock_futex.go`) |

## 3. Audit findings (original code)

- **C1** `StartM` never created threads (1:N). Evidence: `Threads: 1`,
  2400 ms for 8 × 300 ms of CPU.
- **C2** Exception state per thread, not per pasrutina. Evidence: cascade
  of `EAccessViolation` and a hang; exit code 255 in every multi-threaded
  run (`halt(255)` from `fpc_PopAddrStack`).
- **C3** A P could be bound to two Ms (`UnbindP` + `StartM`).
- **C4** `RunqSteal` read the queue after the CAS.
- **C5** Timers: lost wake-up, stale firing (290 ms instead of 2000), O(n)
  list (20 000 sleepers: 866 ms).
- **C6** Poller: no latch (hang), no `EPOLL_CTL_DEL`, undocumented
  `O_NONBLOCK`, thundering herd of Ms, `Netpoll(0)` on every `Schedule`.
- **C7** `Wakep` without spinning state: one thread wake-up per spawn or
  ready.
- **C8** Program exit with live Ms: `SIGSEGV` in `FindRunnable` after
  `end.`.
- **C9** `Close` versus `select`: double `Ready` and use after free;
  `PasSelect` returned `-1`.
- **M1** Stacks: 2 VMAs per pasrutina, never released, 4.4 KiB of RSS
  each, 1.3 GB after 300 000 spawns.
- **M2** Every `GetM` was a call to `FPC_THREADVAR_RELOCATE` (the binary
  has no `%fs:` access: this FPC does not use section threadvars).
- **M3** Sudogs on the heap, queues without a tail pointer, `GetPollDesc`
  O(n).
- **M4** No preemption and no P hand-off in system calls.
- **M5** Signal handlers on 8–16 KiB stacks without `sigaltstack`.
- **M6** Unsynchronised `WriteLn` in the examples: 17 % of the lines
  corrupted with real threads.
- **B1** `PASMAXPROCS` after `PasInit` had no effect; `GetTickCount64`
  with 1 ms resolution; README with false statements about threads.

## 4. Verification method

Every finding was reproduced with a program; those programs, turned into
tests with exit codes, are now in `tests/` and run under `make check`.
The multi-threaded runs used a copy of the runtime without the
`IsMultiThread` guard, `gdb` for the thread stacks, and
`objdump`/`readelf` for the threadvar model and the RTL symbols.

---

## 5. State after the fixes

### 5.1 What changed

`src/pasrutinas.pas` was rewritten following `proc.go`, `time.go`,
`netpoll.go`, `lock_futex.go`, `sema.go` and `internal/sync/mutex.go`;
`src/paschan.pas` following `chan.go` and `select.go`. Every routine
names the Go function it mirrors. User-visible changes:

- New API: `PasSleepNs`, `PasNow`, `PasEnterSyscall`/`PasExitSyscall`,
  `PasWaitWriteTimeout`, `PasUnregisterFd`, `PasWriteLn`, `TPasLock`
  (`PasLockAcquire`/`PasLockRelease`), `Ok` field in `TPasSelectCase`.
- `PASMAXPROCS(N)` after initialisation raises instead of being ignored.
- A `select` sending on a closed channel raises, as Go panics.
- `PASRUTINAS_STATS=1` prints scheduler counters at exit.
- The examples use `PasWriteLn`; `select.pas` uses the blocking select
  and `Ok`; `poll.pas` follows the "try, wait on EAGAIN" pattern.

### 5.2 How each finding was resolved

| Finding | Fix | Test |
|---|---|---|
| C1 | Guard removed; `NewM` creates threads on demand | `test_mn` |
| C2 | The offsets of `ExceptAddrStack`/`ExceptObjectStack` inside the threadvar block are discovered at init (probe frame with `FPC_PUSHEXCEPTADDR`, probe exception, scan through `FPC_THREADVAR_RELOCATE`); saved in `FinishPark`, restored in `Execute`; fallback through `FPC_PUSHEXCEPTADDR`/`FPC_POPADDRSTACK` | `test_exceptions` |
| C3 | `HandoffP`, `StopM`/`StartM` with `nextp` written only by `StartM` | examples ×30 |
| C4 | `RunqGrab` with a local batch before the CAS; `runqtail` published with `xchg` | `test_stress` |
| C5 | Heaps per P, armed in `FinishPark`, `(G, seq)` per park, CAS arbitration with the pollDesc | `test_timers` |
| C6 | `pdReady` latch, single poller, `PasUnregisterFd`, `Netpoll(0)` only with waiters | `test_netpoll` |
| C7 | `spinning` per M, `nSpinning`, `needSpinning` | `PASRUTINAS_STATS` |
| C8 | `ExitProc`: parks the Ms and flushes `Output`/`StdErr` of every thread | all (exit code 0) |
| C9 | `Dequeue` claims with a CAS, `Close` included; `Ok` on the chosen case | `test_selclose` |
| M1 | Stacks from slabs of 64 with an `madvise(MADV_GUARD_INSTALL)` guard (no VMA split; `mprotect` on kernels < 6.13), per-P cache, global warm list and cold list with `MADV_DONTNEED` | `test_stress` |
| M2 | `StackBottom`/`StackLength` addresses cached per M; `mp` passed as a parameter; `NowNs` only when timers exist | micro-benchmark |
| M3 | Sudog on the pasrutina's stack; queues with `first/last`; pollDesc indexed by fd | `test_chan`, `test_select` |
| M4 | `sysmon` with `retake`; `PasEnterSyscall`/`PasExitSyscall`; `preempt` flag honoured by `Pas()` | `test_syscall` |
| M5 | 64 KiB `sigaltstack` per M; handlers reinstalled with `SA_ONSTACK` | `test_sigstack` |
| M6 | `PasWriteLn` with a lock and `Flush`; examples updated | `test_writeln` |
| B1 | `PASMAXPROCS` raises; `clock_gettime` in ns; README rewritten | — |

### 5.3 Results

`make check`: 16 tests and 8 examples, `ALL_TESTS_OK`. The 8 examples pass
30 of 30 runs with real threads.

| Test | Original (1:N) | Original with threads | Current |
|---|---|---|---|
| 8 CPU-bound pasrutinas × 200–300 ms | 2400 ms, 1 thread | 300 ms, crashes at exit | 200 ms, 10 threads |
| 64 × 50 `raise`/`except` after `PasSleep` | `EAccessViolation` cascade, hang | 255 | 3200/3200 |
| Parking inside `except` and `finally` | — | — | 2560/2560 |
| `PasSleep(400)` after a satisfied poll timeout | 290 ms (2000 requested) | — | 400 ms |
| Edge arriving while nobody waits | hang | — | received |
| `select` on a closed channel | `-1` | — | case 0, `Ok=False` |
| 300 000 trivial spawns | 1751 ms, 1.3 GB RSS | 235 ms, 129 MB | 37–65 ms, 12 MB |
| 20 000 sleepers of 100–199 ms | 866 ms | 255 | 239 ms |
| 2 000 000 spawns with yield | `EOutOfMemory` | — | 1.7 s |
| 32 pasrutinas × 500 lines through a pipe | 0 corrupted (1 thread) | 2767 corrupted | 0 corrupted |

### 5.4 Comparison with Go 1.27.1

Same machine, 32 CPUs, `GOMAXPROCS=32` against `PASMAXPROCS=32`, best of
three runs (`bench/bench.go` and `bench/bench.pas`, `make bench`):

| Benchmark | Go | pasrutinas |
|---|---|---|
| 300 000 trivial goroutines / pasrutinas | 48 ms | 37 ms |
| 200 000 round trips on an unbuffered channel | 43 ms | 41 ms |
| 8 × 100 000 `Lock`/`Unlock` | 26 ms | 24 ms |
| 20 000 sleepers of 100–199 ms | 211 ms | 239 ms |

Per operation on one P: park plus reschedule 57 ns; buffered send plus
receive 30 ns; unbuffered round trip 194 ns. The remaining gap on the
sleepers is the first page fault of each fresh stack (1.3 µs on this
kernel, plus 0.4 µs for the `madvise` guard): 20 000 pasrutinas alive at
once need 20 000 fresh stacks, and Go amortises that same fault over two
goroutines because its stacks are 2 KiB. Measured: `mprotect` per stack
cost 1.9 µs and made the first fault twice as expensive;
`MADV_POPULATE_WRITE` does not help (the cost is populating the page,
not the trap).

## 6. Known limits

- A stack overflow is **survivable once, then fatal**. The guard is two
  pages: the upper one is opened on the first overflow, which buys a page of
  headroom and turns the fault into a catchable `EStackOverflow`, so the
  pasrutina's own `try/except` runs and its cleanup happens. An overflow that
  continues past that rescue writes a diagnostic naming the pasrutina and its
  stack size, and calls `_exit(2)`. The page is armed again when the stack is
  recycled. See §7.
- No asynchronous preemption: a loop without scheduling points keeps its P
  until it calls `Pas()`, parks or yields (`sysmon` flags the pasrutina;
  `Pas()` yields when it sees the flag).
- On a kernel before 6.13 (no `MADV_GUARD_INSTALL`) each stack takes 2
  VMAs; with `vm.max_map_count = 65530` (the Debian/Ubuntu default) about
  32 000 pasrutinas can be alive at once. With 6.13+ there is no VMA
  limit.
- With `{$S+}` (`-Ct`) the RTL uses `StackMargin = 32768` on x86_64
  (`inc/system.inc:54`), larger than the 16 KiB stack: any procedure
  compiled with stack checking inside a pasrutina raises error 202.
- The poller uses `epoll_wait` with milliseconds: `PasSleepNs` rounds up
  to the millisecond, as Go's `netpoll` does.
- Pasrutinas still running when the main program ends are abandoned, as
  goroutines are.

## 7. Stack overflow: what it did, and what it does now

Added 2026-09-20. Worth its own section because the old behaviour was not
what it looked like, and because the fix is not obvious from the code.

### What it did

A pasrutina that overflowed its stack appeared to die in silence: no
exception, nothing on stderr, and anything waiting on it hung for ever. It
was worse than that. Measured with a chained observer that only logged:

```
#1 control, null deref:  cr2=0x0                 -> EAccessViolation, caught
#2 the overflow:         cr2=rsp=0x7f47eb2c0fd0  -> rsp walks into the guard
#3 the RTL retries:      cr2=0x7f47eb2c0fc8      -> EIGHT BYTES LOWER,
                                                    rip=SignalToHandleErrorAddrFrame
```

`rtl/linux/x86_64/sighnd.inc` does not raise from the handler. It rewrites
the signal context to resume the RTL's error trampoline **on the stack that
just ran out**; the trampoline's own push faults a few bytes lower; repeat.
The process state while "hung": `STAT=R`, **100% of one core, indefinitely**,
with the other Ms idle. So a single bad pasrutina pinned a core for ever,
took its M out of the scheduler permanently, hung every waiter, and printed
nothing.

### What it does now

The guard is two pages instead of one:

```
  [ red page | yellow page ][ stackLo .............. stackHi ]
```

`PasSigSegv` looks at `cr2`. Outside `[stackMap, stackLo)` it chains to the
RTL, so a null dereference still raises a catchable `EAccessViolation`
exactly as before. Inside the band:

- **yellow, first hit** — open the page (one `mprotect`, or
  `MADV_GUARD_REMOVE` on 6.13+), then do what the RTL would have done but
  with error **202** instead of 216: `rdi/rsi/rdx` = (202, rip, rbp) and
  `rip` = `HandleErrorAddrFrame`. The pasrutina resumes with a page of room
  and raises `EStackOverflow`, which its `try/except` can catch.
- **red, or yellow already open** — the rescue itself overflowed. Write the
  diagnostic with `write(2)` and `_exit(2)`. No heap, no `Format`, no
  `PasWriteLn`: async-signal-safe.

`RecycleG` re-arms the page, so a recycled stack is never handed on without
its net.

### Two things worth knowing before touching this

**The handler must preserve `sa_restorer`.** On Linux x86_64 `rt_sigaction`
requires it, and building the struct from `Default(SigActionRec)` zeroes it:
the process then dies with a core on **return** from the handler, even for a
plain null dereference. Read the current action, copy it, replace only the
handler and OR the flags — which is what `InstallOnStackHandlers` already did
for `SA_ONSTACK`, for the same reason.

**Recovering is a deliberate choice, not obviously the right one.** Go treats
stack exhaustion as fatal, and continuing does leave the pasrutina's own
state questionable. The choice here is for the server case — one pasrutina
per connection, where losing a connection is acceptable and losing the
process is not. The red page keeps the fatal path for when recovery has
already failed once.

### Verified

Tested on Fedora 38, FPC 3.2.2, kernel 6.8.9:

- overflow caught, cleanup runs, `wg.Wait()` returns, exit 0
- 200 pasrutinas recycle the stack, a later one overflows and is caught too
- second overflow with the page open: diagnostic on stderr, exit 2
- no regression: `raise`, division by zero and null dereference all still
  caught inside a pasrutina
- `make check` green, 16 tests and 8 examples
- no measurable cost: over 6 runs each, spawns and mutex land inside the
  spread of the unmodified code

**Not** verified: the `MADV_GUARD_REMOVE` path. This kernel is 6.8.9, so it
falls back to `mprotect` and only that branch was exercised. The 6.13+ branch
is symmetric by inspection and untested by measurement.
