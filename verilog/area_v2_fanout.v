// A technology-independent physical distribution stage. Keeping each inverter
// boundary prevents Boolean optimization from collapsing a buffer tree back
// into one heavily loaded net. Both stages map to real library cells; the
// course synthesis and STA flows account for their area and delay normally.
(* keep_hierarchy = 1 *)
module area_v2_timing_inv(input wire A, output wire Y);
  assign Y = ~A;
endmodule
