# pasrutinas

An important addition to [Free Pascal](https://www.freepascal.org/):
**user-space lightweight threads**, modelled on Go goroutines.

FPC already ships OS threads (`TThread`, `BeginThread`) and callback
event loops (`fcl-async`). It has nothing like Go’s goroutines: hundreds
of thousands of tiny stacks multiplexed onto a few pthreads, parked on
channels, timers and I/O without blocking the OS thread. That is the
gap this package fills. It is offered to the FPC team for inclusion
under `packages/`.

A *pasrutina* is not an operating-system thread. It is a small control
block plus a few kilobytes of stack, multiplexed by an M:N scheduler
onto `PASMAXPROCS` OS threads. Waiting on a channel, a timer, a mutex or
a file descriptor parks the pasrutina and frees the OS thread to run
another one.

**Author:** Germán Luis Aracil Boned  
**License:** LGPL 2.1 with the FPC linking exception (`COPYING.FPC`), same as the RTL and packages  
**Platform:** Linux x86_64, Free Pascal 3.2.2+  
**GitHub:** https://github.com/garacil/pasrutinas  
**GitLab:** https://gitlab.com/garacilb/pasrutinas  

Offered to the Free Pascal team (GitLab group `freepascal.org/fpc`, id 12463123):
https://gitlab.com/freepascal.org/fpc/source/-/work_items/41919

## Requirements

- Linux x86_64 (epoll, eventfd, futex, sigaltstack)
- Free Pascal Compiler 3.2.2 or later
- `cthreads` as the **first** unit in every program

```pascal
program demo;
{$mode objfpc}{$H+}
uses
  cthreads, pasrutinas, paschan;
```

## Build

```
make            # examples and tests, warnings/notes/hints are errors
make check      # runs the 16 tests and the 8 examples
./bin/hola
./bin/pingpong
./bin/miles
./bin/sleep
./bin/select
./bin/poll
./bin/mutex
./bin/once
```

Add `src/` to the compiler unit path:

```
fpc -Fu/path/to/pasrutinas/src -Mobjfpc yourprog.pas
```

## Quick start

```pascal
uses cthreads, pasrutinas;

procedure Worker(Arg: Pointer);
begin
  PasWriteLn('pasrutina %d', [PasID]);
  TPasWaitGroup(Arg).Done;
end;

var
  wg: TPasWaitGroup;
begin
  wg := TPasWaitGroup.Create;
  try
    wg.Add(1);
    Pas(@Worker, wg);   { spawn: same role as  go worker() }
    wg.Wait;
  finally
    wg.Free;
  end;
end.
```

## Performance

Same machine (32 CPUs, Linux 7.2), Go 1.27.1 with `GOMAXPROCS=32`
against pasrutinas with `PASMAXPROCS=32`, best of three runs:

| Benchmark | Go | pasrutinas |
|---|---|---|
| Spawn 300 000 trivial goroutines / pasrutinas | 44 ms | 45 ms |
| 200 000 round trips on an unbuffered channel | 43 ms | 42 ms |
| 8 × 100 000 `Lock`/`Unlock` on one mutex | 31 ms | 22 ms |
| 20 000 sleepers of 100..199 ms | 209 ms | 300 ms |

Per operation: a park plus reschedule costs about 57 ns, a buffered
send plus receive 30 ns, a full unbuffered round trip 194 ns on one P.
The remaining gap on sleepers is thread wake-ups while 20 000 timers are
armed within a few milliseconds.

## How it works

Go’s runtime uses three objects: **G** (goroutine), **M** (machine / OS
thread), **P** (logical processor). pasrutinas copies that design from
`golang/src/runtime`; every routine names the Go function it mirrors.

| Object | Name here | What it is |
|---|---|---|
| G | pasrutina | Work item: registers + `mmap` stack (16 KiB default) |
| M | OS thread | `BeginThread` → `pthread_create`. Started on demand, parked in a futex when idle |
| P | processor | Local run queue of 256, work stealing, per-P timer heap, the right to execute Pascal code |

`Pas(@F)` does **not** create a pthread. It:

1. Takes a G from the per-P free list, or `mmap`s a new stack with a guard page.
2. Builds a register context (`TPasBuf`, same layout as FPC `jmp_buf`).
3. Pushes the G onto the current P’s run queue (`runnext`).
4. `wakep`: starts one spinning M if there is an idle P and none is spinning.

Context switch uses `FPC_SETJMP` / `FPC_LONGJMP`. No syscall. When a
pasrutina waits, the switch to the scheduler stack commits the park
(status, lock release, timer arming) *after* the pasrutina is off its
OS thread, so a waker can never see a running pasrutina. The event that
unblocks it (the other end of a channel, a timer, epoll,
`WaitGroup.Done`) calls `ready`.

Scheduler mechanisms copied from Go: `findRunnable` (local queue, global
queue every 61 ticks, non-blocking netpoll, spinning work stealing over
4 rounds, then release the P and either block in `epoll_wait` as the
single poller or park the M), `handoffp`, `runqgrab`, `injectglist`,
`entersyscall`/`exitsyscall` with a `sysmon` thread that retakes Ps
blocked in system calls, `sync.Mutex` with spinning and starvation
mode on a semaphore, futex-based runtime locks, per-P timer heaps,
edge-triggered `netpoll` with the `pdReady` latch.

**Exceptions.** Free Pascal keeps the chain of `try` frames and the
chain of raised objects in threadvars, i.e. per OS thread
(`rtl/inc/except.inc`). Go keeps `_defer`/`_panic` in the goroutine.
pasrutinas saves and restores both chains per pasrutina on every
switch, so `raise`, `try/except` and `try/finally` work across parks,
including parking inside an `except` handler. An uncaught exception in
a pasrutina is reported on stderr and terminates that pasrutina only.
Runtime errors (`SIGSEGV`, `SIGFPE`) are delivered on a per-thread
signal stack, so they can be caught even inside an 8 KiB stack.

**Stacks.** Go can start at 2 KiB per goroutine because the compiler
inserts stack growth (`morestack`). Free Pascal cannot. Default stack is
16 KiB (`PasSetStackSize`); 8 KiB is enough for tiny workers, anything
that formats strings or raises needs the default. Stacks are
demand-paged: an idle pasrutina dirties about one page. Each stack is
one `mmap` plus one guard page, i.e. two kernel VMAs; with the default
`vm.max_map_count` of 65530 that allows about 32 000 pasrutinas alive at
once (raise the sysctl for more). Stacks are cached per P and globally,
and unmapped above 1024 cached.

**Output.** The RTL’s `WriteLn` keeps a buffer per OS thread and is not
thread safe. Use `PasWriteLn` from pasrutinas: one whole line per call,
flushed, from any thread. Buffers left in other threads’ `Output` by a
plain `WriteLn` are flushed at exit.

**Blocking calls.** A pasrutina that never parks, yields, or hits the
runtime keeps its P. Call `PasYield` in long CPU loops. Wrap blocking
system calls in `PasEnterSyscall`/`PasExitSyscall`: `sysmon` hands the P
to another OS thread after 10 ms in the kernel. For file descriptors use
`PasWaitRead`/`PasWaitWrite`: try the non-blocking operation first and
wait only after `EAGAIN` (the poller is edge-triggered and remembers a
readiness edge that arrives while nobody waits). Call `PasUnregisterFd`
before closing an fd that was waited on.

**Program end.** When the main program reaches `end.` the runtime stops
its OS threads before the RTL finalises units, as `main` returning ends
a Go program. Pasrutinas still running are abandoned.

Set `PASRUTINAS_STATS=1` to print scheduler counters at exit.

## API

See `docs/api.md`. Summary:

- Spawn and scheduling: `Pas`, `PasYield`, `PasExit`, `PasSleep`,
  `PasSleepNs`, `PasNow`, `PasID`, `PasCurrent`, `NumPasrutinas`,
  `PASMAXPROCS`, `PasSetStackSize`, `PasStackSize`, `PasInit`.
- Waiting: `PasPark`/`PasReady` (raw), `PasParkUnlock`,
  `PasEnterSyscall`/`PasExitSyscall`.
- I/O: `PasWaitRead`, `PasWaitWrite`, `PasWaitReadTimeout`,
  `PasWaitWriteTimeout`, `PasUnregisterFd`.
- Sync: `TPasWaitGroup`, `TPasMutex`, `TPasRWMutex`, `TPasOnce`,
  `TPasCond`, `TPasLock` (`PasLockAcquire`/`PasLockRelease`).
- Output: `PasWriteLn`.
- Channels (`paschan`): `TPasChan<T>` with `Send`, `Recv`, `RecvOk`,
  `TrySend`, `TryRecv`, `Close`; `PasSelect` over `TPasSelectCase`
  (`Kind`, `Chan`, `Elem`, output `Ok`).

## Tests

`make check` builds and runs everything with `-Sewnh` (warnings, notes
and hints are errors):

| Test | What it proves |
|---|---|
| test_spawn, test_chan, test_bufchan, test_select, test_sleep, test_mutex, test_once | basic API |
| test_mn | 8 CPU-bound pasrutinas run in parallel on several OS threads |
| test_exceptions | raise/catch after parking, parking inside `except` and `finally`, uncaught reports |
| test_sigstack | access violations caught inside 8 KiB stacks |
| test_timers | no stale timer firing, accurate sleeps, 20 000 sleepers |
| test_netpoll | edge latch, timeout path, `PasUnregisterFd` |
| test_selclose | select on a closed channel, send to closed raises |
| test_writeln | 16 000 lines from 32 pasrutinas through a pipe, none corrupted |
| test_stress | 300 000 spawns, 1 000 000 yields, 20 000 parked at once |
| test_syscall | blocking syscalls hand their P to another OS thread |

## Layout

```
src/pasrutinas.pas   scheduler, timers, poller, sync, exceptions
src/paschan.pas      channels and select
examples/            hola pingpong miles sleep select poll mutex once
tests/               see above
docs/                api.md architecture.md go-runtime.md
golang/              Go runtime sources used as the design reference (not built)
```
