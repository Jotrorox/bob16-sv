// 8N1 receiver; data_valid/frame_error are one-cycle pulses. Feed a FIFO.
`default_nettype none
module bob16_uart_rx #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer BAUD=115_200
) (
    input logic clk, rst, rx,
    output logic [7:0] data,
    output logic data_valid,
    output logic frame_error
);
    localparam integer CPB=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(CPB<2) ? 1 : $clog2(CPB);
    typedef enum logic [2:0] {IDLE, START, BITS, STOP, RECOVER} state_t;
    state_t state;
    (* ASYNC_REG="TRUE" *) logic rx_meta, rx_sync;
    logic [CW-1:0] count;
    logic [2:0] bit_index;
    logic [7:0] shift;
    always_ff @(posedge clk) begin
        if (rst) begin rx_meta<=1'b1; rx_sync<=1'b1; end
        else begin rx_meta<=rx; rx_sync<=rx_meta; end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            state<=IDLE; count<='0; bit_index<=3'd0;
            shift<=8'h00; data<=8'h00; data_valid<=1'b0; frame_error<=1'b0;
        end else begin
            data_valid<=1'b0; frame_error<=1'b0;
            case (state)
                IDLE: if (!rx_sync) begin count<=CW'(CPB/2-1); state<=START; end
                START: if (count!=0) count<=count-1'b1;
                    else if (rx_sync) state<=IDLE; // False start.
                    else begin count<=CW'(CPB-1); bit_index<=3'd0; state<=BITS; end
                BITS: if (count!=0) count<=count-1'b1;
                    else begin
                        shift[bit_index]<=rx_sync; count<=CW'(CPB-1);
                        if (bit_index==3'd7) state<=STOP;
                        else bit_index<=bit_index+3'd1;
                    end
                STOP: if (count!=0) count<=count-1'b1;
                    else if (rx_sync) begin data<=shift; data_valid<=1'b1; state<=IDLE; end
                    else begin frame_error<=1'b1; state<=RECOVER; end
                // Do not interpret a sustained BREAK as repeated data frames.
                RECOVER: if (rx_sync) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial if (CPB<4) $fatal(1, "UART requires >=4 clock cycles/bit");
`endif
endmodule
`default_nettype wire
