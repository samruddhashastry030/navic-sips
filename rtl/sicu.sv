// ---------------------------------------------------------------------------
// sicu.sv
//
// NavIC-SIPS Scintillation Index Computation Unit -- S4 path.
//
// Computes the amplitude scintillation index over a 10 s window of prompt
// correlator output:
//
//     I     = amplitude^2                       (intensity)
//     S4    = sqrt( n * sum(I^2) / sum(I)^2 - 1 )
//
// Every parameter below was measured against CDAAC's published s4_L1 on
// 952 windows of real COSMIC-2 50 Hz signal, not assumed:
//
//   Window     10 s centred = 500 samples at 50 Hz. Correlation against
//              CDAAC peaks there (0.9755) and falls off at 5 s (0.949),
//              20 s (0.942) and 60 s (0.764).
//   Intensity  8 bits after shifting. Widening to 10 or 12 bits changes the
//              median error by 0.0005, so it buys nothing.
//   Shift      CARRIED FROM THE PREVIOUS WINDOW. S4 is scale-invariant, so
//              any shift is valid as long as the window does not saturate.
//              Carry tracks the ideal two-pass shift to within 0.0004 median.
//              A FIXED shift is unusable: median error 0.188 against 0.006.
//   Accumul.   sum(I^2) needs 26 bits at 8-bit intensity.
//
// Accuracy: median |error| 0.006 against CDAAC, 95%-trimmed rms 0.019.
//
// DIVISION IS SEQUENTIAL. The first version of this block used combinational
// divides for the ratio and for each Newton-Raphson step. Post-CTS timing
// showed a worst slack of -330 ns against a 20 ns period -- a path sixteen
// clock periods deep -- and the resizer could not fix it, because the problem
// is logic depth rather than drive. A shared restoring divider costs latency
// that is free here: the block produces one result per 10 s window, roughly
// 500 million cycles at 50 MHz, and needs about 400 of them.
//
// Output is Q4.12 unsigned. S4 genuinely exceeds 1.0 in strong scintillation
// -- the validation set reaches 1.17 -- so Q0.16 would clip.
//
// Repo conventions: _i inputs, _o outputs, _q registered, rst_ni synchronous
// active-low reset, ready/valid on the input side, single clock domain.
// ---------------------------------------------------------------------------

