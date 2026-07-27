# cocotb testbench for uart_tx
#
#   make             run with Icarus Verilog (default)
#   make SIM=verilator
#   rm -rf sim_build results.xml   clean rebuild

SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

RTL_DIR := $(abspath $(CURDIR)/../../rtl)

VERILOG_SOURCES     := $(RTL_DIR)/uart_tx.sv $(CURDIR)/tb_uart_tx.sv
TOPLEVEL            := tb_uart_tx
COCOTB_TEST_MODULES := test_uart_tx

ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-structs --assert -Wall -Wno-fatal
endif
ifeq ($(SIM),icarus)
    COMPILE_ARGS += -g2012
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
