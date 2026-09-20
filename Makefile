FPC      ?= fpc
CPUFLAGS ?= -Px86_64
MODE     := -Mobjfpc -Scgi -O2
INCLUDES := -Fu./src
OUTDIR   := ./bin
UNITDIR  := ./units
# -Sewnh: treat warnings, notes and hints as errors.
# -vm11030,11031: hide FPC's own "reading /etc/fpc.cfg" hints.
WARN     := -vwnh -Sewnh -vm11030,11031
FLAGS    := $(CPUFLAGS) $(MODE) $(INCLUDES) -FE$(OUTDIR) -FU$(UNITDIR) -gl $(WARN)

SRCS     := src/pasrutinas.pas src/paschan.pas

EXAMPLES := hola pingpong miles sleep select poll mutex once
TESTS    := test_spawn test_chan test_bufchan test_select test_sleep test_mutex \
            test_once test_mn test_exceptions test_sigstack test_timers \
            test_netpoll test_selclose test_writeln test_stress test_syscall

.PHONY: all examples tests check bench clean install uninstall \
        install-units uninstall-units

all: examples tests

$(OUTDIR) $(UNITDIR):
	mkdir -p $@

examples: $(OUTDIR) $(UNITDIR) $(addprefix $(OUTDIR)/,$(EXAMPLES))
tests: $(OUTDIR) $(UNITDIR) $(addprefix $(OUTDIR)/,$(TESTS))

$(OUTDIR)/%: examples/%.pas $(SRCS) | $(OUTDIR) $(UNITDIR)
	$(FPC) $(FLAGS) $<

$(OUTDIR)/%: tests/%.pas $(SRCS) | $(OUTDIR) $(UNITDIR)
	$(FPC) $(FLAGS) $<

# Every test exits non-zero on failure. test_writeln is checked from
# outside: 16000 lines of 120 characters must come out whole through a
# pipe. Examples are run once as well.
check: all
	@set -e; \
	for t in $(TESTS); do \
	  echo "==== $$t ===="; \
	  if [ $$t = test_writeln ]; then \
	    timeout 60 $(OUTDIR)/$$t | awk 'length($$0)!=120{bad++} END{print "lines="NR" corrupted="bad+0; exit (bad+0)>0 || NR!=16000}'; \
	  else \
	    timeout 120 $(OUTDIR)/$$t; \
	  fi; \
	done; \
	for e in $(EXAMPLES); do \
	  echo "==== example $$e ===="; \
	  timeout 60 $(OUTDIR)/$$e > /dev/null; \
	done; \
	echo ALL_TESTS_OK

# Side by side with Go: needs a Go toolchain in PATH.
bench: $(OUTDIR) $(UNITDIR)
	$(FPC) $(FLAGS) bench/bench.pas
	cd bench && go build -o ../$(OUTDIR)/bench_go bench.go
	@for i in 1 2 3; do $(OUTDIR)/bench_go; $(OUTDIR)/bench; done

# ---------------------------------------------------------------------------
# Installation.
#
# "make install" uses fpmake, which is FPC's own package tool and the right
# one: fpmake.pp already declares the package, its two units and their
# dependency, the examples, and the OS/CPU restrictions fppkg needs. These
# targets only save the reader from having to know that.
#
# fpmake resolves the implicit "rtl" dependency through the GLOBAL unit
# directory, which it does NOT read from fpc.cfg, so the directory is asked of
# the compiler itself (-iV, -iTP, -iTO) rather than hard-coded. Override it if
# your units live somewhere the loop does not look:
#   make install FPCUNITS=/opt/fpc/3.2.2/units/x86_64-linux
#
# ON A DISTRIBUTION PACKAGE OF FPC, fpmake may still stop with
#   Could not find unit directory for dependency package "rtl"
# because distro RPM/DEB builds ship the .ppu/.o files WITHOUT the .fpm
# metadata that fpmake uses to resolve dependencies (Fedora's fpc 3.2.2 is one:
# no .fpm anywhere under units/, and fppkg left with an old-format config).
# Nothing is wrong with the package; the tool has nothing to resolve against.
# For that case use "make install-units", which does what the distro itself
# would have done: copy the compiled units into the compiler's unit tree. It is
# purely additive and overwrites nothing.
# ---------------------------------------------------------------------------
FPMAKEBIN := fpmake.bin
PREFIX    ?=

FPCUNITS ?= $(shell for b in /usr/lib64/fpc /usr/lib/fpc /usr/local/lib/fpc; do \
  d="$$b/$$($(FPC) -iV)/units/$$($(FPC) -iTP)-$$($(FPC) -iTO)"; \
  [ -d "$$d/rtl" ] && echo "$$d" && break; \
done)

FPMAKEOPT := $(if $(FPCUNITS),--globalunitdir=$(FPCUNITS),) \
             $(if $(PREFIX),--prefix=$(PREFIX),)

$(FPMAKEBIN): fpmake.pp
	$(FPC) $(CPUFLAGS) $(MODE) fpmake.pp -o$(FPMAKEBIN)

install: $(FPMAKEBIN)
	./$(FPMAKEBIN) build $(FPMAKEOPT)
	./$(FPMAKEBIN) install $(FPMAKEOPT)

uninstall: $(FPMAKEBIN)
	./$(FPMAKEBIN) uninstall $(FPMAKEOPT)

# Fallback for distro installs: build the units clean (no -gl) and copy them
# into their own directory under the compiler's unit tree, exactly as a
# packaged library is laid out. After this, "uses pasrutinas, paschan" compiles
# from anywhere with no -Fu.
install-units:
	@test -n "$(FPCUNITS)" || { echo "FPCUNITS not found; pass it explicitly"; exit 1; }
	mkdir -p $(UNITDIR) $(FPCUNITS)/pasrutinas
	$(FPC) $(CPUFLAGS) $(MODE) $(INCLUDES) -FU$(UNITDIR) src/paschan.pas
	cp -f $(UNITDIR)/pasrutinas.ppu $(UNITDIR)/pasrutinas.o \
	      $(UNITDIR)/paschan.ppu    $(UNITDIR)/paschan.o    $(FPCUNITS)/pasrutinas/
	@echo "installed into $(FPCUNITS)/pasrutinas"

uninstall-units:
	rm -rf $(FPCUNITS)/pasrutinas

clean:
	rm -rf $(OUTDIR) $(UNITDIR)
	rm -f $(FPMAKEBIN) fpmake.o fpmake.ppu
