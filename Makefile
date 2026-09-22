PYTHON   ?= python3
IVERILOG ?= iverilog
VVP      ?= vvp
YOSYS    ?= yosys

SRCS     = $(shell cat rtl/files.f)
PROGRAMS = programs/hello.hex programs/echo.hex programs/arithmetic.hex
TESTS    = soc top uart memory fifo

.PHONY: all sim test clean synth $(TESTS)

all: $(PROGRAMS)

programs/%.hex: programs/%.basm tools/assemble.py
	$(PYTHON) tools/assemble.py $< -o $@ --words 4096

sim: test

test: $(TESTS)

$(TESTS): all
	@mkdir -p build
	$(IVERILOG) -g2012 -s tb_$@ -o build/$@.vvp $(SRCS) tb/tb_$@.sv
	$(VVP) build/$@.vvp

# Technology-independent logic synthesis check (optional)
synth:
	@mkdir -p build
	$(YOSYS) -l build/yosys-core.log -p 'read_verilog -sv rtl/bob16_alu.sv rtl/bob16_core.sv; synth -top bob16_core; check; stat'

clean:
	rm -rf build $(PROGRAMS)
