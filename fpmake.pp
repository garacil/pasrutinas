{$mode objfpc}{$H+}
program fpmake;

uses
{$ifdef unix}
  cthreads,
{$endif}
  fpmkunit;

var
  P: TPackage;
  T: TTarget;
begin
  with Installer do
  begin
    P := AddPackage('pasrutinas');
    P.ShortName := 'pasrt';
    P.Version := '1.0.0';
    P.Author := 'Germán Luis Aracil Boned';
    P.License := 'LGPL with modification';
    P.Email := 'garacil@tucall.com';
    P.HomepageURL := 'https://github.com/garacil/pasrutinas';
    { GitLab mirror: https://gitlab.com/garacilb/pasrutinas }
    P.Description :=
      'User-space lightweight threads for Free Pascal (Go-style goroutines). ' +
      'An M:N scheduler: many pasrutinas (G) on a few OS threads (M) with ' +
      'logical processors (P), channels, select, timers and epoll. ' +
      'FPC has OS threads and callback event loops; this package adds the ' +
      'missing green-thread runtime.';
    P.NeedLibC := True;
    P.OSes := [linux];
    P.CPUs := [x86_64];

    P.SourcePath.Add('src');
    P.Targets.AddUnit('pasrutinas.pas');
    T := P.Targets.AddUnit('paschan.pas');
    T.Dependencies.AddUnit('pasrutinas');
    P.Targets.AddExampleProgram('mutex.pas');
    P.Targets.AddExampleProgram('once.pas');

    P.ExamplePath.Add('examples');
    P.Targets.AddExampleProgram('hola.pas');
    P.Targets.AddExampleProgram('pingpong.pas');
    P.Targets.AddExampleProgram('miles.pas');
    P.Targets.AddExampleProgram('sleep.pas');
    P.Targets.AddExampleProgram('select.pas');
    P.Targets.AddExampleProgram('poll.pas');

    Run;
  end;
end.
