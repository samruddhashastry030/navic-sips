// ---------------------------------------------------------------------------
// navic_sips_top.sv
//
// NavIC-SIPS chip top level: every block is real RTL, no stubs.
//
//   PicoRV32 (RV32IMC) <-> soc_bus <-> boot ROM (inside soc_bus)
//                                  <-> data RAM    = event SRAM port 0
//                                  <-> weight SRAM port 0   (load at boot)
//                                  <-> system regs -> navic_sips_regs inputs
//                                  <-> spi_master  -> SPI pins (weight flash)
//                                  <-> uart_tx     -> uart_tx_o
//                                  <-> sicu        <- prompt I/Q pins
//                                  <-> lstm_accel  -> weight SRAM port 1
//   host bus pins <-> navic_sips_regs -> irq_o, ready_pin_o, fault_pin_o
//
// The host (receiver baseband) sees the chip ONLY through navic_sips_regs.
// Everything the chip decides reaches it via the idx_valid / pred_valid
// strobes from soc_bus -- see soc_bus.sv for why those strobes exist.
//
// Pin protocol for prompt I/Q: iq_valid_i is a ONE-CYCLE strobe per sample.
// There is no backpressure pin: a sample arriving while the SICU is busy
// finishing a window (~450 cycles) is dropped. At 50 Hz against a 33 MHz
// clock that never happens in practice, but it is a real constraint.
//
// Host soft reset (CTRL.SOFTRST) restarts the CPU and datapath -- the
// firmware reboots and reloads its weights -- but not navic_sips_regs, which
// holds the host's own configuration.
// ---------------------------------------------------------------------------

