# Auditoría técnica de pasrutinas

Autor: Germán Luis Aracil Boned  
Fechas: auditoría 2026-09-19, corrección 2026-09-20  
Alcance: `src/pasrutinas.pas`, `src/paschan.pas`, `examples/`, `tests/`, `Makefile`, `fpmake.pp`.  
Referencias contrastadas:

- RTL de Free Pascal 3.2.2 en `/usr/lib/fpc/src/rtl` (`inc/except.inc`,
  `inc/excepth.inc`, `inc/objpash.inc`, `inc/systemh.inc`, `inc/system.inc`,
  `inc/thread.inc`, `inc/threadvr.inc`, `inc/text.inc`, `x86_64/setjump.inc`,
  `unix/cthreads.pp`, `unix/sysutils.pp`, `linux/system.pp`, `linux/ossysc.inc`).
- Runtime de Go incluido en `golang/src/runtime` (commit `a448594`, árbol de
  desarrollo de Go 1.28) y `internal/sync/mutex.go` del Go 1.27.1 instalado.
- Máquina de pruebas: Linux 7.2.6, 32 CPU, FPC 3.2.2, flags del `Makefile`
  (`-O2 -Sewnh -vwnh -gl`).

El documento tiene dos partes: la auditoría del código original (secciones
1 a 4) y el estado tras la corrección (secciones 5 y 6).

---

## 1. Resumen ejecutivo de la auditoría

1. **Los 8 ejemplos compilaban limpios y pasaban**, pero el runtime original
   **no era M:N sino 1:N**: `StartM` comprobaba `IsMultiThread` antes de
   `BeginThread`, y `cthreads` solo pone esa variable a `True` dentro del
   primer `BeginThread` (`unix/cthreads.pp:414-419`). Nunca nacía un hilo.
   8 pasrutinas de CPU de 300 ms tardaban 2400 ms con `Threads: 1`.
2. **Con hilos habilitados** (quitando esa comprobación) los ejemplos
   fallaban casi siempre: `mutex` 30/30, `pingpong` 29/30, `select` 29/30.
3. **Las excepciones estaban rotas incluso en 1:N**: el RTL guarda la cadena
   de marcos `try` en un `threadvar` y `raise` hace `longjmp` sobre ella
   (`inc/except.inc:21-27,184`); `fpc_PopAddrStack` hace `halt(255)` con la
   cadena vacía (`:196-207`). Al intercalar pasrutinas la cadena se mezcla:
   64 pasrutinas con `PasSleep` + `raise`/`except` daban una cascada de
   `EAccessViolation` y un cuelgue.
4. Otros fallos verificados: `PasSleep(2000)` dormía 290 ms por un timer
   obsoleto; `PasWaitRead` se colgaba si el dato llegó antes de esperar
   (epoll edge-triggered sin latch); `PasSelect` devolvía `-1` al cerrarse
   un canal; 2 000 000 de spawns terminaban en `EOutOfMemory`; 300 000
   spawns dejaban 1,3 GB de RSS.

## 2. ¿Era la mejor forma de implementar gorutinas?

La arquitectura (G/M/P, colas locales con robo, park/ready, sudog, select
con locks ordenados, epoll) era la correcta y es la de Go. Fallaba que se
habían copiado a medias las piezas que hacen el diseño correcto bajo
concurrencia, y que un problema específico de FPC (estado de excepciones
por hilo) no estaba resuelto.

