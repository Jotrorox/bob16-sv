`timescale 1ns/1ps
`default_nettype none
module tb_fifo;
    logic clk=0,rst=1,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    logic [7:0] in_data=0,out_data;
    logic in_ready,out_valid;
    bob16_rx_fifo #(.DEPTH(16)) dut (
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_data(in_data),.in_ready(in_ready),
        .out_valid(out_valid),.out_data(out_data),.out_ready(out_ready)
    );
    logic [7:0] reference_data [0:15];
    integer head=0,tail=0,count=0,read_count=0,write_count=0;
    logic pop_now,push_now;
    always @(posedge clk) begin
        if(rst) begin head=0; tail=0; count=0; read_count=0; write_count=0; end
        else begin
            if(out_valid!==(count!=0)) $fatal(1,"FIFO valid mismatch");
            pop_now=(count!=0)&&out_ready;
            if(in_ready!==((count<16)||pop_now)) $fatal(1,"FIFO ready mismatch");
            push_now=in_valid&&in_ready;
            if(pop_now) begin
                if(out_data!==reference_data[head]) $fatal(1,"FIFO data/order mismatch");
                head=(head+1)%16; read_count=read_count+1;
            end
            if(push_now) begin
                reference_data[tail]=in_data; tail=(tail+1)%16; write_count=write_count+1;
            end
            count=count+int'(push_now)-int'(pop_now);
        end
    end
    logic [31:0] random_bits=32'hb0b160ab;
    integer i;
    initial begin
        repeat(4) @(negedge clk); rst=0;
        // Full, empty, wraparound and simultaneous push/pop at full capacity.
        for(i=0;i<20;i=i+1) begin @(negedge clk); in_valid=1; in_data=8'(i); end
        for(i=0;i<20;i=i+1) begin @(negedge clk); out_ready=1; in_data=8'(i+20); end
        for(i=0;i<1000;i=i+1) begin
            @(negedge clk);
            random_bits={random_bits[30:0],random_bits[31]^random_bits[21]^random_bits[1]^random_bits[0]};
            in_valid=random_bits[4]; out_ready=random_bits[8]; in_data=random_bits[23:16];
        end
        @(negedge clk); in_valid=0; out_ready=1;
        repeat(20) @(negedge clk);
        if(count!=0 || read_count!=write_count || read_count<100) $fatal(1,"FIFO totals mismatch");
        $display("PASS FIFO: %0d bytes, full/empty/wrap/simultaneous operations",read_count); $finish;
    end
    initial begin #100000; $fatal(1,"FIFO timeout"); end
endmodule
`default_nettype wire
