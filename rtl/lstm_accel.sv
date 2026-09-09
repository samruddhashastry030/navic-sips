// ---------------------------------------------------------------------------
// lstm_accel.sv
//
// NavIC-SIPS LSTM inference accelerator -- SEQUENTIAL REFERENCE VERSION.
//
// One MAC per cycle, one weight fetch per MAC. This is deliberately the
// simple implementation: it exists to be provably correct against
// rtl/weights/golden_vectors.hex, so the 8x8 systolic version can be
// developed against a known-good reference rather than debugged blind
// alongside the control FSM.
//
// Throughput, because it affects how the systolic array is justified:
// one inference is 26,624 MACs (832 per timestep x 32 timesteps), which at
// roughly 3 cycles per MAC and 10 MHz is about 8 ms, against a window that
// arrives every 10 s. Sequential is already fast enough by three orders of
// magnitude, so the systolic array's case has to be energy per inference,
// not throughput.
//
// Numeric contract -- must match rtl/weights/WEIGHT_FORMAT.md and
// python/ml/quantise.py exactly:
//   Q8.8 signed two's complement. Accumulate at full width; round once back
//   to Q8.8 after each matrix-vector product and after each elementwise
//   product. Gates are 256-entry LUTs over [-8, +8].
//
// Weight SRAM: 512 x 32, two Q8.8 slots per word, even slot in bits [15:0].
// Slots 0-4 are header (mu[2], sd[2], threshold) and are not read here --
// normalisation happens upstream in the SICU, and the threshold is applied
// by firmware, so this block emits raw logits and a plain argmax.
//
// Repo conventions: _i inputs, _o outputs, _q registered, rst_ni synchronous
// active-low reset, ready/valid on the input side, single clock domain.
// ---------------------------------------------------------------------------

