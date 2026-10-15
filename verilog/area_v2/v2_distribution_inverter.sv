// Ordinary RTL inverter bank, independently mapped by the course ABC flow.
(* keep_hierarchy=1 *)
module v2_distribution_inverter #(parameter integer WIDTH=1)(
  input wire [WIDTH-1:0] data_in,
  output wire [WIDTH-1:0] data_out
);
  assign data_out=~data_in;
endmodule
