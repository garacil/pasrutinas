# Architecture

pasrutinas is an M:N user-level scheduler for Free Pascal on Linux
x86_64. It copies the Go runtime model (G, M, P) from
`golang/src/runtime` without changing the Pascal language. Every
routine in `src/pasrutinas.pas` names the Go function it mirrors.

## Objects

```
          PASMAXPROCS
     ┌───────── P ─────────┐
     │  runq[256]  runnext │
     │  timers heap        │
     │  gFree cache        │
     └─────────┬───────────┘
               │ bound
     ┌─────────▼───────────┐
     │  M  (pthread)       │
     │  g0 scheduler stack │
     │  signal stack       │
     │  curg ──► G         │
     └─────────────────────┘
               │
     ┌─────────▼───────────┐
     │  G  (pasrutina)     │
     │  TPasBuf registers  │
     │  mmap stack + guard │
     │  exception chains   │
     └─────────────────────┘
```

- **G** — pasrutina. Status: runnable, running, syscall, waiting,
  dead (`Gwaiting -> Grunnable` and `Grunnable -> Grunning` are CAS
  transitions, so a pasrutina can never be readied or executed twice).
  Recycled on exit through per-P and global free lists (`gfput`/`gfget`).
- **M** — OS thread. Created with `BeginThread` when there is work and
  no idle M (`newm`), parked on an `RTLEvent` when idle (`stopm`), never
  destroyed. Each M has a `g0` used only by the scheduler and a
  `sigaltstack`.
- **P** — logical processor. Exactly `PASMAXPROCS` of them
  (`procresize`). An M must hold a P to run Pascal code. A P is either
  running, idle (on `sched.pidle`), or in a system call.

## Spawn

`Pas(@F)` (`newproc`):

1. Take a G from the P's free list, else a stack from the slab
   allocator: one `mmap` per 64 stacks, the first page of each stack
   guarded with `madvise(MADV_GUARD_INSTALL)` (no VMA split; `mprotect`
   on kernels before 6.13). Freed stacks go to the P's cache, then to a
   global warm list, then to a cold list whose pages are released with
   `MADV_DONTNEED`.
2. Point `TPasBuf.rip` at `PasTrampoline`, `rsp` at the top of the
   stack with a zero return address (`gostartcall`).
3. `runqput(next = true)`: the new G becomes `runnext`, the previous
   `runnext` moves to the ring; a full ring sends half of itself to the
   global queue (`runqputslow`).
4. `wakep`: if there is an idle P and no spinning M, start one spinning
   M (`startm`).

The trampoline runs the user procedure inside `try/except`, reports an
uncaught exception, then `PasExit` (`goexit0`).

## Park and ready

A running G that must wait calls `ParkWith` (`gopark` + `mcall(park_m)`):

1. `FPC_SETJMP` into `G.sched`, `FPC_LONGJMP` onto the M's `g0` stack.
2. `FinishPark` runs on g0, after the G is off its M: status becomes
   waiting, the locks handed over by the G are released
   (`unlockf`), a poll wait is committed with a CAS on the pollDesc
   word (`netpollblockcommit`), and a timer is armed only now
   (`resetForSleep`). A waker that already holds the lock therefore
   always sees a parked G.
3. `Ready` (`ready`): CAS waiting -> runnable, `runqput` on the
   current P (`runnext`), `wakep`.

The next `Schedule`/`FindRunnable` on some M executes it
(`execute`): CAS runnable -> running, restore the RTL exception chains
and stack bounds, `FPC_LONGJMP` back into `G.sched`.

## FindRunnable

Order (`findRunnable`):

1. Timers of this P (`checkTimers`).
2. Global queue once every 61 scheduler ticks (fairness).
3. Local `runnext`, then the ring.
4. Global queue, taking a batch (`globrunqget`).
5. Non-blocking `epoll_wait` if an fd waiter exists and no M is blocked
   in the poller.
6. Become spinning (at most half the busy Ps spin) and steal: four
   rounds over a random permutation of the Ps, half of a victim's ring
   per grab (`runqgrab` copies before the CAS), `runnext` and the
   victim's timers only on the last round.
7. Release the P (`releasep`, `pidleput`). If this was the last
   spinning M, recheck every queue and the timers.
8. Block in `epoll_wait` until the earliest timer of any P, but only
   one M at a time (`sched.lastpoll`); the others park (`stopm`) until
   `startm` hands them a P.

`handoffp` (a P released by a syscall or by `sysmon`) gives the P to an
M if it has work, starts a spinning M if none exists, keeps one M to
poll when it is the last P, otherwise parks the P.

## System calls and sysmon

