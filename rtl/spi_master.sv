// ---------------------------------------------------------------------------
// spi_master.sv
//
// NavIC-SIPS SPI master.
//
// PRIMARY JOB: load INT8 LSTM weights from external SPI Flash into on-chip
// weight SRAM at boot, under PicoRV32 firmware control. This is what makes
// the weights field-updatable without a re-spin — the mitigation for
// training on synthetic data.
//
// SPI mode 0 (CPOL=0, CPHA=0), MSB first. That is what standard SPI Flash
// parts expect, and it is the simplest thing to get right.
//
//   SCLK idle low.
//   MOSI changes on the falling edge.
//   MISO is sampled on the rising edge.
//
// MULTI-BYTE TRANSFERS: assert hold_cs_i to keep CS low between bytes. A
// Flash read is command + 3 address bytes + N data bytes as one CS-low
// transaction, so this is not optional.
//
// SCLK rate = clk_i / (2 * (clk_div_i + 1))
//   at 100 MHz:  clk_div_i = 0 -> 50 MHz
//                clk_div_i = 4 -> 10 MHz
//                clk_div_i = 49 -> 1 MHz
// Start slow, speed up once the board works.
// ---------------------------------------------------------------------------

`default_nettype none

module spi_master #(
    parameter int DIV_WIDTH  = 8,
    parameter int DATA_WIDTH = 8
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    // ---- control ----------------------------------------------------------
    input  wire [DIV_WIDTH-1:0]      clk_div_i,   // SCLK divider
    input  wire                      start_i,     // pulse to begin a byte
    input  wire                      hold_cs_i,   // keep CS low after this byte
    input  wire [DATA_WIDTH-1:0]     tx_data_i,
    output reg  [DATA_WIDTH-1:0]     rx_data_o,
    output reg                       busy_o,
    output reg                       done_o,      // one-cycle pulse

    // ---- SPI pads ---------------------------------------------------------
    output reg                       cs_no,
    output reg                       sclk_o,
    output reg                       mosi_o,
    input  wire                      miso_i
);

  localparam int CNT_W = $clog2(DATA_WIDTH) + 1;

  localparam logic [1:0] ST_IDLE = 2'd0;
  localparam logic [1:0] ST_LEAD = 2'd1;   // CS asserted, first bit presented
  localparam logic [1:0] ST_RUN  = 2'd2;
  localparam logic [1:0] ST_TAIL = 2'd3;   // final half-period, then release

  reg [1:0]            state;
  reg [DATA_WIDTH-1:0] tx_shift;
  reg [DATA_WIDTH-1:0] rx_shift;
  reg [CNT_W-1:0]      bit_cnt;
  reg [DIV_WIDTH-1:0]  div_cnt;
  reg                  phase;      // 0 = next edge is rising, 1 = falling

  wire tick = (div_cnt == clk_div_i);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state     <= ST_IDLE;
      tx_shift  <= '0;
      rx_shift  <= '0;
      rx_data_o <= '0;
      bit_cnt   <= '0;
      div_cnt   <= '0;
      phase     <= 1'b0;
      busy_o    <= 1'b0;
      done_o    <= 1'b0;
      cs_no     <= 1'b1;
      sclk_o    <= 1'b0;
      mosi_o    <= 1'b0;
    end else begin
      done_o <= 1'b0;

      case (state)

        // -------------------------------------------------------------
        ST_IDLE: begin
          sclk_o  <= 1'b0;
          div_cnt <= '0;
          phase   <= 1'b0;
          if (start_i) begin
            tx_shift <= tx_data_i;
            // Mode 0: the first bit must be valid on MOSI before the first
            // rising edge, so present it as CS goes low.
            mosi_o   <= tx_data_i[DATA_WIDTH-1];
            cs_no    <= 1'b0;
            bit_cnt  <= '0;
            busy_o   <= 1'b1;
            state    <= ST_LEAD;
          end else if (!hold_cs_i) begin
            cs_no  <= 1'b1;
            busy_o <= 1'b0;
          end
        end

        // -------------------------------------------------------------
        // Half a period of CS setup before the first SCLK edge. Flash
        // parts specify a minimum CS-to-clock setup; this covers it.
        ST_LEAD: begin
          if (tick) begin
            div_cnt <= '0;
            state   <= ST_RUN;
          end else begin
            div_cnt <= div_cnt + 1'b1;
          end
        end

        // -------------------------------------------------------------
        ST_RUN: begin
          if (tick) begin
            div_cnt <= '0;

            if (phase == 1'b0) begin
              // rising edge: sample MISO
              sclk_o   <= 1'b1;
              rx_shift <= {rx_shift[DATA_WIDTH-2:0], miso_i};
              phase    <= 1'b1;
            end else begin
              // falling edge: shift out the next bit
              sclk_o <= 1'b0;
              phase  <= 1'b0;

              if (bit_cnt == CNT_W'(DATA_WIDTH-1)) begin
                state <= ST_TAIL;
              end else begin
                tx_shift <= {tx_shift[DATA_WIDTH-2:0], 1'b0};
                mosi_o   <= tx_shift[DATA_WIDTH-2];
                bit_cnt  <= bit_cnt + 1'b1;
              end
            end
          end else begin
            div_cnt <= div_cnt + 1'b1;
          end
        end

        // -------------------------------------------------------------
        ST_TAIL: begin
          if (tick) begin
            div_cnt   <= '0;
            rx_data_o <= rx_shift;
            done_o    <= 1'b1;
            state     <= ST_IDLE;
            if (!hold_cs_i) begin
              cs_no  <= 1'b1;
              busy_o <= 1'b0;
            end
            // hold_cs_i: CS stays low and busy stays high, ready for the
            // next byte of the same transaction.
          end else begin
            div_cnt <= div_cnt + 1'b1;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
