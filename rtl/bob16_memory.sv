// Synchronous, single-port, word-addressed RAM + one-outstanding response adapter.
// Contents initialize at FPGA configuration, NOT on CPU reset.
`default_nettype none
module bob16_memory #(
    parameter integer ADDR_WIDTH = 12, // 12=8 KiB, 16=128 KiB; supported range 1..16.
    parameter MEM_FILE = ""
) (
    input  logic clk, rst,
    input  logic valid, write,
    input  logic [15:0] addr, wdata,
    output logic ready,
    output logic [15:0] rdata,
    output logic error
);
    localparam integer DEPTH = 1 << ADDR_WIDTH;
    (* ram_style = "block" *) logic [15:0] mem [0:DEPTH-1];
    logic pending, bad_latched;
    wire out_of_range = ((addr >> ADDR_WIDTH) != 16'h0000);
    wire launch = valid && !pending && !rst;
    assign ready = pending && !rst;
    assign error = bad_latched;
    integer i;
    initial begin
        for (i=0; i<DEPTH; i=i+1) mem[i]=16'h0000;
        if (MEM_FILE != "") $readmemh(MEM_FILE, mem);
    end
    // No reset of the array or read output: preserves block RAM inference.
    // Plain clocked always also permits the separate configuration-time initializer.
    always @(posedge clk) begin
        if (launch && !out_of_range) begin
            if (write) mem[addr[ADDR_WIDTH-1:0]] <= wdata;
            else rdata <= mem[addr[ADDR_WIDTH-1:0]];
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin pending<=1'b0; bad_latched<=1'b0; end
        else if (pending) pending<=1'b0;
        else if (valid) begin pending<=1'b1; bad_latched<=out_of_range; end
    end
`ifndef SYNTHESIS
    initial if (ADDR_WIDTH<1 || ADDR_WIDTH>16) $fatal(1, "ADDR_WIDTH must be 1..16");
`endif
endmodule
`default_nettype wire
