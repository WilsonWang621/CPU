(* keep_hierarchy=1 *)
module v2_address_chunk(
  input wire [3:0] a,b,
  output wire propagate,generate_carry,
  output wire [3:0] zero_sum,one_sum
);
  wire [4:0] sum={1'b0,a}+{1'b0,b};
  assign propagate=&(a^b);
  assign generate_carry=sum[4];
  assign zero_sum=sum[3:0];
  assign one_sum=sum[3:0]+4'd1;
endmodule
