// Live extended ROB tags span less than half of the sequence space.
(* keep_hierarchy=1 *)
module v2_order_compare #(parameter integer BITS=6)(
  input wire [BITS-1:0] a,b,
  output wire first
);
  wire [BITS-1:0] difference=a-b;
  assign first=difference[BITS-1] || a==b;
endmodule
