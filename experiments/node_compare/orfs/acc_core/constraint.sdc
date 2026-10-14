# ASAP7 time unit is ps. CLK_PS defaults to the SKY130 chip's 33 ns so the two
# nodes are compared at the same clock; set CLK_PS=2000 (env) for a speed run.
set clk_ps [expr {[info exists ::env(CLK_PS)] ? $::env(CLK_PS) : 33000}]
create_clock -name clk -period $clk_ps [get_ports clk_i]
set io [expr {$clk_ps * 0.25}]
set_input_delay  $io -clock clk [delete_from_list [all_inputs] [get_ports clk_i]]
set_output_delay $io -clock clk [all_outputs]
