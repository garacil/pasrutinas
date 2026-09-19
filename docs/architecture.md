# Architecture

pasrutinas is an M:N user-level scheduler for Free Pascal on Linux
x86_64. It copies the Go runtime model (G, M, P) without changing the
Pascal language.

## Objects

```
          PASMAXPROCS
     ┌───────── P ─────────┐
     │  runq[256]  runnext │
     └─────────┬───────────┘
               │ bound
     ┌─────────▼───────────┐
     │  M  (pthread)       │
     │  g0 scheduler stack │
     │  curg ──► G         │
     └─────────────────────┘
               │
     ┌─────────▼───────────┐
     │  G  (pasrutina)     │
     │  TPasBuf registers  │
     │  mmap stack + guard │
     └─────────────────────┘
```

- **G** — pasrutina. Status: idle, runnable, running, waiting, dead.
  Recycled on exit (`gfget` / recycle).
- **M** — OS thread. Created with `BeginThread` (pthreads). Each M has
  a `g0` used only by the scheduler (`G0Loop` / `Schedule`).
- **P** — logical processor. Exactly `PASMAXPROCS` of them. An M must
  hold a P to run Pascal code.

## Spawn

`Pas(@F)` (`NewPas`):

1. Allocate or reuse a G and a stack (`mmap`, `PROT_NONE` guard page).
2. Point `TPasBuf.rip` at `PasTrampoline`, `rsp` at the top of the stack.
3. `RunqPut` on the current P (`runnext` first, then the ring, then the
   global queue).
4. `Wakep`: if there is an idle P and no spinning M, start or unpark an M.

The trampoline runs the user procedure, catches exceptions, then
`PasExit`.

## Park and ready

A running G that must wait calls `ParkWith`:

1. `FPC_SETJMP` into `G.sched`.
2. `FPC_LONGJMP` onto the M’s `g0` stack.
3. `FinishPark` sets status to waiting and drops the G from the M.
   Channel / mutex locks held across the park are released here, so the
   counterpart cannot `PasReady` a G that is still running.

`PasReady` sets runnable and `RunqPut`. The next `Schedule` /
`FindRunnable` on some M executes it with `FPC_LONGJMP` back into
`G.sched`.

This is the same split as Go’s `mcall` + `park_m` / `gogo`.

## FindRunnable

Order, after firing expired timers and a non-blocking `epoll_wait`:

1. Local `runnext` and `runq`.
2. Global run queue (under `sched.lock`).
3. Steal half of another P’s queue.

If nothing is runnable, `ParkM` unbinds the P. If that P still has
work, it is handed to another M (`StartM`). Otherwise the M waits in
`epoll_wait` (or `RTLEvent` if epoll failed). `eventfd` plus the M’s
park event wake it.

## Channels

`TPasRawChan` is `hchan`: mutex, optional ring buffer, send and recv
wait queues of `sudog`. Send/recv park the G; the other side copies
through `sudog.elem` (which may point into the parked G’s stack) and
readies it.

`PasSelect` locks involved channels in address order, polls in a
shuffled order, and either completes immediately or enqueues a sudog
on every case and parks. A CAS on `selDone` elects a single winner
when two cases fire at once.

## Timers

`PasSleep` inserts the G into a sorted list and parks. `FireTimers`
runs from `FindRunnable` / `ParkM` and readies expired Gs. The M’s
wait timeout is the next deadline.

## I/O

Linux `epoll` (edge-triggered) plus `eventfd` for scheduler wakeups.
`PasWaitRead` / `PasWaitWrite` register the fd, enqueue the G on the
poll descriptor, and park. Ready events walk the reader/writer lists
and `PasReady` those Gs.

## Threading rules

- `cthreads` must be the first unit so FPC’s heap and threadvars are
  multi-thread safe.
- `currentM` is a threadvar: each OS thread has its own M pointer.
- Pascal `threadvar` is per M, not per G. Do not use threadvars as
  per-pasrutina storage.
- The FPC heap is shared; Gs may migrate across Ms.
