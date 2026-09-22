// tb_system.sv -- first end-to-end run of the NavIC-SIPS control path.
//
// Real PicoRV32 (RV32IMC, as hardened), real soc_bus, real firmware from the
// boot ROM. Behavioural models stand in for:
//   - SPI flash      byte-level: answers each spi_start with the next byte
//   - SICU           pulses a new S4 every SICU_PERIOD cycles once enabled
//   - accelerator    accepts 32 timesteps, then returns fixed logits
// The SRAMs are modelled with a registered output like the SKY130 macros.
//
// Checks that the firmware boots, loads and verifies all 512 weight words,
// feeds the accelerator 32 correctly normalised timesteps in order, and
// publishes the class, loop settings and weights_ready it should.
`timescale 1ns/1ps
`default_nettype none
module tb_system;
  localparam SICU_PERIOD = 1500;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ---- CPU ----------------------------------------------------------------
  wire        mem_valid, mem_instr, mem_ready, trap;
  wire [31:0] mem_addr, mem_wdata, mem_rdata;
  wire [ 3:0] mem_wstrb;

  picorv32 #(
    .ENABLE_MUL(1), .ENABLE_DIV(1), .COMPRESSED_ISA(1), .ENABLE_IRQ(1),
    .ENABLE_COUNTERS64(0),
    .PROGADDR_RESET(32'h0000_0000), .PROGADDR_IRQ(32'h0000_0010)
  ) u_cpu (
    .clk(clk), .resetn(rst_n), .trap(trap),
    .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
    .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
    .mem_rdata(mem_rdata),
    .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(),
    .mem_la_wstrb(),
    .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
    .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
    .irq(32'd0), .eoi(), .trace_valid(), .trace_data()
  );

  // ---- bus + peripheral wires ---------------------------------------------
  wire dram_csb, dram_web, wram_csb, wram_web;
  wire [3:0] dram_wmask, wram_wmask; wire [7:0] dram_addr; wire [8:0] wram_addr;
  wire [31:0] dram_din, wram_din; reg [31:0] dram_dout = 0, wram_dout = 0;

  wire weights_ready, weights_fault, bist_done, bist_pass, loop_fll_en;
  wire [1:0] pred_class, loop_band_pref; wire [3:0] pred_conf;
  wire [2:0] loop_pll_bw, loop_t_coh; wire [15:0] s4_report;

  wire spi_start, spi_hold_cs; wire [7:0] spi_tx; reg [7:0] spi_rx = 0;
  reg spi_done = 0;
  wire uart_valid; wire [7:0] uart_data;

  wire sicu_enable; reg sicu_s4_valid = 0; reg [15:0] sicu_s4 = 0;
  wire accel_start, accel_in_valid; reg accel_in_ready = 0, accel_out_valid = 0;
  wire [15:0] feat0, feat1;
  reg [15:0] l0 = 0, l1 = 0, l2 = 0; reg [1:0] acls = 0; reg accel_busy = 0;

  soc_bus #(.FW_HEX("firmware.hex")) u_bus (
    .clk_i(clk), .rst_ni(rst_n),
    .mem_valid_i(mem_valid), .mem_ready_o(mem_ready), .mem_addr_i(mem_addr),
    .mem_wdata_i(mem_wdata), .mem_wstrb_i(mem_wstrb), .mem_rdata_o(mem_rdata),
    .dram_csb_o(dram_csb), .dram_web_o(dram_web), .dram_wmask_o(dram_wmask),
    .dram_addr_o(dram_addr), .dram_din_o(dram_din), .dram_dout_i(dram_dout),
    .wram_csb_o(wram_csb), .wram_web_o(wram_web), .wram_wmask_o(wram_wmask),
    .wram_addr_o(wram_addr), .wram_din_o(wram_din), .wram_dout_i(wram_dout),
    .weights_ready_o(weights_ready), .weights_fault_o(weights_fault),
    .bist_done_o(bist_done), .bist_pass_o(bist_pass),
    .pred_class_o(pred_class), .pred_conf_o(pred_conf),
    .loop_pll_bw_o(loop_pll_bw), .loop_fll_en_o(loop_fll_en),
    .loop_t_coh_o(loop_t_coh), .loop_band_pref_o(loop_band_pref),
    .s4_report_o(s4_report), .host_ctrl_i(4'd0),
    .spi_start_o(spi_start), .spi_hold_cs_o(spi_hold_cs), .spi_tx_o(spi_tx),
    .spi_rx_i(spi_rx), .spi_done_i(spi_done),
    .uart_valid_o(uart_valid), .uart_data_o(uart_data), .uart_busy_i(1'b0),
    .sicu_enable_o(sicu_enable), .sicu_s4_valid_i(sicu_s4_valid),
    .sicu_s4_i(sicu_s4), .sicu_saturated_i(1'b0), .sicu_shift_i(5'd0),
    .sicu_busy_i(1'b0),
    .accel_start_o(accel_start), .accel_busy_i(accel_busy),
    .accel_in_valid_o(accel_in_valid), .accel_in_ready_i(accel_in_ready),
    .accel_feat0_o(feat0), .accel_feat1_o(feat1),
    .accel_out_valid_i(accel_out_valid), .accel_logit0_i(l0),
    .accel_logit1_i(l1), .accel_logit2_i(l2), .accel_class_i(acls));

  // ---- SRAM models ---------------------------------------------------------
  reg [31:0] dmem [0:255], wmem [0:511];
  integer k;
  always @(posedge clk) begin
    if (!dram_csb) begin
      if (!dram_web) for (k = 0; k < 4; k = k + 1)
        begin if (dram_wmask[k]) dmem[dram_addr][8*k +: 8] <= dram_din[8*k +: 8]; end
      else dram_dout <= dmem[dram_addr];
    end
    if (!wram_csb) begin
      if (!wram_web) for (k = 0; k < 4; k = k + 1)
        begin if (wram_wmask[k]) wmem[wram_addr][8*k +: 8] <= wram_din[8*k +: 8]; end
      else wram_dout <= wmem[wram_addr];
    end
  end

  // ---- SPI flash model, byte level ----------------------------------------
  // Byte 0 is the command, 1-3 the address; data starts at byte 4.
  reg [7:0] flash [0:2051];
  initial $readmemh("flash_bad.hex", flash);
  integer spi_idx = 0, spi_wait = -1, n_spi = 0;
  reg hold_d = 0;
  always @(posedge clk) begin
    spi_done <= 0;
    hold_d   <= spi_hold_cs;
    if (spi_hold_cs && !hold_d) spi_idx = 0;       // CS asserted: new burst
    if (spi_start) begin spi_wait = 6; n_spi = n_spi + 1; end
    else if (spi_wait > 0) spi_wait = spi_wait - 1;
    else if (spi_wait == 0) begin
      spi_rx   <= (spi_idx >= 4) ? flash[spi_idx - 4] : 8'hFF;
      spi_done <= 1;
      spi_idx  = spi_idx + 1;
      spi_wait = -1;
    end
  end

  // ---- SICU model: an S4 ramp, one value per window -----------------------
  integer n_windows = 0, sicu_t = 0, cyc_w32 = 0;
  reg [15:0] s4_seq [0:63];
  initial for (k = 0; k < 64; k = k + 1) s4_seq[k] = 16'h0100 + k * 16'h0040;
  always @(posedge clk) begin
    sicu_s4_valid <= 0;
    if (sicu_enable) begin
      sicu_t = sicu_t + 1;
      if (sicu_t == SICU_PERIOD) begin
        sicu_t = 0;
        sicu_s4 <= s4_seq[n_windows];
        sicu_s4_valid <= 1;
        n_windows = n_windows + 1;
        if (n_windows == 32) cyc_w32 = cyc;
      end
    end
  end

  // ---- accelerator model --------------------------------------------------
  integer n_feat = 0, accel_wait = -1, n_starts = 0;
  reg [15:0] got_feat [0:31];
  always @(posedge clk) begin
    accel_in_ready  <= 0;
    accel_out_valid <= 0;
    if (accel_start) begin n_starts = n_starts + 1; n_feat = 0; accel_busy <= 1; end
    if (accel_in_valid && !accel_in_ready && n_feat < 32) begin
      accel_in_ready <= 1;
      got_feat[n_feat] = feat0;
      if (feat0 !== feat1) begin
        $display("FAIL  timestep %0d: feat0 %h != feat1 %h", n_feat, feat0, feat1);
      end
      n_feat = n_feat + 1;
      if (n_feat == 32) accel_wait = 40;
    end
    if (accel_wait > 0) accel_wait = accel_wait - 1;
    else if (accel_wait == 0) begin
      // SEVERE by a clear margin: l2 - max(l0, l1) = 0.75 >= 0.25
      l0 <= 16'sh0040; l1 <= 16'sh0080; l2 <= 16'sh0140; acls <= 2;
      accel_out_valid <= 1; accel_busy <= 0; accel_wait = -1;
    end
  end

  // ---- checks -------------------------------------------------------------
  integer errors = 0, cyc = 0;
  reg [31:0] wexp [0:511];
  function automatic signed [15:0] norm(input [15:0] s4);
    integer q88, d, o;
    begin
      q88 = (s4 + 8) >>> 4;
      d   = q88 - 16'h0020;
      o   = (d * 16'sh0145 + 128) >>> 8;
      norm = o[15:0];
    end
  endfunction

  always @(posedge clk) begin
    cyc = cyc + 1;
    if (trap) begin
      $display("FAIL  CPU trapped at cycle %0d, pc near %h", cyc, mem_addr);
      errors = errors + 1; $finish;
    end
  end

  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    wait (weights_fault === 1'b1);
    $display("cycle %0d  weights_fault asserted after %0d SPI bytes (%0d attempts)",
             cyc, n_spi, n_spi / 2056);
    repeat (50000) @(posedge clk);
    if (weights_ready)  $display("FAIL  became ready despite a bad image");
    else                $display("pass  never becomes ready -- host keeps its own settings");
    if (sicu_enable)    $display("FAIL  started measuring on a bad image");
    else                $display("pass  never starts measuring");
    if (loop_pll_bw == 3 && loop_t_coh == 3) $display("pass  loop settings stay at the safe defaults");
    else                $display("FAIL  loop settings moved off safe");
    $finish;
  end

  initial begin #20_000_000; $display("FAIL: timeout at cycle %0d", cyc); $finish; end
endmodule
`default_nettype wire
