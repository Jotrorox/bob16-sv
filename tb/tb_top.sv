`timescale 1ns/1ps
`default_nettype none
module tb_top;
    localparam integer CPB=10;
    logic clk=0,reset_n=0,uart_rx=1;
    always #5 clk=~clk;
    logic uart_tx,halted,faulted,tx_busy,rx_overrun,rx_frame_error;
    bob16_top #(.CLK_HZ(100_000_000),.BAUD(10_000_000)) dut (
        .clk(clk),.reset_n(reset_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .halted(halted),.faulted(faulted),.tx_busy(tx_busy),
        .rx_overrun(rx_overrun),.rx_frame_error(rx_frame_error)
    );
    logic [7:0] expected_bytes [0:3];
    logic [7:0] observed;
    integer received=0,b,i;
    // Behavioral serial decoder, independent of the RTL UART receiver.
    initial forever begin
        @(negedge uart_tx);
        repeat(CPB/2) @(posedge clk); #1;
        if(uart_tx!==0) $fatal(1,"Top UART bad start");
        for(b=0;b<8;b=b+1) begin
            repeat(CPB) @(posedge clk); #1; observed[b]=uart_tx;
        end
        repeat(CPB) @(posedge clk); #1;
        if(uart_tx!==1 || received>=4 || observed!==expected_bytes[received])
            $fatal(1,"Top UART output mismatch");
        received=received+1;
    end
    task automatic send_byte(input logic [7:0] value,input logic good_stop);
        integer j;
        begin
            @(negedge clk); uart_rx=0;
            repeat(CPB) @(negedge clk);
            for(j=0;j<8;j=j+1) begin uart_rx=value[j]; repeat(CPB) @(negedge clk); end
            uart_rx=good_stop;
            repeat(CPB) @(negedge clk); uart_rx=1;
        end
    endtask
    initial begin
        expected_bytes[0]="b"; expected_bytes[1]="o";
        expected_bytes[2]="b"; expected_bytes[3]=8'h0a;
        repeat(4) @(negedge clk); reset_n=1;
        wait(halted);
        while(tx_busy || received!=4) @(negedge clk);
        if(faulted || rx_overrun || rx_frame_error) $fatal(1,"Top initial status mismatch");
        // CPU is halted, so incoming bytes accumulate until the 16-byte FIFO fills.
        for(i=0;i<20;i=i+1) send_byte(8'(65+i),1'b1);
        repeat(3*CPB) @(negedge clk);
        if(!rx_overrun) $fatal(1,"Top did not flag RX FIFO overrun");
        send_byte(8'ha5,1'b0);
        repeat(3*CPB) @(negedge clk);
        if(!rx_frame_error) $fatal(1,"Top did not flag framing error");
        reset_n=0;
        repeat(4) @(negedge clk);
        if(rx_overrun || rx_frame_error || halted || faulted) $fatal(1,"Top reset failed");
        $display("PASS board-independent top: serial output, RX overrun/framing flags, reset");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Top timeout"); end
endmodule
`default_nettype wire
