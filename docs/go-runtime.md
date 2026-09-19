# Go runtime (reference)

The scheduler, channels, timers, poller and locks follow the Go
runtime. The files below are from the official tree at
https://github.com/golang/go (`src/runtime`, and `src/internal/sync`
from the installed toolchain). They are a design reference, not part
of this package's build; a copy lives in `golang/` (ignored by git).

| File | Role in Go | Role here |
|---|---|---|
| `HACKING.md` | G, M, P; `gopark` / `goready` | Same three objects |
| `runtime2.go` | `g`, `m`, `p`, `gobuf`, `sudog` | `TG`, `TM`, `TPasP`, `TPasBuf`, `TSudog` |
| `proc.go` | `newproc`, `schedule`, `findRunnable`, `runqput`, `runqgrab`, `wakep`, `startm`, `stopm`, `handoffp`, `injectglist`, `entersyscall`, `exitsyscall`, `sysmon`, `retake` | Same names in `pasrutinas.pas` |
| `asm_amd64.s` | `gogo`, `mcall`, `procyield` | `FPC_LONGJMP` / `FPC_SETJMP`, `ProcYield` |
| `sys_x86.go` | `gostartcall` | `SetupFreshStack` |
| `stack.go` | 2 KiB stacks, `morestack`, stack spans | Fixed stacks from `PROT_NONE` slabs, guard page, per-P cache |
| `chan.go` | `hchan`, `waitq.dequeue`, `closechan` | `TPasRawChan` |
| `select.go` | `selectgo` | `PasSelect` |
| `time.go` | per-P timer heaps, `resetForSleep`, `wakeNetPoller`, `timeSleepUntil` | Per-P heaps armed in `FinishPark` |
| `netpoll.go`, `netpoll_epoll.go` | `pollDesc` with `pdReady`/`pdWait`, `netpollblock`, `netpollunblock`, epoll + eventfd | `WaitPoll`, `Netpoll`, `NetpollUnblock` |
| `lock_futex.go`, `os_linux.go` | `lock2`/`unlock2`, `futexsleep`/`futexwakeup` | `TPasLock`, `FutexCall` |
| `sema.go` | `semacquire1`, `semrelease1`, `cansemacquire` | `TPasSema` |
| `internal/sync/mutex.go` | `Mutex.lockSlow`, `unlockSlow`, spinning, starvation | `TPasMutex` |
| `os_linux.go` | `gsignal`, `sigaltstack` | Per-M signal stack, `SA_ONSTACK` |

Go's copyright remains with The Go Authors (BSD-style license in that
tree).
