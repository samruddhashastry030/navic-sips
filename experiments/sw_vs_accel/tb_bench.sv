// tb_bench.sv -- runs bench.c on the full chip RTL and prints its reports.
`timescale 1ns/1ps
`default_nettype none
module tb_bench;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wire [31:0] rd; wire ack, cs, sclk, mosi, irq, rdy, flt, tx;
  navic_sips_top #(.FW_HEX("bench.hex"), .LUT_SIG("lut_sigmoid.hex"),
                   .LUT_TANH("lut_tanh.hex")) dut (
    .clk_i(clk), .rst_ni(rst_n), .bus_sel_i(1'b0), .bus_we_i(1'b0),
    .bus_addr_i(5'd0), .bus_wdata_i(32'd0), .bus_rdata_o(rd), .bus_ack_o(ack),
    .iq_valid_i(1'b0), .iq_i_i(16'd0), .iq_q_i(16'd0),
    .spi_cs_no(cs), .spi_sclk_o(sclk), .spi_mosi_o(mosi), .spi_miso_i(1'b0),
    .bypass_pin_i(1'b0), .irq_o(irq), .ready_pin_o(rdy), .fault_pin_o(flt),
    .uart_tx_o(tx));
  defparam dut.u_bus.ROM_WORDS = 1024;
  initial $readmemh("wimage.hex", dut.u_weight_sram.mem);   // weights preloaded
  integer cyc = 0; always @(posedge clk) cyc = cyc + 1;
  always @(posedge clk)
    if (dut.mem_valid && dut.mem_ready && |dut.mem_wstrb)
      case (dut.mem_addr)
        32'h3000_0020: $write("cycles %0d ", dut.mem_wdata);
        32'h3000_0024: $write("logits %0d %0d ", $signed(dut.mem_wdata[15:0]),
                              $signed(dut.mem_wdata[31:16]));
        32'h3000_0028: begin
                         $display("%0d  vector %0d", $signed(dut.mem_wdata[15:0]),
                                  dut.mem_wdata[31:16]);
                         $fflush;
                       end
        32'h3000_002C: begin $display("bench done at cycle %0d", cyc); $finish; end
        default: ;
      endcase
  initial begin repeat (5) @(posedge clk); rst_n = 1; end
  initial begin #200_000_000; $display("FAIL: bench timeout"); $finish; end
endmodule
`default_nettype wire
