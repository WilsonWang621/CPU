module alu (
  input cpu_pkg::op_t op,
  input logic [31:0] a, b, pc, imm,
  output logic [31:0] result
);
  import cpu_pkg::*;

  wire subtract=op==OP_SUB || op==OP_SLT || op==OP_SLTU;
  wire [31:0] arithmetic_value,pc_value;
  wire no_borrow;
  v2_prefix_adder #(.WIDTH(32)) add_operands (
    .a(a),.b(b^{32{subtract}}),.carry_in(subtract),.sum(arithmetic_value),.carry_out(no_borrow));
  v2_prefix_adder #(.WIDTH(32)) add_pc (
    .a(pc),.b(imm),.carry_in(1'b0),.sum(pc_value),.carry_out());
  always_comb begin
    case (op)
      OP_ADD:   result = arithmetic_value;
      OP_SUB:   result = arithmetic_value;
      OP_SLL:   result = a << b[4:0];
      OP_SLT:   result = {31'b0, a[31]!=b[31] ? a[31]:!no_borrow};
      OP_SLTU:  result = {31'b0, !no_borrow};
      OP_XOR:   result = a ^ b;
      OP_SRL:   result = a >> b[4:0];
      OP_SRA:   result = $signed(a) >>> b[4:0];
      OP_OR:    result = a | b;
      OP_AND:   result = a & b;
      OP_LUI:   result = imm;
      OP_AUIPC: result = pc_value;
      default:  result = 32'b0;
    endcase
  end
endmodule
