// Carry composition: the high group consumes the low group's carry.
// Preserve this boundary so timing mapping keeps the logarithmic prefix graph.
(* keep_hierarchy=1 *)
module v2_prefix_node(
  input wire high_g,high_p,low_g,low_p,
  output wire group_g,group_p
);
  assign group_g=high_g | (high_p & low_g);
  assign group_p=high_p & low_p;
endmodule