`PasEnterSyscall` (`entersyscall`) marks the P as in-syscall and drops
it from the M; `PasExitSyscall` (`exitsyscall`) takes the same P back
with a CAS, else any idle P, else parks the G on the global queue and
stops the M. A `sysmon` thread without a P wakes every 20 µs to 10 ms
and (`retake`) hands off Ps that have been in a syscall for more than
10 ms or have work, flags a G that has run for more than 10 ms without
a scheduling point (honoured by `Pas()`), polls the network when nobody
did for 10 ms and fires overdue timers when no M is polling.

## Channels

`TPasRawChan` is `hchan`: a futex lock, an optional ring buffer, send
and receive wait queues of `sudog`. A sudog lives on the stack of the
waiting pasrutina (stacks are fixed, so no cache is needed). The other
side copies through `sudog.elem`, sets `success`, releases the lock
and readies the G. `Close` releases every waiter (receivers get zero
and `ok = False`, senders raise).

`PasSelect` (`selectgo`) locks the channels in address order, polls
the cases in a random order, and either completes at once or enqueues
one sudog per case and parks. Every dequeue, including `Close`, claims
the sudog with a CAS on the select's done word (`waitq.dequeue`), so
exactly one party readies the pasrutina; the losers are dequeued under
all locks afterwards. `Ok` reports a receive on a closed channel.

## Timers

Each P owns a binary heap (`timers`), protected by its own futex lock
and mirrored by an atomic earliest-when. `PasSleep` records the
deadline and parks; `FinishPark` inserts into the heap of the P it
runs on. Entries are identified by `(G, sequence)`: every park bumps
the sequence, so a timer left behind by an earlier wait is dropped when
it surfaces instead of waking the wrong wait. Poll timeouts are
arbitrated against I/O readiness with a CAS on the pollDesc word. The
poller sleeps until the earliest timer of any P; `AddTimer` interrupts
it (`wakeNetPoller`) when a new timer is earlier.

## I/O

Linux `epoll` in edge-triggered mode plus `eventfd` for scheduler
wake-ups (`netpollBreak`). A pollDesc per fd (indexed by fd, never
freed) holds one word per direction with the Go state machine
`pdNil / pdReady / pdWait / G`: readiness that arrives while nobody
waits is latched in `pdReady`, a waiter commits with `pdWait -> G`
after parking, `netpollunblock` swaps in `pdReady` and returns the G.
`PasUnregisterFd` removes the fd from epoll and fails its waiters.

## Exception state

Free Pascal keeps `ExceptAddrStack` (chain of `try` frames, records on
the stack of the procedure that entered the `try`) and
`ExceptObjectStack` (chain of raised objects) in threadvars
(`rtl/inc/except.inc`). `raise` longjmps to the head of the first
chain; popping an empty chain halts with code 255. Both chains must
follow the pasrutina, as `_defer`/`_panic` follow a goroutine.

At init the runtime locates the two threadvars inside the per-thread
block: it pushes a probe frame with `FPC_PUSHEXCEPTADDR`, raises and
catches a probe exception, and scans the block (addressed through
`FPC_THREADVAR_RELOCATE`) for those addresses. Every M caches the base
of its own block; `FinishPark` saves both heads into the G and clears
them, `Execute` restores them. If the scan fails (an RTL built with
section threadvars) the frame chain is still switched through
`FPC_PUSHEXCEPTADDR`/`FPC_POPADDRSTACK`; only the object chain is not,
so a pasrutina must then not park inside an `except` handler.

## Locks

`TPasLock` is Go's `lock_futex.go` mutex: `xchg` fast path, four rounds
of `PAUSE` spinning, one `sched_yield`, then a futex sleep with the
state set to "locked with sleepers" so the unlocker knows to wake.
`TPasMutex` is `internal/sync/mutex.go` on top of a `sema.go`
semaphore: CAS fast path, spinning when other Ps are busy, normal mode
(a woken waiter competes) and starvation mode (direct hand-off after
1 ms of waiting).

## Threading rules

- `cthreads` must be the first unit so FPC's heap and threadvars are
  multi-thread safe. The first `BeginThread` (the `sysmon` thread)
  switches the RTL to per-thread threadvar blocks; the runtime locates
  its exception state only after that.
- `currentM` is a threadvar: each OS thread has its own M pointer.
- Pascal `threadvar` is per M, not per G. Do not use threadvars as
  per-pasrutina storage. `Output`, `StdErr` etc. are threadvars too:
  use `PasWriteLn`.
- The FPC heap is shared; Gs migrate across Ms.
- Never hold a `TPasLock` or a critical section across a park: hand it
  to `PasParkUnlock`/`PasInternalParkUnlockLock` instead.
