// Same four measurements as bench.pas, for a side by side comparison:
// make bench
package main

import (
	"fmt"
	"runtime"
	"sync"
	"time"
)

const (
	nSpawn      = 300000
	nRoundTrips = 200000
	nSleepers   = 20000
	nLockers    = 8
	nLocks      = 100000
)

func main() {
	var wg sync.WaitGroup

	t0 := time.Now()
	wg.Add(nSpawn)
	for i := 0; i < nSpawn; i++ {
		go func() { wg.Done() }()
	}
	wg.Wait()
	fmt.Printf("go: %d trivial goroutines: %d ms\n", nSpawn, time.Since(t0).Milliseconds())

	ch := make(chan int)
	t0 = time.Now()
	go func() {
		for i := 0; i < nRoundTrips; i++ {
			v := <-ch
			ch <- v + 1
		}
	}()
	last := 0
	for i := 0; i < nRoundTrips; i++ {
		ch <- i
		last = <-ch
	}
	fmt.Printf("go: %d unbuffered round trips: %d ms (last=%d)\n", nRoundTrips, time.Since(t0).Milliseconds(), last)

	t0 = time.Now()
	wg.Add(nSleepers)
	for i := 0; i < nSleepers; i++ {
		go func(i int) {
			time.Sleep(time.Duration(100+i%100) * time.Millisecond)
			wg.Done()
		}(i)
	}
	wg.Wait()
	fmt.Printf("go: %d sleepers of 100..199 ms: %d ms\n", nSleepers, time.Since(t0).Milliseconds())

	var mu sync.Mutex
	n := 0
	t0 = time.Now()
	wg.Add(nLockers)
	for i := 0; i < nLockers; i++ {
		go func() {
			for k := 0; k < nLocks; k++ {
				mu.Lock()
				n++
				mu.Unlock()
			}
			wg.Done()
		}()
	}
	wg.Wait()
	fmt.Printf("go: %dx%d mutex lock/unlock: %d ms (n=%d, GOMAXPROCS=%d)\n", nLockers, nLocks, time.Since(t0).Milliseconds(), n, runtime.GOMAXPROCS(0))
}
