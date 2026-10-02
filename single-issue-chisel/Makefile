ROOT := $(abspath ..)
SBT ?= $(HOME)/.local/bin/sbt
JOBS ?= 8
LATENCY ?= 20
MAX_CYCLES ?= 30000000
OUT ?= single-issue-chisel/build/default
.PHONY: generate build test perf synth
generate:
	python3 scripts/generate_baseline.py
build:
	$(MAKE) -C $(ROOT) build FILELIST=single-issue-chisel/rtl/filelist.f BUILD=$(OUT)/sim JOBS=$(JOBS)
test:
	$(MAKE) -C $(ROOT) test SIM=$(OUT)/sim/sim LATENCY=$(LATENCY) MAX_CYCLES=$(MAX_CYCLES)
perf:
	$(MAKE) -C $(ROOT) perf SIM=$(OUT)/sim/sim LATENCY=$(LATENCY) MAX_CYCLES=$(MAX_CYCLES)
synth:
	$(MAKE) -C $(ROOT) synth FILELIST=single-issue-chisel/rtl/filelist.f SYNTH_OUT=$(OUT)/synth
