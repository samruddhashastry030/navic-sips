// ---------------------------------------------------------------------------
// acc_core.sv
//
// The LSTM accelerator as a hardenable block.
//
// Why a wrapper: for the hierarchical layout the accelerator is hardened on
// its own as a macro. Its gate lookup tables are loaded with $readmemh at
// synthesis, so the LUT file paths must be fixed when the MACRO is hardened
// (set with SYNTH_PARAMETERS in flow/librelane/hier/acc_core/config.json),
// not when the chip instantiates it. The chip-level hierarchical build
// therefore instantiates acc_core with NO parameters (NAVIC_HIER defined);
// simulation and the flat build still pass LUT_SIG / LUT_TANH down as before.
//
// CLOCK GATE. The accelerator works for ~101,000 cycles out of every ~303
// million (one forecast per 10 s window) but its 1,122 flip-flops used to be
// clocked on every cycle -- an estimated ~1.6 mW for nothing (see
// experiments/README.md). It now runs on a gated clock, enabled only while
// it has something to do:
//
//   !rst_ni      the synchronous reset needs clock edges to take effect
//   start_i      the one-cycle start pulse from soc_bus must be seen
//   busy_o       any state but S_IDLE (feeding, computing, S_DONE)
//   out_valid_o  one more edge after S_DONE, so out_valid_o is cleared;
//                without it out_valid_o would stay high and soc_bus would
//                re-set accel_done after every read
//
// Every input the accelerator reacts to while idle is start_i, so nothing is
// missed: in_valid_i and w_dout_i only matter in states where busy_o is high.
//
// Silicon (SKY130_ICG defined by the LibreLane configs): the PDK's integrated
// clock-gating cell, a latch plus AND that cannot glitch, which STA and CTS
// recognise as a clock gate. Simulation: the same latch-and-AND behaviour.
//
// Logic behaviour is identical to the ungated block; only idle cycles change.
// ---------------------------------------------------------------------------

`default_nettype none

module acc_core #(
    parameter LUT_SIG  = "rtl/weights/lut_sigmoid.hex",
    parameter LUT_TANH = "rtl/weights/lut_tanh.hex"
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        start_i,
    output wire        busy_o,

    input  wire        in_valid_i,
    output wire        in_ready_o,
    input  wire [15:0] in_feat0_i,
    input  wire [15:0] in_feat1_i,

    output wire        w_csb_o,
    output wire [ 8:0] w_addr_o,
    input  wire [31:0] w_dout_i,

    output wire        out_valid_o,
    output wire [15:0] logit0_o,
    output wire [15:0] logit1_o,
    output wire [15:0] logit2_o,
    output wire [ 1:0] class_o
);

  wire clk_en = !rst_ni | start_i | busy_o | out_valid_o;
  wire gclk;

`ifdef SKY130_ICG
  (* keep *)
  sky130_fd_sc_hd__dlclkp_2 u_icg (
      .CLK  (clk_i),
      .GATE (clk_en),
      .GCLK (gclk)
  );
`else
  reg en_latched;
  always_latch
    if (!clk_i) en_latched = clk_en;   // transparent while the clock is low
  assign gclk = clk_i & en_latched;
`endif

  lstm_accel #(.LUT_SIG(LUT_SIG), .LUT_TANH(LUT_TANH)) u_lstm (
      .clk_i       (gclk),
      .rst_ni      (rst_ni),
      .start_i     (start_i),
      .busy_o      (busy_o),
      .in_valid_i  (in_valid_i),
      .in_ready_o  (in_ready_o),
      .in_feat0_i  (in_feat0_i),
      .in_feat1_i  (in_feat1_i),
      .w_csb_o     (w_csb_o),
      .w_addr_o    (w_addr_o),
      .w_dout_i    (w_dout_i),
      .out_valid_o (out_valid_o),
      .logit0_o    (logit0_o),
      .logit1_o    (logit1_o),
      .logit2_o    (logit2_o),
      .class_o     (class_o)
  );

endmodule

`default_nettype wire
