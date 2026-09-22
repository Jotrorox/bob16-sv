// Board-independent UART top. Supply the ACTUAL oscillator frequency and pins.
// No board pin numbers or FPGA part are assumed.
`default_nettype none
module bob16_top #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer BAUD=115_200,
    parameter integer ADDR_WIDTH=12,
    parameter MEM_FILE="programs/hello.hex",
    parameter logic [15:0] RESET_PC=16'h0000,
    parameter bit PUTS_NEWLINE=1'b1
) (
    input logic clk,
    input logic reset_n,  // External active-low reset, held low across clock edges.
    input logic uart_rx,
    output logic uart_tx,
    output logic halted, faulted, tx_busy,
    output logic rx_overrun, rx_frame_error // Sticky until reset.
);
    (* ASYNC_REG="TRUE" *) logic [1:0] reset_pipe;
    wire rst=reset_pipe[1];
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) reset_pipe<=2'b11;
        else reset_pipe<={reset_pipe[0],1'b0};
    end
    logic tx_valid, tx_ready, rx_valid, rx_ready;
    logic [7:0] tx_data, rx_data;
    logic serial_valid, serial_frame_error, fifo_ready;
    logic [7:0] serial_data;
    bob16_soc #(.ADDR_WIDTH(ADDR_WIDTH), .MEM_FILE(MEM_FILE),
        .RESET_PC(RESET_PC), .PUTS_NEWLINE(PUTS_NEWLINE)) soc (
        .clk(clk), .rst(rst), .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_ready(rx_ready),
        .halted(halted), .faulted(faulted), .fault_code(),
        .debug_reg_addr(3'd0), .debug_reg_data(), .debug_pc(), .debug_ir(),
        .debug_cc(), .retired(), .retired_pc(), .retired_ir()
    );
    bob16_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) tx_unit (
        .clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data),
        .ready(tx_ready), .tx(uart_tx), .busy(tx_busy)
    );
    bob16_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) rx_unit (
        .clk(clk), .rst(rst), .rx(uart_rx), .data(serial_data),
        .data_valid(serial_valid), .frame_error(serial_frame_error)
    );
    bob16_rx_fifo #(.DEPTH(16)) rx_fifo (
        .clk(clk), .rst(rst), .in_valid(serial_valid), .in_data(serial_data),
        .in_ready(fifo_ready), .out_valid(rx_valid), .out_data(rx_data), .out_ready(rx_ready)
    );
    always_ff @(posedge clk) begin
        if (rst) begin rx_overrun<=1'b0; rx_frame_error<=1'b0; end
        else begin
            if (serial_valid && !fifo_ready) rx_overrun<=1'b1;
            if (serial_frame_error) rx_frame_error<=1'b1;
        end
    end
endmodule
`default_nettype wire
