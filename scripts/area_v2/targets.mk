.PHONY: export-verilog verify-rtl synth-stage1
STAGE1_OUT ?= build/area-v2/frequency

export-verilog:
	"$(PYTHON)" scripts/area_v2/export_plain.py

verify-rtl:
	./scripts/area_v2/verify_rtl.sh

# The standard synth target remains available for the raw mapping comparison.
# The physical recipe uses the same libraries and all course timing budgets.
synth-stage1:
	@frozen_list=$$("$(PYTHON)" scripts/area_v2/freeze.py --out "$(STAGE1_OUT)/sources"); \
	$(MAKE) --no-print-directory synth FILELIST="$$frozen_list" SYNTH_OUT="$(STAGE1_OUT)/raw" \
	  MODE=opt CLOCK_PERIOD_NS=2.0 ABC="$(FRAMEWORK_DIR)/scripts/area_v2/abc_direct.py"
	"$(PYTHON)" scripts/area_v2/buffer_timing.py --raw "$(STAGE1_OUT)/raw/opt" --out "$(STAGE1_OUT)/mapped" --period 3.333