`default_nettype none

module lstm_accel #(
    parameter int unsigned N_FEAT    = 2,
    parameter int unsigned HIDDEN    = 8,
    parameter int unsigned SEQ_LEN   = 32,
    parameter int unsigned FRAC_BITS = 8,
    parameter int unsigned N_CLASS   = 3,
    parameter int unsigned ACC_W     = 40,
    parameter              LUT_SIG   = "rtl/weights/lut_sigmoid.hex",
    parameter              LUT_TANH  = "rtl/weights/lut_tanh.hex"
) (
    input  wire                clk_i,
    input  wire                rst_ni,

    // ---- control ----------------------------------------------------------
    input  wire                start_i,       // pulse: begin a new sequence
    output wire                busy_o,

    // ---- input stream: one timestep per handshake -------------------------
    input  wire                in_valid_i,
    output wire                in_ready_o,
    input  wire signed [15:0]  in_feat0_i,    // Q8.8, already normalised
    input  wire signed [15:0]  in_feat1_i,

    // ---- weight SRAM read port (1-cycle read latency) ---------------------
    output reg                 w_csb_o,       // active low
    output reg  [ 8:0]         w_addr_o,
    input  wire [31:0]         w_dout_i,

    // ---- result -----------------------------------------------------------
    output reg                 out_valid_o,
    output reg  signed [15:0]  logit0_o,
    output reg  signed [15:0]  logit1_o,
    output reg  signed [15:0]  logit2_o,
    output reg  [ 1:0]         class_o
);

  // -------------------------------------------------------------------------
  // Weight slot map, derived from the parameters so it cannot drift out of
  // step with WEIGHT_FORMAT.md while HIDDEN and N_FEAT match the export.
  // -------------------------------------------------------------------------
  localparam int unsigned G      = 4 * HIDDEN;
  localparam int unsigned HDR    = 5;

  localparam int unsigned WIH0_B = HDR;
  localparam int unsigned WHH0_B = WIH0_B + G * N_FEAT;
  localparam int unsigned BIH0_B = WHH0_B + G * HIDDEN;
  localparam int unsigned BHH0_B = BIH0_B + G;
  localparam int unsigned WIH1_B = BHH0_B + G;
  localparam int unsigned WHH1_B = WIH1_B + G * HIDDEN;
  localparam int unsigned BIH1_B = WHH1_B + G * HIDDEN;
  localparam int unsigned BHH1_B = BIH1_B + G;
  localparam int unsigned HEDW_B = BHH1_B + G;
  localparam int unsigned HEDB_B = HEDW_B + N_CLASS * HIDDEN;

  // -------------------------------------------------------------------------
  typedef enum logic [4:0] {
    S_IDLE,
    S_ACCEPT,
    S_ROW_START,
    S_BIH,          // bias_ih fetched
    S_BHH,          // bias_hh fetched
    S_MACD,         // weight fetched, accumulate
    S_GATE,
    S_CELL,
    S_HID,
    S_UNIT_NEXT,
    S_HEAD_START,
    S_HEAD_BIAS,
    S_HEAD_MACD,
    S_HEAD_STORE,
    S_ARGMAX,
    S_DONE,
    S_FETCH,        // issue SRAM read for slot_q
    S_FETCH_D       // capture the half-word, return to ret_q
  } state_e;

  state_e state_q, ret_q;

  reg signed [15:0] h_q      [0:1][0:HIDDEN-1];  // current hidden
  reg signed [15:0] h_prev_q [0:1][0:HIDDEN-1];  // hidden at t-1
  reg signed [15:0] c_q      [0:1][0:HIDDEN-1];
  reg signed [15:0] xin_q    [0:N_FEAT-1];
  reg signed [15:0] gate_q   [0:3];              // i, f, g, o
  reg signed [15:0] logit_q  [0:N_CLASS-1];
  reg signed [15:0] c_new_q;

  reg [5:0]  step_q;
  reg        layer_q;
  reg [4:0]  unit_q;
  reg [1:0]  gsel_q;
  reg [5:0]  term_q;
  reg [1:0]  cls_q;

  reg signed [ACC_W-1:0] acc_q;
  reg        [9:0]       slot_q;
  reg                    half_q;
  reg signed [15:0]      fetched_q;

  wire [5:0] n_terms = (layer_q == 1'b0) ? 6'(N_FEAT + HIDDEN)
                                         : 6'(HIDDEN + HIDDEN);

  assign busy_o     = (state_q != S_IDLE);
  assign in_ready_o = (state_q == S_ACCEPT);

  // -------------------------------------------------------------------------
  function automatic signed [15:0] sat_round(input signed [ACC_W-1:0] a);
    logic signed [ACC_W-1:0] r;
    begin
      r = (a + (1 <<< (FRAC_BITS - 1))) >>> FRAC_BITS;
      if (r > 32767)       sat_round = 16'sh7FFF;
      else if (r < -32768) sat_round = 16'sh8000;
      else                 sat_round = r[15:0];
    end
  endfunction

  // -------------------------------------------------------------------------
  // Gate LUTs: 256 Q8.8 entries over [-8, +8].
  //   index = round((clip(x,-8,8) + 8) / 16 * 255)
  // In Q8.8 the clip bounds are +/-2048, so:
  //   index = ((xq + 2048) * 255 + 2048) >> 12
  // -------------------------------------------------------------------------
  reg signed [15:0] lut_sigmoid [0:255];
  reg signed [15:0] lut_tanh    [0:255];

  initial begin
    $readmemh(LUT_SIG,  lut_sigmoid);
    $readmemh(LUT_TANH, lut_tanh);
  end

  function automatic [7:0] lut_index(input signed [15:0] x);
    logic signed [31:0] xc, num;
    begin
      xc = 32'(x);
      if (xc >  2048) xc =  2048;
      if (xc < -2048) xc = -2048;
      num = ((xc + 2048) * 255 + 2048) >>> 12;
      if (num > 255) num = 255;
      if (num < 0)   num = 0;
      lut_index = num[7:0];
    end
  endfunction

  function automatic signed [15:0] f_sigmoid(input signed [15:0] x);
    f_sigmoid = lut_sigmoid[lut_index(x)];
  endfunction

  function automatic signed [15:0] f_tanh(input signed [15:0] x);
    f_tanh = lut_tanh[lut_index(x)];
  endfunction

  // -------------------------------------------------------------------------
  // Addressing helpers
  // -------------------------------------------------------------------------
  wire [9:0] row = 10'(gsel_q) * 10'(HIDDEN) + 10'(unit_q);

  function automatic [9:0] term_slot(input [5:0] k);
    logic [9:0] wih_base, whh_base;
    logic [5:0] in_w;
    begin
      wih_base = (layer_q == 1'b0) ? 10'(WIH0_B) : 10'(WIH1_B);
      whh_base = (layer_q == 1'b0) ? 10'(WHH0_B) : 10'(WHH1_B);
      in_w     = (layer_q == 1'b0) ? 6'(N_FEAT)  : 6'(HIDDEN);
      if (k < in_w) term_slot = wih_base + row * 10'(in_w) + 10'(k);
      else          term_slot = whh_base + row * 10'(HIDDEN) + 10'(k - in_w);
    end
  endfunction

  // Operand paired with term k. Layer 0 takes the external features and its
  // own previous hidden; layer 1 takes layer 0's CURRENT hidden as input and
  // its own previous hidden as the recurrent term.
  function automatic signed [15:0] term_operand(input [5:0] k);
    logic [5:0] in_w;
    begin
      in_w = (layer_q == 1'b0) ? 6'(N_FEAT) : 6'(HIDDEN);
      if (k < in_w)
        term_operand = (layer_q == 1'b0) ? xin_q[k] : h_q[0][k];
      else
        term_operand = h_prev_q[layer_q][k - in_w];
    end
  endfunction

  task automatic do_fetch(input [9:0] s, input state_e r);
    begin
      slot_q   <= s;
      w_addr_o <= s[9:1];
      half_q   <= s[0];
      w_csb_o  <= 1'b0;
      ret_q    <= r;
      state_q  <= S_FETCH;
    end
  endtask

  wire [9:0] bih_base = (layer_q == 1'b0) ? 10'(BIH0_B) : 10'(BIH1_B);
  wire [9:0] bhh_base = (layer_q == 1'b0) ? 10'(BHH0_B) : 10'(BHH1_B);

  integer i, j;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      ret_q       <= S_IDLE;
      w_csb_o     <= 1'b1;
      w_addr_o    <= 9'd0;
      half_q      <= 1'b0;
      slot_q      <= 10'd0;
      fetched_q   <= 16'sd0;
      out_valid_o <= 1'b0;
      logit0_o    <= 16'sd0;
      logit1_o    <= 16'sd0;
      logit2_o    <= 16'sd0;
      class_o     <= 2'd0;
      step_q      <= 6'd0;
      layer_q     <= 1'b0;
      unit_q      <= 5'd0;
      gsel_q      <= 2'd0;
      term_q      <= 6'd0;
      cls_q       <= 2'd0;
      acc_q       <= '0;
      c_new_q     <= 16'sd0;
      for (i = 0; i < 2; i = i + 1)
        for (j = 0; j < HIDDEN; j = j + 1) begin
          h_q[i][j]      <= 16'sd0;
          h_prev_q[i][j] <= 16'sd0;
          c_q[i][j]      <= 16'sd0;
        end
      for (j = 0; j < N_FEAT;  j = j + 1) xin_q[j]   <= 16'sd0;
      for (j = 0; j < 4;       j = j + 1) gate_q[j]  <= 16'sd0;
      for (j = 0; j < N_CLASS; j = j + 1) logit_q[j] <= 16'sd0;
    end else begin
      w_csb_o     <= 1'b1;
      out_valid_o <= 1'b0;

      case (state_q)

        // ---------------------------------------------------------------
        S_IDLE: begin
          if (start_i) begin
            step_q  <= 6'd0;
            layer_q <= 1'b0;
            unit_q  <= 5'd0;
            gsel_q  <= 2'd0;
            for (i = 0; i < 2; i = i + 1)
              for (j = 0; j < HIDDEN; j = j + 1) begin
                h_q[i][j]      <= 16'sd0;
                h_prev_q[i][j] <= 16'sd0;
                c_q[i][j]      <= 16'sd0;
              end
            state_q <= S_ACCEPT;
          end
        end

        // ---------------------------------------------------------------
        S_ACCEPT: begin
          if (in_valid_i) begin
            xin_q[0] <= in_feat0_i;
            if (N_FEAT > 1) xin_q[1] <= in_feat1_i;
            // Snapshot h(t-1) for both layers before this timestep runs.
            for (i = 0; i < 2; i = i + 1)
              for (j = 0; j < HIDDEN; j = j + 1)
                h_prev_q[i][j] <= h_q[i][j];
            layer_q <= 1'b0;
            unit_q  <= 5'd0;
            gsel_q  <= 2'd0;
            state_q <= S_ROW_START;
          end
        end

        // ---------------------------------------------------------------
        // Begin one gate row: acc = bias_ih + bias_hh, then MAC the terms.
        S_ROW_START: begin
          acc_q  <= '0;
          term_q <= 6'd0;
          do_fetch(bih_base + row, S_BIH);
        end

        S_BIH: begin
          acc_q <= ACC_W'(fetched_q) <<< FRAC_BITS;
          do_fetch(bhh_base + row, S_BHH);
        end

        S_BHH: begin
          acc_q <= acc_q + (ACC_W'(fetched_q) <<< FRAC_BITS);
          do_fetch(term_slot(6'd0), S_MACD);
        end

        S_MACD: begin
          acc_q <= acc_q + ACC_W'(fetched_q * term_operand(term_q));
          if (term_q + 6'd1 == n_terms) begin
            state_q <= S_GATE;
          end else begin
            term_q <= term_q + 6'd1;
            do_fetch(term_slot(term_q + 6'd1), S_MACD);
          end
        end

        // ---------------------------------------------------------------
        S_GATE: begin
          gate_q[gsel_q] <= (gsel_q == 2'd2) ? f_tanh(sat_round(acc_q))
                                             : f_sigmoid(sat_round(acc_q));
          if (gsel_q == 2'd3) begin
            state_q <= S_CELL;
          end else begin
            gsel_q  <= gsel_q + 2'd1;
            state_q <= S_ROW_START;
          end
        end

        // c = f*c + i*g
        S_CELL: begin
          c_new_q <= sat_round(
              ACC_W'(gate_q[1] * c_q[layer_q][unit_q]) +
              ACC_W'(gate_q[0] * gate_q[2]));
          state_q <= S_HID;
        end

        // h = o * tanh(c)
        S_HID: begin
          c_q[layer_q][unit_q] <= c_new_q;
          h_q[layer_q][unit_q] <= sat_round(
              ACC_W'(gate_q[3] * f_tanh(c_new_q)));
          state_q <= S_UNIT_NEXT;
        end

        // ---------------------------------------------------------------
        S_UNIT_NEXT: begin
          gsel_q <= 2'd0;
          if (unit_q + 5'd1 == 5'(HIDDEN)) begin
            unit_q <= 5'd0;
            if (layer_q == 1'b0) begin
              layer_q <= 1'b1;
              state_q <= S_ROW_START;
            end else if (step_q + 6'd1 == 6'(SEQ_LEN)) begin
              cls_q   <= 2'd0;
              state_q <= S_HEAD_START;
            end else begin
              step_q  <= step_q + 6'd1;
              state_q <= S_ACCEPT;
            end
          end else begin
            unit_q  <= unit_q + 5'd1;
            state_q <= S_ROW_START;
          end
        end

        // ---------------------------------------------------------------
        // logits = head.weight @ h[layer 1] + head.bias
        S_HEAD_START: begin
          acc_q  <= '0;
          term_q <= 6'd0;
          do_fetch(10'(HEDB_B) + 10'(cls_q), S_HEAD_BIAS);
        end

        S_HEAD_BIAS: begin
          acc_q <= ACC_W'(fetched_q) <<< FRAC_BITS;
          do_fetch(10'(HEDW_B) + 10'(cls_q) * 10'(HIDDEN), S_HEAD_MACD);
        end

        S_HEAD_MACD: begin
          acc_q <= acc_q + ACC_W'(fetched_q * h_q[1][term_q[4:0]]);
          if (term_q + 6'd1 == 6'(HIDDEN)) begin
            state_q <= S_HEAD_STORE;
          end else begin
            term_q <= term_q + 6'd1;
            do_fetch(10'(HEDW_B) + 10'(cls_q) * 10'(HIDDEN)
                     + 10'(term_q + 6'd1), S_HEAD_MACD);
          end
        end

        S_HEAD_STORE: begin
          logit_q[cls_q] <= sat_round(acc_q);
          if (cls_q + 2'd1 == 2'(N_CLASS)) state_q <= S_ARGMAX;
          else begin
            cls_q   <= cls_q + 2'd1;
            state_q <= S_HEAD_START;
          end
        end

        // ---------------------------------------------------------------
        S_ARGMAX: begin
          logit0_o <= logit_q[0];
          logit1_o <= logit_q[1];
          logit2_o <= logit_q[2];
          if (logit_q[2] >= logit_q[0] && logit_q[2] >= logit_q[1])
            class_o <= 2'd2;
          else if (logit_q[1] >= logit_q[0])
            class_o <= 2'd1;
          else
            class_o <= 2'd0;
          state_q <= S_DONE;
        end

        S_DONE: begin
          out_valid_o <= 1'b1;
          state_q     <= S_IDLE;
        end

        // ---------------------------------------------------------------
        // Shared fetch tail: the read was issued last cycle, data is valid
        // now, so capture the requested half and return to the caller.
        S_FETCH_D: begin
          fetched_q <= half_q ? $signed(w_dout_i[31:16])
                              : $signed(w_dout_i[15:0]);
          state_q   <= ret_q;
        end

        // Address is registered out at edge N, the SRAM samples it at
        // N+1 and its registered dout is valid after that, so data can only
        // be captured at N+2. This state is that extra cycle.
        S_FETCH: state_q <= S_FETCH_D;

        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifdef LSTM_ACCEL_ASSERT
  // Procedural equivalents, so these also run under Icarus (no SVA).
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (out_valid_o && busy_o)
        $error("lstm_accel: out_valid_o asserted while busy");
      if (in_valid_i && !in_ready_o && state_q != S_IDLE)
        $display("lstm_accel: input offered while not ready (stalling)");
    end
  end
`endif

endmodule

`default_nettype wire
