# =============================================================================
# AHB-to-APB bridge verification - Verilator 5 flow
#
#   make compile                  build the simulator (build/default)
#   make run TEST=<t> SEED=<n>    run one test        -> logs/<t>_<n>.log
#   make regress                  every test x several seeds, summary table
#   make waves TEST=<t> SEED=<n>  run with VCD dump and open it in Surfer
#   make cov                      regression with coverage merge + reports
#   make bugs                     bug-injection campaign (INJECT_BUG_1..4)
#   make lint                     verilator -Wall lint of the RTL
#   make clean
# =============================================================================
SHELL      := /bin/bash
VERILATOR  ?= verilator
VCOV       ?= verilator_coverage
WAVE_VIEW  ?= surfer

TEST       ?= single_rw
SEED       ?= 1
BUG        ?=
NUM_TXNS   ?=
PLUSARGS   ?=

ifeq ($(BUG),)
  VARIANT  := default
  DEFINES  :=
else
  VARIANT  := bug$(BUG)
  DEFINES  := -DINJECT_BUG_$(BUG)
endif

BUILD_DIR  := build/$(VARIANT)
SIM_BIN    := $(BUILD_DIR)/Vtb_top
LOG_DIR    := logs
COV_DIR    := cov
WAVE_DIR   := waves

RTL_SRCS   := rtl/ahb2apb_bridge.sv
TB_SRCS    := tb/pkg/ahb2apb_cfg_pkg.sv \
              tb/sva/ahb2apb_sva_pkg.sv \
              tb/if/rst_if.sv tb/if/ahb_if.sv tb/if/apb_if.sv \
              $(wildcard tb/sva/ahb2apb_sva.sv) \
              tb/classes/ahb2apb_pkg.sv \
              tb/tests/ahb2apb_test_pkg.sv \
              tb/top/tb_top.sv
TB_INCS    := $(wildcard tb/classes/*.svh tb/tests/*.svh)

VFLAGS     := --binary --timing --assert --trace --coverage \
              -j 0 --timescale 1ns/1ps --top-module tb_top \
              +incdir+tb/classes +incdir+tb/tests \
              --x-assign unique --x-initial unique \
              -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICITSTATIC -Wno-VARHIDDEN \
              -Wno-CONSTRAINTIGN -Wno-TIMESCALEMOD -Wno-UNOPTFLAT \
              --Mdir $(BUILD_DIR) -o Vtb_top $(DEFINES)

RUN_ARGS   = +TEST=$(TEST) +SEED=$(SEED) +verilator+seed+$(SEED) +verilator+rand+reset+2 \
             +verilator+coverage+file+$(COV_DIR)/$(VARIANT)_$(TEST)_$(SEED).dat \
             $(if $(NUM_TXNS),+NUM_TXNS=$(NUM_TXNS)) $(PLUSARGS)

.PHONY: compile run regress waves cov bugs lint clean help

help:
	@sed -n '2,14p' Makefile

compile: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(TB_SRCS) $(TB_INCS) Makefile
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(TB_SRCS) 2>&1 | tee $(BUILD_DIR)/compile.log; \
	  test $${PIPESTATUS[0]} -eq 0

run: compile
	@mkdir -p $(LOG_DIR) $(COV_DIR) $(WAVE_DIR)
	$(SIM_BIN) $(RUN_ARGS) 2>&1 | tee $(LOG_DIR)/$(VARIANT)_$(TEST)_$(SEED).log; \
	  test $${PIPESTATUS[0]} -eq 0

waves: compile
	@mkdir -p $(LOG_DIR) $(COV_DIR) $(WAVE_DIR)
	-$(SIM_BIN) $(RUN_ARGS) +WAVES 2>&1 | tee $(LOG_DIR)/$(VARIANT)_$(TEST)_$(SEED).log
	@echo "Opening $(WAVE_DIR)/$(TEST)_$(SEED).vcd"
	$(WAVE_VIEW) $(WAVE_DIR)/$(TEST)_$(SEED).vcd &

regress: compile
	python3 scripts/regress.py

cov: compile
	python3 scripts/regress.py --coverage

bugs:
	python3 scripts/bug_inject.py

lint:
	$(VERILATOR) --lint-only -Wall $(RTL_SRCS)
	@for b in 1 2 3 4; do $(VERILATOR) --lint-only -Wall -DINJECT_BUG_$$b $(RTL_SRCS) || exit 1; done
	@echo "RTL lint clean (default + INJECT_BUG_1..4)"

clean:
	rm -rf build logs cov waves obj_dir coverage.dat
