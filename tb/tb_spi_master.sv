// ---------------------------------------------------------------------------
// tb_spi_master.sv — self-checking testbench with a behavioural SPI Flash
//
//   iverilog -g2012 -o tb.vvp rtl/spi_master.sv tb/tb_spi_master.sv
//   vvp tb.vvp
//
// Tests the real use case: a Flash READ (0x03) transaction — command, three
// address bytes, then N data bytes, all in one CS-low window. That is how
// the LSTM weights get loaded at boot.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_spi_master;

  reg        clk = 0, rst_n = 0;
  reg  [7:0] clk_div = 8'd1;
  reg        start = 0, hold_cs = 0;
  reg  [7:0] tx_data = 0;
  wire [7:0] rx_data;
  wire       busy, done;
  wire       cs_n, sclk, mosi;
  wire       miso;

  integer errors = 0, checks = 0;

  spi_master #(.DIV_WIDTH(8), .DATA_WIDTH(8)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .clk_div_i(clk_div), .start_i(start), .hold_cs_i(hold_cs),
      .tx_data_i(tx_data), .rx_data_o(rx_data),
      .busy_o(busy), .done_o(done),
      .cs_no(cs_n), .sclk_o(sclk), .mosi_o(mosi), .miso_i(miso)
  );

  // -------------------------------------------------------------------------
  // Behavioural SPI Flash. Understands 0x03 READ; returns a simple pattern.
  // -------------------------------------------------------------------------
  reg [7:0]  flash_mem [0:255];
  reg [7:0]  f_shift_in, f_shift_out;
  reg [2:0]  f_bitcnt;
  reg [7:0]  f_cmd;
  reg [23:0] f_addr;
  reg [2:0]  f_state;   // 0 cmd, 1..3 addr, 4 data
  reg        f_miso;

  assign miso = cs_n ? 1'bz : f_miso;

  integer i;
  initial for (i = 0; i < 256; i = i + 1) flash_mem[i] = i ^ 8'hA5;

  always @(negedge cs_n) begin
    f_bitcnt   <= 0;
    f_state    <= 0;
    f_shift_in <= 0;
    f_miso     <= 1'b0;
  end

  // sample MOSI on rising SCLK
  always @(posedge sclk) if (!cs_n) begin
    f_shift_in <= {f_shift_in[6:0], mosi};
    if (f_bitcnt == 3'd7) begin
      case (f_state)
        3'd0: begin f_cmd  <= {f_shift_in[6:0], mosi};              f_state <= 1; end
        3'd1: begin f_addr[23:16] <= {f_shift_in[6:0], mosi};       f_state <= 2; end
        3'd2: begin f_addr[15:8]  <= {f_shift_in[6:0], mosi};       f_state <= 3; end
        3'd3: begin f_addr[7:0]   <= {f_shift_in[6:0], mosi};       f_state <= 4; end
        default: f_addr <= f_addr + 1;
      endcase
      f_bitcnt <= 0;
    end else begin
      f_bitcnt <= f_bitcnt + 1;
    end
  end

  // drive MISO on falling SCLK
  always @(negedge sclk) if (!cs_n) begin
    if (f_state == 4) begin
      if (f_bitcnt == 0) begin
        f_shift_out <= flash_mem[f_addr[7:0]];
        f_miso      <= flash_mem[f_addr[7:0]][7];
      end else begin
        f_miso      <= f_shift_out[6-(f_bitcnt-1)];
      end
    end else begin
      f_miso <= 1'b0;
    end
  end

  always #5 clk = ~clk;   // 100 MHz

  // -------------------------------------------------------------------------
  task automatic spi_byte(input [7:0] d, input hold, output [7:0] r);
    begin
      @(negedge clk);
      tx_data = d; hold_cs = hold; start = 1;
      @(negedge clk); start = 0;
      wait (done);
      @(negedge clk);
      r = rx_data;
    end
  endtask

  task automatic chk(input [255:0] name, input [31:0] got, input [31:0] exp);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("  FAIL %0s: got %0h expected %0h", name, got, exp);
      end else begin
        $display("  ok   %0s = %0h", name, got);
      end
    end
  endtask

  reg [7:0] r;
  reg [7:0] cmd_seen;
  integer   t0, t1;

  initial begin
    $dumpfile("tb_spi_master.vcd");
    $dumpvars(0, tb_spi_master);

    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    $display("\n== 1. idle state ==");
    chk("cs_n idle high", {31'h0, cs_n},   32'h1);
    chk("sclk idle low",  {31'h0, sclk},   32'h0);
    chk("busy idle low",  {31'h0, busy},   32'h0);

    $display("\n== 2. single byte, CS released ==");
    spi_byte(8'h9F, 1'b0, r);
    repeat (4) @(negedge clk);
    chk("cs_n released", {31'h0, cs_n}, 32'h1);
    chk("busy cleared",  {31'h0, busy}, 32'h0);

    $display("\n== 3. Flash READ transaction (the real use case) ==");
    // 0x03 READ, address 0x000010, then four data bytes.
    spi_byte(8'h03, 1'b1, r);
    spi_byte(8'h00, 1'b1, r);
    spi_byte(8'h00, 1'b1, r);
    spi_byte(8'h10, 1'b1, r);
    chk("cs_n held low", {31'h0, cs_n}, 32'h0);

    spi_byte(8'h00, 1'b1, r);
    chk("data[0x10]", {24'h0, r}, {24'h0, 8'h10 ^ 8'hA5});
    spi_byte(8'h00, 1'b1, r);
    chk("data[0x11]", {24'h0, r}, {24'h0, 8'h11 ^ 8'hA5});
    spi_byte(8'h00, 1'b1, r);
    chk("data[0x12]", {24'h0, r}, {24'h0, 8'h12 ^ 8'hA5});
    spi_byte(8'h00, 1'b0, r);   // last byte, release CS
    chk("data[0x13]", {24'h0, r}, {24'h0, 8'h13 ^ 8'hA5});

    repeat (4) @(negedge clk);
    chk("cs_n released after burst", {31'h0, cs_n}, 32'h1);
    // capture now: later single-byte tests overwrite the flash command reg
    cmd_seen = f_cmd;
    chk("flash saw READ cmd", {24'h0, cmd_seen}, {24'h0, 8'h03});

    $display("\n== 4. clock divider changes SCLK rate ==");
    clk_div = 8'd0;
    @(negedge clk);
    t0 = $time;
    spi_byte(8'hFF, 1'b0, r);
    t1 = $time;
    $display("  div=0  byte time = %0d ns", t1-t0);

    clk_div = 8'd4;
    @(negedge clk);
    t0 = $time;
    spi_byte(8'hFF, 1'b0, r);
    t1 = $time;
    $display("  div=4  byte time = %0d ns  (should be ~5x longer)", t1-t0);

    clk_div = 8'd1;

    $display("\n-----------------------------------------");
    if (errors == 0)
      $display("PASS  -- %0d checks, 0 failures", checks);
    else
      $display("FAIL  -- %0d checks, %0d failures", checks, errors);
    $display("-----------------------------------------\n");
    $finish;
  end

  initial begin
    #500000;
    $display("TIMEOUT");
    $finish;
  end

endmodule

`default_nettype wire
