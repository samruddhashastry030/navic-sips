# RTL Coding Guidelines

- Single clock domain, `clk_i`, posedge triggered.
- Synchronous, active-low reset: `rst_ni`.
- Sequential (registered) signals suffixed `_q`.
- Every module uses a ready/valid handshake on its input side.
- No latches. No multiple always blocks driving the same signal.
- Every new RTL block ships with a cocotb testbench in the same PR.
- SVA assertions are fine for documentation, but any check that must
  also run under Icarus (no SVA support) needs a procedural equivalent
  in an always_ff block.
