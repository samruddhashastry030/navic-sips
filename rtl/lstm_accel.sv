// ---------------------------------------------------------------------------
// lstm_accel.sv
//
// NavIC-SIPS LSTM inference accelerator -- SEQUENTIAL REFERENCE VERSION.
//
// One MAC per cycle, one weight fetch per MAC. Deliberately simple: it is
// provably correct against rtl/weights/golden_vectors.hex, so the 8x8
// systolic version can be developed against a known-good reference.
//
// ONE SHARED MULTIPLIER. The first hardened version let Yosys infer eight
// separate 16x16 $mul cells -- one per multiply expression -- even though the
// FSM only ever performs one multiply per cycle. Two came from lut_index's
// x*255, now written as (x<<8) - x; that alone cut die area by 21,356 um2 and
// power by 71%. The remaining six are routed here through a single
// multiplier whose operands are selected by the FSM state. S_CELL used to
// compute f*c and i*g in the same cycle, so it is now split into S_CELL_A and
// S_CELL_B, costing one cycle per unit per timestep -- 512 cycles per
// inference against a ~98,000-cycle total.
//
// The arithmetic is unchanged: every product is identical, and the cell
// update is still sat_round(f*c + i*g) summed at full width before rounding.
//
// PIPELINED GATE LOOKUPS. Whole-chip timing at ss found the critical path
// was S_GATE doing, in ONE cycle: 40-bit sat_round -> lut_index -> 256-entry
// LUT read -> gate_q write (worst path started at acc_q[32], ~30 gates).
// It closed standalone only through over-constraint, and failed by 1.20 ns
// once the logic was spread across the full die. S_GATE now computes the LUT
// index and S_GATE_LUT reads the table. S_HID had the same shape -- a tanh
// lookup feeding the multiplier -- so S_TANH_C does that lookup first.
// Cost: 4 cycles per unit per layer per timestep, ~2,560 cycles per
// inference against ~99,000. Arithmetic unchanged.
//
// Throughput: one inference is 26,624 MACs, roughly 99,000 cycles, about 3 ms
// at 33 MHz against a window that arrives every 10 s. The systolic array's
// case has to be energy per inference, not throughput.
//
// Numeric contract -- must match rtl/weights/WEIGHT_FORMAT.md and
// python/ml/quantise.py exactly:
//   Q8.8 signed two's complement. Accumulate at full width; round once back
//   to Q8.8, ROUND-HALF-UP, after each matrix-vector product and after each
//   elementwise product. Gates are 256-entry LUTs over [-8, +8].
//
// Weight SRAM: 512 x 32, two Q8.8 slots per word, even slot in bits [15:0].
// Registered output: address at edge N, sampled at N+1, data valid at N+2,
// hence the two-state fetch (S_FETCH then S_FETCH_D).
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

    input  wire                start_i,
    output wire                busy_o,

    input  wire                in_valid_i,
    output wire                in_ready_o,
    input  wire signed [15:0]  in_feat0_i,
    input  wire signed [15:0]  in_feat1_i,

    output reg                 w_csb_o,
    output reg  [ 8:0]         w_addr_o,
    input  wire [31:0]         w_dout_i,

    output reg                 out_valid_o,
    output reg  signed [15:0]  logit0_o,
    output reg  signed [15:0]  logit1_o,
    output reg  signed [15:0]  logit2_o,
    output reg  [ 1:0]         class_o
);

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

  typedef enum logic [4:0] {
    S_IDLE,
    S_ACCEPT,
    S_ROW_START,
    S_BIH,
    S_BHH,
    S_MACD,
    S_GATE,         // gate LUT index from the accumulator
    S_GATE_LUT,     // gate LUT read into gate_q
    S_CELL_A,       // cell_tmp = f * c
    S_CELL_B,       // c_new = round(cell_tmp + i * g)
    S_TANH_C,       // tanh(c_new) looked up and registered
    S_HID,
    S_UNIT_NEXT,
    S_HEAD_START,
    S_HEAD_BIAS,
    S_HEAD_MACD,
    S_HEAD_STORE,
    S_ARGMAX,
    S_DONE,
    S_FETCH,
    S_FETCH_D
  } state_e;

  state_e state_q, ret_q;

  reg signed [15:0] h_q      [0:1][0:HIDDEN-1];
  reg signed [15:0] h_prev_q [0:1][0:HIDDEN-1];
  reg signed [15:0] c_q      [0:1][0:HIDDEN-1];
  reg signed [15:0] xin_q    [0:N_FEAT-1];
  reg signed [15:0] gate_q   [0:3];
  reg signed [15:0] logit_q  [0:N_CLASS-1];
  reg signed [15:0] c_new_q;
  reg        [ 7:0] gidx_q;          // registered gate LUT index
  reg signed [15:0] tanh_c_q;        // registered tanh(c_new)
  reg signed [ACC_W-1:0] cell_tmp_q;

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

  reg signed [15:0] lut_sigmoid [0:255];
  reg signed [15:0] lut_tanh    [0:255];

  initial begin
    $readmemh(LUT_SIG,  lut_sigmoid);
    $readmemh(LUT_TANH, lut_tanh);
  end

  // index = round((clip(x,-8,8) + 8) / 16 * 255), i.e. in Q8.8
  //       = ((xq + 2048) * 255 + 2048) >> 12
  // written with (x<<8) - x so no multiplier is inferred.
  function automatic [7:0] lut_index(input signed [15:0] x);
    logic signed [31:0] xc, num;
    begin
      xc = 32'(x);
      if (xc >  2048) xc =  2048;
      if (xc < -2048) xc = -2048;
      num = ((((xc + 2048) <<< 8) - (xc + 2048)) + 2048) >>> 12;
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

  wire [9:0] bih_base = (layer_q == 1'b0) ? 10'(BIH0_B) : 10'(BIH1_B);
  wire [9:0] bhh_base = (layer_q == 1'b0) ? 10'(BHH0_B) : 10'(BHH1_B);

  // -------------------------------------------------------------------------
  // THE shared multiplier. Every product in the block goes through here;
  // the FSM state selects the operands. One $mul cell in the netlist.
  // -------------------------------------------------------------------------
  reg  signed [15:0] mul_a, mul_b;
  wire signed [31:0] mul_y = mul_a * mul_b;

  always_comb begin
    mul_a = 16'sd0;
    mul_b = 16'sd0;
    case (state_q)
      S_MACD:      begin mul_a = fetched_q; mul_b = term_operand(term_q);        end
      S_CELL_A:    begin mul_a = gate_q[1]; mul_b = c_q[layer_q][unit_q];        end
      S_CELL_B:    begin mul_a = gate_q[0]; mul_b = gate_q[2];                   end
      S_HID:       begin mul_a = gate_q[3]; mul_b = tanh_c_q;                    end
      S_HEAD_MACD: begin mul_a = fetched_q; mul_b = h_q[1][term_q[4:0]];         end
      default:     ;
    endcase
  end

  wire signed [ACC_W-1:0] mul_ext = ACC_W'(mul_y);

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
      cell_tmp_q  <= '0;
      c_new_q     <= 16'sd0;
      gidx_q      <= 8'd0;
      tanh_c_q    <= 16'sd0;
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

        S_ACCEPT: begin
          if (in_valid_i) begin
            xin_q[0] <= in_feat0_i;
            if (N_FEAT > 1) xin_q[1] <= in_feat1_i;
            for (i = 0; i < 2; i = i + 1)
              for (j = 0; j < HIDDEN; j = j + 1)
                h_prev_q[i][j] <= h_q[i][j];
            layer_q <= 1'b0;
            unit_q  <= 5'd0;
            gsel_q  <= 2'd0;
            state_q <= S_ROW_START;
          end
        end

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
          acc_q <= acc_q + mul_ext;
          if (term_q + 6'd1 == n_terms) begin
            state_q <= S_GATE;
          end else begin
            term_q <= term_q + 6'd1;
            do_fetch(term_slot(term_q + 6'd1), S_MACD);
          end
        end

        S_GATE: begin
          gidx_q  <= lut_index(sat_round(acc_q));
          state_q <= S_GATE_LUT;
        end

        S_GATE_LUT: begin
          gate_q[gsel_q] <= (gsel_q == 2'd2) ? lut_tanh[gidx_q]
                                             : lut_sigmoid[gidx_q];
          if (gsel_q == 2'd3) begin
            state_q <= S_CELL_A;
          end else begin
            gsel_q  <= gsel_q + 2'd1;
            state_q <= S_ROW_START;
          end
        end

        // c = f*c + i*g, now over two cycles through the shared multiplier.
        // The sum is still formed at full width before the single rounding.
        S_CELL_A: begin
          cell_tmp_q <= mul_ext;                       // f * c
          state_q    <= S_CELL_B;
        end

        S_CELL_B: begin
          c_new_q <= sat_round(cell_tmp_q + mul_ext);  // + i * g
          state_q <= S_TANH_C;
        end

        S_TANH_C: begin
          tanh_c_q <= f_tanh(c_new_q);
          state_q  <= S_HID;
        end

        // h = o * tanh(c)
        S_HID: begin
          c_q[layer_q][unit_q] <= c_new_q;
          h_q[layer_q][unit_q] <= sat_round(mul_ext);
          state_q <= S_UNIT_NEXT;
        end

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
          acc_q <= acc_q + mul_ext;
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

        // Address is registered out at edge N, the SRAM samples it at N+1,
        // and its registered dout is valid after that, so data can only be
        // captured at N+2. S_FETCH is that extra cycle.
        S_FETCH: state_q <= S_FETCH_D;

        S_FETCH_D: begin
          fetched_q <= half_q ? $signed(w_dout_i[31:16])
                              : $signed(w_dout_i[15:0]);
          state_q   <= ret_q;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
