ROOT := $(abspath ..)
SBT ?= sbt
OUT ?= dual-issue-chisel/build/default
JOBS ?= 4
LATENCY ?= 20
MAX_CYCLES ?= 20000000
.PHONY: generate build test perf synth verify-units

generate:
	$(SBT) -batch 'run --out rtl'

build:
	$(MAKE) -C $(ROOT) build FILELIST=dual-issue-chisel/rtl/filelist.f BUILD=$(OUT)/sim JOBS=$(JOBS)

test:
	$(MAKE) -C $(ROOT) test SIM=$(OUT)/sim/sim LATENCY=$(LATENCY) MAX_CYCLES=$(MAX_CYCLES)

perf:
	$(MAKE) -C $(ROOT) perf SIM=$(OUT)/sim/sim LATENCY=$(LATENCY) MAX_CYCLES=$(MAX_CYCLES)

synth:
	$(MAKE) -C $(ROOT) synth FILELIST=dual-issue-chisel/rtl/filelist.f SYNTH_OUT=$(OUT)/synth

verify-units:
	$(SBT) -batch \
	  'run --module muldiv --out build/muldiv' \
	  'run --module rename --checkpoints 4 --out build/rename4' \
	  'run --module frontend --cache-bytes 128 --queue-entries 4 --bht-entries 16 --btb-entries 4 --history-entries 4 --out build/frontend-unit' \
	  'run --module dcache --cache-bytes 2048 --line-bytes 16 --mshrs 2 --load-slots 4 --store-slots 4 --credits 8 --out build/dcache-write' \
	  'run --module dcache --cache-bytes 512 --line-bytes 16 --mshrs 4 --load-slots 8 --store-slots 4 --credits 16 --ram-bytes 16384 --out build/dcache-return'
	python3 scripts/verify_units.py
