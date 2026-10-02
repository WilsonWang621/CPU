SHELL := /bin/bash
.DEFAULT_GOAL := build-v2

BUILD_DIR ?= build
JOBS ?= 2
PARAMS ?=
SIM_FLAGS ?=
V2_BUILD_DIR ?= build/area-v2/cpu
V2_BUILD_ARGS ?=
LATENCY ?= 3
TEST_JOBS ?= $(JOBS)
TEST_ARGS ?=
VERILATOR ?= $(CURDIR)/RISC-V-CPU-2026-Toolchain/bin/verilator
BUILD_ABS := $(abspath $(BUILD_DIR))
SIM := $(BUILD_ABS)/cpu_sim
RTL := rtl/cpu_pkg.sv $(filter-out rtl/cpu_pkg.sv,$(sort $(wildcard rtl/*.sv)))
LINT_FLAGS := --assert --unroll-count 1024 --unroll-stmts 100000 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY

.PHONY: all build-v2 test-v2 verify-v2 synth-v2 export-verilog-v2 build lint test test-isa test-cache test-frontend test-core test-lsu test-system test-all export-verilog synth-check synth clean
all: build-v2

build-v2:
	python3 designs/area_v2/build.py --output "$(V2_BUILD_DIR)" --jobs $(JOBS) $(V2_BUILD_ARGS)

test-v2: build-v2
	python3 scripts/run_tests.py --binary "$(V2_BUILD_DIR)/cpu_sim" --latency $(LATENCY) \
	  --jobs $(TEST_JOBS) --output "$(V2_BUILD_DIR)/results-latency$(LATENCY)" $(TEST_ARGS)

verify-v2:
	python3 designs/area_v2/build.py --output "$(V2_BUILD_DIR)/verified" --jobs $(JOBS) --verify $(V2_BUILD_ARGS)
	python3 designs/area_v2/verify_core.py --binary "$(V2_BUILD_DIR)/verified/cpu_sim" --output "$(V2_BUILD_DIR)/mechanisms"

synth-v2: build-v2
	python3 designs/area_v2/synthesize.py --build-dir "$(V2_BUILD_DIR)" --output "$(V2_BUILD_DIR)/synthesis"

export-verilog-v2: build-v2
	python3 designs/area_v2/export.py --build-dir "$(V2_BUILD_DIR)"

# Re-invoke Verilator so changing PARAMS in the same BUILD_DIR cannot silently
# reuse a simulator built with an earlier hardware configuration.
build:
	mkdir -p "$(BUILD_ABS)"
	$(VERILATOR) --cc --exe --build -j $(JOBS) --top-module cpu_top \
	  --Mdir "$(BUILD_ABS)/obj" -o "$(SIM)" $(LINT_FLAGS) $(SIM_FLAGS) $(PARAMS) \
	  -CFLAGS '-std=c++17' -MAKEFLAGS 'OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1' \
	  $(RTL) "$(CURDIR)/sim/main.cpp"

lint:
	$(VERILATOR) --lint-only --top-module cpu_top $(LINT_FLAGS) $(PARAMS) $(RTL)

test: build
	python3 scripts/run_tests.py --binary "$(SIM)" --latency $(LATENCY) \
	  --jobs $(TEST_JOBS) --output "$(BUILD_ABS)/results-latency$(LATENCY)" $(TEST_ARGS)

test-isa:
	JOBS=$(JOBS) VERILATOR="$(VERILATOR)" bash tests/isa/run.sh

test-cache:
	JOBS=$(JOBS) CACHE_TEST_BUILD_DIR="$(BUILD_ABS)/tests-cache" bash tests/cache/run.sh

test-system: build
	python3 tests/system/generate.py
	python3 scripts/run_tests.py --binary "$(SIM)" --root build/system_tests \
	  --latency $(LATENCY) --jobs $(TEST_JOBS) --differential \
	  --output "$(BUILD_ABS)/system-results-latency$(LATENCY)" $(TEST_ARGS)

test-frontend:
	bash tests/frontend/run.sh

test-core:
	python3 tests/core/run.py --jobs $(JOBS)

test-lsu:
	python3 tests/lsu/run.py --jobs $(JOBS)

test-all: test-isa test-cache test-frontend test-core test-lsu test test-system

export-verilog:
	python3 scripts/export_verilog.py --output "$(BUILD_ABS)/cpu.v"

synth-check:
	python3 scripts/synthesize.py --output "$(BUILD_ABS)/synth-check" --mode check $(SYNTH_ARGS)

synth:
	python3 scripts/synthesize.py --output "$(BUILD_ABS)/synth" --mode asap7 $(SYNTH_ARGS)

clean:
	rm -rf -- "$(BUILD_ABS)/obj" "$(SIM)"
