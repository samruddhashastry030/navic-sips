// sram_models.sv -- SIMULATION ONLY behavioural models of the two SKY130
// SRAM macros, with the same module names and ports as the PDK. Registered
// output, like the real macros: address sampled at one edge, dout valid
// after it. Never include this file in synthesis -- the flow uses the real
// macros from the PDK.
`default_nettype none
module sky130_sram_2kbyte_1rw1r_32x512_8 (
    input  wire        clk0, csb0, web0, input wire [3:0] wmask0,
    input  wire [ 8:0] addr0, input wire [31:0] din0, output reg [31:0] dout0,
    input  wire        clk1, csb1, input wire [8:0] addr1, output reg [31:0] dout1);
  reg [31:0] mem [0:511];
  integer b;
  always @(posedge clk0) if (!csb0) begin
    if (!web0) begin for (b = 0; b < 4; b = b + 1)
                 if (wmask0[b]) mem[addr0][8*b +: 8] <= din0[8*b +: 8]; end
    else dout0 <= mem[addr0];
  end
  always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
endmodule

module sky130_sram_1kbyte_1rw1r_32x256_8 (
    input  wire        clk0, csb0, web0, input wire [3:0] wmask0,
    input  wire [ 7:0] addr0, input wire [31:0] din0, output reg [31:0] dout0,
    input  wire        clk1, csb1, input wire [7:0] addr1, output reg [31:0] dout1);
  reg [31:0] mem [0:255];
  integer b;
  always @(posedge clk0) if (!csb0) begin
    if (!web0) begin for (b = 0; b < 4; b = b + 1)
                 if (wmask0[b]) mem[addr0][8*b +: 8] <= din0[8*b +: 8]; end
    else dout0 <= mem[addr0];
  end
  always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
endmodule
`default_nettype wire
