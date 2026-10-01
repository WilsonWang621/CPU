// Integer execution: one registered issue packet enters each execution lane.
module pararisc_alu (
  input wire [31:0] insn, pc, a, b,
  output reg [31:0] value, target,
  output reg branch, taken, illegal
);
  wire [6:0] op = insn[6:0];
  wire [2:0] f3 = insn[14:12];
  wire [6:0] f7 = insn[31:25];
  wire [31:0] ii = {{20{insn[31]}}, insn[31:20]};
  wire [31:0] is = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  wire [31:0] ib = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  wire [31:0] ij = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
  wire [31:0] rhs = op == 7'h13 ? ii : b;
  always @* begin
    value = 0; target = pc + 4; branch = 0; taken = 0; illegal = 0;
    case (op)
      7'h37: value = {insn[31:12], 12'b0};
      7'h17: value = pc + {insn[31:12], 12'b0};
      7'h13, 7'h33: begin
        if (op == 7'h33 && f7 != 0 && !(f7 == 7'h20 && (f3 == 0 || f3 == 5))) illegal = 1;
        case (f3)
          0: value = op == 7'h33 && insn[30] ? a - rhs : a + rhs;
          1: begin value = a << rhs[4:0]; if (f7 != 0) illegal = 1; end
          2: value = {31'b0, $signed(a) < $signed(rhs)};
          3: value = {31'b0, a < rhs};
          4: value = a ^ rhs;
          5: begin
            if (insn[30]) value = $signed(a) >>> rhs[4:0];
            else value = a >> rhs[4:0];
            if (f7 != 0 && f7 != 7'h20) illegal = 1;
          end
          6: value = a | rhs;
          7: value = a & rhs;
        endcase
      end
      7'h03: begin
        value = a + ii;
        if (!(f3 == 0 || f3 == 1 || f3 == 2 || f3 == 4 || f3 == 5)) illegal = 1;
        if ((f3 == 1 || f3 == 5) && value[0]) illegal = 1;
        if (f3 == 2 && value[1:0] != 0) illegal = 1;
      end
      7'h23: begin
        value = a + is;
        if (f3 > 2 || (f3 == 1 && value[0]) || (f3 == 2 && value[1:0] != 0)) illegal = 1;
      end
      7'h63: begin
        branch = 1;
        case (f3)
          0: taken = a == b;
          1: taken = a != b;
          4: taken = $signed(a) < $signed(b);
          5: taken = $signed(a) >= $signed(b);
          6: taken = a < b;
          7: taken = a >= b;
          default: illegal = 1;
        endcase
        target = taken ? pc + ib : pc + 4;
      end
      7'h6f: begin branch = 1; taken = 1; value = pc + 4; target = pc + ij; end
      7'h67: begin
        branch = 1; taken = 1; value = pc + 4; target = (a + ii) & 32'hffff_fffe;
        if (f3 != 0) illegal = 1;
      end
      7'h0f: begin end
      default: illegal = 1;
    endcase
    if (branch && target[1:0] != 0) illegal = 1;
  end
endmodule
