// Small register-based FIFO. DEPTH must be a power of two >=2.
`default_nettype none
module bob16_rx_fifo #(parameter integer DEPTH=16) (
    input logic clk, rst,
    input logic in_valid,
    input logic [7:0] in_data,
    output logic in_ready,
    output logic out_valid,
    output logic [7:0] out_data,
    input logic out_ready
);
    localparam integer AW=$clog2(DEPTH);
    logic [7:0] buf_mem [0:DEPTH-1];
    logic [AW-1:0] wr_ptr, rd_ptr;
    logic [AW:0] count;
    wire pop=out_valid && out_ready;
    wire push=in_valid && in_ready;
    assign out_valid=(count!=0) && !rst;
    assign in_ready=((count!=DEPTH) || pop) && !rst;
    assign out_data=buf_mem[rd_ptr];
    always_ff @(posedge clk) begin
        if (rst) begin wr_ptr<='0; rd_ptr<='0; count<='0; end
        else begin
            if (push) begin buf_mem[wr_ptr]<=in_data; wr_ptr<=wr_ptr+1'b1; end
            if (pop) rd_ptr<=rd_ptr+1'b1;
            case ({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: begin end
            endcase
        end
    end
`ifndef SYNTHESIS
    initial if (DEPTH<2 || (DEPTH & (DEPTH-1))!=0)
        $fatal(1, "FIFO DEPTH must be a power of two >=2");
`endif
endmodule
`default_nettype wire
