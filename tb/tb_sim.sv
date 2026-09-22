`timescale 1ns/1ps
`default_nettype none

// Fast console runner for the uploaded bob16_soc.
// This observes the byte-stream handshake, NOT the serialized UART wire.
// Uses Icarus Verilog's $finish_and_return to propagate errors to make.
//
//   vvp build/sim/tb_sim.vvp +HEX=programs/hello.hex
//   vvp build/sim/tb_sim.vvp +HEX=programs/echo.hex +INPUT=input.txt
//   Optional: +MAX_CYCLES=1000000 (positive signed 32-bit integer).
module tb_sim;
    localparam integer ADDR_WIDTH = 12;
    localparam integer STDERR = 32'h80000002;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic tx_valid;
    logic [7:0] tx_data;
    wire tx_ready = 1'b1;
    logic rx_valid = 1'b0;
    logic [7:0] rx_data = 8'h00;
    logic rx_ready;
    logic halted, faulted;
    logic [3:0] fault_code;
    logic [15:0] debug_pc, debug_ir;

    string hex_file = "programs/hello.hex";
    string input_file = "";
    integer max_cycles = 1000000;
    integer cycles = 0;
    integer hex_fd;
    integer input_fd = 0;
    integer ignored;
    bit rx_accepted;

    bob16_soc #(
        .ADDR_WIDTH(ADDR_WIDTH),
        // Disable the RAM's default time-zero file load. Load +HEX below,
        // after its zero-initialization has completed, with reset asserted.
        .MEM_FILE("")
    ) dut (
        .clk(clk), .rst(rst),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_ready(rx_ready),
        .halted(halted), .faulted(faulted), .fault_code(fault_code),
        .debug_reg_addr(3'd0), .debug_reg_data(),
        .debug_pc(debug_pc), .debug_ir(debug_ir), .debug_cc(),
        .retired(), .retired_pc(), .retired_ir()
    );

    task automatic fail(input string message);
        begin
            $fflush();
            $fdisplay(STDERR, "\n[SIM] ERROR: %s", message);
            if (input_fd != 0) $fclose(input_fd);
            $finish_and_return(1);
        end
    endtask

    // Called only on falling edges, so data/valid are stable when the CPU
    // samples them on a rising edge. EOF is NOT sent as a character.
    task automatic advance_input;
        integer value;
        begin
            value = -1;
            if (input_fd != 0) value = $fgetc(input_fd);
            if (value == -1) begin
                rx_valid = 1'b0;
                rx_data = 8'h00;
                if (input_fd != 0) begin
                    $fclose(input_fd);
                    input_fd = 0;
                end
            end else begin
                rx_valid = 1'b1;
                rx_data = value[7:0];
            end
        end
    endtask

    initial begin
        ignored = $value$plusargs("HEX=%s", hex_file);
        ignored = $value$plusargs("INPUT=%s", input_file);
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)
            && $test$plusargs("MAX_CYCLES="))
            fail("Invalid +MAX_CYCLES; supply a positive integer.");
        if ((^max_cycles === 1'bx) || max_cycles <= 0)
            fail("MAX_CYCLES must be an integer from 1 to 2147483647.");

        // $readmemh does not return an open status, so check the file first.
        hex_fd = $fopen(hex_file, "r");
        if (hex_fd == 0)
            fail($sformatf("Cannot open HEX file '%s'.", hex_file));
        $fclose(hex_fd);

        if (input_file != "") begin
            input_fd = $fopen(input_file, "rb");
            if (input_fd == 0)
                fail($sformatf("Cannot open input file '%s'.", input_file));
        end

        // Avoid racing bob16_memory's initial zero-fill at simulation time 0.
        @(negedge clk);
        $readmemh(hex_file, dut.ram.mem);
        repeat (3) @(negedge clk);
        advance_input();
        rst = 1'b0;
        $fdisplay(STDERR, "[SIM] Running %s (limit: %0d cycles)",
                  hex_file, max_cycles);

        forever begin
            @(posedge clk);
            cycles = cycles + 1;

            // Sample the values participating in THIS rising-edge transfer,
            // before the CPU's nonblocking assignments change its state.
            if (tx_valid && tx_ready) begin
                $write("%c", tx_data);
                $fflush();
            end
            rx_accepted = rx_valid && rx_ready;

            // The CPU's registered status has settled by the falling edge.
            @(negedge clk);
            if (faulted)
                fail($sformatf("CPU fault %0d after %0d cycles; PC=%04h IR=%04h.",
                               fault_code, cycles, debug_pc, debug_ir));
            if (halted) begin
                $fflush();
                $fdisplay(STDERR, "\n[SIM] CPU halted normally after %0d cycles.",
                          cycles);
                if (input_fd != 0) $fclose(input_fd);
                $finish_and_return(0);
            end
            if (cycles >= max_cycles)
                fail($sformatf("Cycle limit reached (%0d); PC=%04h IR=%04h.",
                               max_cycles, debug_pc, debug_ir));

            if (rx_accepted) advance_input();
            if (rx_ready && !rx_valid) begin
                if (input_file == "")
                    fail("CPU needs console input. Use make run INPUT=input.txt or +INPUT=input.txt.");
                else
                    fail($sformatf("Input file '%s' ended, but the CPU needs another byte. Check the newline or GETS length.",
                                   input_file));
            end
        end
    end
endmodule
`default_nettype wire
