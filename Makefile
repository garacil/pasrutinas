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

.PHONY: all examples tests check bench clean

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

clean:
	rm -rf $(OUTDIR) $(UNITDIR)
