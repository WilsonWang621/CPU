#!/bin/sh
set -eu
out=${1:-build/area-v2/unit}
mkdir -p "$out"
iverilog -g2005 -s student_top -o "$out/plain-parser" verilog/area_v2_core.v verilog/pararisc_axi_adapter.sv verilog/student_top.sv
iverilog -g2012 -s pararisc_axi_adapter_tb -o "$out/axi" tests/rtl/pararisc_axi_adapter_tb.sv verilog/pararisc_axi_adapter.sv
vvp "$out/axi"
iverilog -g2012 -s pararisc_mdu_tb -o "$out/mdu" tests/rtl/pararisc_mdu_tb.sv verilog/area_v2_core.v
vvp "$out/mdu"
iverilog -g2012 -s v2_rename_prepare_tb -o "$out/rename" tests/rtl/v2_rename_prepare_tb.sv verilog/area_v2_core.v
vvp "$out/rename"
iverilog -g2012 -s v2_frontend_prepare_tb -o "$out/frontend" tests/rtl/v2_frontend_prepare_tb.sv verilog/area_v2_core.v
vvp "$out/frontend"
iverilog -g2012 -s v2_frontend_target_tb -o "$out/frontend_target" tests/rtl/v2_frontend_prepare_tb.sv verilog/area_v2_core.v
vvp "$out/frontend_target"
iverilog -g2012 -s v2_frontend_sequential_tb -o "$out/frontend_sequential" tests/rtl/v2_frontend_sequential_tb.sv verilog/area_v2_core.v
vvp "$out/frontend_sequential"
iverilog -g2012 -s v2_select_wrap_tb -o "$out/select" tests/rtl/v2_select_wrap_tb.sv verilog/area_v2_core.v
vvp "$out/select"
iverilog -g2012 -s v2_dcache_write_tb -o "$out/dcache" tests/rtl/v2_dcache_write_tb.sv verilog/area_v2_core.v
vvp "$out/dcache"
iverilog -g2012 -s v2_dcache_return_tb -o "$out/dcache_return" tests/rtl/v2_dcache_return_tb.sv verilog/area_v2_core.v
vvp "$out/dcache_return"
iverilog -g2012 -s v2_terminal_squash_tb -o "$out/terminal" tests/rtl/v2_terminal_squash_tb.sv verilog/area_v2_core.v
vvp "$out/terminal"
iverilog -g2012 -s v2_branch_recovery_tb -o "$out/branch_recovery" tests/rtl/v2_branch_recovery_tb.sv verilog/area_v2_core.v
vvp "$out/branch_recovery"
iverilog -g2012 -s v2_retire_read_tb -o "$out/retire_read" tests/rtl/v2_retire_read_tb.sv verilog/area_v2_core.v
vvp "$out/retire_read"
iverilog -g2012 -s v2_retire_boundary_tb -o "$out/retire_boundary" tests/rtl/v2_retire_boundary_tb.sv verilog/area_v2_core.v
vvp "$out/retire_boundary"
iverilog -g2012 -s v2_increment_tb -o "$out/increment" tests/rtl/v2_increment_tb.sv verilog/area_v2_core.v
vvp "$out/increment"
iverilog -g2012 -s v2_operand_tb -o "$out/operand" tests/rtl/v2_operand_tb.sv verilog/area_v2_core.v
vvp "$out/operand"
