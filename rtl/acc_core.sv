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
// Behaviour is identical to the lstm_accel instance it replaces.
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

  lstm_accel #(.LUT_SIG(LUT_SIG), .LUT_TANH(LUT_TANH)) u_lstm (
      .clk_i       (clk_i),
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
