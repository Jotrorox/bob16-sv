# BOB-16 — SystemVerilog FPGA Implementation

A clean, multicycle hardware implementation of the [BOB-16 architecture](https://github.com/somerandomviolinkid/bob16) (created by **misterbob**) in SystemVerilog. Includes an SoC wrapper, UART controller, Python assembler, and testbenches.

---

## Architecture

BOB-16 is a 16-bit word-addressed load/store architecture:
- **Registers**: Eight 16-bit GPRs (`R0`–`R7`), Program Counter (`PC`), Instruction Register (`IR`), and Condition Codes (`{N, Z, P}`).
- **Memory**: 16-bit word-addressed synchronous RAM (default 4096 words / 8 KiB).
- **Execution**: Multicycle FSM supporting stallable memory and streaming console traps.

### Instruction Set

| Opcode | Mnemonic | Operands / Format | Description |
|:---:|---|---|---|
| `0x0` | `NOP` | — | No operation |
| `0x1` | `ADD` | `rD, rA, rB` / immediate (`imm4`, `imm7`) | Addition; updates CC |
| `0x2` | `AND` | `rD, rA, rB` / immediate (`imm4`, `imm7`) | Bitwise AND; updates CC |
| `0x3` | `NOT` | `not rD, rA` / `not rD` | Bitwise NOT (`~rA` or in-place `~rD`); updates CC |
| `0x4` | `LD`  | `rD, PCoffset9` | Direct load; updates CC |
| `0x5` | `LDI` | `rD, PCoffset9` | Indirect load; updates CC |
| `0x6` | `LDR` | `rD, rBase, offset6` | Base + offset load; updates CC |
| `0x7` | `ST`  | `rD, PCoffset9` | Direct store |
| `0x8` | `STI` | `rD, PCoffset9` | Indirect store |
| `0x9` | `STR` | `rD, rBase, offset6` | Base + offset store |
| `0xA` | `BR`  | `br <flags> PCoffset9` | Conditional branch (`flags` in `{n,z,p}`) |
| `0xB` | `JMP` | `jmp rBase` | Unconditional jump |
| `0xC` | `JSR`/`JSRR` | `jsr PCoffset11` / `jsrr rBase` | Subroutine call (saves return PC in `R7`) |
| `0xD` | `LEA` | `lea rD, PCoffset9` | Load effective address; updates CC |
| `0xE` | `RET` | `ret` | Return (`PC = R7`) |
| `0xF` | `TRAP`| `trap vector` | `0`: HALT, `1`: PUTC, `2`: PUTS, `3`: GETS |

---

## Hardware Modules

- **Core (`bob16_core`)**: Multicycle CPU with valid/ready synchronous memory bus and streaming console I/O handshake.
- **SoC (`bob16_soc`)**: Integrates core with synchronous block RAM.
- **Top (`bob16_top`)**: Complete FPGA wrapper integrating SoC, UART TX/RX, 16-byte RX FIFO, and reset synchronizer.
  - **Ports**: `clk`, `reset_n`, `uart_rx`, `uart_tx`, and status flags (`halted`, `faulted`, `tx_busy`, `rx_overrun`, `rx_frame_error`).
  - **Parameters**: `CLK_HZ` (`50_000_000`), `BAUD` (`115_200`), `ADDR_WIDTH` (`12` = 4k words), `MEM_FILE` (`"programs/hello.hex"`), `RESET_PC` (`16'h0000`), `PUTS_NEWLINE` (`1`).

---

## Quick Start

### Prerequisites

- Python 3 and `make`
- Icarus Verilog (`iverilog`, `vvp`)
- *(Optional)* Yosys (synthesis check)

### Build & Run

```sh
# Run default demo (hello.basm) via fast console simulator
make run

# Run other programs or pass input
make run PROG=programs/arithmetic.basm
make run PROG=programs/echo.basm INPUT=input.txt

# Run all testbenches (soc, top, uart, memory, fifo)
make test

# Check synthesis
make synth
```

### Assembler

Assemble `.basm` source files to 16-bit hex images for simulation or block RAM initialization:

```sh
python3 tools/bob16_asm.py programs/hello.basm -o programs/hello.hex [--words 4096]
```
