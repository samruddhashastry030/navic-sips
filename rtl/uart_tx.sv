// -----------------------------------------------------------------------------
// uart_tx.sv  --  8N1 UART transmitter
//
// Project : NavIC-SIPS
// Purpose : Stage-A smoke-test block AND the real TX path used by the
//           debug/output UART peripheral later in the project.
//
// Conventions:
//   - single clock domain, posedge clk_i
//   - synchronous, active-low reset rst_ni
//   - sequential state named *_q
//   - ready/valid handshake on the input side
// -----------------------------------------------------------------------------

module uart_tx #(
    parameter int unsigned CLK_FREQ_HZ = 100_000_000,
    parameter int unsigned BAUD_RATE   = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_ni,

    input  logic [7:0] data_i,   // byte to transmit
    input  logic       valid_i,  // asserted when data_i is valid
    output logic       ready_o,  // high when transmitter can accept a byte

    output logic       tx_o      // serial output, idles high
);

  localparam int unsigned DIVISOR    = CLK_FREQ_HZ / BAUD_RATE;
  localparam int unsigned CNT_W      = (DIVISOR <= 1) ? 1 : $clog2(DIVISOR);
  localparam int unsigned FRAME_BITS = 10;   // start + 8 data + stop

  typedef enum logic { ST_IDLE = 1'b0, ST_BUSY = 1'b1 } state_e;

  state_e                state_q;
  logic [CNT_W-1:0]      baud_cnt_q;
  logic [3:0]            bit_idx_q;
  logic [FRAME_BITS-1:0] frame_q;

  wire tick = (baud_cnt_q == CNT_W'(DIVISOR - 1));

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q    <= ST_IDLE;
      baud_cnt_q <= '0;
      bit_idx_q  <= '0;
      frame_q    <= '1;
    end else begin
      case (state_q)

        ST_IDLE: begin
          baud_cnt_q <= '0;
          bit_idx_q  <= '0;
          if (valid_i) begin
            frame_q <= {1'b1, data_i, 1'b0};   // shifted out LSB first
            state_q <= ST_BUSY;
          end
        end

        ST_BUSY: begin
          if (tick) begin
            baud_cnt_q <= '0;
            frame_q    <= {1'b1, frame_q[FRAME_BITS-1:1]};
            if (bit_idx_q == 4'(FRAME_BITS - 1)) begin
              state_q <= ST_IDLE;
            end else begin
              bit_idx_q <= bit_idx_q + 4'd1;
            end
          end else begin
            baud_cnt_q <= baud_cnt_q + CNT_W'(1);
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  assign ready_o = (state_q == ST_IDLE);
  assign tx_o    = (state_q == ST_IDLE) ? 1'b1 : frame_q[0];

  // ---------------------------------------------------------------------------
  // Simulation-only checks. Written procedurally rather than as SVA properties
  // so they also compile under Icarus Verilog, which has no SVA support.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (DIVISOR < 2) begin
      $error("uart_tx: CLK_FREQ_HZ/BAUD_RATE must be >= 2 (got %0d)", DIVISOR);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && valid_i && !ready_o) begin
      $error("uart_tx: valid_i asserted while busy - byte would be dropped");
    end
  end
`endif

endmodule