| Mecanismo de Go | Estado original | Estado actual |
|---|---|---|
| `handoffp` / `pidleput`: una P liberada se entrega o se aparca, nunca ambas | `UnbindP` la metía en `idleP` y luego `StartM(pp)` la entregaba | `HandoffP` copiado de `proc.go:3147` |
| `runqgrab`: copiar el lote antes del CAS | `RunqSteal` leía después del CAS | `RunqGrab` copiado de `proc.go:7720` |
| M "spinning" (`proc.go:37-67`) | `nSpinning` nunca se incrementaba | `BecomeSpinning`, `ResetSpinning`, `needSpinning` |
| `resetForSleep` (`time.go:372`): armar el timer tras aparcar | Se armaba antes; `FireTimers` descartaba la G aún `Grunning` | Armado en `FinishPark` |
| `deltimer`/`modtimer`, montículo por P | Lista global O(n); nunca se borraban | Montículo por P, entradas `(G, seq)` |
| `pdReady` (`netpoll.go:51-68`) | Sin latch: flanco perdido | Máquina de estados `pdNil/pdReady/pdWait/G` |
| Un solo M en `netpoll` (`sched.lastpoll`) | Todos los M ociosos en el mismo `epoll_wait` | Un poller, los demás en `stopm` |
| `closechan` reclama sudogs (`chan.go:864`) | `Close` sin `ClaimSudog` | `Dequeue` reclama siempre |
| `_defer`/`_panic` en la `g` | Cadenas del RTL por hilo | Guardadas y restauradas por pasrutina |
| `gsignal` + `sigaltstack` | Manejadores del RTL sin `SA_ONSTACK` | Pila de señales por M |
| `exit(0)` al volver `main` | Finalización del RTL con M activos | `ExitProc` que aparca los M y vacía sus búferes |
| `sysmon`/`retake`, `entersyscall` | Nada | `PasEnterSyscall`/`PasExitSyscall`, hilo `sysmon` |
| `sync.Mutex` con spinning y modo hambriento | Entrega directa: un cambio de contexto por `Unlock` | Portado de `internal/sync/mutex.go` sobre `sema.go` |
| `runtime.mutex` con futex | Secciones críticas de pthread | `TPasLock` (`lock_futex.go`) |

## 3. Hallazgos de la auditoría (código original)

- **C1** `StartM` nunca creaba hilos (1:N). Evidencia: `Threads: 1`, 2400 ms
  para 8 × 300 ms de CPU.
- **C2** Estado de excepciones por hilo, no por pasrutina. Evidencia:
  cascada de `EAccessViolation` y cuelgue; código 255 en todas las
  ejecuciones multihilo (`halt(255)` de `fpc_PopAddrStack`).
- **C3** Una P podía ligarse a dos M (`UnbindP` + `StartM`).
- **C4** `RunqSteal` leía la cola después del CAS.
- **C5** Timers: despertar perdido, disparo obsoleto (290 ms en vez de
  2000), lista O(n) (20 000 dormilones: 866 ms).
- **C6** Poller: sin latch (cuelgue), sin `EPOLL_CTL_DEL`, `O_NONBLOCK` sin
  documentar, rebaño de M, `Netpoll(0)` en cada `Schedule`.
- **C7** `Wakep` sin estado spinning: un despertar de hilo por cada spawn o
  ready.
- **C8** Salida del programa con M activos: `SIGSEGV` en `FindRunnable`
  tras `end.`.
- **C9** `Close` frente a `select`: doble `Ready` y uso tras liberar;
  `PasSelect` devolvía `-1`.
- **M1** Pilas: 2 VMA por pasrutina, nunca liberadas, 4,4 KiB de RSS cada
  una, 1,3 GB tras 300 000 spawns.
- **M2** Cada `GetM` era una llamada a `FPC_THREADVAR_RELOCATE` (el binario
  no tiene accesos `%fs:`: este FPC no usa threadvars por sección).
- **M3** Sudogs en el heap, colas sin puntero de cola, `GetPollDesc` O(n).
- **M4** Sin preempción ni retirada de P en syscalls.
- **M5** Manejadores de señal sobre pilas de 8–16 KiB sin `sigaltstack`.
- **M6** `WriteLn` no sincronizado en los ejemplos: 17 % de líneas
  corruptas con hilos reales.
