// ---------------------------------------------------------------------------
// navic_sips_top.sv
//
// TOP-LEVEL STUB — this is a FLOORPLAN EXPERIMENT, not a working chip.
//
// PURPOSE
// -------
// Every block below that isn't already written is an empty stub with the
// right ports. The design does nothing. The point is to push a chip-shaped
// thing through LibreLane NOW and find out what we don't know about:
//
//   - SRAM macro placement (the flow has never seen a macro)
//   - power grid over macros
//   - chip-level congestion with 11 blocks instead of 1
//   - timing paths that cross a memory
//   - how big the die actually wants to be
//
// Two 2KB macros are ~570,000 um2. Our three real blocks together are
// ~18,000 um2. Memory dominates by 30x, so the floorplan is two macros with
// logic tucked around them — not the other way round. This run tells us
// whether that's as awkward as it sounds.
//
// This is the December milestone in miniature. Doing it in August means
// meeting these problems on a design where nothing works yet, so nothing
// can break.
//
// REAL BLOCKS (already written and verified)
//   navic_sips_regs, spi_master
//
// STUBS (ports only — replace as each is written)
//   sicu, lstm_accel, cordic, picorv32_stub, bootrom, uart_tx_stub
//
// NOTE ON uart_tx: the real uart_tx.sv exists but its full port list isn't
// captured here. Replace uart_tx_stub with the real instance and fix the
// connections — that's a five-minute job and a good first check.
// ---------------------------------------------------------------------------

