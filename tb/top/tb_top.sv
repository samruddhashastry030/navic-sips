// tb_top.sv -- the chip, tested only through its pins.
//
// Everything is driven and observed at navic_sips_top's ports, the way the
// receiver baseband would see it: the host bus, the interrupt line, ready and
// fault pins, the SPI pins to a flash chip, and the prompt I/Q pins. The
// testbench looks inside the chip only to COMPUTE what the host should see
// (the accelerator's logits, the SICU's last S4), never to observe results.
//
// This is the test that would have caught the missing pred_valid strobe:
// without it, the host reads class 0 and never sees an interrupt.
`timescale 1ns/1ps
`default_nettype none
module tb_top;
  localparam GAP = 8;                           // cycles between I/Q samples
  // navic_sips_regs register map
  localparam [4:0] A_ID = 5'h00, A_CTRL = 5'h04, A_STATUS = 5'h08,
                   A_INDEX = 5'h0C, A_LOOPCFG = 5'h10, A_IRQST = 5'h14,
                   A_IRQEN = 5'h18;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ---- pins -----------------------------------------------------------------
  reg         bus_sel = 0, bus_we = 0;
  reg  [ 4:0] bus_addr = 0;
  reg  [31:0] bus_wdata = 0;
  wire [31:0] bus_rdata;
  wire        bus_ack;
  reg         iq_valid = 0;
  reg  [15:0] iq_i = 0, iq_q = 0;
  wire        spi_cs_n, spi_sclk, spi_mosi, spi_miso;
  reg         bypass_pin = 0;
  wire        irq, ready_pin, fault_pin, uart_tx;

  navic_sips_top #(.FW_HEX("firmware.hex"), .LUT_SIG("lut_sigmoid.hex"),
                   .LUT_TANH("lut_tanh.hex")) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .bus_sel_i(bus_sel), .bus_we_i(bus_we), .bus_addr_i(bus_addr),
    .bus_wdata_i(bus_wdata), .bus_rdata_o(bus_rdata), .bus_ack_o(bus_ack),
    .iq_valid_i(iq_valid), .iq_i_i(iq_i), .iq_q_i(iq_q),
    .spi_cs_no(spi_cs_n), .spi_sclk_o(spi_sclk), .spi_mosi_o(spi_mosi),
    .spi_miso_i(spi_miso),
    .bypass_pin_i(bypass_pin), .irq_o(irq), .ready_pin_o(ready_pin),
    .fault_pin_o(fault_pin), .uart_tx_o(uart_tx));

  // ---- SPI flash chip on the SPI pins (mode 0, 0x03 READ) --------------------
  reg [7:0]  flash [0:4095];
  reg [7:0]  f_shift_in, f_shift_out;
  reg [2:0]  f_bitcnt;  reg [23:0] f_addr;  reg [2:0] f_state;  reg f_miso;
  integer    k;
  assign spi_miso = spi_cs_n ? 1'bz : f_miso;
  initial begin
    for (k = 0; k < 4096; k = k + 1) flash[k] = 8'hFF;
    $readmemh("flash.hex", flash);
  end
  always @(negedge spi_cs_n) begin f_bitcnt <= 0; f_state <= 0; f_miso <= 0; end
  always @(posedge spi_sclk) if (!spi_cs_n) begin
    f_shift_in <= {f_shift_in[6:0], spi_mosi};
    if (f_bitcnt == 3'd7) begin
      case (f_state)
        3'd0: f_state <= 1;
        3'd1: begin f_addr[23:16] <= {f_shift_in[6:0], spi_mosi}; f_state <= 2; end
        3'd2: begin f_addr[15:8]  <= {f_shift_in[6:0], spi_mosi}; f_state <= 3; end
        3'd3: begin f_addr[7:0]   <= {f_shift_in[6:0], spi_mosi}; f_state <= 4; end
        default: f_addr <= f_addr + 1;
      endcase
      f_bitcnt <= 0;
    end else f_bitcnt <= f_bitcnt + 1;
  end
  always @(negedge spi_sclk) if (!spi_cs_n) begin
    if (f_state == 4) begin
      if (f_bitcnt == 0) begin
        f_shift_out <= flash[f_addr[11:0]]; f_miso <= flash[f_addr[11:0]][7];
      end else f_miso <= f_shift_out[6-(f_bitcnt-1)];
    end else f_miso <= 1'b0;
  end

  // ---- prompt I/Q on the I/Q pins: one-cycle strobe per sample ---------------
  // Rotating carrier, amplitude scintillation whose depth ramps steeply so
  // S4 climbs well past the SEVERE threshold of 0.5.
  reg  [31:0] lfsr = 32'hACE1_2468;
  integer     gap = 0, n_samp = 0, n_win = 0;
  real        amp, phase = 0.0, depth, r;
  always @(posedge clk) begin
    iq_valid <= 1'b0;
    if (rst_n) begin
      gap = gap + 1;
      if (gap >= GAP) begin
        gap   = 0;
        lfsr  = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        r     = ($itor(lfsr[15:0]) / 32768.0) - 1.0;
        depth = 0.03 + 0.022 * n_win;
        if (depth > 0.95) depth = 0.95;
        amp   = 1200.0 * (1.0 + depth * r);
        phase = phase + 0.013;
        iq_i  <= $rtoi(amp * $cos(phase));
        iq_q  <= $rtoi(amp * $sin(phase));
        iq_valid <= 1'b1;
        n_samp = n_samp + 1;
        if (n_samp == 500) begin n_samp = 0; n_win = n_win + 1; end
      end
    end
  end

  // ---- host bus master -------------------------------------------------------
  task automatic host_xfer(input we, input [4:0] a, input [31:0] wd,
                           output [31:0] rd);
    begin
      @(negedge clk); bus_sel = 1; bus_we = we; bus_addr = a; bus_wdata = wd;
      @(negedge clk); bus_sel = 0; bus_we = 0;
      while (!bus_ack) @(negedge clk);
      rd = bus_rdata;
    end
  endtask
  reg [31:0] hd;
  task automatic hrd(input [4:0] a, output [31:0] v); host_xfer(0, a, 0, v); endtask
  task automatic hwr(input [4:0] a, input [31:0] v); host_xfer(1, a, v, hd); endtask

  // ---- checks ----------------------------------------------------------------
  integer errors = 0, cyc = 0, cyc_ready = 0;
  always @(posedge clk) cyc = cyc + 1;
  task automatic chk(input [511:0] what, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s: got %h expected %h", what, got, exp); errors = errors + 1;
    end else $display("pass  %0s", what);
  endtask

  // What the firmware's margin rule should publish, from the real logits.
  integer e_cls, e_conf;
  task automatic expected_result;
    integer l0, l1, l2, ru, m;
    begin
      l0 = $signed(dut.accel_logit0); l1 = $signed(dut.accel_logit1);
      l2 = $signed(dut.accel_logit2);
      ru = (l0 > l1) ? l0 : l1;
      if (l2 - ru >= 64) begin e_cls = 2; m = l2 - ru; end
      else if (l1 > l0) begin e_cls = 1; m = l1 - ((l0 > l2) ? l0 : l2); end
      else begin e_cls = 0; m = l0 - ((l1 > l2) ? l1 : l2); end
      e_conf = m >>> 6; if (e_conf > 15) e_conf = 15; if (e_conf < 0) e_conf = 0;
      $display("       accelerator logits %0d %0d %0d -> class %0d, conf %0d",
               l0, l1, l2, e_cls, e_conf);
    end
  endtask

  // loop_table in fw/main.c, packed [2:0] pll [3] fll [6:4] tcoh [8:7] band
  function automatic [31:0] loop_for(input integer c);
    case (c)
      0: loop_for = 32'h020;   // LOOP(0,0,2,0)
      1: loop_for = 32'h021;   // LOOP(1,0,2,0)
      default: loop_for = 32'h01B;   // LOOP(3,1,1,0)
    endcase
  endfunction
  localparam [31:0] LOOP_SAFE = 32'h033;   // PLL 3, FLL 0, T_coh 3, band 0

  reg [31:0] v, st;
  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (5) @(posedge clk);

    $display("=== reset, as the host sees it ===");
    hrd(A_ID, v);       chk("device ID 0x51950001", v, 32'h5195_0001);
    chk("ready pin low while booting", ready_pin, 0);
    chk("fault pin low", fault_pin, 0);
    hrd(A_LOOPCFG, v);  chk("loop settings safe while booting", v, LOOP_SAFE);
    hwr(A_IRQEN, 32'h1);                        // enable the SEVERE interrupt
    hrd(A_IRQEN, v);    chk("SEVERE interrupt enabled", v, 1);

    $display("\n=== boot, weight load, 330 s cold start ===");
    wait (ready_pin === 1'b1 || fault_pin === 1'b1);
    cyc_ready = cyc;
    chk("fault pin still low", fault_pin, 0);
    $display("       ready pin rose at cycle %0d (%0d I/Q windows sent since reset)", cyc, n_win);
    repeat (4) @(posedge clk);

    $display("\n=== first result, read over the host bus ===");
    expected_result;
    hrd(A_STATUS, st);
    $display("       STATUS = %h", st);
    chk("STATUS: prediction valid", st[2], 1);
    chk("STATUS: weights ready", st[8], 1);
    chk("STATUS: not bypassed", st[7], 0);
    chk("STATUS: class from the margin rule", st[1:0], e_cls);
    chk("STATUS: confidence", st[6:3], e_conf);
    hrd(A_INDEX, v);
    $display("       INDEX S4 = %0.4f  (SICU's last S4 %0.4f)",
             v[15:0] / 4096.0, dut.sicu_s4 / 4096.0);
    chk("INDEX: host S4 = what the firmware reported", v[15:0], dut.s4_report);
    chk("INDEX: host S4 is non-zero", v[15:0] != 0, 1);
    hrd(A_LOOPCFG, v);  chk("LOOPCFG: settings for that class", v, loop_for(e_cls));
    hrd(A_IRQST, v);
    if (e_cls == 2) begin
      chk("IRQST: SEVERE latched", v[0], 1);
      chk("irq pin asserted on SEVERE", irq, 1);
      hwr(A_IRQST, 32'h1);                      // RW1C
      hrd(A_IRQST, v);  chk("IRQST cleared by write-1", v[0], 0);
      chk("irq pin released", irq, 0);
    end else begin
      chk("no SEVERE interrupt for class < 2", v[0], 0);
      chk("irq pin quiet", irq, 0);
    end

    $display("\n=== host fail-safe: software bypass ===");
    hwr(A_CTRL, 32'h2);                         // BYPASS
    repeat (2) @(posedge clk);
    hrd(A_STATUS, v);
    chk("bypass: class forced to NOMINAL", v[1:0], 0);
    chk("bypass: prediction not valid", v[2], 0);
    chk("bypass: flagged", v[7], 1);
    hrd(A_LOOPCFG, v);  chk("bypass: loop settings safe", v, LOOP_SAFE);
    hrd(A_INDEX, v);    chk("bypass: S4 hidden", v[15:0], 0);
    chk("bypass: ready pin low", ready_pin, 0);
    hwr(A_CTRL, 32'h0);
    repeat (2) @(posedge clk);
    chk("bypass released: ready pin back", ready_pin, 1);

    $display("\n=== host fail-safe: hardware bypass pin ===");
    bypass_pin = 1;
    repeat (4) @(posedge clk);                  // two-flop synchroniser
    hrd(A_LOOPCFG, v);  chk("pin bypass: loop settings safe", v, LOOP_SAFE);
    chk("pin bypass: ready pin low", ready_pin, 0);
    bypass_pin = 0;
    repeat (4) @(posedge clk);
    chk("pin released: ready pin back", ready_pin, 1);

    $display("");
    if (errors == 0) $display("PASS: chip top level, tested at its pins");
    else             $display("FAIL: chip top level, %0d errors", errors);
    $finish;
  end

  initial begin #60_000_000; $display("FAIL: timeout, %0d windows", n_win); $finish; end
endmodule
`default_nettype wire
