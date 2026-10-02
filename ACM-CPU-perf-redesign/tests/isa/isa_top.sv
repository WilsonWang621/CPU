module isa_top #(parameter integer DIV_STEP_BITS=4) (
  input logic clk, rst, kill,
  input logic [255:0] kill_mask,
  input logic [31:0] inst,
  output logic [5:0] dec_op,
  output logic [4:0] dec_rs1, dec_rs2, dec_rd,
  output logic dec_uses_rs1, dec_uses_rs2, dec_writes_rd, dec_use_imm,
  output logic [31:0] dec_imm,
  output logic [1:0] dec_mem_size,
  output logic dec_load_signed, dec_illegal,
  input logic [5:0] op,
  input logic [31:0] a, b, pc, imm,
  output logic [31:0] alu_result, branch_result, next_pc,
  output logic taken, misaligned,
  input logic req_valid,
  output logic req_ready,mul_ready,div_ready,
  input logic [5:0] req_op,
  input logic [31:0] req_a, req_b,
  input logic [7:0] req_tag,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [31:0] rsp_result,
  output logic [7:0] rsp_tag
);
  cpu_pkg::decoded_t dec;
  decoder decoder_i (.inst, .dec);
  assign dec_op = dec.op;
  assign dec_rs1 = dec.rs1;
  assign dec_rs2 = dec.rs2;
  assign dec_rd = dec.rd;
  assign dec_uses_rs1 = dec.uses_rs1;
  assign dec_uses_rs2 = dec.uses_rs2;
  assign dec_writes_rd = dec.writes_rd;
  assign dec_use_imm = dec.use_imm;
  assign dec_imm = dec.imm;
  assign dec_mem_size = dec.mem_size;
  assign dec_load_signed = dec.load_signed;
  assign dec_illegal = dec.illegal;
  alu alu_i (.op(cpu_pkg::op_t'(op)), .a, .b, .pc, .imm, .result(alu_result));
  branch_unit branch_i (.op(cpu_pkg::op_t'(op)), .a, .b, .pc, .imm,
                       .result(branch_result), .next_pc, .taken, .misaligned);
  muldiv #(.DIV_STEP_BITS(DIV_STEP_BITS)) muldiv_i (.clk, .rst, .kill, .kill_mask, .req_valid, .req_ready, .mul_ready, .div_ready,
                  .req_op(cpu_pkg::op_t'(req_op)), .req_a, .req_b, .req_tag,
                  .rsp_valid, .rsp_ready, .rsp_result, .rsp_tag);
endmodule
