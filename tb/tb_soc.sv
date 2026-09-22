`timescale 1ns/1ps
`default_nettype none
module tb_soc;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    logic tx_valid,tx_ready,rx_ready,halted,faulted,retired;
    logic [7:0] tx_data;
    logic [3:0] fault_code;
    logic [2:0] reg_addr=0,cc;
    logic [15:0] reg_data,pc,ir,ret_pc,ret_ir;
    integer cycles=0,received=0;
    logic [7:0] expected_bytes [0:3];
    assign tx_ready=(cycles%5)!=0;
    bob16_soc dut (
        .clk(clk),.rst(rst),.tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready),
        .rx_valid(1'b0),.rx_data(8'h00),.rx_ready(rx_ready),
        .halted(halted),.faulted(faulted),.fault_code(fault_code),
        .debug_reg_addr(reg_addr),.debug_reg_data(reg_data),.debug_pc(pc),.debug_ir(ir),
        .debug_cc(cc),.retired(retired),.retired_pc(ret_pc),.retired_ir(ret_ir)
    );
    always @(posedge clk) begin
        if(!rst) begin
            if(tx_valid && tx_ready) begin
                if(received>=4 || tx_data!==expected_bytes[received]) $fatal(1,"SoC TX mismatch");
                received<=received+1;
            end
            cycles<=cycles+1;
        end
    end
    initial begin
        expected_bytes[0]="b"; expected_bytes[1]="o";
        expected_bytes[2]="b"; expected_bytes[3]=8'h0a;
        repeat(4) @(negedge clk); rst=0;
        wait(halted); @(negedge clk);
        if(faulted || received!=4 || pc!==16'd3 || reg_data!==0 || cc!==3'b001)
            $fatal(1,"SoC final state mismatch");
        reg_addr=3'd7; #1;
        if(reg_data!==16'd2) $fatal(1,"SoC trap return register mismatch");
        $display("PASS integrated CPU + synchronous RAM: bob + LF"); $finish;
    end
    initial begin #100000; $fatal(1,"SoC timeout"); end
endmodule
`default_nettype wire
