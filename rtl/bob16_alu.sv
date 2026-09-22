// BOB-16 architecture by misterbob (somerandomviolinkid).
// FPGA reimplementation: combinational 16-bit ALU, modulo-65536 arithmetic.
`default_nettype none
module bob16_alu (
    input  logic [3:0]  op,
    input  logic [15:0] a, b,
    output logic [15:0] result
);
    always_comb begin
        case (op)
            4'h1: result = a + b;
            4'h2: result = a & b;
            4'h3: result = ~a;
            default: result = 16'h0000;
        endcase
    end
endmodule
`default_nettype wire
