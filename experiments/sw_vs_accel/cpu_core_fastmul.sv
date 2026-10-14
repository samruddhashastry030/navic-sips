// EXPERIMENT ONLY: rtl/cpu_core.sv with PicoRV32 ENABLE_FAST_MUL (a parallel
// 33x33 multiplier, a few cycles per MUL) in place of the iterative one. Same module name and ports,
// so it drops in for the "faster CPU instead of an accelerator" comparison.
// ---------------------------------------------------------------------------
// cpu_core.sv
//
// PicoRV32 (RV32IMC) with its configuration fixed inside, exposing only the
// native memory bus the chip uses.
//
// Why a wrapper: for the hierarchical layout the CPU is hardened on its own
// as a macro and then placed on the chip as a block, like the SRAMs. A macro
// is a finished layout, so it cannot take Verilog parameters at the point
// where it is instantiated -- the parameters have to be baked in when it is
// hardened. This wrapper bakes them in, and drops the ports the chip never
// uses (look-ahead bus, PCPI, trace, IRQ), so the macro has ~100 pins instead
// of ~400.
//
// Behaviour is identical to the picorv32 instance it replaces in
// navic_sips_top.sv: same parameters, same tie-offs (irq = 0, pcpi idle).
// ---------------------------------------------------------------------------

`default_nettype none

module cpu_core (
    input  wire        clk_i,
    input  wire        rst_ni,

    output wire        mem_valid_o,
    input  wire        mem_ready_i,
    output wire [31:0] mem_addr_o,
    output wire [31:0] mem_wdata_o,
    output wire [ 3:0] mem_wstrb_o,
    input  wire [31:0] mem_rdata_i
);

  picorv32 #(
      .ENABLE_MUL        (0),
      .ENABLE_FAST_MUL   (1),
      .ENABLE_DIV        (1),
      .COMPRESSED_ISA    (1),
      .ENABLE_IRQ        (1),
      .ENABLE_COUNTERS64 (0),
      .PROGADDR_RESET    (32'h0000_0000),
      .PROGADDR_IRQ      (32'h0000_0010)
  ) u_core (
      .clk          (clk_i),
      .resetn       (rst_ni),
      .trap         (),
      .mem_valid    (mem_valid_o),
      .mem_instr    (),
      .mem_ready    (mem_ready_i),
      .mem_addr     (mem_addr_o),
      .mem_wdata    (mem_wdata_o),
      .mem_wstrb    (mem_wstrb_o),
      .mem_rdata    (mem_rdata_i),
      .mem_la_read  (),
      .mem_la_write (),
      .mem_la_addr  (),
      .mem_la_wdata (),
      .mem_la_wstrb (),
      .pcpi_valid   (),
      .pcpi_insn    (),
      .pcpi_rs1     (),
      .pcpi_rs2     (),
      .pcpi_wr      (1'b0),
      .pcpi_rd      (32'd0),
      .pcpi_wait    (1'b0),
      .pcpi_ready   (1'b0),
      .irq          (32'd0),         // firmware polls; see memory-map.md
      .eoi          (),
      .trace_valid  (),
      .trace_data   ()
  );

endmodule

`default_nettype wire