`default_nettype none

module sicu #(
    parameter int unsigned WINDOW_N   = 500,   // 10 s at 50 Hz
    parameter int unsigned AMP_W      = 16,
    parameter int unsigned INT_W      = 8,
    parameter int unsigned SUM_W      = 20,
    parameter int unsigned SUM2_W     = 26,
    parameter int unsigned S4_FRAC    = 12,    // output Q4.12
    parameter int unsigned NR_ITERS   = 6,
    parameter int unsigned DIV_W      = 64
) (
    input  wire                    clk_i,
    input  wire                    rst_ni,

    input  wire                    enable_i,
    output wire                    busy_o,

    input  wire                    in_valid_i,
    output wire                    in_ready_o,
    input  wire [AMP_W-1:0]        amp_i,

    output reg                     s4_valid_o,
    output reg  [15:0]             s4_o,          // Q4.12 unsigned
    output reg                     saturated_o,
    output reg  [ 4:0]             shift_o
);

  localparam int unsigned INT_MAX = (1 << INT_W) - 1;
  localparam int unsigned CNT_W   = $clog2(WINDOW_N + 1);
  localparam int unsigned RATIO_W = 2 * S4_FRAC + 4;
  localparam int unsigned MSB_W   = $clog2(2 * AMP_W + 1);

  typedef enum logic [3:0] {
    S_ACC,
    S_RATIO_REQ,
    S_RATIO_WAIT,
    S_SQRT_INIT,
    S_SQRT_REQ,
    S_SQRT_WAIT,
    S_SQRT_STEP,
    S_EMIT
  } state_e;

  state_e state_q;

  reg [SUM_W-1:0]   sum_i_q;
  reg [SUM2_W-1:0]  sum_i2_q;
  reg [CNT_W-1:0]   count_q;
  reg [4:0]         shift_q;
  reg [4:0]         next_shift_q;
  reg               sat_q;
  reg [MSB_W-1:0]   msb_q;

  reg [RATIO_W-1:0] radicand_q;
  reg [RATIO_W-1:0] root_q;
  reg [3:0]         iter_q;

  assign in_ready_o = enable_i && (state_q == S_ACC);
  assign busy_o     = (state_q != S_ACC);

  // -------------------------------------------------------------------------
  // Intensity path
  // -------------------------------------------------------------------------
  wire [2*AMP_W-1:0] inten_full = amp_i * amp_i;
  wire [2*AMP_W-1:0] inten_shft = inten_full >> shift_q;
  wire               inten_sat  = |(inten_shft[2*AMP_W-1:INT_W]);
  wire [INT_W-1:0]   inten      = inten_sat ? INT_W'(INT_MAX)
                                            : inten_shft[INT_W-1:0];

  function automatic [MSB_W-1:0] msb_pos(input [2*AMP_W-1:0] v);
    int k;
    begin
      msb_pos = '0;
      for (k = 0; k < 2*AMP_W; k = k + 1)
        if (v[k]) msb_pos = MSB_W'(k + 1);
    end
  endfunction

  wire [MSB_W-1:0] msb_of_sample = msb_pos(inten_full);

  function automatic [4:0] sat_sub(input [MSB_W-1:0] a, input int unsigned b);
    begin
      sat_sub = (a > b) ? 5'(a - b) : 5'd0;
    end
  endfunction

  // -------------------------------------------------------------------------
  // Shared sequential restoring divider.
  //
  // One quotient bit per cycle, DIV_W cycles per division. Used once for the
  // ratio and once per Newton-Raphson iteration, so DIV_W * (1 + NR_ITERS)
  // cycles per window -- about 450 at the default parameters.
  // -------------------------------------------------------------------------
  reg               div_start_q;
  reg  [DIV_W-1:0]  div_num_q, div_den_q;
  reg  [DIV_W-1:0]  div_quot_q, div_rem_q;
  reg  [$clog2(DIV_W+1)-1:0] div_cnt_q;
  reg               div_busy_q, div_done_q;

  wire [DIV_W-1:0]  rem_shifted = {div_rem_q[DIV_W-2:0],
                                   div_quot_q[DIV_W-1]};
  wire              rem_ge      = (rem_shifted >= div_den_q);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      div_busy_q <= 1'b0;
      div_done_q <= 1'b0;
      div_quot_q <= '0;
      div_rem_q  <= '0;
      div_cnt_q  <= '0;
    end else begin
      div_done_q <= 1'b0;
      if (div_start_q && !div_busy_q) begin
        div_quot_q <= div_num_q;
        div_rem_q  <= '0;
        div_cnt_q  <= '0;
        div_busy_q <= (div_den_q != 0);
        if (div_den_q == 0) begin
          div_quot_q <= '0;
          div_done_q <= 1'b1;
        end
      end else if (div_busy_q) begin
        div_rem_q  <= rem_ge ? (rem_shifted - div_den_q) : rem_shifted;
        div_quot_q <= {div_quot_q[DIV_W-2:0], rem_ge};
        if (div_cnt_q + 1 == DIV_W[$clog2(DIV_W+1)-1:0]) begin
          div_busy_q <= 1'b0;
          div_done_q <= 1'b1;
        end else begin
          div_cnt_q <= div_cnt_q + 1;
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Main FSM
  // -------------------------------------------------------------------------
  wire [DIV_W-1:0] ratio_num = (64'(count_q) * 64'(sum_i2_q)) << (2*S4_FRAC);
  wire [DIV_W-1:0] ratio_den = 64'(sum_i_q) * 64'(sum_i_q);
  localparam [DIV_W-1:0] ONE_Q2F = 64'd1 << (2 * S4_FRAC);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q      <= S_ACC;
      sum_i_q      <= '0;
      sum_i2_q     <= '0;
      count_q      <= '0;
      shift_q      <= 5'd0;
      next_shift_q <= 5'd0;
      msb_q        <= '0;
      sat_q        <= 1'b0;
      radicand_q   <= '0;
      root_q       <= '0;
      iter_q       <= 4'd0;
      div_start_q  <= 1'b0;
      div_num_q    <= '0;
      div_den_q    <= '0;
      s4_valid_o   <= 1'b0;
      s4_o         <= 16'd0;
      saturated_o  <= 1'b0;
      shift_o      <= 5'd0;
    end else begin
      s4_valid_o  <= 1'b0;
      div_start_q <= 1'b0;

      case (state_q)

        // -------------------------------------------------------------
        S_ACC: begin
          if (enable_i && in_valid_i) begin
            sum_i_q  <= sum_i_q  + SUM_W'(inten);
            sum_i2_q <= sum_i2_q + SUM2_W'(inten * inten);
            if (inten_sat) sat_q <= 1'b1;
            if (msb_of_sample > msb_q) msb_q <= msb_of_sample;

            if (count_q + 1 == CNT_W'(WINDOW_N)) begin
              count_q      <= count_q + 1;
              next_shift_q <= (msb_of_sample > msb_q)
                              ? sat_sub(msb_of_sample, INT_W)
                              : sat_sub(msb_q, INT_W);
              state_q      <= S_RATIO_REQ;
            end else begin
              count_q <= count_q + 1;
            end
          end
        end

        // -------------------------------------------------------------
        // radicand = n * sum_i2 / sum_i^2 - 1, in Q(2*S4_FRAC)
        S_RATIO_REQ: begin
          if (sum_i_q == 0) begin
            radicand_q <= '0;
            state_q    <= S_SQRT_INIT;
          end else begin
            div_num_q   <= ratio_num;
            div_den_q   <= ratio_den;
            div_start_q <= 1'b1;
            state_q     <= S_RATIO_WAIT;
          end
        end

        S_RATIO_WAIT: begin
          if (div_done_q) begin
            radicand_q <= (div_quot_q <= ONE_Q2F)
                          ? '0
                          : ((div_quot_q - ONE_Q2F) > 64'((1 << RATIO_W) - 1)
                             ? RATIO_W'((1 << RATIO_W) - 1)
                             : RATIO_W'(div_quot_q - ONE_Q2F));
            state_q <= S_SQRT_INIT;
          end
        end

        // -------------------------------------------------------------
        // Newton-Raphson: x <- (x + r/x) / 2, seeded at 1.0
        S_SQRT_INIT: begin
          iter_q <= 4'd0;
          if (radicand_q == 0) begin
            root_q  <= '0;
            state_q <= S_EMIT;
          end else begin
            root_q  <= RATIO_W'(1 << S4_FRAC);
            state_q <= S_SQRT_REQ;
          end
        end

        S_SQRT_REQ: begin
          div_num_q   <= DIV_W'(radicand_q);
          div_den_q   <= DIV_W'(root_q);
          div_start_q <= 1'b1;
          state_q     <= S_SQRT_WAIT;
        end

        S_SQRT_WAIT: begin
          if (div_done_q) state_q <= S_SQRT_STEP;
        end

        S_SQRT_STEP: begin
          root_q <= RATIO_W'((root_q + RATIO_W'(div_quot_q)) >> 1);
          if (iter_q + 1 == 4'(NR_ITERS)) state_q <= S_EMIT;
          else begin
            iter_q  <= iter_q + 4'd1;
            state_q <= S_SQRT_REQ;
          end
        end

        // -------------------------------------------------------------
        S_EMIT: begin
          s4_o        <= (root_q > RATIO_W'(65535)) ? 16'hFFFF : root_q[15:0];
          saturated_o <= sat_q;
          shift_o     <= shift_q;
          s4_valid_o  <= 1'b1;

          shift_q  <= next_shift_q;
          sum_i_q  <= '0;
          sum_i2_q <= '0;
          count_q  <= '0;
          msb_q    <= '0;
          sat_q    <= 1'b0;
          state_q  <= S_ACC;
        end

        default: state_q <= S_ACC;
      endcase
    end
  end

endmodule

`default_nettype wire