- **B1** `PASMAXPROCS` tras `PasInit` sin efecto; `GetTickCount64` de 1 ms;
  README con afirmaciones falsas sobre los hilos.

## 4. Método de verificación

Cada hallazgo se reprodujo con un programa; esos programas, convertidos en
tests con código de salida, están ahora en `tests/` y los ejecuta
`make check`. Las pruebas multihilo se hicieron con una copia del runtime
sin el guard `IsMultiThread`, con `gdb` para las pilas de los hilos y con
`objdump`/`readelf` para el modelo de threadvars y los símbolos del RTL.

---

## 5. Estado tras la corrección

### 5.1 Qué se cambió

`src/pasrutinas.pas` se reescribió siguiendo `proc.go`, `time.go`,
`netpoll.go`, `lock_futex.go`, `sema.go` e `internal/sync/mutex.go`;
`src/paschan.pas` siguiendo `chan.go` y `select.go`. Cada rutina cita la
función de Go que refleja. Cambios visibles para el usuario:

- API nueva: `PasSleepNs`, `PasNow`, `PasEnterSyscall`/`PasExitSyscall`,
  `PasWaitWriteTimeout`, `PasUnregisterFd`, `PasWriteLn`, `TPasLock`
  (`PasLockAcquire`/`PasLockRelease`), campo `Ok` en `TPasSelectCase`.
- `PASMAXPROCS(N)` tras la inicialización lanza excepción en vez de
  ignorarse.
- Un `select` con envío a canal cerrado lanza excepción, como Go.
- `PASRUTINAS_STATS=1` imprime contadores del planificador al salir.
- Los ejemplos usan `PasWriteLn`; `select.pas` usa el select bloqueante y
  `Ok`; `poll.pas` sigue el patrón "intenta, espera con EAGAIN".

### 5.2 Cómo se resolvió cada hallazgo

| Hallazgo | Solución | Test |
|---|---|---|
| C1 | Sin guard; `NewM` crea hilos bajo demanda | `test_mn` |
| C2 | Descubrimiento de los offsets de `ExceptAddrStack`/`ExceptObjectStack` en el bloque de threadvars (sonda con `FPC_PUSHEXCEPTADDR`, excepción de prueba, barrido con `FPC_THREADVAR_RELOCATE`); guardado en `FinishPark`, restaurado en `Execute`; fallback con `FPC_PUSHEXCEPTADDR`/`FPC_POPADDRSTACK` | `test_exceptions` |
| C3 | `HandoffP`, `StopM`/`StartM` con `nextp` escrito solo por `StartM` | ejemplos ×30 |
| C4 | `RunqGrab` con lote local antes del CAS; `runqtail` publicado con `xchg` | `test_stress` |
| C5 | Montículos por P, armado en `FinishPark`, `(G, seq)` por parada, arbitraje CAS con el pollDesc | `test_timers` |
| C6 | `pdReady` latch, un poller, `PasUnregisterFd`, `Netpoll(0)` solo con esperas | `test_netpoll` |
| C7 | `spinning` por M, `nSpinning`, `needSpinning` | `PASRUTINAS_STATS` |
| C8 | `ExitProc`: aparca los M y vacía `Output`/`StdErr` de cada hilo | todos (código de salida 0) |
| C9 | `Dequeue` reclama con CAS, `Close` incluido; `Ok` en el caso elegido | `test_selclose` |
| M1 | Pilas por slabs (`PROT_NONE` + `mprotect` por pila), caché por P y global, `munmap` por encima de 1024 | `test_stress` |
| M2 | Punteros a `StackBottom`/`StackLength` cacheados por M; `mp` pasado como parámetro; `NowNs` solo con timers | micro-benchmark |
| M3 | Sudog en la pila de la pasrutina; colas con `first/last`; pollDesc indexado por fd | `test_chan`, `test_select` |
| M4 | `sysmon` con `retake`; `PasEnterSyscall`/`PasExitSyscall`; bandera `preempt` honrada por `Pas()` | `test_syscall` |
| M5 | `sigaltstack` de 64 KiB por M; manejadores reinstalados con `SA_ONSTACK` | `test_sigstack` |
| M6 | `PasWriteLn` con lock y `Flush`; ejemplos actualizados | `test_writeln` |
| B1 | `PASMAXPROCS` lanza; `clock_gettime` en ns; README reescrito | — |

