// tb_system_accel.sv -- end-to-end run with the REAL LSTM accelerator.
//
// Same as tb_system.sv, but the accelerator model is replaced by two copies of
// the verified lstm_accel:
//   u_acc  in the system: reads weights the CPU loaded over SPI into the
//          weight SRAM (port 1), fed timesteps by the firmware through soc_bus
//   u_ref  reference: reads the weight image straight from the file, fed the
//          identical timesteps on the identical cycles
// Both are the same RTL, already bit-exact against the golden vectors, so any
// difference in their logits can only come from integration.
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
module tb_system_accel;
  localparam SICU_PERIOD = 4000;

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
  wire accel_start, accel_in_valid, accel_in_ready, accel_out_valid, accel_busy;
  wire [15:0] feat0, feat1;
  wire signed [15:0] l0, l1, l2; wire [1:0] acls;

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
    if (!acc_w_csb) acc_w_dout <= wmem[acc_w_addr];      // port 1, read only
    if (!ref_w_csb) ref_w_dout <= refmem[ref_w_addr];
  end

  // ---- the real accelerator, and its reference twin ------------------------
  wire acc_w_csb, ref_w_csb; wire [8:0] acc_w_addr, ref_w_addr;
  reg  [31:0] acc_w_dout = 0, ref_w_dout = 0;
  reg  [31:0] refmem [0:511];
  initial $readmemh("wimage.hex", refmem);

  lstm_accel #(.LUT_SIG("lut_sigmoid.hex"), .LUT_TANH("lut_tanh.hex")) u_acc (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(accel_start), .busy_o(accel_busy),
    .in_valid_i(accel_in_valid), .in_ready_o(accel_in_ready),
    .in_feat0_i(feat0), .in_feat1_i(feat1),
    .w_csb_o(acc_w_csb), .w_addr_o(acc_w_addr), .w_dout_i(acc_w_dout),
    .out_valid_o(accel_out_valid),
    .logit0_o(l0), .logit1_o(l1), .logit2_o(l2), .class_o(acls));

  wire ref_ready, ref_valid, ref_busy; wire signed [15:0] r0, r1, r2; wire [1:0] rcls;
  lstm_accel #(.LUT_SIG("lut_sigmoid.hex"), .LUT_TANH("lut_tanh.hex")) u_ref (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(accel_start), .busy_o(ref_busy),
    .in_valid_i(accel_in_valid), .in_ready_o(ref_ready),
    .in_feat0_i(feat0), .in_feat1_i(feat1),
    .w_csb_o(ref_w_csb), .w_addr_o(ref_w_addr), .w_dout_i(ref_w_dout),
    .out_valid_o(ref_valid),
    .logit0_o(r0), .logit1_o(r1), .logit2_o(r2), .class_o(rcls));

  // ---- SPI flash model, byte level ----------------------------------------
  // Byte 0 is the command, 1-3 the address; data starts at byte 4.
  reg [7:0] flash [0:2051];
  initial $readmemh("flash.hex", flash);
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
      if (sicu_t == SICU_PERIOD && n_windows < 63) begin
        sicu_t = 0;
        sicu_s4 <= s4_seq[n_windows];
        sicu_s4_valid <= 1;
        n_windows = n_windows + 1;
        if (n_windows == 32) cyc_w32 = cyc;
      end
    end
  end

  // ---- record what the firmware feeds, and when each accelerator finishes --
  integer n_feat = 0, n_starts = 0, lockstep_err = 0;
  reg [15:0] got_feat [0:31];
  reg signed [15:0] sys_l [0:2], ref_l [0:2];
  reg sys_done = 0, ref_done = 0;
  always @(posedge clk) begin
    if (accel_start) n_starts = n_starts + 1;
    if (accel_in_valid && accel_in_ready) begin
      if (n_feat < 32) got_feat[n_feat] = feat0;
      n_feat = n_feat + 1;
    end
    if (accel_in_ready !== ref_ready) lockstep_err = lockstep_err + 1;
    if (accel_out_valid && !sys_done) begin
      sys_l[0] = l0; sys_l[1] = l1; sys_l[2] = l2; sys_done = 1;
    end
    if (ref_valid && !ref_done) begin
      ref_l[0] = r0; ref_l[1] = r1; ref_l[2] = r2; ref_done = 1;
    end
  end

  // ---- checks -------------------------------------------------------------
  integer errors = 0, cyc = 0;
  reg [31:0] wexp [0:511];
  // mu and 1/sd come from the header of the image under test, not constants:
  // the real exported weights carry different values from any test image.
  integer mu_g, invsd_g;
  function automatic signed [15:0] norm(input [15:0] s4);
    integer q88, d, o;
    begin
      q88 = (s4 + 8) >>> 4;
      d   = q88 - mu_g;
      o   = (d * invsd_g + 128) >>> 8;
      if (o >  32767) o =  32767;
      if (o < -32768) o = -32768;
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
    $readmemh("wimage.hex", wexp);
    mu_g    = $signed(wexp[0][15:0]);
    invsd_g = $signed(wexp[1][15:0]);
    $display("       header: mu = %0d/256, 1/sd = %0d/256", mu_g, invsd_g);
    repeat (5) @(posedge clk); rst_n = 1;

    wait (sicu_enable === 1'b1);
    $display("cycle %0d  firmware reached the main loop (%0d SPI bytes)", cyc, n_spi);
    for (k = 0; k < 512; k = k + 1)
      if (wmem[k] !== wexp[k]) begin
        if (errors < 5) $display("FAIL  weight word %0d: %h != %h", k, wmem[k], wexp[k]);
        errors = errors + 1;
      end
    if (errors == 0) $display("pass  all 512 weight words loaded and match");
    if (weights_fault) begin $display("FAIL  firmware reported weight fault"); errors = errors + 1; end
    else $display("pass  checksum accepted, no fault");
    if (weights_ready) begin $display("FAIL  ready asserted before first result"); errors = errors + 1; end
    else $display("pass  not ready during cold start");

    wait (weights_ready === 1'b1);
    $display("cycle %0d  first result published", cyc);
    $display("       inference latency: %0d cycles from the 32nd window to the result", cyc - cyc_w32);
    $display("       = %0.2f ms at 33 MHz, against a 10 s window", (cyc - cyc_w32) / 33000.0);
    if (n_windows < 32) begin $display("FAIL  result before 32 windows"); errors = errors + 1; end
    if (n_starts != 1)   begin $display("FAIL  %0d accelerator starts", n_starts); errors = errors + 1; end
    for (k = 0; k < 32; k = k + 1)
      if (got_feat[k] !== norm(s4_seq[k])) begin
        if (errors < 8) $display("FAIL  timestep %0d fed %h, expected %h",
                                 k, got_feat[k], norm(s4_seq[k]));
        errors = errors + 1;
      end
    $display("%s  32 timesteps normalised correctly and fed oldest-first",
             (errors == 0) ? "pass" : "    ");
    $display("       accelerator started %0d time(s), took %0d timesteps", n_starts, n_feat);
    if (lockstep_err) begin
      $display("FAIL  system and reference accelerators left lockstep (%0d cycles)", lockstep_err);
      errors = errors + 1;
    end else $display("pass  system and reference accelerators stayed in lockstep");
    if (!sys_done || !ref_done) begin
      $display("FAIL  an accelerator never finished"); errors = errors + 1;
    end
    $display("       system    logits  %6d %6d %6d", sys_l[0], sys_l[1], sys_l[2]);
    $display("       reference logits  %6d %6d %6d", ref_l[0], ref_l[1], ref_l[2]);
    if (sys_l[0] !== ref_l[0] || sys_l[1] !== ref_l[1] || sys_l[2] !== ref_l[2]) begin
      $display("FAIL  logits differ -- integration corrupted weights or timesteps");
      errors = errors + 1;
    end else $display("pass  logits bit-identical to the reference");
    begin : expect_class
      integer ru, ec, m, ec_conf;
      ru = (sys_l[0] > sys_l[1]) ? sys_l[0] : sys_l[1];
      if (sys_l[2] - ru >= 64) begin ec = 2; m = sys_l[2] - ru; end
      else if (sys_l[1] > sys_l[0]) begin
        ec = 1; m = sys_l[1] - ((sys_l[0] > sys_l[2]) ? sys_l[0] : sys_l[2]);
      end else begin
        ec = 0; m = sys_l[0] - ((sys_l[1] > sys_l[2]) ? sys_l[1] : sys_l[2]);
      end
      ec_conf = m >>> 6; if (ec_conf > 15) ec_conf = 15; if (ec_conf < 0) ec_conf = 0;
      if (pred_class !== ec[1:0]) begin
        $display("FAIL  firmware published class %0d, margin rule gives %0d", pred_class, ec);
        errors = errors + 1;
      end else $display("pass  firmware's class %0d matches the margin rule on real logits", pred_class);
      if (pred_conf !== ec_conf[3:0]) begin
        $display("FAIL  confidence %0d, expected %0d", pred_conf, ec_conf);
        errors = errors + 1;
      end else $display("pass  confidence %0d", pred_conf);
    end
    if (s4_report !== s4_seq[31]) begin $display("FAIL  S4 report %h", s4_report); errors = errors + 1; end
    else $display("pass  latest S4 reported to the host block");

    $display("");
    if (errors == 0) $display("PASS: system -- firmware boots, loads, infers, publishes");
    else             $display("FAIL: system -- %0d errors", errors);
    $finish;
  end

  initial begin #20_000_000; $display("FAIL: timeout at cycle %0d", cyc); $finish; end
endmodule
`default_nettype wire
