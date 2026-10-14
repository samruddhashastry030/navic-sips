// measure.sv -- rides alongside tb/top/tb_top.sv for full_chip.sh.
//
// Grows the boot ROM to 4 KB (the software LSTM and its gate tables do not
// fit in 1 KB) and prints what the MEASURE firmware reports: the cycles
// infer() took and the logits it produced. Observation only.
`timescale 1ns/1ps
module measure;
  defparam tb_top.dut.u_bus.ROM_WORDS = 1024;
  reg [31:0] cyc_q;
  always @(posedge tb_top.clk)
    if (tb_top.dut.mem_valid && tb_top.dut.mem_ready && |tb_top.dut.mem_wstrb)
      case (tb_top.dut.mem_addr)
        32'h3000_0020: begin cyc_q = tb_top.dut.mem_wdata;
                       $display("MEASURE infer_cycles %0d", cyc_q); end
        32'h3000_0024: $display("MEASURE logit0 %0d logit1 %0d",
                         $signed(tb_top.dut.mem_wdata[15:0]),
                         $signed(tb_top.dut.mem_wdata[31:16]));
        32'h3000_0028: $display("MEASURE logit2 %0d",
                         $signed(tb_top.dut.mem_wdata[15:0]));
        default: ;
      endcase
endmodule
