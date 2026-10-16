if {[catch {
set report_dir "/home/wangwenxuan/ACM/ParaRisc/dual-issue-chisel/build/requirements-entry/synth/opt"
set clock_port "clock"
set clock_period 2
read_liberty "/tmp/appimage_extracted_90fb4ab12aa572d488eec12b9403c6f4/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
read_liberty "/tmp/appimage_extracted_90fb4ab12aa572d488eec12b9403c6f4/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
read_liberty "/tmp/appimage_extracted_90fb4ab12aa572d488eec12b9403c6f4/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
read_liberty "/tmp/appimage_extracted_90fb4ab12aa572d488eec12b9403c6f4/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
read_liberty "/tmp/appimage_extracted_90fb4ab12aa572d488eec12b9403c6f4/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"
set_cmd_units -time ns -capacitance fF
read_verilog "/home/wangwenxuan/ACM/ParaRisc/dual-issue-chisel/build/requirements-entry/synth/opt/mapped.v"
link_design student_top
source "/home/wangwenxuan/ACM/ParaRisc/scripts/timing.tcl"
} message]} {
  puts stderr "Timing analysis failed: $message"
  exit 1
}
exit 0
