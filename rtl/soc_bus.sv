// ---------------------------------------------------------------------------
// soc_bus.sv
//
// NavIC-SIPS system bus. Sits between PicoRV32's native memory interface and
// every target on the chip, and implements the register interfaces the
// firmware expects. The contract is docs/memory-map.md and fw/sips.h; any
// change here must be mirrored there.
//
//   addr[31:28]   target
//   0x0           boot ROM, 1 KB, loaded from firmware.hex
//   0x1           data RAM  = event SRAM port 0
//   0x2           weight SRAM port 0
//   0x3           system register block -> drives navic_sips_regs inputs
//   0x4           SPI master
//   0x5           UART
//   0x6           SICU
//   0x7           LSTM accelerator
//   other         completes immediately, reads zero -- never hangs the bus
//
// Handshake. PicoRV32 holds mem_valid until it sees mem_ready for one cycle.
// This bus accepts a request in S_IDLE, performs every side effect exactly
// once at that point (register writes, read-to-clear flags, the single SRAM
// operation), then returns mem_ready from a register:
//
//   registers, ROM   take -> ready               1 cycle
//   SRAMs            take -> WAIT -> ready       2 cycles
//
// The SRAM path needs the extra cycle because the SKY130 macros register
// their output: address sampled at one edge, dout valid only after it.
//
// Sticky flags. The SICU and accelerator signal completion with one-cycle
// pulses the CPU may not be watching. Both are latched here and cleared by
// reading the result register, so a result is never missed and never read
// twice. If a new result arrives in the same cycle as the clearing read, the
// new result wins.
//
// Repo conventions: _i inputs, _o outputs, _q registered, rst_ni synchronous
// active-low reset, single clock domain.
// ---------------------------------------------------------------------------

