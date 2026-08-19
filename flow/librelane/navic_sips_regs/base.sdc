create_clock -name clk_i -period 10.0 [get_ports clk_i]
set_clock_uncertainty 0.25 [get_clocks clk_i]
set_clock_transition 0.15 [get_clocks clk_i]

# OpenSTA has no remove_from_collection; filter the port list in Tcl.
set inputs_no_clk {}
foreach p [all_inputs] {
    if {[get_property $p full_name] ne "clk_i"} {
        lappend inputs_no_clk $p
    }
}

# Without a driving cell / load the tool assumes infinite input slew and
# unloaded outputs, which produced ~400 spurious slew violations at ss.
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y $inputs_no_clk
set_load 0.02 [all_outputs]

# The host bus is not a critical interface. 2 ns each way is realistic.
set_input_delay  -clock clk_i 2.0 $inputs_no_clk
set_output_delay -clock clk_i 2.0 [all_outputs]

# bypass_pin_i is asynchronous, double-synchronised inside the block
set_false_path -from [get_ports bypass_pin_i]
