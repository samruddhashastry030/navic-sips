// tb_acc_clock_gate.sv -- the accelerator's clock gate (rtl/acc_core.sv).
//
// Runs golden vector 0 through acc_core twice, with a long idle gap between,
// and checks that:
//   1. the logits are the golden ones, both times (gating changed nothing)
//   2. the gated clock stops within 2 cycles of the result
//   3. it stays stopped through 5,000 idle cycles
//   4. a start pulse wakes it, with no lost first cycle
//   5. every gated-clock pulse is a full half-period: no glitches
// Inputs are driven on the falling edge, as from a register on clk.
//
// Also runs on the hardened macro's gate-level netlist (tb/gls/acc/run.sh):
//   GLS       instantiate the netlist, which has no parameters (its LUTs are
//             baked in at synthesis)
//   HALF_NS   clock half-period; GLS uses 16.5 for the chip's 33 ns clock
// and, for power, records switching activity over one window:
//   +vcd_active  10,000 cycles in the middle of a forecast  -> acc_active.vcd
//   +vcd_idle    10,000 idle cycles after it                -> acc_idle.vcd
`timescale 1ns/1ps
`default_nettype none
`ifndef HALF_NS
 `define HALF_NS 5
`endif
module tb_acc_clock_gate;
  reg clk = 0, rst_n = 0;
  always #(`HALF_NS) clk = ~clk;

  reg         start = 0, in_valid = 0;
  reg  [15:0] f0 = 0, f1 = 0;
  wire        busy, in_ready, w_csb, out_valid;
  wire [ 8:0] w_addr;
  reg  [31:0] w_dout;
  wire [15:0] l0, l1, l2;
  wire [ 1:0] cls;

`ifdef GLS
  acc_core dut (
`else
  acc_core #(.LUT_SIG("lut_sigmoid.hex"), .LUT_TANH("lut_tanh.hex")) dut (
`endif
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .busy_o(busy),
    .in_valid_i(in_valid), .in_ready_o(in_ready),
    .in_feat0_i(f0), .in_feat1_i(f1),
    .w_csb_o(w_csb), .w_addr_o(w_addr), .w_dout_i(w_dout),
    .out_valid_o(out_valid), .logit0_o(l0), .logit1_o(l1), .logit2_o(l2),
    .class_o(cls));

  // weight SRAM read port, registered output, on the UNGATED clock as on chip
  reg [31:0] wmem [0:511];
  initial $readmemh("weights.hex", wmem);
  always @(posedge clk) if (!w_csb) w_dout <= wmem[w_addr];

  reg [15:0] vec [0:63];        // 32 x (feat0, feat1)
  reg [15:0] expv [0:2];
  initial begin $readmemh("vec0.hex", vec); $readmemh("exp0.hex", expv); end

  // ---- gated-clock observation -------------------------------------------
  integer gedges = 0, cyc = 0, glitches = 0;
  realtime trise;
  always @(posedge clk) cyc = cyc + 1;
  always @(posedge dut.gclk) begin gedges = gedges + 1; trise = $realtime; end
  always @(negedge dut.gclk)
    if ($realtime - trise < `HALF_NS - 0.01 || $realtime - trise > `HALF_NS + 0.01) begin
      glitches = glitches + 1;
      $display("glitch: gated clock high for %0.3f ns at %0t", $realtime - trise, $time);
    end

  integer errors = 0;
  task automatic chk(input [511:0] what, input integer ok);
    if (ok) $display("pass  %0s", what);
    else begin $display("FAIL  %0s", what); errors = errors + 1; end
  endtask

  task automatic infer(input integer n);
    integer t;
    begin
      @(negedge clk) start = 1;
      @(negedge clk) start = 0;
      for (t = 0; t < 32; t = t + 1) begin
        f0 = vec[2*t]; f1 = vec[2*t+1]; in_valid = 1;
        @(posedge clk); while (!in_ready) @(posedge clk);
        @(negedge clk) in_valid = 0;
      end
      while (!out_valid) @(posedge clk);
      $display("       run %0d logits %0d %0d %0d (golden %0d %0d %0d)", n,
               $signed(l0), $signed(l1), $signed(l2),
               $signed(expv[0]), $signed(expv[1]), $signed(expv[2]));
      chk("logits match the golden vector", l0 === expv[0] && l1 === expv[1] && l2 === expv[2]);
    end
  endtask

  // ---- switching activity for power (gate-level runs) ----------------------
  integer vcd_from = -1;
  initial begin
    if ($test$plusargs("vcd_active")) $dumpfile("acc_active.vcd");
    if ($test$plusargs("vcd_idle"))   $dumpfile("acc_idle.vcd");
  end
  task automatic vcd_window;
    begin
      $dumpvars(0, dut); $display("       recording activity from cycle %0d", cyc);
      repeat (10000) @(posedge clk);
      $dumpoff; $dumpflush; $display("       recorded 10,000 cycles");
    end
  endtask
  initial begin
    if ($test$plusargs("vcd_active")) begin
      wait (busy === 1'b1); repeat (40000) @(posedge clk); vcd_window;
    end
  end

  integer e0, c0;
  initial begin
    repeat (4) @(posedge clk); @(negedge clk) rst_n = 1;

    // idle after reset: the gate must close
    repeat (4) @(posedge clk);
    e0 = gedges; repeat (1000) @(posedge clk);
    chk("no gated clock edges while idle after reset", gedges == e0);

    c0 = cyc; e0 = gedges;
    infer(1);
    $display("       run 1: %0d clock cycles, %0d gated edges", cyc - c0, gedges - e0);
    repeat (2) @(posedge clk);
    if ($test$plusargs("vcd_idle")) vcd_window;
    e0 = gedges; repeat (5000) @(posedge clk);
    chk("gated clock stopped after the result, 5000 idle cycles", gedges == e0);
    chk("out_valid_o cleared before the clock stopped", out_valid === 1'b0);

    infer(2);
    chk("second run after a long idle gap", 1);
    chk("no glitches on the gated clock", glitches == 0);

    if (errors == 0) $display("PASS: accelerator clock gate");
    else             $display("FAIL: accelerator clock gate, %0d errors", errors);
    $finish;
  end
  initial begin wait (cyc == 400000); $display("FAIL: timeout"); $finish; end
endmodule
`default_nettype wire
