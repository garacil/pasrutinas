FPC      ?= fpc
CPUFLAGS ?= -Px86_64
MODE     := -Mobjfpc -Scgi -O2
INCLUDES := -Fu./src
OUTDIR   := ./bin
UNITDIR  := ./units
FLAGS    := $(CPUFLAGS) $(MODE) $(INCLUDES) -FE$(OUTDIR) -FU$(UNITDIR) -gl

EXAMPLES := hola pingpong miles sleep select poll mutex once
TESTS    := test_spawn test_chan test_bufchan test_select test_sleep test_mutex test_once

.PHONY: all examples tests check clean

all: examples tests

$(OUTDIR) $(UNITDIR):
	mkdir -p $@

examples: $(OUTDIR) $(UNITDIR) $(addprefix $(OUTDIR)/,$(EXAMPLES))
tests: $(OUTDIR) $(UNITDIR) $(addprefix $(OUTDIR)/,$(TESTS))

$(OUTDIR)/hola: examples/hola.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) examples/hola.pas

$(OUTDIR)/pingpong: examples/pingpong.pas src/pasrutinas.pas src/paschan.pas
	$(FPC) $(FLAGS) examples/pingpong.pas

$(OUTDIR)/miles: examples/miles.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) examples/miles.pas

$(OUTDIR)/sleep: examples/sleep.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) examples/sleep.pas

$(OUTDIR)/select: examples/select.pas src/pasrutinas.pas src/paschan.pas
	$(FPC) $(FLAGS) examples/select.pas

$(OUTDIR)/poll: examples/poll.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) examples/poll.pas

$(OUTDIR)/mutex: examples/mutex.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) examples/mutex.pas

$(OUTDIR)/once: examples/once.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) examples/once.pas

$(OUTDIR)/test_spawn: tests/test_spawn.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) tests/test_spawn.pas

$(OUTDIR)/test_chan: tests/test_chan.pas src/pasrutinas.pas src/paschan.pas
	$(FPC) $(FLAGS) tests/test_chan.pas

$(OUTDIR)/test_bufchan: tests/test_bufchan.pas src/pasrutinas.pas src/paschan.pas
	$(FPC) $(FLAGS) tests/test_bufchan.pas

$(OUTDIR)/test_select: tests/test_select.pas src/pasrutinas.pas src/paschan.pas
	$(FPC) $(FLAGS) tests/test_select.pas

$(OUTDIR)/test_sleep: tests/test_sleep.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) tests/test_sleep.pas

$(OUTDIR)/test_mutex: tests/test_mutex.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) tests/test_mutex.pas

$(OUTDIR)/test_once: tests/test_once.pas src/pasrutinas.pas
	$(FPC) $(FLAGS) tests/test_once.pas

check: tests
	@set -e; \
	for t in $(TESTS); do \
	  echo "==== $$t ===="; \
	  timeout 20 $(OUTDIR)/$$t; \
	done; \
	echo ALL_TESTS_OK

clean:
	rm -rf $(OUTDIR) $(UNITDIR)
