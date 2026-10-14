# OpenROAD-flow-scripts (ORFS) config: the LSTM accelerator on ASAP7.
# Place this directory at  <ORFS>/flow/designs/asap7/navic_acc/  and set
# NAVIC to the absolute path of your navic-sips checkout, then from <ORFS>/flow:
#   make DESIGN_CONFIG=./designs/asap7/navic_acc/config.mk NAVIC=$HOME/navic-sips
# Same RTL as the SKY130 macro. ASAP7 is a PREDICTIVE kit: the result can be
# placed, routed and timed, but never fabricated.
export PLATFORM      = asap7
export DESIGN_NAME   = acc_core
export DESIGN_NICKNAME = navic_acc
export VERILOG_FILES = $(NAVIC)/rtl/lstm_accel.sv $(NAVIC)/rtl/acc_core.sv
export VERILOG_TOP_PARAMS = LUT_SIG  $(NAVIC)/rtl/weights/lut_sigmoid.hex \
                            LUT_TANH $(NAVIC)/rtl/weights/lut_tanh.hex
export SDC_FILE      = $(DESIGN_DIR)/constraint.sdc
export CORE_UTILIZATION = 40
export PLACE_DENSITY    = 0.60
