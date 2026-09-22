# BOB-16 — SystemVerilog FPGA Implementation

A clean, multicycle hardware implementation of the BOB-16 architecture in SystemVerilog.

> **Attribution**: BOB-16 was created by **misterbob** ([GitHub: somerandomviolinkid/bob16](https://github.com/somerandomviolinkid/bob16)).
> This repository provides an independent SystemVerilog core, SoC wrapper, peripheral controllers, assembler tooling, and simulation testbenches.

---

## Architecture

BOB-16 is a 16-bit word-addressed load/store architecture:
- **Registers**: Eight 16-bit general-purpose registers (`R0`–`R7`), Program Counter (`PC`), Instruction Register (`IR`), and Condition Codes (`{N, Z, P}`).
- **Memory**: 16-bit word-addressed space (default 4096 words / 8 KiB block RAM, configurable up to 65536 words).
- **Execution**: Multicycle FSM supporting synchronous stallable memory and streaming console traps.

### Instruction Set

| Opcode `[15:12]` | Mnemonic | Format / Semantics | Description |
|---|---|---|---|
| `0x0` | `NOP` | `nop` | No operation (increments PC) |
| `0x1` | `ADD` | `add rD, rA, rB` / immediate modes | Arithmetic addition; updates CC |
| `0x2` | `AND` | `and rD, rA, rB` / immediate modes | Bitwise AND; updates CC |
| `0x3` | `NOT` | `not rD, rA` / `not rD` | Bitwise complement; updates CC |
| `0x4` | `LD` | `ld rD, PCoffset9` | Load direct (`R[D] = mem[PC + sext(off9)]`); updates CC |
| `0x5` | `LDI` | `ldi rD, PCoffset9` | Load indirect (`R[D] = mem[mem[PC + sext(off9)]]`); updates CC |
| `0x6` | `LDR` | `ldr rD, rBase, offset6` | Load base+offset (`R[D] = mem[R[Base] + sext(off6)]`); updates CC |
| `0x7` | `ST` | `st rD, PCoffset9` | Store direct (`mem[PC + sext(off9)] = R[D]`) |
| `0x8` | `STI` | `sti rD, PCoffset9` | Store indirect (`mem[mem[PC + sext(off9)]] = R[D]`) |
| `0x9` | `STR` | `str rD, rBase, offset6` | Store base+offset (`mem[R[Base] + sext(off6)] = R[D]`) |
| `0xA` | `BR` | `br[n][z][p] PCoffset9` | Conditional branch on matching CC (`N=[11]`, `Z=[10]`, `P=[9]`) |
| `0xB` | `JMP` | `jmp rBase` | Unconditional jump (`PC = R[Base]`) |
| `0xC` | `JSR` / `JSRR` | `jsr offset11` / `jsrr rBase` | Subroutine call; saves return address into `R7` |
| `0xD` | `LEA` | `lea rD, PCoffset9` | Load effective address (`R[D] = PC + sext(off9)`); updates CC |
| `0xE` | `RET` | `ret` | Return from subroutine (`PC = R7`) |
| `0xF` | `TRAP` | `trap vector8` | System trap / console I/O routine |

#### ADD / AND Addressing Modes (`ir[8:7]`)

- `00`: `rD = rA + rB` (3-register)
- `01`: `rD = rA + sext(imm4)` (2-register + 4-bit immediate: -8..7)
- `10`: `rD = rD + rA` (in-place register)
- `11`: `rD = rD + sext(imm7)` (in-place 7-bit immediate: -64..63)

#### Trap Vectors

- `0x00` (`TRAP 0`): **HALT** — Stops execution, asserts `halted`.
- `0x01` (`TRAP 1`): **PUTC** — Transmits low byte of `R0` via console stream.
- `0x02` (`TRAP 2`): **PUTS** — Streams null-terminated 16-bit string at address `R0` (appends LF by default).
- `0x03` (`TRAP 3`): **GETS** — Reads characters into buffer at `R0` with max capacity `R1` until LF or limit.

---

## Hardware Modules & Interfaces

### CPU Bus Interface (`bob16_core`)

- **Memory**: Single outstanding transaction using `mem_valid` and `mem_ready` handshake. Supports synchronous block RAM latency with out-of-range detection (`mem_error`).
- **Console Stream**: Byte transfers on clock edge when `tx_valid && tx_ready` (outbound) or `rx_valid && rx_ready` (inbound).

### Top-Level Module (`bob16_top`)

Self-contained FPGA wrapper integrating the core, synchronous memory, UART transmitter, receiver with 2-stage input synchronizer, and 16-byte RX FIFO.

#### Ports

| Port | Direction | Description |
|---|---|---|
| `clk` | Input | System clock |
| `reset_n` | Input | Asynchronous active-low reset (synchronized internally) |
| `uart_rx` | Input | Serial receive pin |
| `uart_tx` | Output | Serial transmit pin |
| `halted` | Output | High when CPU is halted (via `TRAP 0` or fault) |
| `faulted` | Output | High when CPU encountered an invalid instruction or bad memory access |
| `tx_busy` | Output | High while UART transmitter is sending a frame |
| `rx_overrun` | Output | Sticky indicator for RX FIFO overflow |
| `rx_frame_error` | Output | Sticky indicator for UART framing errors |

#### Parameters

| Parameter | Default | Description |
|---|---:|---|
| `CLK_HZ` | `50_000_000` | System clock rate in Hz (computes UART baud divider) |
| `BAUD` | `115_200` | Serial baud rate (8N1) |
| `ADDR_WIDTH` | `12` | Memory address bits (`12` = 4096 words / 8 KiB) |
| `MEM_FILE` | `"programs/hello.hex"` | Initial memory image loaded at configuration |
| `RESET_PC` | `16'h0000` | Address fetched after reset |
| `PUTS_NEWLINE`| `1` | Automatically append newline (`0x0A`) after `PUTS` |

---

## Quick Start

### Prerequisites
- Python 3.10+
- Icarus Verilog (`iverilog` and `vvp`) for simulation
- (Optional) Yosys for logic synthesis check

### Build & Test

```sh
# Assemble all example programs
make all

# Run all testbenches (soc, top, uart, memory, fifo)
make test

# Run a specific testbench
make soc
make top
make uart
make memory
make fifo

# Check logic synthesis with Yosys
make synth

# Clean build artifacts and generated hex images
make clean
```

### Assembling Custom Programs

The zero-dependency assembler translates `.basm` files to 16-bit hex images suitable for `$readmemh`:

```sh
python3 tools/assemble.py programs/hello.basm -o programs/hello.hex --words 4096
```

---

## Repository Structure

```text
bob16-sv/
├── Makefile             # Simulation and assembly targets
├── README.md            # Architecture, interface, and usage documentation
├── rtl/                 # SystemVerilog RTL modules
│   ├── bob16_alu.sv     # ALU (ADD, AND, NOT)
│   ├── bob16_core.sv    # Multicycle CPU controller and register file
│   ├── bob16_memory.sv  # Synchronous RAM interface
│   ├── bob16_rx_fifo.sv # 16-byte UART RX FIFO
│   ├── bob16_soc.sv     # CPU + RAM integration
│   ├── bob16_top.sv     # Top-level module with reset synchronizer and UART
│   ├── bob16_uart_rx.sv # UART receiver with glitch filter
│   ├── bob16_uart_tx.sv # UART transmitter
│   └── files.f          # RTL source file manifest
├── tb/                  # Testbenches
│   ├── tb_fifo.sv       # FIFO capacity and simultaneous R/W test
│   ├── tb_memory.sv     # Memory timing and bounds check test
│   ├── tb_soc.sv        # Integrated SoC execution test (runs hello program)
│   ├── tb_top.sv        # Top-level UART and error flag verification
│   └── tb_uart.sv       # Comprehensive UART loopback and timing test
├── programs/            # Assembly source programs
│   ├── arithmetic.basm  # Arithmetic and logic verification program
│   ├── echo.basm        # Interactive serial echo demo
│   └── hello.basm       # Upstream "bob" demo
└── tools/
    └── assemble.py      # Standalone BOB-16 assembler
```
