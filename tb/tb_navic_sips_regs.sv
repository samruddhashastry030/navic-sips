// ---------------------------------------------------------------------------
// tb_navic_sips_regs.sv  -- self-checking testbench
//
//   iverilog -g2012 -o tb.vvp rtl/navic_sips_regs.sv tb/tb_navic_sips_regs.sv
//   vvp tb.vvp
//
// A cocotb version should replace this once the block is integrated; this is
// the quick standalone check.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_navic_sips_regs;

  localparam logic [4:0] ADDR_ID      = 5'h00;
  localparam logic [4:0] ADDR_CTRL    = 5'h04;
  localparam logic [4:0] ADDR_STATUS  = 5'h08;
  localparam logic [4:0] ADDR_INDEX   = 5'h0C;
  localparam logic [4:0] ADDR_LOOPCFG = 5'h10;
  localparam logic [4:0] ADDR_IRQST   = 5'h14;
  localparam logic [4:0] ADDR_IRQEN   = 5'h18;
  localparam logic [4:0] ADDR_SCRATCH = 5'h1C;

  reg         clk = 0, rst_n = 0;
  reg         sel = 0, we = 0;
  reg  [ 4:0] addr = 0;
  reg  [31:0] wdata = 0;
  wire [31:0] rdata;
  wire        ack;

  reg         idx_valid = 0;
  reg  [15:0] s4 = 0, sphi = 0;
  reg         pred_valid = 0;
  reg  [ 1:0] pred_class = 0;
  reg  [ 3:0] pred_conf = 0;
  reg  [ 2:0] pll_bw = 3'd5;
  reg         fll_en = 1'b1;
  reg  [ 2:0] t_coh = 3'd6;
  reg  [ 1:0] band_pref = 2'd1;
  reg         w_ready = 0, w_fault = 0;
  reg         bist_done = 0, bist_pass = 0;
  reg         bypass_pin = 0;

  wire enable, bist_start, soft_reset, irq, ready_pin, fault_pin;

  integer errors = 0;
  integer checks = 0;

  navic_sips_regs dut (
      .clk_i(clk), .rst_ni(rst_n),
      .bus_sel_i(sel), .bus_we_i(we), .bus_addr_i(addr),
      .bus_wdata_i(wdata), .bus_rdata_o(rdata), .bus_ack_o(ack),
      .idx_valid_i(idx_valid), .s4_i(s4), .sphi_i(sphi),
      .pred_valid_i(pred_valid), .pred_class_i(pred_class),
      .pred_conf_i(pred_conf),
      .loop_pll_bw_i(pll_bw), .loop_fll_en_i(fll_en),
      .loop_t_coh_i(t_coh), .loop_band_pref_i(band_pref),
      .weights_ready_i(w_ready), .weights_fault_i(w_fault),
      .bist_done_i(bist_done), .bist_pass_i(bist_pass),
      .enable_o(enable), .bist_start_o(bist_start),
      .soft_reset_o(soft_reset),
      .bypass_pin_i(bypass_pin), .irq_o(irq),
      .ready_pin_o(ready_pin), .fault_pin_o(fault_pin)
  );

  always #5 clk = ~clk;

  task automatic bus_wr(input [4:0] a, input [31:0] d);
    begin
      @(negedge clk); sel = 1; we = 1; addr = a; wdata = d;
      @(negedge clk); sel = 0; we = 0;
    end
  endtask

  task automatic bus_rd(input [4:0] a, output [31:0] d);
    begin
      @(negedge clk); sel = 1; we = 0; addr = a;
      @(negedge clk); sel = 0;
      @(negedge clk); d = rdata;
    end
  endtask

  task automatic chk(input [255:0] name, input [31:0] got, input [31:0] exp);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("  FAIL %0s: got %08x expected %08x", name, got, exp);
      end else begin
        $display("  ok   %0s = %08x", name, got);
      end
    end
  endtask

  reg [31:0] d;

  initial begin
    $dumpfile("tb_navic_sips_regs.vcd");
    $dumpvars(0, tb_navic_sips_regs);

    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    $display("\n== 1. bring-up aids ==");
    bus_rd(ADDR_ID, d);       chk("DEVICE_ID", d, 32'h5195_0001);
    bus_wr(ADDR_SCRATCH, 32'hDEAD_BEEF);
    bus_rd(ADDR_SCRATCH, d);  chk("SCRATCH rw", d, 32'hDEAD_BEEF);

    $display("\n== 2. CTRL / enable ==");
    bus_rd(ADDR_CTRL, d);     chk("CTRL reset", d, 32'h0);
    chk("enable low", {31'h0, enable}, 32'h0);
    bus_wr(ADDR_CTRL, 32'h1);            // ENABLE
    bus_rd(ADDR_CTRL, d);     chk("CTRL enabled", d, 32'h1);
    chk("enable high", {31'h0, enable}, 32'h1);

    $display("\n== 3. datapath capture ==");
    @(negedge clk); idx_valid = 1; s4 = 16'h1234; sphi = 16'h5678;
    @(negedge clk); idx_valid = 0;
    bus_rd(ADDR_INDEX, d);    chk("INDEX {sphi,s4}", d, 32'h5678_1234);

    @(negedge clk); pred_valid = 1; pred_class = 2'd1; pred_conf = 4'hA;
    @(negedge clk); pred_valid = 0;
    bus_rd(ADDR_STATUS, d);
    chk("class DEGRADED", {30'h0, d[1:0]}, 32'd1);
    chk("valid set",      {31'h0, d[2]},   32'd1);
    chk("conf",           {28'h0, d[6:3]}, 32'hA);

    $display("\n== 4. LOOP_CFG incl. BAND_PREF ==");
    bus_rd(ADDR_LOOPCFG, d);
    chk("pll_bw",    {29'h0, d[2:0]}, 32'd5);
    chk("fll_en",    {31'h0, d[3]},   32'd1);
    chk("t_coh",     {29'h0, d[6:4]}, 32'd6);
    chk("band_pref", {30'h0, d[8:7]}, 32'd1);   // S band recommended

    $display("\n== 5. SEVERE interrupt ==");
    bus_wr(ADDR_IRQEN, 32'h7);
    @(negedge clk); pred_valid = 1; pred_class = 2'd2; pred_conf = 4'hF;
    @(negedge clk); pred_valid = 0;
    repeat (2) @(negedge clk);
    chk("irq asserted", {31'h0, irq}, 32'h1);
    bus_rd(ADDR_IRQST, d);  chk("IRQ_STATUS SEVERE", {31'h0, d[0]}, 32'h1);
    bus_wr(ADDR_IRQST, 32'h1);                   // W1C
    repeat (2) @(negedge clk);
    chk("irq cleared", {31'h0, irq}, 32'h0);

    $display("\n== 6. BIST ==");
    bus_wr(ADDR_CTRL, 32'h5);                    // ENABLE | BIST
    chk("bist_start pulsed", {31'h0, bist_start}, 32'h1);
    repeat (2) @(negedge clk);
    chk("bist_start self-clears", {31'h0, bist_start}, 32'h0);
    @(negedge clk); bist_done = 1; bist_pass = 1;
    @(negedge clk); bist_done = 0;
    bus_rd(ADDR_STATUS, d);
    chk("BIST_DONE", {31'h0, d[10]}, 32'h1);
    chk("BIST_PASS", {31'h0, d[11]}, 32'h1);

    $display("\n== 7. weight-load pads ==");
    @(negedge clk); w_ready = 1;
    repeat (2) @(negedge clk);
    chk("ready_pin", {31'h0, ready_pin}, 32'h1);

    $display("\n== 8. BYPASS fail-safe (the important one) ==");
    @(negedge clk); bypass_pin = 1;
    repeat (3) @(negedge clk);
    chk("enable forced low", {31'h0, enable}, 32'h0);
    chk("irq suppressed",    {31'h0, irq},    32'h0);
    chk("ready deasserted",  {31'h0, ready_pin}, 32'h0);
    bus_rd(ADDR_STATUS, d);
    chk("class -> NOMINAL", {30'h0, d[1:0]}, 32'd0);
    chk("valid cleared",    {31'h0, d[2]},   32'd0);
    chk("bypass flag",      {31'h0, d[7]},   32'd1);
    bus_rd(ADDR_LOOPCFG, d);
    chk("safe pll_bw",    {29'h0, d[2:0]}, 32'd3);
    chk("safe fll_en",    {31'h0, d[3]},   32'd0);
    chk("safe t_coh",     {29'h0, d[6:4]}, 32'd3);
    chk("safe band L5",   {30'h0, d[8:7]}, 32'd0);
    bus_rd(ADDR_INDEX, d); chk("indices zeroed", d, 32'h0);

    $display("\n== 9. recovery from bypass ==");
    @(negedge clk); bypass_pin = 0;
    repeat (3) @(negedge clk);
    chk("enable restored", {31'h0, enable}, 32'h1);
    bus_rd(ADDR_INDEX, d); chk("indices restored", d, 32'h5678_1234);

    $display("\n-----------------------------------------");
    if (errors == 0)
      $display("PASS  -- %0d checks, 0 failures", checks);
    else
      $display("FAIL  -- %0d checks, %0d failures", checks, errors);
    $display("-----------------------------------------\n");

    $finish;
  end

  initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
  end

endmodule

`default_nettype wire
