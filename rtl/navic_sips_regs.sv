// ---------------------------------------------------------------------------
// navic_sips_regs.sv
//
// NavIC-SIPS host register block.
//
// This is the interface contract between the SoC and the host receiver
// baseband. Everything else in the design attaches to it:
//
//   - the SICU writes S4 / sigma_phi here
//   - the classifier writes CLASS and CONF here
//   - the firmware writes LOOP_CFG here (class -> loop settings mapping is a
//     firmware table, deliberately, so it is tunable without a re-spin)
//   - the host reads all of it and applies the recommended tracking settings
//
// Implements the four spec additions:
//   1. BIST      -- SELFTEST_START in CTRL, BIST_PASS/BIST_DONE in STATUS
//   2. BAND_PREF -- L5 vs S band recommendation (NavIC dual-band; no other
//                   GNSS can do this)
//   3. BYPASS    -- hardware fail-safe. Forces safe defaults so the chip can
//                   never take the host's navigation solution down.
//   4. CONF      -- 4-bit argmax margin alongside the class
//
// Bus: simple synchronous read/write. A SPI or Wishbone adapter sits on top.
// Naming follows the existing repo convention (_i inputs, _o outputs,
// rst_ni active-low reset).
// ---------------------------------------------------------------------------

`default_nettype none

module navic_sips_regs #(
    parameter logic [31:0] DEVICE_ID = 32'h5195_0001   // "SIPS" rev 1
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    // ---- host bus ---------------------------------------------------------
    input  wire        bus_sel_i,        // transaction valid
    input  wire        bus_we_i,         // 1 = write, 0 = read
    input  wire [ 4:0] bus_addr_i,       // byte address, 32-bit aligned
    input  wire [31:0] bus_wdata_i,
    output reg  [31:0] bus_rdata_o,
    output reg         bus_ack_o,

    // ---- from datapath ----------------------------------------------------
    input  wire        idx_valid_i,      // strobe: new S4 / sigma_phi
    input  wire [15:0] s4_i,
    input  wire [15:0] sphi_i,

    input  wire        pred_valid_i,     // strobe: new classification
    input  wire [ 1:0] pred_class_i,     // 0 NOMINAL, 1 DEGRADED, 2 SEVERE
    input  wire [ 3:0] pred_conf_i,      // argmax margin, quantised

    input  wire [ 2:0] loop_pll_bw_i,    // recommended PLL bandwidth index
    input  wire        loop_fll_en_i,    // recommend PLL -> FLL fallback
    input  wire [ 2:0] loop_t_coh_i,     // recommended coherent integration
    input  wire [ 1:0] loop_band_pref_i, // 0 L5, 1 S, 2 weighted, 3 hold

    input  wire        weights_ready_i,  // weight load complete
    input  wire        weights_fault_i,  // weight load failed after retries

    input  wire        bist_done_i,      // self-test finished
    input  wire        bist_pass_i,      // self-test result

    // ---- to datapath / pads ----------------------------------------------
    output wire        enable_o,         // datapath enable
    output wire        bist_start_o,     // pulse: run self-test
    output wire        soft_reset_o,     // pulse: reset datapath

    // ---- pads -------------------------------------------------------------
    input  wire        bypass_pin_i,     // HARDWARE fail-safe, async assert
    output wire        irq_o,
    output wire        ready_pin_o,
    output wire        fault_pin_o
);

  // -------------------------------------------------------------------------
  // Address map
  // -------------------------------------------------------------------------
  localparam logic [4:0] ADDR_ID      = 5'h00;  // RO   magic — bring-up aid
  localparam logic [4:0] ADDR_CTRL    = 5'h04;  // RW
  localparam logic [4:0] ADDR_STATUS  = 5'h08;  // RO
  localparam logic [4:0] ADDR_INDEX   = 5'h0C;  // RO   {sphi, s4}
  localparam logic [4:0] ADDR_LOOPCFG = 5'h10;  // RO
  localparam logic [4:0] ADDR_IRQST   = 5'h14;  // RW1C
  localparam logic [4:0] ADDR_IRQEN   = 5'h18;  // RW
  localparam logic [4:0] ADDR_SCRATCH = 5'h1C;  // RW   bus bring-up aid

  // CTRL bits
  localparam int C_ENABLE   = 0;
  localparam int C_BYPASS   = 1;   // software bypass, ORed with the pin
  localparam int C_BIST     = 2;   // self-clearing
  localparam int C_SOFTRST  = 3;   // self-clearing

  // IRQ bits
  localparam int I_SEVERE   = 0;
  localparam int I_FAULT    = 1;
  localparam int I_BISTDONE = 2;

  // Safe defaults asserted in bypass. These must be what the host receiver
  // does when it has no advice: nominal class, mid PLL bandwidth, no FLL
  // fallback, mid coherent integration, L5 band.
  localparam logic [1:0] SAFE_CLASS     = 2'd0;
  localparam logic [2:0] SAFE_PLL_BW    = 3'd3;
  localparam logic       SAFE_FLL_EN    = 1'b0;
  localparam logic [2:0] SAFE_T_COH     = 3'd3;
  localparam logic [1:0] SAFE_BAND_PREF = 2'd0;

  // -------------------------------------------------------------------------
  // Bypass — synchronise the async pin, then OR with the software bit
  // -------------------------------------------------------------------------
  reg [1:0] bypass_sync;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) bypass_sync <= 2'b00;
    else         bypass_sync <= {bypass_sync[0], bypass_pin_i};
  end

  reg [31:0] ctrl_q;
  wire bypass = bypass_sync[1] | ctrl_q[C_BYPASS];

  // -------------------------------------------------------------------------
  // CTRL
  // -------------------------------------------------------------------------
  wire bus_write = bus_sel_i & bus_we_i;
  wire bus_read  = bus_sel_i & ~bus_we_i;

  reg bist_start_q, soft_reset_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_q       <= 32'h0;
      bist_start_q <= 1'b0;
      soft_reset_q <= 1'b0;
    end else begin
      // self-clearing pulses default low
      bist_start_q <= 1'b0;
      soft_reset_q <= 1'b0;

      if (bus_write && bus_addr_i == ADDR_CTRL) begin
        ctrl_q[C_ENABLE] <= bus_wdata_i[C_ENABLE];
        ctrl_q[C_BYPASS] <= bus_wdata_i[C_BYPASS];
        // BIST and SOFTRST are write-1-to-pulse, never stored
        bist_start_q     <= bus_wdata_i[C_BIST];
        soft_reset_q     <= bus_wdata_i[C_SOFTRST];
      end
    end
  end

  // Bypass forces the datapath off — it must not drive anything.
  assign enable_o     = ctrl_q[C_ENABLE] & ~bypass;
  assign bist_start_o = bist_start_q & ~bypass;
  assign soft_reset_o = soft_reset_q;

  // -------------------------------------------------------------------------
  // Captured datapath state
  // -------------------------------------------------------------------------
  reg [15:0] s4_q, sphi_q;
  reg [ 1:0] class_q;
  reg [ 3:0] conf_q;
  reg        pred_valid_q;
  reg        bist_done_q, bist_pass_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s4_q         <= 16'h0;
      sphi_q       <= 16'h0;
      class_q      <= 2'h0;
      conf_q       <= 4'h0;
      pred_valid_q <= 1'b0;
      bist_done_q  <= 1'b0;
      bist_pass_q  <= 1'b0;
    end else if (soft_reset_q) begin
      s4_q         <= 16'h0;
      sphi_q       <= 16'h0;
      class_q      <= 2'h0;
      conf_q       <= 4'h0;
      pred_valid_q <= 1'b0;
      bist_done_q  <= 1'b0;
      bist_pass_q  <= 1'b0;
    end else begin
      if (idx_valid_i) begin
        s4_q   <= s4_i;
        sphi_q <= sphi_i;
      end
      if (pred_valid_i) begin
        class_q      <= pred_class_i;
        conf_q       <= pred_conf_i;
        pred_valid_q <= 1'b1;
      end
      if (bist_done_i) begin
        bist_done_q <= 1'b1;
        bist_pass_q <= bist_pass_i;
      end
      if (bist_start_q) begin
        bist_done_q <= 1'b0;
        bist_pass_q <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Muxed outputs — bypass substitutes safe defaults
  // -------------------------------------------------------------------------
  wire [1:0] class_out = bypass ? SAFE_CLASS : class_q;
  wire [3:0] conf_out  = bypass ? 4'h0       : conf_q;
  wire       valid_out = bypass ? 1'b0       : pred_valid_q;

  wire [2:0] pll_bw_out    = bypass ? SAFE_PLL_BW    : loop_pll_bw_i;
  wire       fll_en_out    = bypass ? SAFE_FLL_EN    : loop_fll_en_i;
  wire [2:0] t_coh_out     = bypass ? SAFE_T_COH     : loop_t_coh_i;
  wire [1:0] band_pref_out = bypass ? SAFE_BAND_PREF : loop_band_pref_i;

  wire [15:0] s4_out   = bypass ? 16'h0 : s4_q;
  wire [15:0] sphi_out = bypass ? 16'h0 : sphi_q;

  // -------------------------------------------------------------------------
  // Interrupts
  // -------------------------------------------------------------------------
  reg [31:0] irq_status_q, irq_enable_q;

  wire severe_event = pred_valid_i && (pred_class_i == 2'd2) && !bypass;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_status_q <= 32'h0;
      irq_enable_q <= 32'h0;
    end else begin
      if (bus_write && bus_addr_i == ADDR_IRQEN)
        irq_enable_q <= bus_wdata_i;

      // write-1-to-clear
      if (bus_write && bus_addr_i == ADDR_IRQST)
        irq_status_q <= irq_status_q & ~bus_wdata_i;

      // set has priority over clear
      if (severe_event)       irq_status_q[I_SEVERE]   <= 1'b1;
      if (weights_fault_i)    irq_status_q[I_FAULT]    <= 1'b1;
      if (bist_done_i)        irq_status_q[I_BISTDONE] <= 1'b1;
    end
  end

  assign irq_o = |(irq_status_q & irq_enable_q) & ~bypass;

  // Pads. READY deasserts in bypass (we are not operational);
  // FAULT still reports honestly.
  assign ready_pin_o = weights_ready_i & ~bypass;
  assign fault_pin_o = weights_fault_i;

  // -------------------------------------------------------------------------
  // Read mux
  // -------------------------------------------------------------------------
  reg [31:0] scratch_q;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                                          scratch_q <= 32'h0;
    else if (bus_write && bus_addr_i == ADDR_SCRATCH)     scratch_q <= bus_wdata_i;
  end

  wire [31:0] status_word = {
      20'h0,
      bist_pass_q,          // [11]
      bist_done_q,          // [10]
      weights_fault_i,      // [9]
      weights_ready_i,      // [8]
      bypass,               // [7]
      conf_out,             // [6:3]
      valid_out,            // [2]
      class_out             // [1:0]
  };

  wire [31:0] loopcfg_word = {
      23'h0,
      band_pref_out,        // [8:7]
      t_coh_out,            // [6:4]
      fll_en_out,           // [3]
      pll_bw_out            // [2:0]
  };

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bus_rdata_o <= 32'h0;
      bus_ack_o   <= 1'b0;
    end else begin
      bus_ack_o <= bus_sel_i;
      if (bus_read) begin
        case (bus_addr_i)
          ADDR_ID:      bus_rdata_o <= DEVICE_ID;
          ADDR_CTRL:    bus_rdata_o <= {30'h0, ctrl_q[C_BYPASS], ctrl_q[C_ENABLE]};
          ADDR_STATUS:  bus_rdata_o <= status_word;
          ADDR_INDEX:   bus_rdata_o <= {sphi_out, s4_out};
          ADDR_LOOPCFG: bus_rdata_o <= loopcfg_word;
          ADDR_IRQST:   bus_rdata_o <= irq_status_q;
          ADDR_IRQEN:   bus_rdata_o <= irq_enable_q;
          ADDR_SCRATCH: bus_rdata_o <= scratch_q;
          default:      bus_rdata_o <= 32'h0;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
