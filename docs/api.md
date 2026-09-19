# API

All public names use the prefix `Pas` or `PAS`. Internal helpers used
by `paschan` (`PasInternalParkUnlock`, `PasInternalReady`, channel
`LockPtr` / `TrySendLocked` / `EnqueueSudog`) are not a stable API.

`cthreads` must appear first in the program `uses` clause.

## pasrutinas

### Types

- `TPasProc = procedure`
- `TPasProcArg = procedure(Arg: Pointer)`
- `TPasMethod = procedure of object`
- `TPasrutina = Pointer` — opaque G handle (`PasCurrent`, `PasReady`)

### Spawn

```
procedure Pas(Proc: TPasProc);
procedure Pas(Proc: TPasProcArg; Arg: Pointer);
procedure Pas(Method: TPasMethod);
```

### Control

```
procedure PasYield;
procedure PasExit;
procedure PasSleep(Ms: QWord);
procedure PasPark;
procedure PasReady(G: TPasrutina);
function  PasCurrent: TPasrutina;
function  PasID: QWord;
function  NumPasrutinas: LongInt;
function  PASMAXPROCS(N: LongInt): LongInt;
procedure PasSetStackSize(Bytes: PtrUInt);
function  PasStackSize: PtrUInt;
procedure PasInit;
```

`PASMAXPROCS(n)` only takes effect before the first `Pas` / `PasInit`.
`PASMAXPROCS(0)` returns the current value. Default is
`sysconf(_SC_NPROCESSORS_ONLN)`.

### I/O

```
procedure PasWaitRead(Fd: LongInt);
procedure PasWaitWrite(Fd: LongInt);
function  PasWaitReadTimeout(Fd: LongInt; Ms: LongInt): Boolean;
```

The fd is set `O_NONBLOCK` and added to the process-wide epoll set
(edge-triggered). Returns from timeout as `False`.

### TPasWaitGroup

```
procedure Add(Delta: LongInt);
procedure Done;
procedure Wait;
```

### TPasMutex

```
procedure Lock;
procedure Unlock;
```

Parks the calling pasrutina. Does not block the OS thread except for
the short critical section around the wait list.

### TPasRWMutex

```
procedure BeginRead;
procedure EndRead;
procedure Lock;     { write }
procedure Unlock;
```

Writers are preferred over new readers.

### TPasOnce

```
procedure Do_(Proc: TPasProc);
```

`Do` is reserved in Pascal.

### TPasCond

```
procedure Wait(M: TPasMutex);
procedure Signal;
procedure Broadcast;
```

`Wait` atomically unlocks `M`, parks, and locks `M` again on wakeup.

## paschan

### TPasChan\<T\>

```
constructor Create(ACapacity: SizeInt = 0);
procedure Send(const V: T);
function  Recv: T;
function  TrySend(const V: T): Boolean;
function  TryRecv(out V: T): Boolean;
function  RecvOk(out V: T): Boolean;
procedure Close;
function  Closed: Boolean;
function  Len: SizeInt;
function  Cap: SizeInt;
function  Raw: TPasRawChan;
```

Capacity `0` is unbuffered (a send waits for a recv). `Recv` on a
closed empty channel returns `Default(T)`. `RecvOk` returns `False` in
that case.

### TPasRawChan

Untyped elements: `Send(Src: Pointer)` copies `ElemSize` bytes.
Construct with `Create(AElemSize, ACapacity)`.

### PasSelect

```
const
  pasCaseSend    = 0;
  pasCaseRecv    = 1;
  pasCaseDefault = 2;

type
  TPasSelectCase = record
    Kind: LongInt;
    Chan: TPasRawChan;
    Elem: Pointer;
  end;

function PasSelect(var Cases: array of TPasSelectCase): LongInt;
```

Returns the index of the chosen case. At most 16 cases. A default case
does not park. With no default and no ready case, the pasrutina parks
until one case can proceed. Nil channels are ignored.
