CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra
ASSEMBLE ?= tools/assemble
IVERILOG ?= iverilog
VVP      ?= vvp
YOSYS    ?= yosys

SRCS     = $(shell cat rtl/files.f)
PROGRAMS = programs/hello.hex programs/echo.hex programs/arithmetic.hex
TESTS    = soc top uart memory fifo

PROG          ?= programs/hello.basm
MAX_CYCLES    ?= 1000000
INPUT         ?=
SIM_BUILD_DIR ?= build/sim
SIM_ARGS      ?=

BOB16_SIM_BIN      := $(SIM_BUILD_DIR)/tb_sim.vvp
BOB16_SIM_HEX      := $(SIM_BUILD_DIR)/program.hex
BOB16_SIM_MAKEFILE := $(lastword $(MAKEFILE_LIST))

.PHONY: all sim test run clean synth $(TESTS)

all: $(PROGRAMS)

programs/%.hex: programs/%.basm tools/assemble
	$(ASSEMBLE) $< -o $@ --words 4096

sim: test

test: $(TESTS)

$(TESTS): all
	@mkdir -p build
	$(IVERILOG) -g2012 -s tb_$@ -o build/$@.vvp $(SRCS) tb/tb_$@.sv
	$(VVP) build/$@.vvp

run: $(BOB16_SIM_BIN) $(PROG) tools/assemble
	@set -eu; \
	hex="$(PROG)"; \
	case "$(PROG)" in \
	    *.basm) \
	        $(ASSEMBLE) "$(PROG)" \
	            -o "$(BOB16_SIM_HEX)" --words 4096 >&2; \
	        hex="$(BOB16_SIM_HEX)" ;; \
	    *.hex) ;; \
	    *) printf '%s\n' 'PROG must name a .basm or .hex file.' >&2; exit 2 ;; \
	esac; \
	$(VVP) "$(BOB16_SIM_BIN)" "+HEX=$$hex" \
	    "+MAX_CYCLES=$(MAX_CYCLES)" $(if $(strip $(INPUT)),"+INPUT=$(INPUT)") $(SIM_ARGS)

$(BOB16_SIM_BIN): tb/tb_sim.sv rtl/files.f $(wildcard rtl/*.sv rtl/*.svh) $(BOB16_SIM_MAKEFILE)
	@mkdir -p "$(@D)"
	@$(IVERILOG) -g2012 -s tb_sim -o "$@.tmp" -f rtl/files.f tb/tb_sim.sv >&2
	@mv "$@.tmp" "$@"

synth:
	@mkdir -p build
	$(YOSYS) -l build/yosys-core.log -p 'read_verilog -sv rtl/bob16_alu.sv rtl/bob16_core.sv; synth -top bob16_core; check; stat'

tools/assemble: tools/assemble.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -rf build $(PROGRAMS)
