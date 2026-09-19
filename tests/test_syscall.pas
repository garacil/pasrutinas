program test_syscall;
{ PasEnterSyscall/PasExitSyscall hand the P to another M while the OS
  thread blocks in the kernel (sysmon retake), so blocking calls do not
  serialise the program. }
{$mode objfpc}{$H+}
uses
  cthreads, SysUtils, BaseUnix, pasrutinas;

const
  N = 8;
  BlockMs = 150;

var
  wg: TPasWaitGroup;
  i: Integer;
  t0, elapsed: Int64;

procedure Blocker(Arg: Pointer);
var
  req, rem: TTimeSpec;
begin
  req.tv_sec := 0;
  req.tv_nsec := BlockMs * 1000000;
  PasEnterSyscall;
  FpNanoSleep(@req, @rem);
  PasExitSyscall;
  TPasWaitGroup(Arg).Done;
end;

begin
  { two Ps only: without hand-off eight 150 ms blocking calls need 600 ms }
  PASMAXPROCS(2);
  PasInit;
  wg := TPasWaitGroup.Create;
  try
    t0 := PasNow;
    wg.Add(N);
    for i := 1 to N do
      Pas(@Blocker, wg);
    wg.Wait;
    elapsed := (PasNow - t0) div 1000000;
  finally
    wg.Free;
  end;
  PasWriteLn('%d blocking syscalls of %d ms on PASMAXPROCS=2: %d ms', [N, BlockMs, elapsed]);
  if elapsed > 3 * BlockMs then
    Halt(1);
end.
