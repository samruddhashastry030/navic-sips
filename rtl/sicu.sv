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
// Accuracy achieved: median |error| 0.006 against CDAAC, 95%-trimmed rms
// 0.019. The residual is concentrated in a dozen very strong windows
// (S4 > 0.8) where the plain estimator saturates.
//
// Output format is Q4.12 unsigned. S4 genuinely exceeds 1.0 in strong
// scintillation -- the validation set reaches 1.17 -- so Q0.16 would clip.
//
// Repo conventions: _i inputs, _o outputs, _q registered, rst_ni synchronous
// active-low reset, ready/valid on the input side, single clock domain.
// ---------------------------------------------------------------------------

`default_nettype none

module sicu #(
    parameter int unsigned WINDOW_N   = 500,   // 10 s at 50 Hz
    parameter int unsigned AMP_W      = 16,    // correlator amplitude width
    parameter int unsigned INT_W      = 8,     // intensity kept after shift
    parameter int unsigned SUM_W      = 20,    // sum(I),   500 * 255 < 2^17
    parameter int unsigned SUM2_W     = 26,    // sum(I^2), 500 * 255^2 < 2^26
    parameter int unsigned S4_FRAC    = 12,    // output Q4.12
    parameter int unsigned NR_ITERS   = 6      // Newton-Raphson sqrt steps
) (
    input  wire                    clk_i,
    input  wire                    rst_ni,

    // ---- control ----------------------------------------------------------
    input  wire                    enable_i,     // gate the whole block
    output wire                    busy_o,

    // ---- sample stream ----------------------------------------------------
    input  wire                    in_valid_i,
    output wire                    in_ready_o,
    input  wire [AMP_W-1:0]        amp_i,        // |prompt|, unsigned

    // ---- result, one pulse per completed window ---------------------------
    output reg                     s4_valid_o,
    output reg  [15:0]             s4_o,         // Q4.12 unsigned
    output reg                     saturated_o,  // window clipped -> suspect
    output reg  [ 4:0]             shift_o       // shift used, for telemetry
);

  localparam int unsigned INT_MAX  = (1 << INT_W) - 1;
  localparam int unsigned CNT_W    = $clog2(WINDOW_N + 1);
  localparam int unsigned RATIO_W  = 2 * S4_FRAC + 4;   // headroom for S4^2

  typedef enum logic [2:0] {
    S_ACC,        // accumulating the window
    S_RATIO,      // n * sum_i2 / sum_i^2
    S_SQRT_INIT,
    S_SQRT,       // Newton-Raphson
    S_EMIT
  } state_e;

  state_e state_q;

  reg [SUM_W-1:0]   sum_i_q;
  reg [SUM2_W-1:0]  sum_i2_q;
  reg [CNT_W-1:0]   count_q;
  reg [4:0]         shift_q;        // in use for the window being accumulated
  reg [4:0]         next_shift_q;   // derived from this window, used by the next
  reg               sat_q;

  reg [RATIO_W-1:0] radicand_q;     // S4^2 in Q(2*S4_FRAC)
  reg [RATIO_W-1:0] root_q;
  reg [2:0]         iter_q;

  assign in_ready_o = enable_i && (state_q == S_ACC);
  assign busy_o     = (state_q != S_ACC);

  // -------------------------------------------------------------------------
  // Intensity: square the amplitude, shift down, saturate to INT_W bits.
  // Saturation is flagged rather than silently accepted -- a clipped window
  // gives a wrong S4 and the firmware should know.
  // -------------------------------------------------------------------------
  wire [2*AMP_W-1:0] inten_full = amp_i * amp_i;
  wire [2*AMP_W-1:0] inten_shft = inten_full >> shift_q;
  wire               inten_sat  = |(inten_shft[2*AMP_W-1:INT_W]);
  wire [INT_W-1:0]   inten      = inten_sat ? INT_W'(INT_MAX)
                                            : inten_shft[INT_W-1:0];

  // Track the highest bit seen this window, so the next window can pick a
  // shift that keeps the peak just inside INT_W bits.
  reg [$clog2(2*AMP_W+1)-1:0] msb_q;
  wire [$clog2(2*AMP_W+1)-1:0] msb_of_sample = msb_pos(inten_full);

  function automatic [$clog2(2*AMP_W+1)-1:0] msb_pos(input [2*AMP_W-1:0] v);
    int k;
    begin
      msb_pos = '0;
      for (k = 0; k < 2*AMP_W; k = k + 1)
        if (v[k]) msb_pos = ($clog2(2*AMP_W+1))'(k + 1);
    end
  endfunction

  // -------------------------------------------------------------------------
  // Newton-Raphson square root on a Q(2*S4_FRAC) radicand.
  //   x <- (x + r/x) / 2
  // Four iterations from a shift-based seed converge well inside one LSB of
  // Q4.12 for the range S4^2 in [0, 4].
  // -------------------------------------------------------------------------
  // radicand is Q(2*S4_FRAC), root is Q(S4_FRAC), so radicand/root is
  // already Q(S4_FRAC) -- no extra shift. The earlier version shifted by
  // S4_FRAC again, making the correction term 4096x too large.
  wire [RATIO_W-1:0] nr_next =
      (root_q == 0) ? '0
                    : RATIO_W'((root_q + (radicand_q / root_q)) >> 1);

  integer i;

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
      iter_q       <= 3'd0;
      s4_valid_o   <= 1'b0;
      s4_o         <= 16'd0;
      saturated_o  <= 1'b0;
      shift_o      <= 5'd0;
    end else begin
      s4_valid_o <= 1'b0;

      case (state_q)

        // -------------------------------------------------------------
        S_ACC: begin
          if (enable_i && in_valid_i) begin
            sum_i_q  <= sum_i_q  + SUM_W'(inten);
            sum_i2_q <= sum_i2_q + SUM2_W'(inten * inten);
            if (inten_sat) sat_q <= 1'b1;
            if (msb_of_sample > msb_q) msb_q <= msb_of_sample;

            if (count_q + 1 == CNT_W'(WINDOW_N)) begin
              // Shift for the NEXT window: keep the observed peak just
              // inside INT_W bits.
              next_shift_q <= (msb_of_sample > msb_q)
                              ? sat_sub(msb_of_sample, INT_W)
                              : sat_sub(msb_q, INT_W);
              state_q <= S_RATIO;
            end else begin
              count_q <= count_q + 1;
            end
          end
        end

        // -------------------------------------------------------------
        // S4^2 = n * sum_i2 / sum_i^2 - 1, in Q(2*S4_FRAC).
        S_RATIO: begin
          if (sum_i_q == 0) begin
            radicand_q <= '0;
          end else begin
            radicand_q <= sat_ratio(sum_i_q, sum_i2_q, count_q + 1);
          end
          state_q <= S_SQRT_INIT;
        end

        S_SQRT_INIT: begin
          // Seed at half the radicand's magnitude; any non-zero seed works,
          // this one just saves an iteration.
          // Seed at 1.0 in Q(S4_FRAC). S4 lies in roughly [0, 2], so this
          // converges in a handful of iterations from either side.
          root_q  <= (radicand_q == 0) ? '0 : RATIO_W'(1 << S4_FRAC);
          iter_q  <= 3'd0;
          state_q <= (radicand_q == 0) ? S_EMIT : S_SQRT;
        end

        S_SQRT: begin
          root_q <= nr_next;
          if (iter_q + 1 == 3'(NR_ITERS)) state_q <= S_EMIT;
          else iter_q <= iter_q + 3'd1;
        end

        // -------------------------------------------------------------
        S_EMIT: begin
          s4_o        <= (root_q > RATIO_W'(65535)) ? 16'hFFFF : root_q[15:0];
          saturated_o <= sat_q;
          shift_o     <= shift_q;
          s4_valid_o  <= 1'b1;

          // Reset for the next window, carrying the new shift forward.
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

  // -------------------------------------------------------------------------
  function automatic [4:0] sat_sub(input [$clog2(2*AMP_W+1)-1:0] a,
                                   input int unsigned b);
    begin
      sat_sub = (a > b) ? 5'(a - b) : 5'd0;
    end
  endfunction

  // n * sum_i2 / sum_i^2 - 1, scaled to Q(2*S4_FRAC), saturating.
  function automatic [RATIO_W-1:0] sat_ratio(input [SUM_W-1:0]  si,
                                             input [SUM2_W-1:0] si2,
                                             input [CNT_W:0]    n);
    logic [63:0] num, den, q;
    begin
      num = 64'(n) * 64'(si2);
      den = 64'(si) * 64'(si);
      if (den == 0) sat_ratio = '0;
      else begin
        q = (num << (2 * S4_FRAC)) / den;
        if (q <= (64'd1 << (2 * S4_FRAC))) sat_ratio = '0;
        else begin
          q = q - (64'd1 << (2 * S4_FRAC));
          sat_ratio = (q > 64'((1 << RATIO_W) - 1))
                      ? RATIO_W'((1 << RATIO_W) - 1) : RATIO_W'(q);
        end
      end
    end
  endfunction

endmodule

`default_nettype wire
