#!/bin/sh
set -eu
out=${1:-build/area-v2/unit}
mkdir -p "$out"
iverilog -g2005 -s student_top -o "$out/plain-parser" verilog/area_v2_core.v verilog/pararisc_axi_adapter.sv verilog/student_top.sv
iverilog -g2012 -s pararisc_axi_adapter_tb -o "$out/axi" tests/rtl/pararisc_axi_adapter_tb.sv verilog/pararisc_axi_adapter.sv
vvp "$out/axi"
iverilog -g2012 -s pararisc_mdu_tb -o "$out/mdu" tests/rtl/pararisc_mdu_tb.sv verilog/area_v2_core.v
vvp "$out/mdu"