`default_nettype none

module navic_sips_top #(
    parameter              FW_HEX       = "fw/firmware.hex",
    parameter              LUT_SIG      = "rtl/weights/lut_sigmoid.hex",
    parameter              LUT_TANH     = "rtl/weights/lut_tanh.hex",
    parameter int unsigned SPI_CLK_DIV  = 1,             // SCLK = clk / 4
    parameter int unsigned CLK_FREQ_HZ  = 33_000_000
) (
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
  // Resets.
  //
  // rst_ni is an asynchronous pin, and navic_sips_regs and spi_master reset
  // asynchronously from it. Releasing an asynchronous reset straight from a
  // pin is a real hazard: a flop can sample it as it changes and go
  // metastable, and whole-chip timing showed it as removal violations at ss
  // on thousands of reset inputs. This synchroniser asserts asynchronously
  // the instant the pin drops -- so reset still works with no clock -- and
  // releases synchronously two clock edges later.
  //
  // The host's soft reset restarts everything except its own register block.
  // soft_reset is a registered one-cycle pulse, so the derived reset is
  // glitch-free.
  // -------------------------------------------------------------------------
  wire enable, bist_start, soft_reset;

  reg [1:0] rst_sync_q;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) rst_sync_q <= 2'b00;
    else         rst_sync_q <= {rst_sync_q[0], 1'b1};
  wire rst_sync_n = rst_sync_q[1];

  wire core_rst_n = rst_sync_n & ~soft_reset;

  // -------------------------------------------------------------------------
  // CPU <-> bus
  // -------------------------------------------------------------------------
  wire        mem_valid, mem_instr, mem_ready;
  wire [31:0] mem_addr, mem_wdata, mem_rdata;
  wire [ 3:0] mem_wstrb;

  picorv32 #(
      .ENABLE_MUL        (1),
      .ENABLE_DIV        (1),
      .COMPRESSED_ISA    (1),
      .ENABLE_IRQ        (1),
      .ENABLE_COUNTERS64 (0),
      .PROGADDR_RESET    (32'h0000_0000),
      .PROGADDR_IRQ      (32'h0000_0010)
  ) u_cpu (
      .clk          (clk_i),
      .resetn       (core_rst_n),
      .trap         (),
      .mem_valid    (mem_valid),
      .mem_instr    (mem_instr),
      .mem_ready    (mem_ready),
      .mem_addr     (mem_addr),
      .mem_wdata    (mem_wdata),
      .mem_wstrb    (mem_wstrb),
      .mem_rdata    (mem_rdata),
      .mem_la_read  (),
      .mem_la_write (),
      .mem_la_addr  (),
      .mem_la_wdata (),
      .mem_la_wstrb (),
      .pcpi_valid   (),
      .pcpi_insn    (),
      .pcpi_rs1     (),
      .pcpi_rs2     (),
      .pcpi_wr      (1'b0),
      .pcpi_rd      (32'd0),
      .pcpi_wait    (1'b0),
      .pcpi_ready   (1'b0),
      .irq          (32'd0),         // firmware polls; see memory-map.md
      .eoi          (),
      .trace_valid  (),
      .trace_data   ()
  );

  // -------------------------------------------------------------------------
  // Bus-side nets
  // -------------------------------------------------------------------------
  wire        dram_csb, dram_web, wram_csb0, wram_web0;
  wire [ 3:0] dram_wmask, wram_wmask0;
  wire [ 7:0] dram_addr;
  wire [ 8:0] wram_addr0;
  wire [31:0] dram_din, dram_dout, wram_din0, wram_dout0;

  wire        weights_ready, weights_fault, bist_done, bist_pass;
  wire [ 1:0] pred_class, loop_band_pref;
  wire [ 3:0] pred_conf;
  wire [ 2:0] loop_pll_bw, loop_t_coh;
  wire        loop_fll_en;
  wire [15:0] s4_report;
  wire        idx_valid, pred_valid;

  wire        spi_start, spi_hold_cs, spi_done;
  wire [ 7:0] spi_tx, spi_rx;

  wire        uart_valid, uart_ready;
  wire [ 7:0] uart_data;

  wire        sicu_enable, sicu_s4_valid, sicu_saturated, sicu_busy, sicu_ready;
  wire [15:0] sicu_s4;
  wire [ 4:0] sicu_shift;

  wire        accel_start, accel_busy, accel_in_valid, accel_in_ready;
  wire        accel_out_valid;
  wire [15:0] accel_feat0, accel_feat1;
  wire [15:0] accel_logit0, accel_logit1, accel_logit2;
  wire [ 1:0] accel_class;
  wire        wram_csb1;
  wire [ 8:0] wram_addr1;
  wire [31:0] wram_dout1;

  soc_bus #(.FW_HEX(FW_HEX)) u_bus (
      .clk_i             (clk_i),
      .rst_ni            (core_rst_n),
      .mem_valid_i       (mem_valid),
      .mem_ready_o       (mem_ready),
      .mem_addr_i        (mem_addr),
      .mem_wdata_i       (mem_wdata),
      .mem_wstrb_i       (mem_wstrb),
      .mem_rdata_o       (mem_rdata),
      .dram_csb_o        (dram_csb),
      .dram_web_o        (dram_web),
      .dram_wmask_o      (dram_wmask),
      .dram_addr_o       (dram_addr),
      .dram_din_o        (dram_din),
      .dram_dout_i       (dram_dout),
      .wram_csb_o        (wram_csb0),
      .wram_web_o        (wram_web0),
      .wram_wmask_o      (wram_wmask0),
      .wram_addr_o       (wram_addr0),
      .wram_din_o        (wram_din0),
      .wram_dout_i       (wram_dout0),
      .weights_ready_o   (weights_ready),
      .weights_fault_o   (weights_fault),
      .bist_done_o       (bist_done),
      .bist_pass_o       (bist_pass),
      .pred_class_o      (pred_class),
      .pred_conf_o       (pred_conf),
      .loop_pll_bw_o     (loop_pll_bw),
      .loop_fll_en_o     (loop_fll_en),
      .loop_t_coh_o      (loop_t_coh),
      .loop_band_pref_o  (loop_band_pref),
      .s4_report_o       (s4_report),
      .idx_valid_o       (idx_valid),
      .pred_valid_o      (pred_valid),
      .host_ctrl_i       ({soft_reset, bist_start, bypass_pin_i, enable}),
      .spi_start_o       (spi_start),
      .spi_hold_cs_o     (spi_hold_cs),
      .spi_tx_o          (spi_tx),
      .spi_rx_i          (spi_rx),
      .spi_done_i        (spi_done),
      .uart_valid_o      (uart_valid),
      .uart_data_o       (uart_data),
      .uart_busy_i       (~uart_ready),
      .sicu_enable_o     (sicu_enable),
      .sicu_s4_valid_i   (sicu_s4_valid),
      .sicu_s4_i         (sicu_s4),
      .sicu_saturated_i  (sicu_saturated),
      .sicu_shift_i      (sicu_shift),
      .sicu_busy_i       (sicu_busy),
      .accel_start_o     (accel_start),
      .accel_busy_i      (accel_busy),
      .accel_in_valid_o  (accel_in_valid),
      .accel_in_ready_i  (accel_in_ready),
      .accel_feat0_o     (accel_feat0),
      .accel_feat1_o     (accel_feat1),
      .accel_out_valid_i (accel_out_valid),
      .accel_logit0_i    (accel_logit0),
      .accel_logit1_i    (accel_logit1),
      .accel_logit2_i    (accel_logit2),
      .accel_class_i     (accel_class)
  );

  // -------------------------------------------------------------------------
  // Host register block -- the chip's only face to the receiver
  // -------------------------------------------------------------------------
  navic_sips_regs u_regs (
      .clk_i             (clk_i),
      .rst_ni            (rst_sync_n),       // NOT soft-reset: host config
      .bus_sel_i         (bus_sel_i),
      .bus_we_i          (bus_we_i),
      .bus_addr_i        (bus_addr_i),
      .bus_wdata_i       (bus_wdata_i),
      .bus_rdata_o       (bus_rdata_o),
      .bus_ack_o         (bus_ack_o),
      .idx_valid_i       (idx_valid),
      .s4_i              (s4_report),
      .sphi_i            (16'd0),            // sigma_phi not computed
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
  // Peripherals
  // -------------------------------------------------------------------------
  spi_master #(.DIV_WIDTH(8), .DATA_WIDTH(8)) u_spi (
      .clk_i     (clk_i),
      .rst_ni    (core_rst_n),
      .clk_div_i (8'(SPI_CLK_DIV)),
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

  uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(115_200)) u_uart (
      .clk_i   (clk_i),
      .rst_ni  (core_rst_n),
      .data_i  (uart_data),
      .valid_i (uart_valid),
      .ready_o (uart_ready),
      .tx_o    (uart_tx_o)
  );

  sicu u_sicu (
      .clk_i       (clk_i),
      .rst_ni      (core_rst_n),
      .enable_i    (sicu_enable),
      .busy_o      (sicu_busy),
      .in_valid_i  (iq_valid_i),
      .in_ready_o  (sicu_ready),             // no backpressure pin; see header
      .i_i         (iq_i_i),
      .q_i         (iq_q_i),
      .s4_valid_o  (sicu_s4_valid),
      .s4_o        (sicu_s4),
      .saturated_o (sicu_saturated),
      .shift_o     (sicu_shift)
  );

  lstm_accel #(.LUT_SIG(LUT_SIG), .LUT_TANH(LUT_TANH)) u_acc (
      .clk_i       (clk_i),
      .rst_ni      (core_rst_n),
      .start_i     (accel_start),
      .busy_o      (accel_busy),
      .in_valid_i  (accel_in_valid),
      .in_ready_o  (accel_in_ready),
      .in_feat0_i  (accel_feat0),
      .in_feat1_i  (accel_feat1),
      .w_csb_o     (wram_csb1),
      .w_addr_o    (wram_addr1),
      .w_dout_i    (wram_dout1),
      .out_valid_o (accel_out_valid),
      .logit0_o    (accel_logit0),
      .logit1_o    (accel_logit1),
      .logit2_o    (accel_logit2),
      .class_o     (accel_class)
  );

  // -------------------------------------------------------------------------
  // SRAM macros. Power is connected by the flow (PDN_MACRO_CONNECTIONS), so
  // there are no power pins here -- unchanged from the floorplan experiment.
  // -------------------------------------------------------------------------
  sky130_sram_2kbyte_1rw1r_32x512_8 u_weight_sram (
      .clk0   (clk_i),
      .csb0   (wram_csb0),
      .web0   (wram_web0),
      .wmask0 (wram_wmask0),
      .addr0  (wram_addr0),
      .din0   (wram_din0),
      .dout0  (wram_dout0),
      .clk1   (clk_i),
      .csb1   (wram_csb1),
      .addr1  (wram_addr1),
      .dout1  (wram_dout1)
  );

  sky130_sram_1kbyte_1rw1r_32x256_8 u_event_sram (
      .clk0   (clk_i),
      .csb0   (dram_csb),
      .web0   (dram_web),
      .wmask0 (dram_wmask),
      .addr0  (dram_addr),
      .din0   (dram_din),
      .dout0  (dram_dout),
      .clk1   (clk_i),
      .csb1   (1'b1),                         // port 1 unused
      .addr1  (8'd0),
      .dout1  ()
  );

endmodule

`default_nettype wire
