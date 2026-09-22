`timescale 1ns/1ps
`default_nettype none
module tb_memory;
    logic clk=0, rst=1, valid=0, wr=0;
    always #5 clk=~clk;
    logic [15:0] addr=0,wdata=0,rdata;
    logic ready,error;
    bob16_memory #(.ADDR_WIDTH(4),.MEM_FILE("")) dut (
        .clk(clk),.rst(rst),.valid(valid),.write(wr),.addr(addr),.wdata(wdata),
        .ready(ready),.rdata(rdata),.error(error)
    );
    task automatic transfer(input logic write_op, input logic [15:0] a,d,
                            input logic want_error, input logic [15:0] want_data);
        begin
            @(negedge clk); valid=1; wr=write_op; addr=a; wdata=d;
            do @(posedge clk); while (!ready);
            if (error!==want_error) $fatal(1,"RAM error status mismatch");
            if (!write_op && !want_error && rdata!==want_data) $fatal(1,"RAM read mismatch");
            @(negedge clk); valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        transfer(0,0,0,0,0);
        transfer(1,3,16'habcd,0,0);
        transfer(0,3,0,0,16'habcd);
        transfer(1,16'h0013,16'hffff,1,0);
        transfer(0,16'h0013,0,1,0);
        transfer(0,3,0,0,16'habcd); // High address did not alias location 3.
        @(negedge clk); rst=1;
        repeat(3) @(negedge clk); rst=0;
        transfer(0,3,0,0,16'habcd); // CPU reset must not clear program/data memory.
        $display("PASS synchronous RAM, bounds and reset persistence"); $finish;
    end
    initial begin #10000; $fatal(1,"RAM timeout"); end
endmodule
`default_nettype wire