### 5.3 Resultados

`make check`: 16 tests y 8 ejemplos, `ALL_TESTS_OK`. Los 8 ejemplos pasan
30 de 30 ejecuciones con hilos reales.

| Prueba | Original (1:N) | Original con hilos | Actual |
|---|---|---|---|
| 8 pasrutinas de CPU × 200–300 ms | 2400 ms, 1 hilo | 300 ms, se cuelga al salir | 200 ms, 10 hilos |
| 64 × 50 `raise`/`except` tras `PasSleep` | cascada de `EAccessViolation`, cuelgue | 255 | 3200/3200 |
| Aparcar dentro de `except` y `finally` | — | — | 2560/2560 |
| `PasSleep(400)` tras un poll con timeout satisfecho | 290 ms (2000 pedidos) | — | 400 ms |
| Flanco que llega sin nadie esperando | cuelgue | — | recibido |
| `select` con canal cerrado | `-1` | — | caso 0, `Ok=False` |
| 300 000 spawns triviales | 1751 ms, 1,3 GB RSS | 235 ms, 129 MB | 45–65 ms, 12 MB |
| 20 000 dormilones de 100–199 ms | 866 ms | 255 | 289 ms |
| 2 000 000 spawns con yield | `EOutOfMemory` | — | 1,7 s |
| 32 pasrutinas × 500 líneas por tubería | 0 corruptas (1 hilo) | 2767 corruptas | 0 corruptas |

### 5.4 Comparación con Go 1.27.1

Misma máquina, 32 CPU, `GOMAXPROCS=32` frente a `PASMAXPROCS=32`, mejor de
tres ejecuciones (`bench.go` y `bench.pas` equivalentes):

| Benchmark | Go | pasrutinas |
|---|---|---|
| 300 000 gorutinas/pasrutinas triviales | 44 ms | 45 ms |
| 200 000 idas y vueltas por canal sin búfer | 43 ms | 41 ms |
| 8 × 100 000 `Lock`/`Unlock` | 29 ms | 22 ms |
| 20 000 dormilones de 100–199 ms | 209 ms | 289 ms |

Por operación (un P): parada más replanificación 57 ns; envío más
recepción con búfer 30 ns; ida y vuelta sin búfer 194 ns. La diferencia
que queda en los dormilones es el coste de la primera asignación de cada
pila (`mprotect` de la guarda y el fallo de página inicial, unos 4 µs por
pila nueva; las recicladas cuestan 150 ns). Go no usa páginas de guarda
porque su compilador comprueba la pila.

## 6. Límites conocidos

- Sin preempción asíncrona: un bucle sin puntos de planificación retiene
  su P hasta que llama a `Pas()`, aparca o cede (`sysmon` marca la
  pasrutina; `Pas()` cede al verlo).
- Cada pila ocupa 2 VMA; con `vm.max_map_count = 65530` (valor por defecto
  de Debian/Ubuntu) caben unas 32 000 pasrutinas vivas a la vez.
- Con `{$S+}` (`-Ct`) el RTL usa `StackMargin = 32768` en x86_64
  (`inc/system.inc:54`), mayor que la pila de 16 KiB: cualquier
  procedimiento compilado con comprobación de pila dentro de una
  pasrutina dispara el error 202.
- El poller usa `epoll_wait` con milisegundos: `PasSleepNs` redondea hacia
  arriba al milisegundo, como el `netpoll` de Go.
- Las pasrutinas que siguen ejecutándose cuando el programa principal
  termina se abandonan, como las gorutinas.
