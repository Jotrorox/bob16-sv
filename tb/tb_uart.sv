`timescale 1ns/1ps
`default_nettype none
module tb_uart;
    localparam integer CPB=10;
    logic clk=0,rst=1,valid=0;
    always #5 clk=~clk;
    logic [7:0] data=0,received_data;
    logic ready,serial_tx,busy,received_valid,frame_error;
    logic loopback=1,manual_rx=1;
    wire serial_rx=loopback ? serial_tx : manual_rx;
    integer received=0,errors=0;
    bob16_uart_tx #(.CLK_HZ(100_000_000),.BAUD(10_000_000)) tx_dut (
        .clk(clk),.rst(rst),.valid(valid),.data(data),.ready(ready),.tx(serial_tx),.busy(busy)
    );
    bob16_uart_rx #(.CLK_HZ(100_000_000),.BAUD(10_000_000)) rx_dut (
        .clk(clk),.rst(rst),.rx(serial_rx),.data(received_data),
        .data_valid(received_valid),.frame_error(frame_error)
    );
    always @(posedge clk) if(!rst) begin
        if(received_valid) begin
            if(!loopback || received_data!==8'(received)) $fatal(1,"UART receive mismatch");
            received<=received+1;
        end
        if(frame_error) errors<=errors+1;
    end
    task automatic send_and_check(input logic [7:0] byte_value);
        integer b;
        begin
            @(negedge clk); data=byte_value; valid=1;
            do @(posedge clk); while(!ready);
            @(negedge clk); valid=0;
            repeat(CPB/2) @(negedge clk);
            if(serial_tx!==0) $fatal(1,"TX start bit mismatch");
            for(b=0;b<8;b=b+1) begin
                repeat(CPB) @(negedge clk);
                if(serial_tx!==byte_value[b]) $fatal(1,"TX bit %0d mismatch",b);
            end
            repeat(CPB) @(negedge clk);
            if(serial_tx!==1) $fatal(1,"TX stop bit mismatch");
            while(!ready) @(negedge clk);
        end
    endtask
    integer i;
    initial begin
        repeat(4) @(negedge clk); rst=0;
        for(i=0;i<256;i=i+1) send_and_check(8'(i));
        repeat(3*CPB) @(negedge clk);
        if(received!=256 || errors!=0) $fatal(1,"UART loopback count mismatch");
        loopback=0;
        // A one-clock glitch is shorter than the start-bit validation interval.
        @(negedge clk); manual_rx=0;
        @(negedge clk); manual_rx=1;
        repeat(3*CPB) @(negedge clk);
        if(errors!=0) $fatal(1,"False-start glitch was not rejected");
        // Hold RX low for a break: exactly one frame error, no data delivery.
        manual_rx=0;
        repeat(30*CPB) @(negedge clk);
        manual_rx=1;
        repeat(3*CPB) @(negedge clk);
        if(errors!=1 || received!=256) $fatal(1,"UART BREAK handling mismatch");
        $display("PASS UART: all 256 bytes, sampled TX waveform, glitch and BREAK"); $finish;
    end
    initial begin #1000000; $fatal(1,"UART timeout"); end
endmodule
`default_nettype wire
