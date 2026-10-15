// One unsigned restoring step. Carry-out is the exact unsigned no-borrow test.
(* keep_hierarchy=1 *)
module v2_div_step (
  input wire [31:0] quotient,divisor,
  input wire [32:0] remainder,
  output wire [31:0] next_quotient,
  output wire [32:0] next_remainder
);
  wire [32:0] shifted={remainder[31:0],quotient[31]};
  wire [32:0] difference;
  wire no_borrow;
  v2_prefix_adder #(.WIDTH(33)) subtract_divisor (
    .a(shifted),.b(~{1'b0,divisor}),.carry_in(1'b1),.sum(difference),.carry_out(no_borrow));
  assign next_quotient={quotient[30:0],no_borrow};
  assign next_remainder=no_borrow ? difference:shifted;
endmodule
