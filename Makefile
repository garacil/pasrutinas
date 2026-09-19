FPC      ?= fpc
CPUFLAGS ?= -Px86_64
MODE     := -Mobjfpc -Scgi -O2
INCLUDES := -Fu./src
OUTDIR   := ./bin
UNITDIR  := ./units
FLAGS    := $(CPUFLAGS) $(MODE) $(INCLUDES) -FE$(OUTDIR) -FU$(UNITDIR) -gl

EXAMPLES := hola pingpong miles sleep select poll

.PHONY: all examples clean

all: examples

$(OUTDIR) $(UNITDIR):
	mkdir -p $@

examples: $(OUTDIR) $(UNITDIR) $(addprefix $(OUTDIR)/,$(EXAMPLES))

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

clean:
	rm -rf $(OUTDIR) $(UNITDIR)
