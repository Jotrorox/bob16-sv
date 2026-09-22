// CPU + internal RAM, with byte-stream console and debug/retirement interface.
`default_nettype none
module bob16_soc #(
    parameter integer ADDR_WIDTH=12,
    parameter MEM_FILE="programs/hello.hex",
    parameter logic [15:0] RESET_PC=16'h0000,
    parameter bit PUTS_NEWLINE=1'b1
) (
    input logic clk, rst,
    output logic tx_valid,
    output logic [7:0] tx_data,
    input logic tx_ready,
    input logic rx_valid,
    input logic [7:0] rx_data,
    output logic rx_ready,
    output logic halted, faulted,
    output logic [3:0] fault_code,
    input logic [2:0] debug_reg_addr,
    output logic [15:0] debug_reg_data, debug_pc, debug_ir,
    output logic [2:0] debug_cc,
    output logic retired,
    output logic [15:0] retired_pc, retired_ir
);
    logic mem_valid, mem_write, mem_ready, mem_error;
    logic [15:0] mem_addr, mem_wdata, mem_rdata;
    bob16_core #(.RESET_PC(RESET_PC), .PUTS_NEWLINE(PUTS_NEWLINE)) core (
        .clk(clk), .rst(rst), .mem_valid(mem_valid), .mem_write(mem_write),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_ready(mem_ready),
        .mem_rdata(mem_rdata), .mem_error(mem_error),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_ready(rx_ready),
        .halted(halted), .faulted(faulted), .fault_code(fault_code),
        .debug_reg_addr(debug_reg_addr), .debug_reg_data(debug_reg_data),
        .debug_pc(debug_pc), .debug_ir(debug_ir), .debug_cc(debug_cc),
        .retired(retired), .retired_pc(retired_pc), .retired_ir(retired_ir)
    );
    bob16_memory #(.ADDR_WIDTH(ADDR_WIDTH), .MEM_FILE(MEM_FILE)) ram (
        .clk(clk), .rst(rst), .valid(mem_valid), .write(mem_write),
        .addr(mem_addr), .wdata(mem_wdata), .ready(mem_ready),
        .rdata(mem_rdata), .error(mem_error)
    );
endmodule
`default_nettype wire
