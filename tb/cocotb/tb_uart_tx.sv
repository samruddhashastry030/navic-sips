// -----------------------------------------------------------------------------
// tb_uart_tx.sv -- thin SystemVerilog wrapper used as the cocotb toplevel.
//
// Parameters are set here rather than via simulator -G / -P flags, because
// that syntax differs between Verilator, Icarus, Questa, VCS and Xcelium,
// and fails SILENTLY when you get it wrong. A wrapper is portable and
// explicit. Use this pattern for every parameterised block in the project.
// -----------------------------------------------------------------------------

module tb_uart_tx #(
    parameter int unsigned CLK_FREQ_HZ = 1_000_000,
    parameter int unsigned BAUD_RATE   = 100_000    // -> 10 cycles per bit
) (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic [7:0] data_i,
    input  logic       valid_i,
    output logic       ready_o,
    output logic       tx_o
);

  uart_tx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .BAUD_RATE  (BAUD_RATE)
  ) u_dut (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .data_i (data_i),
      .valid_i(valid_i),
      .ready_o(ready_o),
      .tx_o   (tx_o)
  );

endmodule
