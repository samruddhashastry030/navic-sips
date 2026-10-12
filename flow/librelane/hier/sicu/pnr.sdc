create_clock -name clk_i -period 27.0 [get_ports clk_i]
set_clock_uncertainty 0.25 [get_clocks clk_i]
set_clock_transition 0.15 [get_clocks clk_i]

# OpenSTA has no remove_from_collection; filter the port list in Tcl.
set inputs_no_clk {}
foreach p [all_inputs] {
    if {[get_property $p full_name] ne "clk_i"} {
        lappend inputs_no_clk $p
    }
}

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y $inputs_no_clk
set_load 0.02 [all_outputs]

# Macro I/O budget: 8 ns of the cycle belongs to the wires and glue logic
# outside this block. The chip-level STA on the real timing models is the
# actual signoff; this only keeps the block from spending that time itself.
set_input_delay  -clock clk_i 8 $inputs_no_clk
set_output_delay -clock clk_i 8 [all_outputs]

# Inputs driven directly by chip pins: same 2 ns as the chip's own SDC.
set_input_delay -clock clk_i 2.0 [get_ports {in_valid_i i_i[*] q_i[*]}]