`default_nettype none

module soc_bus #(
    parameter              FW_HEX    = "fw/firmware.hex",
    parameter int unsigned ROM_WORDS = 256                   // 1 KB
) (
    input  wire         clk_i,
    input  wire         rst_ni,

    // ---- PicoRV32 native interface ---------------------------------------
    input  wire         mem_valid_i,
    output reg          mem_ready_o,
    input  wire [31:0]  mem_addr_i,
    input  wire [31:0]  mem_wdata_i,
    input  wire [ 3:0]  mem_wstrb_i,
    output reg  [31:0]  mem_rdata_o,

    // ---- data RAM: event SRAM port 0 (256 x 32) --------------------------
    output wire         dram_csb_o,
    output wire         dram_web_o,
    output wire [ 3:0]  dram_wmask_o,
    output wire [ 7:0]  dram_addr_o,
    output wire [31:0]  dram_din_o,
    input  wire [31:0]  dram_dout_i,

    // ---- weight SRAM port 0 (512 x 32) -----------------------------------
    output wire         wram_csb_o,
    output wire         wram_web_o,
    output wire [ 3:0]  wram_wmask_o,
    output wire [ 8:0]  wram_addr_o,
    output wire [31:0]  wram_din_o,
    input  wire [31:0]  wram_dout_i,

    // ---- system register block -> navic_sips_regs inputs -----------------
    output reg          weights_ready_o,
    output reg          weights_fault_o,
    output reg          bist_done_o,
    output reg          bist_pass_o,
    output reg  [ 1:0]  pred_class_o,
    output reg  [ 3:0]  pred_conf_o,
    output reg  [ 2:0]  loop_pll_bw_o,
    output reg          loop_fll_en_o,
    output reg  [ 2:0]  loop_t_coh_o,
    output reg  [ 1:0]  loop_band_pref_o,
    output reg  [15:0]  s4_report_o,
    input  wire [ 3:0]  host_ctrl_i,     // {soft_reset, bist_start, bypass, enable}

    // ---- SPI master ------------------------------------------------------
    output reg          spi_start_o,     // one-cycle pulse per byte
    output reg          spi_hold_cs_o,
    output reg  [ 7:0]  spi_tx_o,
    input  wire [ 7:0]  spi_rx_i,
    input  wire         spi_done_i,      // pulse: byte finished, rx valid

    // ---- UART ------------------------------------------------------------
    output reg          uart_valid_o,    // one-cycle pulse per byte
    output reg  [ 7:0]  uart_data_o,
    input  wire         uart_busy_i,

    // ---- SICU ------------------------------------------------------------
    output reg          sicu_enable_o,
    input  wire         sicu_s4_valid_i, // pulse
    input  wire [15:0]  sicu_s4_i,       // Q4.12, held between windows
    input  wire         sicu_saturated_i,
    input  wire [ 4:0]  sicu_shift_i,
    input  wire         sicu_busy_i,

    // ---- LSTM accelerator ------------------------------------------------
    output reg          accel_start_o,   // one-cycle pulse
    input  wire         accel_busy_i,
    output wire         accel_in_valid_o,
    input  wire         accel_in_ready_i,
    output reg  [15:0]  accel_feat0_o,
    output reg  [15:0]  accel_feat1_o,
    input  wire         accel_out_valid_i,  // pulse
    input  wire [15:0]  accel_logit0_i,
    input  wire [15:0]  accel_logit1_i,
    input  wire [15:0]  accel_logit2_i,
    input  wire [ 1:0]  accel_class_i
);

  // -------------------------------------------------------------------------
  // Region decode
  // -------------------------------------------------------------------------
  localparam logic [3:0] R_ROM  = 4'h0;
  localparam logic [3:0] R_DRAM = 4'h1;
  localparam logic [3:0] R_WRAM = 4'h2;
  localparam logic [3:0] R_SYS  = 4'h3;
  localparam logic [3:0] R_SPI  = 4'h4;
  localparam logic [3:0] R_UART = 4'h5;
  localparam logic [3:0] R_SICU = 4'h6;
  localparam logic [3:0] R_ACCL = 4'h7;

  wire [3:0] region = mem_addr_i[31:28];
  wire [7:0] off    = mem_addr_i[7:0];            // register byte offset
  wire       is_wr  = |mem_wstrb_i;

  typedef enum logic { S_IDLE, S_WAIT } state_e;
  state_e state_q;

  // A new request is taken only in S_IDLE, and never in the cycle mem_ready
  // is high: PicoRV32 is still holding mem_valid for the request being
  // completed, and taking it again would repeat every side effect.
  wire take = (state_q == S_IDLE) && mem_valid_i && !mem_ready_o;

  // -------------------------------------------------------------------------
  // Boot ROM
  // -------------------------------------------------------------------------
  reg [31:0] rom [0:ROM_WORDS-1];
  initial $readmemh(FW_HEX, rom);

  wire [$clog2(ROM_WORDS)-1:0] rom_idx = mem_addr_i[$clog2(ROM_WORDS)+1:2];

  // -------------------------------------------------------------------------
  // SRAMs: one operation per request, issued combinationally in the cycle the
  // request is taken, so the macro samples it at the next edge.
  // -------------------------------------------------------------------------
  wire take_dram = take && (region == R_DRAM);
  wire take_wram = take && (region == R_WRAM);

  assign dram_csb_o   = ~take_dram;
  assign dram_web_o   = ~is_wr;
  assign dram_wmask_o = mem_wstrb_i;
  assign dram_addr_o  = mem_addr_i[9:2];
  assign dram_din_o   = mem_wdata_i;

  assign wram_csb_o   = ~take_wram;
  assign wram_web_o   = ~is_wr;
  assign wram_wmask_o = mem_wstrb_i;
  assign wram_addr_o  = mem_addr_i[10:2];
  assign wram_din_o   = mem_wdata_i;

  reg [3:0] pend_region_q;     // which SRAM a read in S_WAIT belongs to

  // -------------------------------------------------------------------------
  // Peripheral state
  // -------------------------------------------------------------------------
  reg        spi_busy_q;
  reg [7:0]  spi_rx_q;
  reg        s4_valid_q;
  reg        accel_pending_q;
  reg        accel_done_q;

  assign accel_in_valid_o = accel_pending_q;

  // Read-to-clear strobes, asserted only for a genuine read of that address.
  wire rd_sicu_s4   = take && !is_wr && (region == R_SICU) && (off == 8'h08);
  wire rd_accel_l2  = take && !is_wr && (region == R_ACCL) && (off == 8'h10);

  // -------------------------------------------------------------------------
  // Read data for register-type targets, computed in the cycle of the take.
  // -------------------------------------------------------------------------
  reg [31:0] reg_rdata;
  always_comb begin
    reg_rdata = 32'd0;
    case (region)
      R_ROM:  reg_rdata = rom[rom_idx];
      R_SYS: case (off)
        8'h00: reg_rdata = {28'd0, bist_pass_o, bist_done_o,
                            weights_fault_o, weights_ready_o};
        8'h04: reg_rdata = {24'd0, pred_conf_o, 2'd0, pred_class_o};
        8'h08: reg_rdata = {23'd0, loop_band_pref_o, loop_t_coh_o,
                            loop_fll_en_o, loop_pll_bw_o};
        8'h0C: reg_rdata = {16'd0, s4_report_o};
        8'h10: reg_rdata = {28'd0, host_ctrl_i};
        default: ;
      endcase
      R_SPI: case (off)
        8'h04: reg_rdata = {24'd0, spi_rx_q};
        8'h08: reg_rdata = {31'd0, spi_busy_q};
        8'h0C: reg_rdata = {31'd0, spi_hold_cs_o};
        default: ;
      endcase
      R_UART: case (off)
        8'h04: reg_rdata = {31'd0, uart_busy_i};
        default: ;
      endcase
      R_SICU: case (off)
        8'h00: reg_rdata = {31'd0, sicu_enable_o};
        8'h04: reg_rdata = {29'd0, sicu_busy_i, sicu_saturated_i, s4_valid_q};
        8'h08: reg_rdata = {16'd0, sicu_s4_i};
        8'h0C: reg_rdata = {27'd0, sicu_shift_i};
        default: ;
      endcase
      R_ACCL: case (off)
        8'h04: reg_rdata = {29'd0, accel_done_q, accel_pending_q, accel_busy_i};
        8'h0C: reg_rdata = {accel_logit1_i, accel_logit0_i};
        8'h10: reg_rdata = {14'd0, accel_class_i, accel_logit2_i};
        default: ;
      endcase
      default: reg_rdata = 32'd0;        // unmapped: read zero
    endcase
  end

  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q          <= S_IDLE;
      mem_ready_o      <= 1'b0;
      mem_rdata_o      <= 32'd0;
      pend_region_q    <= 4'd0;

      // System block resets to the same safe settings navic_sips_regs uses
      // in BYPASS, so nothing downstream sees garbage before firmware runs.
      weights_ready_o  <= 1'b0;
      weights_fault_o  <= 1'b0;
      bist_done_o      <= 1'b0;
      bist_pass_o      <= 1'b0;
      pred_class_o     <= 2'd0;
      pred_conf_o      <= 4'd0;
      loop_pll_bw_o    <= 3'd3;
      loop_fll_en_o    <= 1'b0;
      loop_t_coh_o     <= 3'd3;
      loop_band_pref_o <= 2'd0;
      s4_report_o      <= 16'd0;

      spi_start_o      <= 1'b0;
      spi_hold_cs_o    <= 1'b0;
      spi_tx_o         <= 8'd0;
      spi_busy_q       <= 1'b0;
      spi_rx_q         <= 8'd0;

      uart_valid_o     <= 1'b0;
      uart_data_o      <= 8'd0;

      sicu_enable_o    <= 1'b0;
      s4_valid_q       <= 1'b0;

      accel_start_o    <= 1'b0;
      accel_feat0_o    <= 16'd0;
      accel_feat1_o    <= 16'd0;
      accel_pending_q  <= 1'b0;
      accel_done_q     <= 1'b0;
    end else begin
      mem_ready_o   <= 1'b0;
      spi_start_o   <= 1'b0;
      uart_valid_o  <= 1'b0;
      accel_start_o <= 1'b0;

      // ---- events from the blocks, independent of the bus ---------------
      if (spi_done_i) begin
        spi_busy_q <= 1'b0;
        spi_rx_q   <= spi_rx_i;
      end
      // Accelerator consumed the pending timestep.
      if (accel_pending_q && accel_in_ready_i)
        accel_pending_q <= 1'b0;

      // Sticky flags: set on the block's pulse, cleared on the result read.
      // Set is written after clear so a coincident new result wins.
      if (rd_sicu_s4)        s4_valid_q   <= 1'b0;
      if (sicu_s4_valid_i)   s4_valid_q   <= 1'b1;
      if (rd_accel_l2)       accel_done_q <= 1'b0;
      if (accel_out_valid_i) accel_done_q <= 1'b1;

      // ---- bus ----------------------------------------------------------
      case (state_q)
        S_IDLE: if (take) begin
          if (region == R_DRAM || region == R_WRAM) begin
            pend_region_q <= region;
            state_q       <= S_WAIT;     // SRAM op issued combinationally
          end else begin
            mem_rdata_o <= reg_rdata;
            mem_ready_o <= 1'b1;

            if (is_wr) case (region)
              R_SYS: case (off)
                8'h00: begin
                  weights_ready_o <= mem_wdata_i[0];
                  weights_fault_o <= mem_wdata_i[1];
                  bist_done_o     <= mem_wdata_i[2];
                  bist_pass_o     <= mem_wdata_i[3];
                end
                8'h04: begin
                  pred_class_o <= mem_wdata_i[1:0];
                  pred_conf_o  <= mem_wdata_i[7:4];
                end
                8'h08: begin
                  loop_pll_bw_o    <= mem_wdata_i[2:0];
                  loop_fll_en_o    <= mem_wdata_i[3];
                  loop_t_coh_o     <= mem_wdata_i[6:4];
                  loop_band_pref_o <= mem_wdata_i[8:7];
                end
                8'h0C: s4_report_o <= mem_wdata_i[15:0];
                default: ;
              endcase
              R_SPI: case (off)
                8'h00: begin
                  spi_tx_o    <= mem_wdata_i[7:0];
                  spi_start_o <= 1'b1;
                  spi_busy_q  <= 1'b1;
                end
                8'h0C: spi_hold_cs_o <= mem_wdata_i[0];
                default: ;
              endcase
              R_UART: if (off == 8'h00) begin
                uart_data_o  <= mem_wdata_i[7:0];
                uart_valid_o <= 1'b1;
              end
              R_SICU: if (off == 8'h00) sicu_enable_o <= mem_wdata_i[0];
              R_ACCL: case (off)
                8'h00: accel_start_o <= mem_wdata_i[0];
                8'h08: begin
                  accel_feat0_o   <= mem_wdata_i[15:0];
                  accel_feat1_o   <= mem_wdata_i[31:16];
                  accel_pending_q <= 1'b1;   // after the clear above: wins
                end
                default: ;
              endcase
              default: ;                     // ROM and unmapped: ignored
            endcase
          end
        end

        // SRAM sampled our request at the edge that brought us here; its
        // registered dout is valid now.
        S_WAIT: begin
          mem_rdata_o <= (pend_region_q == R_DRAM) ? dram_dout_i : wram_dout_i;
          mem_ready_o <= 1'b1;
          state_q     <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
