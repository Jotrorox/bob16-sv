// BOB-16 architecture by misterbob (somerandomviolinkid).
// Multicycle FPGA reimplementation. See README.md for details.
`default_nettype none
module bob16_core #(
    parameter logic [15:0] RESET_PC = 16'h0000,
    parameter bit PUTS_NEWLINE = 1'b1
) (
    input  logic clk,
    input  logic rst,             // Active-high, synchronous; cancels execution.
    // One outstanding memory transaction. Hold request until ready.
    // Read data/error are valid on a rising edge with valid && ready.
    output logic        mem_valid,
    output logic        mem_write,
    output logic [15:0] mem_addr,
    output logic [15:0] mem_wdata,
    input  logic        mem_ready,
    input  logic [15:0] mem_rdata,
    input  logic        mem_error,
    // Byte streams, valid/ready handshake on the rising clock edge.
    output logic        tx_valid,
    output logic [7:0]  tx_data,
    input  logic        tx_ready,
    input  logic        rx_valid,
    input  logic [7:0]  rx_data,
    output logic        rx_ready,
    output logic        halted,
    output logic        faulted,
    output logic [3:0]  fault_code, // 0:none, 1:encoding/vector, 2:memory, 3:GETS n=0
    input  logic [2:0]  debug_reg_addr,
    output logic [15:0] debug_reg_data,
    output logic [15:0] debug_pc,
    output logic [15:0] debug_ir,
    output logic [2:0]  debug_cc,    // {negative, zero, positive}
    output logic        retired,
    output logic [15:0] retired_pc,
    output logic [15:0] retired_ir
);
    localparam logic [3:0] OP_NOP=4'h0, OP_ADD=4'h1, OP_AND=4'h2,
        OP_NOT=4'h3, OP_LD=4'h4, OP_LDI=4'h5, OP_LDR=4'h6,
        OP_ST=4'h7, OP_STI=4'h8, OP_STR=4'h9, OP_BR=4'ha,
        OP_JMP=4'hb, OP_JSR=4'hc, OP_LEA=4'hd, OP_RET=4'he, OP_TRAP=4'hf;
    typedef enum logic [3:0] {
        S_FETCH, S_EXEC, S_INDIRECT, S_LOAD, S_STORE, S_PUTS_READ,
        S_TX, S_GETS_RX, S_GETS_WRITE, S_GETS_ZERO, S_STOP
    } state_t;
    typedef enum logic [1:0] {TX_CHAR, TX_STRING, TX_NEWLINE} tx_kind_t;

    state_t state;
    tx_kind_t tx_kind;
    logic [15:0] regs [0:7];
    logic [15:0] pc, ir, ir_pc, effective_addr, saved_store;
    logic [15:0] string_ptr, chars_left;
    logic [7:0] tx_hold, rx_hold;
    logic [2:0] cc;
    logic [15:0] alu_a, alu_b, alu_result;
    logic illegal;
    wire [3:0] opcode = ir[15:12];
    wire [2:0] dest = ir[11:9];
    wire [15:0] off9 = {{7{ir[8]}}, ir[8:0]};
    wire [15:0] off6 = {{10{ir[5]}}, ir[5:0]};
    wire [15:0] off11 = {{5{ir[10]}}, ir[10:0]};

    function automatic logic [2:0] nzp(input logic [15:0] value);
        if (value == 16'h0000) nzp = 3'b010;
        else if (value[15])    nzp = 3'b100;
        else                  nzp = 3'b001;
    endfunction

    bob16_alu alu (.op(opcode), .a(alu_a), .b(alu_b), .result(alu_result));

    always_comb begin
        alu_a = 16'h0000;
        alu_b = 16'h0000;
        illegal = 1'b0;
        case (opcode)
            OP_ADD, OP_AND: begin
                case (ir[8:7])
                    2'b00: begin
                        alu_a = regs[ir[6:4]];
                        alu_b = regs[ir[3:1]];
                        illegal = ir[0];
                    end
                    2'b01: begin
                        alu_a = regs[ir[6:4]];
                        alu_b = {{12{ir[3]}}, ir[3:0]};
                    end
                    2'b10: begin
                        alu_a = regs[dest];
                        alu_b = regs[ir[6:4]];
                        illegal = |ir[3:0]; // Fix upstream AND's overlapping 0x1f mask.
                    end
                    2'b11: begin
                        alu_a = regs[dest];
                        alu_b = {{9{ir[6]}}, ir[6:0]};
                    end
                endcase
            end
            OP_NOT: begin
                alu_a = ir[8] ? regs[dest] : regs[ir[7:5]];
                illegal = |ir[4:0];
            end
            OP_JMP: illegal = |ir[8:0];
            OP_TRAP: illegal = (|ir[7:0]) || (ir[11:8] > 4'd3);
            default: begin end
        endcase
    end

    always_comb begin
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr  = effective_addr;
        mem_wdata = saved_store;
        tx_valid  = 1'b0;
        tx_data   = tx_hold;
        rx_ready  = 1'b0;
        if (!rst) begin
            case (state)
                S_FETCH: begin mem_valid=1'b1; mem_addr=pc; end
                S_INDIRECT, S_LOAD: mem_valid=1'b1;
                S_STORE: begin mem_valid=1'b1; mem_write=1'b1; end
                S_PUTS_READ: begin mem_valid=1'b1; mem_addr=string_ptr; end
                S_TX: tx_valid=1'b1;
                S_GETS_RX: rx_ready=1'b1;
                S_GETS_WRITE: begin
                    mem_valid=1'b1; mem_write=1'b1;
                    mem_addr=string_ptr; mem_wdata={8'h00, rx_hold};
                end
                S_GETS_ZERO: begin
                    mem_valid=1'b1; mem_write=1'b1;
                    mem_addr=string_ptr; mem_wdata=16'h0000;
                end
                default: begin end
            endcase
        end
    end

    assign debug_reg_data = regs[debug_reg_addr];
    assign debug_pc = pc;
    assign debug_ir = ir;
    assign debug_cc = cc;
    assign retired_pc = ir_pc;
    assign retired_ir = ir;
    assign faulted = (fault_code != 4'd0);

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
            pc <= RESET_PC;
            ir <= 16'h0000;
            ir_pc <= RESET_PC;
            cc <= 3'b000; // Match the C emulator's initially clear flags.
            effective_addr <= 16'h0000;
            saved_store <= 16'h0000;
            string_ptr <= 16'h0000;
            chars_left <= 16'h0000;
            tx_hold <= 8'h00;
            rx_hold <= 8'h00;
            tx_kind <= TX_CHAR;
            halted <= 1'b0;
            fault_code <= 4'd0;
            retired <= 1'b0;
            for (i=0; i<8; i=i+1) regs[i] <= 16'h0000;
        end else begin
            retired <= 1'b0;
            if (mem_valid && mem_ready && mem_error) begin
                fault_code <= 4'd2;
                halted <= 1'b1;
                state <= S_STOP;
            end else begin
                case (state)
                    S_FETCH: if (mem_ready) begin
                        ir <= mem_rdata;
                        ir_pc <= pc;
                        pc <= pc + 16'd1;
                        state <= S_EXEC;
                    end
                    S_EXEC: begin
                        // Simple instructions retire here; long instructions override these.
                        state <= S_FETCH;
                        retired <= 1'b1;
                        if (illegal) begin
                            fault_code <= 4'd1;
                            halted <= 1'b1;
                            state <= S_STOP;
                            retired <= 1'b0;
                        end else begin
                            case (opcode)
                                OP_NOP: begin end
                                OP_ADD, OP_AND, OP_NOT: begin
                                    regs[dest] <= alu_result;
                                    cc <= nzp(alu_result);
                                end
                                OP_LD, OP_LDI, OP_LDR, OP_ST, OP_STI, OP_STR: begin
                                    retired <= 1'b0;
                                    saved_store <= regs[dest];
                                    if (opcode==OP_LDR || opcode==OP_STR)
                                        effective_addr <= regs[ir[8:6]] + off6;
                                    else effective_addr <= pc + off9;
                                    if (opcode==OP_LDI || opcode==OP_STI) state<=S_INDIRECT;
                                    else if (opcode==OP_LD || opcode==OP_LDR) state<=S_LOAD;
                                    else state<=S_STORE;
                                end
                                OP_BR: if (|(cc & ir[11:9])) pc <= pc + off9;
                                OP_JMP: pc <= regs[dest];
                                OP_JSR: begin
                                    // Nonblocking assignments intentionally read OLD R7 for JSRR R7.
                                    regs[7] <= pc;
                                    if (ir[11]) pc <= regs[ir[10:8]];
                                    else pc <= pc + off11;
                                end
                                OP_LEA: begin
                                    regs[dest] <= pc + off9;
                                    cc <= nzp(pc + off9);
                                end
                                OP_RET: pc <= regs[7];
                                OP_TRAP: begin
                                    case (ir[11:8])
                                        4'd0: begin halted<=1'b1; state<=S_STOP; end
                                        4'd1: begin
                                            retired<=1'b0; tx_hold<=regs[0][7:0];
                                            tx_kind<=TX_CHAR; state<=S_TX;
                                        end
                                        4'd2: begin
                                            retired<=1'b0; regs[7]<=pc;
                                            string_ptr<=regs[0]; state<=S_PUTS_READ;
                                        end
                                        4'd3: begin
                                            retired<=1'b0;
                                            if (regs[1]==16'h0000) begin
                                                halted<=1'b1; fault_code<=4'd3; state<=S_STOP;
                                            end else begin
                                                regs[7]<=pc; string_ptr<=regs[0];
                                                chars_left<=regs[1]-16'd1;
                                                if (regs[1]==16'd1) state<=S_GETS_ZERO;
                                                else state<=S_GETS_RX;
                                            end
                                        end
                                        default: begin end // Rejected by illegal decoder.
                                    endcase
                                end
                                default: begin end // All sixteen opcodes are defined.
                            endcase
                        end
                    end
                    S_INDIRECT: if (mem_ready) begin
                        effective_addr <= mem_rdata;
                        if (opcode==OP_LDI) state<=S_LOAD;
                        else state<=S_STORE;
                    end
                    S_LOAD: if (mem_ready) begin
                        regs[dest] <= mem_rdata;
                        cc <= nzp(mem_rdata);
                        state <= S_FETCH; retired <= 1'b1;
                    end
                    S_STORE: if (mem_ready) begin state<=S_FETCH; retired<=1'b1; end
                    S_PUTS_READ: if (mem_ready) begin
                        regs[0] <= mem_rdata;
                        if (mem_rdata==16'h0000) begin
                            if (PUTS_NEWLINE) begin
                                tx_hold<=8'h0a; tx_kind<=TX_NEWLINE; state<=S_TX;
                            end else begin state<=S_FETCH; retired<=1'b1; end
                        end else begin
                            tx_hold<=mem_rdata[7:0]; tx_kind<=TX_STRING; state<=S_TX;
                        end
                    end
                    S_TX: if (tx_ready) begin
                        if (tx_kind==TX_STRING) begin
                            string_ptr<=string_ptr+16'd1; state<=S_PUTS_READ;
                        end else begin state<=S_FETCH; retired<=1'b1; end
                    end
                    S_GETS_RX: if (rx_valid) begin rx_hold<=rx_data; state<=S_GETS_WRITE; end
                    S_GETS_WRITE: if (mem_ready) begin
                        string_ptr <= string_ptr + 16'd1;
                        chars_left <= chars_left - 16'd1;
                        if (rx_hold==8'h0a || chars_left==16'd1) state<=S_GETS_ZERO;
                        else state<=S_GETS_RX;
                    end
                    S_GETS_ZERO: if (mem_ready) begin state<=S_FETCH; retired<=1'b1; end
                    S_STOP: begin end
                    default: begin halted<=1'b1; fault_code<=4'd1; state<=S_STOP; end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
