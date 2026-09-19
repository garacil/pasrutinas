# Go runtime (reference)

The scheduler, channels and poller follow the Go runtime. The files
below are from the official tree at
https://github.com/golang/go
(`src/runtime`). They are a design reference, not part of this
package’s build.

| File | Role in Go | Role here |
|---|---|---|
| `HACKING.md` | G, M, P; `gopark` / `goready` | Same three objects |
| `runtime2.go` | `g`, `m`, `p`, `gobuf`, `sudog` | `TG`, `TM`, `TPasP`, `TPasBuf` |
| `proc.go` | `newproc`, `schedule`, `findRunnable`, `runqput` | `NewPas`, `Schedule`, `FindRunnable`, `RunqPut` |
| `asm_amd64.s` | `gogo`, `mcall` | `FPC_LONGJMP` / `FPC_SETJMP` |
| `sys_x86.go` | `gostartcall` | `SetupFreshStack` |
| `stack.go` | 2 KiB stacks, `morestack` | Fixed `mmap` stacks (no growth) |
| `chan.go` | `hchan`, send/recv queues | `TPasRawChan` |
| `select.go` | `selectgo` | `PasSelect` |
| `netpoll.go`, `netpoll_epoll.go` | epoll + eventfd | `PasWaitRead` / `ParkM` |
| `sema.go` | user-level semaphores | `TPasMutex`, `TPasWaitGroup` |

Go’s copyright remains with The Go Authors (BSD-style license in that
tree).