`default_nettype none

module navic_sips_top (
    input  wire        clk_i,
    input  wire        rst_ni,

    // ---- host bus (from the receiver baseband) ---------------------------
    input  wire        bus_sel_i,
    input  wire        bus_we_i,
    input  wire [ 4:0] bus_addr_i,
    input  wire [31:0] bus_wdata_i,
    output wire [31:0] bus_rdata_o,
    output wire        bus_ack_o,

    // ---- prompt I/Q in, from the tracking channel ------------------------
    input  wire        iq_valid_i,
    input  wire [15:0] iq_i_i,
    input  wire [15:0] iq_q_i,

    // ---- SPI to external weight Flash ------------------------------------
    output wire        spi_cs_no,
    output wire        spi_sclk_o,
    output wire        spi_mosi_o,
    input  wire        spi_miso_i,

    // ---- pads --------------------------------------------------------------
    input  wire        bypass_pin_i,
    output wire        irq_o,
    output wire        ready_pin_o,
    output wire        fault_pin_o,
    output wire        uart_tx_o
);

  // -------------------------------------------------------------------------
  // Internal nets
  // -------------------------------------------------------------------------
  wire        enable, bist_start, soft_reset;

  wire        idx_valid;
  wire [15:0] s4_val, sphi_val;

  wire        pred_valid;
  wire [ 1:0] pred_class;
  wire [ 3:0] pred_conf;

  wire [ 2:0] loop_pll_bw;
  wire        loop_fll_en;
  wire [ 2:0] loop_t_coh;
  wire [ 1:0] loop_band_pref;

  wire        weights_ready, weights_fault;
  wire        bist_done, bist_pass;

  // CORDIC
  wire        cordic_valid;
  wire [15:0] cordic_phase;

  // weight SRAM port A (write during load, read during inference)
  wire        wsram_clk    = clk_i;
  wire        wsram_csb0;
  wire        wsram_web0;
  wire [ 3:0] wsram_wmask0;
  wire [ 8:0] wsram_addr0;
  wire [31:0] wsram_din0;
  wire [31:0] wsram_dout0;
  wire        wsram_csb1;
  wire [ 8:0] wsram_addr1;
  wire [31:0] wsram_dout1;

  // event log SRAM
  wire        esram_csb0;
  wire        esram_web0;
  wire [ 3:0] esram_wmask0;
  wire [ 7:0] esram_addr0;
  wire [31:0] esram_din0;
  wire [31:0] esram_dout0;
  wire        esram_csb1;
  wire [ 7:0] esram_addr1;

  // SPI arbitration
  wire        spi_start, spi_hold_cs, spi_done;
  wire [ 7:0] spi_tx, spi_rx;

  // -------------------------------------------------------------------------
  // REAL: host register block
  // -------------------------------------------------------------------------
  navic_sips_regs u_regs (
      .clk_i             (clk_i),
      .rst_ni            (rst_ni),
      .bus_sel_i         (bus_sel_i),
      .bus_we_i          (bus_we_i),
      .bus_addr_i        (bus_addr_i),
      .bus_wdata_i       (bus_wdata_i),
      .bus_rdata_o       (bus_rdata_o),
      .bus_ack_o         (bus_ack_o),
      .idx_valid_i       (idx_valid),
      .s4_i              (s4_val),
      .sphi_i            (sphi_val),
      .pred_valid_i      (pred_valid),
      .pred_class_i      (pred_class),
      .pred_conf_i       (pred_conf),
      .loop_pll_bw_i     (loop_pll_bw),
      .loop_fll_en_i     (loop_fll_en),
      .loop_t_coh_i      (loop_t_coh),
      .loop_band_pref_i  (loop_band_pref),
      .weights_ready_i   (weights_ready),
      .weights_fault_i   (weights_fault),
      .bist_done_i       (bist_done),
      .bist_pass_i       (bist_pass),
      .enable_o          (enable),
      .bist_start_o      (bist_start),
      .soft_reset_o      (soft_reset),
      .bypass_pin_i      (bypass_pin_i),
      .irq_o             (irq_o),
      .ready_pin_o       (ready_pin_o),
      .fault_pin_o       (fault_pin_o)
  );

  // -------------------------------------------------------------------------
  // REAL: SPI master
  // -------------------------------------------------------------------------
  spi_master #(.DIV_WIDTH(8), .DATA_WIDTH(8)) u_spi (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .clk_div_i (8'd4),
      .start_i   (spi_start),
      .hold_cs_i (spi_hold_cs),
      .tx_data_i (spi_tx),
      .rx_data_o (spi_rx),
      .busy_o    (),
      .done_o    (spi_done),
      .cs_no     (spi_cs_no),
      .sclk_o    (spi_sclk_o),
      .mosi_o    (spi_mosi_o),
      .miso_i    (spi_miso_i)
  );

  // -------------------------------------------------------------------------
  // STUBS — replace each as it is written
  // -------------------------------------------------------------------------
  cordic_stub u_cordic (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .valid_i   (iq_valid_i),
      .i_i       (iq_i_i),
      .q_i       (iq_q_i),
      .valid_o   (cordic_valid),
      .phase_o   (cordic_phase)
  );

  sicu_stub u_sicu (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .enable_i     (enable),
      .iq_valid_i   (iq_valid_i),
      .i_i          (iq_i_i),
      .q_i          (iq_q_i),
      .phase_valid_i(cordic_valid),
      .phase_i      (cordic_phase),
      .idx_valid_o  (idx_valid),
      .s4_o         (s4_val),
      .sphi_o       (sphi_val)
  );

  lstm_accel_stub u_lstm (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .enable_i     (enable),
      .idx_valid_i  (idx_valid),
      .s4_i         (s4_val),
      .sphi_i       (sphi_val),
      .w_csb_o      (wsram_csb1),
      .w_addr_o     (wsram_addr1),
      .w_data_i     (wsram_dout1),
      .pred_valid_o (pred_valid),
      .pred_class_o (pred_class),
      .pred_conf_o  (pred_conf)
  );

  picorv32_stub u_cpu (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .soft_reset_i    (soft_reset),
      .bist_start_i    (bist_start),
      .pred_class_i    (pred_class),
      .spi_start_o     (spi_start),
      .spi_hold_cs_o   (spi_hold_cs),
      .spi_tx_o        (spi_tx),
      .spi_rx_i        (spi_rx),
      .spi_done_i      (spi_done),
      .w_csb_o         (wsram_csb0),
      .w_web_o         (wsram_web0),
      .w_wmask_o       (wsram_wmask0),
      .w_addr_o        (wsram_addr0),
      .w_din_o         (wsram_din0),
      .w_dout_i        (wsram_dout0),
      .e_csb_o         (esram_csb0),
      .e_web_o         (esram_web0),
      .e_wmask_o       (esram_wmask0),
      .e_addr_o        (esram_addr0),
      .e_din_o         (esram_din0),
      .e_dout_i        (esram_dout0),
      .loop_pll_bw_o   (loop_pll_bw),
      .loop_fll_en_o   (loop_fll_en),
      .loop_t_coh_o    (loop_t_coh),
      .loop_band_pref_o(loop_band_pref),
      .weights_ready_o (weights_ready),
      .weights_fault_o (weights_fault),
      .bist_done_o     (bist_done),
      .bist_pass_o     (bist_pass),
      .uart_tx_o       (uart_tx_o)
  );

  // event-log SRAM read port is unused in the stub
  assign esram_csb1  = 1'b1;
  assign esram_addr1 = 8'd0;

  // -------------------------------------------------------------------------
  // SRAM MACROS — the reason this experiment exists
  //
  // VERIFY THE PORT LIST before running. Check the PDK's own Verilog:
  //   ~/.ciel/ciel/sky130/versions/*/sky130A/libs.ref/sky130_sram_macros/verilog/
  // -------------------------------------------------------------------------
  sky130_sram_2kbyte_1rw1r_32x512_8 u_weight_sram (
      .clk0   (wsram_clk),
      .csb0   (wsram_csb0),
      .web0   (wsram_web0),
      .wmask0 (wsram_wmask0),
      .addr0  (wsram_addr0),
      .din0   (wsram_din0),
      .dout0  (wsram_dout0),
      .clk1   (wsram_clk),
      .csb1   (wsram_csb1),
      .addr1  (wsram_addr1),
      .dout1  (wsram_dout1)
  );

  sky130_sram_1kbyte_1rw1r_32x256_8 u_event_sram (
      .clk0   (clk_i),
      .csb0   (esram_csb0),
      .web0   (esram_web0),
      .wmask0 (esram_wmask0),
      .addr0  (esram_addr0),
      .din0   (esram_din0),
      .dout0  (esram_dout0),
      .clk1   (clk_i),
      .csb1   (esram_csb1),
      .addr1  (esram_addr1),
      .dout1  ()
  );

endmodule


// ===========================================================================
// STUB MODULES
//
// Each holds a single flop so synthesis does not optimise it away entirely,
// giving the floorplanner something to place. Replace one at a time as the
// real blocks are written.
// ===========================================================================

module cordic_stub (
    input  wire        clk_i, rst_ni, valid_i,
    input  wire [15:0] i_i, q_i,
    output reg         valid_o,
    output reg  [15:0] phase_o
);
  always @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin valid_o <= 1'b0; phase_o <= 16'h0; end
    else begin valid_o <= valid_i; phase_o <= i_i ^ q_i; end
endmodule


module sicu_stub (
    input  wire        clk_i, rst_ni, enable_i, iq_valid_i,
    input  wire [15:0] i_i, q_i,
    input  wire        phase_valid_i,
    input  wire [15:0] phase_i,
    output reg         idx_valid_o,
    output reg  [15:0] s4_o, sphi_o
);
  always @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      idx_valid_o <= 1'b0; s4_o <= 16'h0; sphi_o <= 16'h0;
    end else if (enable_i) begin
      idx_valid_o <= iq_valid_i & phase_valid_i;
      s4_o        <= i_i + q_i;
      sphi_o      <= phase_i;
    end
endmodule


module lstm_accel_stub (
    input  wire        clk_i, rst_ni, enable_i, idx_valid_i,
    input  wire [15:0] s4_i, sphi_i,
    output reg         w_csb_o,
    output reg  [ 8:0] w_addr_o,
    input  wire [31:0] w_data_i,
    output reg         pred_valid_o,
    output reg  [ 1:0] pred_class_o,
    output reg  [ 3:0] pred_conf_o
);
  always @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      w_csb_o <= 1'b1; w_addr_o <= 9'd0;
      pred_valid_o <= 1'b0; pred_class_o <= 2'd0; pred_conf_o <= 4'd0;
    end else if (enable_i) begin
      w_csb_o      <= ~idx_valid_i;
      w_addr_o     <= w_addr_o + 9'd1;
      pred_valid_o <= idx_valid_i;
      pred_class_o <= s4_i[15:14] ^ {2{^s4_i}};
      pred_conf_o  <= (w_data_i[3:0] ^ sphi_i[3:0]) ^ {4{(^w_data_i) ^ (^sphi_i)}};
    end
endmodule


module picorv32_stub (
    input  wire        clk_i, rst_ni, soft_reset_i, bist_start_i,
    input  wire [ 1:0] pred_class_i,
    output reg         spi_start_o, spi_hold_cs_o,
    output reg  [ 7:0] spi_tx_o,
    input  wire [ 7:0] spi_rx_i,
    input  wire        spi_done_i,
    output reg         w_csb_o, w_web_o,
    output reg  [ 3:0] w_wmask_o,
    output reg  [ 8:0] w_addr_o,
    output reg  [31:0] w_din_o,
    input  wire [31:0] w_dout_i,
    output reg         e_csb_o, e_web_o,
    output reg  [ 3:0] e_wmask_o,
    output reg  [ 7:0] e_addr_o,
    output reg  [31:0] e_din_o,
    input  wire [31:0] e_dout_i,
    output reg  [ 2:0] loop_pll_bw_o,
    output reg         loop_fll_en_o,
    output reg  [ 2:0] loop_t_coh_o,
    output reg  [ 1:0] loop_band_pref_o,
    output reg         weights_ready_o, weights_fault_o,
    output reg         bist_done_o, bist_pass_o,
    output reg         uart_tx_o
);
  reg [7:0] ctr;
  always @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      spi_start_o <= 1'b0; spi_hold_cs_o <= 1'b0; spi_tx_o <= 8'h0;
      w_csb_o <= 1'b1; w_web_o <= 1'b1; w_wmask_o <= 4'hF;
      w_addr_o <= 9'd0; w_din_o <= 32'h0;
      e_csb_o <= 1'b1; e_web_o <= 1'b1; e_wmask_o <= 4'hF;
      e_addr_o <= 8'd0; e_din_o <= 32'h0;
      loop_pll_bw_o <= 3'd3; loop_fll_en_o <= 1'b0;
      loop_t_coh_o <= 3'd3; loop_band_pref_o <= 2'd0;
      weights_ready_o <= 1'b0; weights_fault_o <= 1'b0;
      bist_done_o <= 1'b0; bist_pass_o <= 1'b0;
      uart_tx_o <= 1'b1; ctr <= 8'h0;
    end else begin
      ctr <= ctr + 8'd1 + {7'd0, (^w_dout_i) ^ (^e_dout_i)};

      // stand-in for the boot weight-load sequence
      spi_start_o   <= (ctr == 8'd1);
      spi_hold_cs_o <= (ctr < 8'd200);
      spi_tx_o      <= ctr;
      w_csb_o       <= ~spi_done_i;
      w_web_o       <= ~spi_done_i;
      w_wmask_o     <= 4'hF;
      if (spi_done_i) w_addr_o <= w_addr_o + 9'd1;
      w_din_o       <= {24'h0, spi_rx_i};

      // stand-in for the class -> loop settings firmware table
      case (pred_class_i)
        2'd0: begin loop_pll_bw_o <= 3'd2; loop_t_coh_o <= 3'd4;
                    loop_fll_en_o <= 1'b0; loop_band_pref_o <= 2'd0; end
        2'd1: begin loop_pll_bw_o <= 3'd4; loop_t_coh_o <= 3'd3;
                    loop_fll_en_o <= 1'b0; loop_band_pref_o <= 2'd0; end
        default: begin loop_pll_bw_o <= 3'd7; loop_t_coh_o <= 3'd1;
                       loop_fll_en_o <= 1'b1; loop_band_pref_o <= 2'd1; end
      endcase

      // event log write
      e_csb_o   <= ~(ctr[3:0] == 4'hF);
      e_web_o   <= ~(ctr[3:0] == 4'hF);
      e_wmask_o <= 4'hF;
      if (ctr[3:0] == 4'hF) e_addr_o <= e_addr_o + 8'd1;
      e_din_o   <= {16'h0, w_dout_i[7:0], e_dout_i[7:0]};

      weights_ready_o <= (w_addr_o == 9'd511);
      weights_fault_o <= 1'b0;
      bist_done_o     <= bist_start_i;
      bist_pass_o     <= bist_start_i;
      uart_tx_o       <= ctr[0] ^ soft_reset_i;
    end
endmodule

`default_nettype wire
