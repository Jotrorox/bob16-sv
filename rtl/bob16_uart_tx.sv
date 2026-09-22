`default_nettype none
module bob16_uart_tx #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer BAUD=115_200
) (
    input logic clk, rst,
    input logic valid,
    input logic [7:0] data,
    output logic ready,
    output logic tx,
    output logic busy
);
    localparam integer CPB=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(CPB<2) ? 1 : $clog2(CPB);
    logic [CW-1:0] count;
    logic [3:0] bit_index;
    logic [9:0] frame;
    assign ready=!busy && !rst;
    assign tx=busy ? frame[0] : 1'b1;
    always_ff @(posedge clk) begin
        if (rst) begin
            busy<=1'b0; count<='0; bit_index<=4'd0; frame<=10'h3ff;
        end else if (!busy) begin
            if (valid) begin
                frame<={1'b1, data, 1'b0}; busy<=1'b1;
                count<=CW'(CPB-1); bit_index<=4'd0;
            end
        end else if (count==0) begin
            count<=CW'(CPB-1);
            if (bit_index==4'd9) busy<=1'b0;
            else begin frame<={1'b1, frame[9:1]}; bit_index<=bit_index+4'd1; end
        end else count<=count-1'b1;
    end
`ifndef SYNTHESIS
    initial if (CPB<4) $fatal(1, "UART requires >=4 clock cycles/bit");
`endif
endmodule
`default_nettype wire
