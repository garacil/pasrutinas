# pasrutinas

An important addition to [Free Pascal](https://www.freepascal.org/):
**user-space lightweight threads**, modelled on Go goroutines.

FPC already ships OS threads (`TThread`, `BeginThread`) and callback
event loops (`fcl-async`). It has nothing like Go’s goroutines: tens of
thousands of tiny stacks multiplexed onto a few pthreads, parked on
channels, timers and I/O without blocking the OS thread. That is the
gap this package fills. It is offered to the FPC team for inclusion
under `packages/`.

A *pasrutina* is not an operating-system thread. It is a small control
block plus a few kilobytes of stack, multiplexed by a user-level
scheduler onto a handful of OS threads (`PASMAXPROCS`). Waiting on a
channel, a timer, a mutex or a file descriptor parks the pasrutina and
frees the OS thread to run another one.

**Author:** Germán Luis Aracil Boned  
**License:** LGPL 2.1 with the FPC linking exception (`COPYING.FPC`), same as the RTL and packages  
**Platform:** Linux x86_64, Free Pascal 3.2.2+  
**GitHub:** https://github.com/garacil/pasrutinas  
**GitLab:** https://gitlab.com/garacilb/pasrutinas  

Offered to the Free Pascal team (GitLab group `freepascal.org/fpc`, id 12463123):
https://gitlab.com/freepascal.org/fpc/source/-/work_items/41919

## Requirements

- Linux x86_64
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
make
make check
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
  WriteLn('pasrutina ', PasID);
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

## How it works

Go’s runtime uses three objects: **G** (goroutine), **M** (machine / OS
thread), **P** (logical processor). pasrutinas copies that design.

| Object | Name here | What it is |
|---|---|---|
| G | pasrutina | Work item: registers + `mmap` stack (16 KiB default) |
| M | OS thread | `BeginThread` → `pthread_create`. At most `PASMAXPROCS` of them |
| P | processor | Local run queue of 256, work stealing, right to execute Pascal code |

`Pas(@F)` does **not** create a pthread. It:

1. Takes a G from a free list, or `mmap`s a new stack with a guard page.
2. Builds a register context (`TPasBuf`, same layout as FPC `jmp_buf`).
3. Pushes the G onto the current P’s run queue.
4. Wakes an M if one is idle.

Context switch uses `FPC_SETJMP` / `FPC_LONGJMP`. No syscall. When a
pasrutina waits, it is marked waiting and the M runs the next runnable
G. The event that unblocks it (the other end of a channel, a timer,
epoll, `WaitGroup.Done`) calls `PasReady`.

That is why tens of thousands of pasrutinas are cheap: 50 000 of them
in `./bin/miles` finish in a few hundred milliseconds. The kernel still
sees about `PASMAXPROCS` threads (one per CPU by default).

Go can start at 2 KiB per goroutine because the compiler inserts stack
growth (`morestack`). Free Pascal cannot. Default stack is 16 KiB
(8 KiB is enough for tiny workers: `PasSetStackSize(8*1024)`). Stacks
are demand-paged; an idle G typically dirties one page of RSS.

Cooperative scheduling: a pasrutina that never parks, yields, or hits
the runtime will keep its M. Call `PasYield` in tight CPU loops, or
wait on a channel / timer.

## Units

| Unit | Role |
|---|---|
| `pasrutinas` | Scheduler, spawn, sleep, yield, WaitGroup, mutexes, Once, Cond, epoll wait |
| `paschan` | Channels and `PasSelect` |

## API

### Spawn and runtime

| Call | Go analogue |
|---|---|
| `Pas(@Proc)` | `go proc()` |
| `Pas(@Proc, Arg)` | `go proc(arg)` |
| `Pas(Method)` | `go obj.Method()` |
| `PASMAXPROCS(n)` | `GOMAXPROCS(n)` — call **before** the first `Pas` |
| `PasYield` | `runtime.Gosched` |
| `PasExit` | `runtime.Goexit` |
| `PasSleep(ms)` | `time.Sleep` (user-level timer; parks the G, not the M) |
| `PasID` | goroutine id |
| `NumPasrutinas` | `runtime.NumGoroutine` |
| `PasPark` / `PasReady(g)` | `gopark` / `goready` |
| `PasSetStackSize(bytes)` | stack size for new Gs |
| `PasWaitRead(fd)` | netpoll read |
| `PasWaitWrite(fd)` | netpoll write |
| `PasWaitReadTimeout(fd, ms)` | netpoll read with timeout |

File descriptors used with `PasWaitRead` / `PasWaitWrite` are put in
non-blocking mode and registered edge-triggered with `epoll`. Read or
write until `EAGAIN`, then wait again.

### Synchronization (`pasrutinas`)

- `TPasWaitGroup` — `Add`, `Done`, `Wait`
- `TPasMutex` — `Lock`, `Unlock` (parks the G)
- `TPasRWMutex` — `BeginRead`, `EndRead`, `Lock`, `Unlock`
- `TPasOnce` — `Do_(Proc)` (`Do` is a reserved word in Pascal)
- `TPasCond` — `Wait(mutex)`, `Signal`, `Broadcast`

### Channels (`paschan`)

```pascal
type TIntChan = specialize TPasChan<LongInt>;
var ch: TIntChan;
begin
  ch := TIntChan.Create(0);     { unbuffered }
  { ch := TIntChan.Create(16);     buffered }
  ch.Send(1);
  n := ch.Recv;
  if ch.RecvOk(n) then
    ...
  ch.Close;
end;
```

`TPasRawChan` is the untyped implementation (`Send(Src: Pointer)`).
`TPasChan<T>` is a thin generic wrapper.

`PasSelect` is Go `select` (up to 16 cases):

```pascal
cases[0].Kind := pasCaseRecv;
cases[0].Chan := chA.Raw;
cases[0].Elem := @n;
cases[1].Kind := pasCaseDefault;
idx := PasSelect(cases);
```

Kinds: `pasCaseSend`, `pasCaseRecv`, `pasCaseDefault`.

## Examples

| Program | What it shows |
|---|---|
| `examples/hola.pas` | Spawn and WaitGroup |
| `examples/pingpong.pas` | Unbuffered channel |
| `examples/miles.pas` | 50 000 pasrutinas |
| `examples/sleep.pas` | User-level timers |
| `examples/select.pas` | `PasSelect` |
| `examples/poll.pas` | `PasWaitRead` on a pipe |
| `examples/mutex.pas` | `TPasMutex` |
| `examples/once.pas` | `TPasOnce` |

`make check` builds and runs the programs under `tests/` (spawn, channels, buffered channel, select, sleep, mutex, once). They exit non-zero on failure.

## Limits

- Linux x86_64 only (context switch is `FPC_SETJMP` on amd64).
- Stacks do not grow. Overflow hits the guard page (`SIGSEGV`).
- No preemption of a G that never calls the runtime.
- Channel `select` is limited to 16 cases.
- Not a full Go standard library: no garbage-collected stack copy, no
  race detector, no network package.

## Design notes

See [docs/architecture.md](docs/architecture.md) for G/M/P, park/ready,
run queues, timers and epoll. See [docs/api.md](docs/api.md) for the
full public surface. Mapping to Go’s runtime sources:
[docs/go-runtime.md](docs/go-runtime.md).

The scheduler follows Dmitry Vyukov’s Go scheduler (local `runq[256]`,
global queue, work stealing, `handoff` of a P when an M parks).
Channels follow `hchan` / `sudog` in `runtime/chan.go`. I/O follows
`netpoll` on Linux `epoll` plus `eventfd` to wake a sleeping M.

## Copyright

Copyright (c) 2026 Germán Luis Aracil Boned.

Licensed under the same terms as the Free Pascal RTL and packages:
GNU LGPL 2.1 with the FPC linking exception. See `COPYING.FPC` and
`COPYING`. You may link this library into programs under any license.

The Go runtime, used as a design reference, is Copyright The Go Authors.
