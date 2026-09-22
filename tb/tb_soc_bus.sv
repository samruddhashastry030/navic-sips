// tb_soc_bus.sv -- directed test for soc_bus.
// Drives the PicoRV32 native handshake, models the SRAMs with a registered
// output like the SKY130 macros, and checks every target plus the property
// that each access performs its side effects exactly once.
`timescale 1ns/1ps
`default_nettype none
module tb_soc_bus;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  reg         mem_valid = 0;
  wire        mem_ready;
  reg  [31:0] mem_addr = 0, mem_wdata = 0;
  reg  [ 3:0] mem_wstrb = 0;
  wire [31:0] mem_rdata;

  wire dram_csb, dram_web, wram_csb, wram_web;
  wire [3:0] dram_wmask, wram_wmask;
  wire [7:0] dram_addr; wire [8:0] wram_addr;
  wire [31:0] dram_din, wram_din;
  reg  [31:0] dram_dout = 0, wram_dout = 0;

  wire weights_ready, weights_fault, bist_done, bist_pass, loop_fll_en;
  wire [1:0] pred_class, loop_band_pref; wire [3:0] pred_conf;
  wire [2:0] loop_pll_bw, loop_t_coh; wire [15:0] s4_report;
  wire idx_valid, pred_valid;
  reg  [3:0] host_ctrl = 4'b0101;

  wire spi_start, spi_hold_cs; wire [7:0] spi_tx;
  reg  [7:0] spi_rx = 0; reg spi_done = 0;
  wire uart_valid; wire [7:0] uart_data; reg uart_busy = 0;

  wire sicu_enable; reg sicu_s4_valid = 0; reg [15:0] sicu_s4 = 0;
  reg sicu_sat = 0; reg [4:0] sicu_shift = 0; reg sicu_busy = 0;

  wire accel_start, accel_in_valid; reg accel_busy = 0, accel_in_ready = 0;
  wire [15:0] feat0, feat1; reg accel_out_valid = 0;
  reg [15:0] l0 = 16'h1111, l1 = 16'h2222, l2 = 16'h3333; reg [1:0] acls = 2'd2;

  soc_bus #(.FW_HEX("firmware.hex")) dut (
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
    .s4_report_o(s4_report), .idx_valid_o(idx_valid), .pred_valid_o(pred_valid),
    .host_ctrl_i(host_ctrl),
    .spi_start_o(spi_start), .spi_hold_cs_o(spi_hold_cs), .spi_tx_o(spi_tx),
    .spi_rx_i(spi_rx), .spi_done_i(spi_done),
    .uart_valid_o(uart_valid), .uart_data_o(uart_data), .uart_busy_i(uart_busy),
    .sicu_enable_o(sicu_enable), .sicu_s4_valid_i(sicu_s4_valid),
    .sicu_s4_i(sicu_s4), .sicu_saturated_i(sicu_sat), .sicu_shift_i(sicu_shift),
    .sicu_busy_i(sicu_busy),
    .accel_start_o(accel_start), .accel_busy_i(accel_busy),
    .accel_in_valid_o(accel_in_valid), .accel_in_ready_i(accel_in_ready),
    .accel_feat0_o(feat0), .accel_feat1_o(feat1),
    .accel_out_valid_i(accel_out_valid), .accel_logit0_i(l0),
    .accel_logit1_i(l1), .accel_logit2_i(l2), .accel_class_i(acls));

  // ---- SRAM models: sample at the edge, registered dout -----------------
  reg [31:0] dmem [0:255], wmem [0:511];
  integer k;
  initial for (k = 0; k < 512; k = k + 1) begin
    wmem[k] = 32'hDEAD0000 + k; if (k < 256) dmem[k] = 32'hBEEF0000 + k;
  end
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

  // ---- count one-cycle pulses, to prove side effects happen once --------
  integer n_spi_start = 0, n_uart = 0, n_accel_start = 0, n_dram_ops = 0;
  integer n_idx = 0, n_pred = 0;
  reg [1:0] class_at_pulse; reg [15:0] s4_at_pulse;
  always @(posedge clk) begin
    if (spi_start)   n_spi_start   = n_spi_start + 1;
    if (uart_valid)  n_uart        = n_uart + 1;
    if (accel_start) n_accel_start = n_accel_start + 1;
    if (!dram_csb)   n_dram_ops    = n_dram_ops + 1;
    if (idx_valid)  begin n_idx  = n_idx + 1;  s4_at_pulse    = s4_report;  end
    if (pred_valid) begin n_pred = n_pred + 1; class_at_pulse = pred_class; end
  end

  // ---- PicoRV32-style master ---------------------------------------------
  integer errors = 0, cycles, got;
  task automatic access(input [31:0] a, input [31:0] wd, input [3:0] ws,
                        output [31:0] rd);
    begin
      @(negedge clk);
      mem_addr = a; mem_wdata = wd; mem_wstrb = ws; mem_valid = 1;
      cycles = 0; got = 0;
      while (!got) begin
        @(negedge clk); cycles = cycles + 1;
        if (mem_ready) begin rd = mem_rdata; got = 1; end
        else if (cycles > 20) begin
          $display("FAIL  bus hung on addr %h", a); errors = errors + 1;
          rd = 32'hX; got = 1;
        end
      end
      @(posedge clk); #1;
      mem_valid = 0; mem_wstrb = 0;
    end
  endtask

  task automatic rd32(input [31:0] a, output [31:0] v);
    access(a, 32'd0, 4'b0000, v);
  endtask
  reg [31:0] wr_dummy;
  task automatic wr32(input [31:0] a, input [31:0] v);
    access(a, v, 4'b1111, wr_dummy);
  endtask
  task automatic check(input [255:0] what, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s: got %h expected %h", what, got, exp);
      errors = errors + 1;
    end else $display("pass  %0s = %h", what, got);
  endtask

  reg [31:0] v, rom0;
  integer b0;
  initial begin
    $readmemh("firmware.hex", dut.rom);   // also for the expected value
    rom0 = dut.rom[0];
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

    // reset state: safe loop settings, not ready
    check("reset pll_bw (safe=3)", loop_pll_bw, 3);
    check("reset t_coh  (safe=3)", loop_t_coh, 3);
    check("reset weights_ready", weights_ready, 0);

    // ROM
    rd32(32'h0000_0000, v); check("ROM word 0", v, rom0);

    // unmapped region must complete and read zero, not hang
    rd32(32'hF000_0000, v); check("unmapped read", v, 0);

    // data RAM: write, read back, and byte strobes
    wr32(32'h1000_0010, 32'hCAFEF00D);
    rd32(32'h1000_0010, v); check("DRAM word write/read", v, 32'hCAFEF00D);
    access(32'h1000_0010, 32'h000000AA, 4'b0001, v);        // byte 0 only
    rd32(32'h1000_0010, v); check("DRAM byte strobe", v, 32'hCAFEF0AA);
    rd32(32'h1000_0000, v); check("DRAM untouched word", v, 32'hBEEF0000);

    // weight SRAM
    wr32(32'h2000_07FC, 32'h12345678);                      // last word, 511
    rd32(32'h2000_07FC, v); check("WRAM last word", v, 32'h12345678);
    rd32(32'h2000_0004, v); check("WRAM word 1", v, 32'hDEAD0001);

    // one SRAM access must issue exactly one SRAM operation
    b0 = n_dram_ops;
    rd32(32'h1000_0020, v);
    check("DRAM ops per read", n_dram_ops - b0, 1);

    // system register block
    wr32(32'h3000_0000, 32'h1);           check("weights_ready", weights_ready, 1);
    b0 = n_pred;
    wr32(32'h3000_0004, 32'h00000052);    // class 2, conf 5
    check("pred_class", pred_class, 2);   check("pred_conf", pred_conf, 5);
    check("pred_valid pulses", n_pred - b0, 1);
    check("class valid WITH the pulse", class_at_pulse, 2);
    b0 = n_idx;
    wr32(32'h3000_000C, 32'h00000ABC);
    check("idx_valid pulses", n_idx - b0, 1);
    check("S4 valid WITH the pulse", s4_at_pulse, 16'h0ABC);
    b0 = n_pred;
    wr32(32'h3000_0008, 32'h00000000);    // loop write must not fire pred_valid
    check("no pred_valid on loop write", n_pred - b0, 0);
    wr32(32'h3000_0008, 32'h0000019B);    // pll 3, fll 1, tcoh 1, band 3
    check("loop pll", loop_pll_bw, 3);    check("loop fll", loop_fll_en, 1);
    check("loop tcoh", loop_t_coh, 1);    check("loop band", loop_band_pref, 3);
    rd32(32'h3000_0008, v);               check("loop readback", v, 32'h0000019B);
    rd32(32'h3000_0010, v);               check("host ctrl readback", v, 4'b0101);

    // SPI: one start pulse per TX write, busy until done, RX latched
    b0 = n_spi_start;
    wr32(32'h4000_0000, 32'h03);
    check("spi_tx", spi_tx, 8'h03);
    check("spi_start pulses", n_spi_start - b0, 1);
    rd32(32'h4000_0008, v);               check("spi busy", v, 1);
    @(negedge clk); spi_rx = 8'h5A; spi_done = 1; @(negedge clk); spi_done = 0;
    rd32(32'h4000_0008, v);               check("spi busy cleared", v, 0);
    rd32(32'h4000_0004, v);               check("spi rx", v, 8'h5A);

    // UART
    b0 = n_uart;
    wr32(32'h5000_0000, 32'h41);
    check("uart byte", uart_data, 8'h41);
    check("uart pulses", n_uart - b0, 1);

    // SICU: sticky valid, cleared by reading S4, new result wins
    wr32(32'h6000_0000, 32'h1);           check("sicu enable", sicu_enable, 1);
    rd32(32'h6000_0004, v);               check("sicu valid idle", v & 1, 0);
    @(negedge clk); sicu_s4 = 16'h0ABC; sicu_s4_valid = 1;
    @(negedge clk); sicu_s4_valid = 0;
    rd32(32'h6000_0004, v);               check("sicu valid latched", v & 1, 1);
    rd32(32'h6000_0004, v);               check("sicu valid survives STATUS read", v & 1, 1);
    rd32(32'h6000_0008, v);               check("sicu S4", v, 16'h0ABC);
    rd32(32'h6000_0004, v);               check("sicu valid cleared by S4 read", v & 1, 0);

    // accelerator: start pulse, FEAT handshake, sticky done
    b0 = n_accel_start;
    wr32(32'h7000_0000, 32'h1);
    check("accel start pulses", n_accel_start - b0, 1);
    wr32(32'h7000_0008, 32'hBBBB_AAAA);
    check("feat0", feat0, 16'hAAAA);      check("feat1", feat1, 16'hBBBB);
    check("in_valid while pending", accel_in_valid, 1);
    rd32(32'h7000_0004, v);               check("pending flag", (v >> 1) & 1, 1);
    @(negedge clk); accel_in_ready = 1; @(negedge clk); accel_in_ready = 0;
    check("in_valid dropped after accept", accel_in_valid, 0);
    rd32(32'h7000_0004, v);               check("pending cleared", (v >> 1) & 1, 0);
    @(negedge clk); accel_out_valid = 1; @(negedge clk); accel_out_valid = 0;
    rd32(32'h7000_0004, v);               check("done latched", (v >> 2) & 1, 1);
    rd32(32'h7000_000C, v);               check("logit01", v, 32'h2222_1111);
    rd32(32'h7000_0004, v);               check("done survives LOGIT01", (v >> 2) & 1, 1);
    rd32(32'h7000_0010, v);               check("logit2 + class", v, 32'h0002_3333);
    rd32(32'h7000_0004, v);               check("done cleared by LOGIT2", (v >> 2) & 1, 0);

    // back-to-back accesses with no gap must each complete exactly once
    b0 = n_spi_start;
    wr32(32'h4000_0000, 32'h11);
    wr32(32'h4000_0000, 32'h22);
    wr32(32'h4000_0000, 32'h33);
    check("3 back-to-back TX -> 3 pulses", n_spi_start - b0, 3);

    $display("");
    if (errors == 0) $display("PASS: soc_bus, all checks");
    else             $display("FAIL: soc_bus, %0d errors", errors);
    $finish;
  end
endmodule
`default_nettype wire
