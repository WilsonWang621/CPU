// Functional RV32IM baseline for the CPU2026 AXI4-Lite harness.
//
// This deliberately small multi-cycle core is the executable integration
// baseline.  It permits one outstanding transaction and keeps every AXI
// payload stable until its independent handshake completes.
module student_top (
  input  logic        clock,
  input  logic        reset,
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);
  localparam logic [3:0] FETCH_ADDR = 4'd0, FETCH_DATA = 4'd1,
                         EXECUTE    = 4'd2, LOAD_ADDR  = 4'd3,
                         LOAD_DATA  = 4'd4, STORE_SEND = 4'd5,
                         STORE_RESP = 4'd6, FAULT       = 4'd7,
                         I_REFILL    = 4'd8, D_REFILL    = 4'd9,
                         D_FINISH    = 4'd10, DIV_RUN = 4'd11,
                         DIV_INIT    = 4'd12;

  logic [3:0] state;
  logic [31:0] pc, instruction;
  logic [31:0] regs [0:31];
  logic [31:0] memory_addr;
  logic [4:0] load_rd;
  logic [2:0] load_funct3;
  logic [1:0] load_lane;
  logic aw_sent, w_sent;
  logic [4:0] writes_outstanding;
  logic [31:0] div_dividend, div_divisor, div_quotient;
  logic [32:0] div_remainder;
  logic [5:0] div_count;
  logic [4:0] div_rd;
  logic div_is_rem, div_negate_quotient, div_negate_remainder;
  logic [31:0] store_q_addr [0:15];
  logic [31:0] store_q_data [0:15];
  logic [3:0] store_q_strobe [0:15];
  logic [3:0] store_q_head, store_q_tail;
  logic [4:0] store_q_count;
  logic [31:0] refill_base;
  logic [3:0] refill_sent, refill_received;
  // 2 KiB direct-mapped instruction cache.  A word is a complete line because
  // the lower AXI interface is 32 bits wide.  Data stores invalidate a matching
  // entry, preserving correctness for code patched through the data port.
  logic [31:0] ic_data [0:2047];
  logic [18:0] ic_tag [0:2047];
  logic [2047:0] ic_valid;
  logic [31:0] dc_data [0:8191];
  logic [16:0] dc_tag [0:8191];
  logic [8191:0] dc_valid;
  integer i;

  wire [6:0] opcode = instruction[6:0];
  wire [2:0] funct3 = instruction[14:12];
  wire [6:0] funct7 = instruction[31:25];
  wire [4:0] rs1 = instruction[19:15];
  wire [4:0] rs2 = instruction[24:20];
  wire [4:0] rd  = instruction[11:7];
  wire [31:0] a = (rs1 == 0) ? 32'b0 : regs[rs1];
  wire [31:0] b = (rs2 == 0) ? 32'b0 : regs[rs2];
  wire [31:0] imm_i = {{20{instruction[31]}}, instruction[31:20]};
  wire [31:0] imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
  wire [31:0] imm_b = {{19{instruction[31]}}, instruction[31], instruction[7],
                       instruction[30:25], instruction[11:8], 1'b0};
  wire [31:0] imm_u = {instruction[31:12], 12'b0};
  wire [31:0] imm_j = {{11{instruction[31]}}, instruction[31], instruction[19:12],
                       instruction[20], instruction[30:21], 1'b0};
  /* verilator lint_off UNUSEDSIGNAL */
  wire signed [63:0] product_ss = $signed(a) * $signed(b);
  wire        [63:0] product_uu = a * b;
  wire signed [64:0] product_su = $signed({a[31], a}) * $signed({1'b0, b});
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic [5:0] bit_length(input logic [31:0] value);
    integer bit_index;
    begin
      bit_length = 0;
      for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
        if (value[bit_index]) bit_length = bit_index + 1;
    end
  endfunction
  wire [5:0] div_dividend_bits = bit_length(div_dividend);
  wire [5:0] div_divisor_bits = bit_length(div_divisor);
  wire [5:0] div_shift = div_dividend_bits - div_divisor_bits;
  wire div_subtract = div_remainder >= {1'b0, div_divisor};
  wire [32:0] div_remainder_next = div_subtract ?
    div_remainder - {1'b0, div_divisor} : div_remainder;
  wire [31:0] div_quotient_next = div_quotient |
    (div_subtract ? (32'h1 << (div_count - 1)) : 0);
  wire [31:0] div_value = div_is_rem ? div_remainder_next[31:0] : div_quotient_next;
  wire [31:0] div_result =
    ((div_is_rem && div_negate_remainder) || (!div_is_rem && div_negate_quotient)) ?
    -div_value : div_value;
  wire [10:0] fetch_index = pc[12:2];
  wire fetch_hit = ic_valid[fetch_index] && ic_tag[fetch_index] == pc[31:13];
  wire [31:0] enqueue_store_addr = a + imm_s;
  wire [3:0] enqueue_store_strobe = funct3 == 0 ?
    (4'b0001 << enqueue_store_addr[1:0]) :
    (funct3 == 1 ? (4'b0011 << enqueue_store_addr[1:0]) : 4'b1111);
  wire [31:0] enqueue_store_data = b << (8 * enqueue_store_addr[1:0]);
  wire enqueue_store_legal = opcode == 7'h23 && funct3 <= 2 &&
    !(funct3 == 1 && enqueue_store_addr[0]) &&
    !(funct3 == 2 && enqueue_store_addr[1:0] != 0);
  wire store_enqueue = state == EXECUTE && enqueue_store_legal && store_q_count < 16;
  wire write_finish = store_q_count != 0 &&
    (aw_sent || (awvalid && awready)) && (w_sent || (wvalid && wready));
  wire write_response = bvalid && bready;
  wire [31:0] refill_send_addr = refill_base + {26'b0, refill_sent, 2'b0};
  wire [31:0] refill_recv_addr = refill_base + {26'b0, refill_received, 2'b0};

  always_comb begin
    araddr  = (state == I_REFILL || state == D_REFILL) ? refill_send_addr :
      ((state == FETCH_ADDR) ? pc : memory_addr);
    arvalid = ((state == I_REFILL || state == D_REFILL) && refill_sent < 8) ||
      (state == LOAD_ADDR);
    rready  = (state == FETCH_DATA) || (state == LOAD_DATA) ||
      ((state == I_REFILL || state == D_REFILL) && refill_received < 8);
    awaddr  = store_q_addr[store_q_head];
    awvalid = store_q_count != 0 && !aw_sent && writes_outstanding < 16;
    wdata   = store_q_data[store_q_head];
    wstrb   = store_q_strobe[store_q_head];
    wvalid  = store_q_count != 0 && !w_sent && writes_outstanding < 16;
    bready  = writes_outstanding != 0;
  end

  // Complete an instruction and immediately stage the next cached instruction.
  // This turns I-cache hits into a true one-instruction-per-cycle path while a
  // miss still returns through the ordinary AXI fetch states.
  task automatic continue_at(input logic [31:0] next_pc);
    begin
      pc <= next_pc;
      if (ic_valid[next_pc[12:2]] && ic_tag[next_pc[12:2]] == next_pc[31:13]) begin
        instruction <= ic_data[next_pc[12:2]];
        state <= EXECUTE;
      end else state <= FETCH_ADDR;
    end
  endtask

  function automatic [31:0] extend_load(
    input logic [31:0] word,
    input logic [1:0] lane,
    input logic [2:0] size
  );
    logic [31:0] shifted;
    begin
      shifted = word >> (8 * lane);
      case (size)
        3'h0: extend_load = {{24{shifted[7]}}, shifted[7:0]};
        3'h1: extend_load = {{16{shifted[15]}}, shifted[15:0]};
        3'h2: extend_load = shifted;
        3'h4: extend_load = {24'b0, shifted[7:0]};
        3'h5: extend_load = {16'b0, shifted[15:0]};
        default: extend_load = 0;
      endcase
    end
  endfunction

  function automatic logic is_simple(input logic [31:0] insn);
    logic [6:0] op;
    begin
      op = insn[6:0];
      is_simple = op == 7'h37 || op == 7'h17 || op == 7'h13 ||
        (op == 7'h33 && insn[31:25] != 7'h01);
    end
  endfunction

  // M operations remain single-issued: duplicating combinational multiply and
  // divide hardware would exceed both the area budget and the 2 ns path goal.
  function automatic logic is_pairable(input logic [31:0] insn);
    begin
      is_pairable = is_simple(insn);
    end
  endfunction

  function automatic logic is_cond_branch(input logic [31:0] insn);
    begin
      is_cond_branch = insn[6:0] == 7'h63 &&
        (insn[14:12] == 0 || insn[14:12] == 1 || insn[14:12] == 4 ||
         insn[14:12] == 5 || insn[14:12] == 6 || insn[14:12] == 7);
    end
  endfunction

  function automatic [31:0] simple_result(
    input logic [31:0] insn,
    input logic [31:0] insn_pc,
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    logic [6:0] op;
    logic [2:0] f3;
    logic [31:0] imm;
    logic signed [31:0] slhs, srhs;
    begin
      op = insn[6:0]; f3 = insn[14:12];
      imm = {{20{insn[31]}}, insn[31:20]};
      slhs = lhs; srhs = rhs;
      simple_result = 0;
      case (op)
        7'h37: simple_result = {insn[31:12], 12'b0};
        7'h17: simple_result = insn_pc + {insn[31:12], 12'b0};
        7'h13: case (f3)
          3'h0: simple_result = lhs + imm;
          3'h1: simple_result = lhs << insn[24:20];
          3'h2: simple_result = {31'b0, slhs < $signed(imm)};
          3'h3: simple_result = {31'b0, lhs < imm};
          3'h4: simple_result = lhs ^ imm;
          3'h5: simple_result = insn[30] ? slhs >>> insn[24:20] : lhs >> insn[24:20];
          3'h6: simple_result = lhs | imm;
          3'h7: simple_result = lhs & imm;
        endcase
        7'h33: begin
          case (f3)
            3'h0: simple_result = insn[30] ? lhs - rhs : lhs + rhs;
            3'h1: simple_result = lhs << rhs[4:0];
            3'h2: simple_result = {31'b0, slhs < srhs};
            3'h3: simple_result = {31'b0, lhs < rhs};
            3'h4: simple_result = lhs ^ rhs;
            3'h5: simple_result = insn[30] ? slhs >>> rhs[4:0] : lhs >> rhs[4:0];
            3'h6: simple_result = lhs | rhs;
            3'h7: simple_result = lhs & rhs;
          endcase
        end
      endcase
    end
  endfunction

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= FETCH_ADDR;
      pc <= 0;
      instruction <= 0;
      memory_addr <= 0;
      load_rd <= 0;
      load_funct3 <= 0;
      load_lane <= 0;
      aw_sent <= 0;
      w_sent <= 0;
      writes_outstanding <= 0;
      div_dividend <= 0; div_divisor <= 0; div_quotient <= 0;
      div_remainder <= 0; div_count <= 0; div_rd <= 0;
      div_is_rem <= 0; div_negate_quotient <= 0; div_negate_remainder <= 0;
      store_q_head <= 0; store_q_tail <= 0; store_q_count <= 0;
      refill_base <= 0;
      refill_sent <= 0;
      refill_received <= 0;
      for (i = 0; i < 32; i = i + 1) regs[i] <= 0;
      ic_valid <= '0;
      dc_valid <= '0;
    end else begin
      regs[0] <= 0;
      case (state)
        FETCH_ADDR: begin
          if (fetch_hit) begin instruction <= ic_data[fetch_index]; state <= EXECUTE; end
          else begin
            refill_base <= pc & 32'hffff_ffe0;
            refill_sent <= 0; refill_received <= 0; state <= I_REFILL;
          end
        end
        FETCH_DATA: if (rvalid && rready) begin
          if (rresp != 0) state <= FAULT;
          else begin
            instruction <= rdata;
            ic_data[fetch_index] <= rdata;
            ic_tag[fetch_index] <= pc[31:13];
            ic_valid[fetch_index] <= 1;
            state <= EXECUTE;
          end
        end
        EXECUTE: begin : execute_instruction
          logic [31:0] address;
          logic [31:0] result;
          logic branch_taken;
          logic [31:0] second_pc, second_inst, result0, result1, lhs1, rhs1;
          logic second_hit, branch1_taken;
          logic [31:0] branch1_imm;
          logic [4:0] rd0, rs1_1, rs2_1, rd1;
          address = a + ((opcode == 7'h23) ? imm_s : imm_i);
          result = 0;
          branch_taken = 0;
          second_pc = pc + 4;
          second_inst = ic_data[second_pc[12:2]];
          second_hit = ic_valid[second_pc[12:2]] &&
            ic_tag[second_pc[12:2]] == second_pc[31:13];
          rd0 = instruction[11:7];
          rs1_1 = second_inst[19:15]; rs2_1 = second_inst[24:20];
          rd1 = second_inst[11:7];
          result0 = simple_result(instruction, pc, a, b);
          lhs1 = rs1_1 == 0 ? 0 :
            ((rd0 != 0 && rs1_1 == rd0) ? result0 : regs[rs1_1]);
          rhs1 = rs2_1 == 0 ? 0 :
            ((rd0 != 0 && rs2_1 == rd0) ? result0 : regs[rs2_1]);
          result1 = simple_result(second_inst, second_pc, lhs1, rhs1);
          branch1_imm = {{19{second_inst[31]}}, second_inst[31], second_inst[7],
            second_inst[30:25], second_inst[11:8], 1'b0};
          branch1_taken = 0;
          case (second_inst[14:12])
            3'h0: branch1_taken = lhs1 == rhs1;
            3'h1: branch1_taken = lhs1 != rhs1;
            3'h4: branch1_taken = $signed(lhs1) < $signed(rhs1);
            3'h5: branch1_taken = $signed(lhs1) >= $signed(rhs1);
            3'h6: branch1_taken = lhs1 < rhs1;
            3'h7: branch1_taken = lhs1 >= rhs1;
            default: branch1_taken = 0;
          endcase
          if (is_simple(instruction)) begin
            if (rd0 != 0) regs[rd0] <= result0;
            if (second_hit && is_pairable(instruction) &&
                (is_pairable(second_inst) || is_cond_branch(second_inst))) begin
              if (is_cond_branch(second_inst))
                continue_at(branch1_taken ? second_pc + branch1_imm : pc + 8);
              else begin
                if (rd1 != 0) regs[rd1] <= result1;
                continue_at(pc + 8);
              end
            end else continue_at(pc + 4);
          end else begin
          case (opcode)
            7'h37: begin if (rd != 0) regs[rd] <= imm_u; continue_at(pc + 4); end
            7'h17: begin if (rd != 0) regs[rd] <= pc + imm_u; continue_at(pc + 4); end
            7'h6f: begin
              if (rd != 0) regs[rd] <= pc + 4;
              second_pc = pc + imm_j;
              second_inst = ic_data[second_pc[12:2]];
              second_hit = ic_valid[second_pc[12:2]] &&
                ic_tag[second_pc[12:2]] == second_pc[31:13];
              rs1_1 = second_inst[19:15]; rs2_1 = second_inst[24:20];
              rd1 = second_inst[11:7];
              lhs1 = rs1_1 == 0 ? 0 : ((rd != 0 && rs1_1 == rd) ? pc + 4 : regs[rs1_1]);
              rhs1 = rs2_1 == 0 ? 0 : ((rd != 0 && rs2_1 == rd) ? pc + 4 : regs[rs2_1]);
              result1 = simple_result(second_inst, second_pc, lhs1, rhs1);
              if (second_hit && is_pairable(second_inst)) begin
                if (rd1 != 0) regs[rd1] <= result1;
                continue_at(second_pc + 4);
              end else continue_at(second_pc);
            end
            7'h67: begin
              if (funct3 != 0) state <= FAULT;
              else begin
                if (rd != 0) regs[rd] <= pc + 4;
                second_pc = (a + imm_i) & 32'hffff_fffe;
                second_inst = ic_data[second_pc[12:2]];
                second_hit = ic_valid[second_pc[12:2]] &&
                  ic_tag[second_pc[12:2]] == second_pc[31:13];
                rs1_1 = second_inst[19:15]; rs2_1 = second_inst[24:20];
                rd1 = second_inst[11:7];
                lhs1 = rs1_1 == 0 ? 0 : ((rd != 0 && rs1_1 == rd) ? pc + 4 : regs[rs1_1]);
                rhs1 = rs2_1 == 0 ? 0 : ((rd != 0 && rs2_1 == rd) ? pc + 4 : regs[rs2_1]);
                result1 = simple_result(second_inst, second_pc, lhs1, rhs1);
                if (second_hit && is_pairable(second_inst)) begin
                  if (rd1 != 0) regs[rd1] <= result1;
                  continue_at(second_pc + 4);
                end else continue_at(second_pc);
              end
            end
            7'h63: begin
              case (funct3)
                3'h0: branch_taken = (a == b);
                3'h1: branch_taken = (a != b);
                3'h4: branch_taken = ($signed(a) < $signed(b));
                3'h5: branch_taken = ($signed(a) >= $signed(b));
                3'h6: branch_taken = (a < b);
                3'h7: branch_taken = (a >= b);
                default: begin branch_taken = 0; state <= FAULT; end
              endcase
              if (!(funct3 == 2 || funct3 == 3)) begin
                second_pc = branch_taken ? pc + imm_b : pc + 4;
                second_inst = ic_data[second_pc[12:2]];
                second_hit = ic_valid[second_pc[12:2]] &&
                  ic_tag[second_pc[12:2]] == second_pc[31:13];
                rs1_1 = second_inst[19:15]; rs2_1 = second_inst[24:20];
                rd1 = second_inst[11:7];
                lhs1 = rs1_1 == 0 ? 0 : regs[rs1_1];
                rhs1 = rs2_1 == 0 ? 0 : regs[rs2_1];
                result1 = simple_result(second_inst, second_pc, lhs1, rhs1);
                if (second_hit && is_pairable(second_inst)) begin
                  if (rd1 != 0) regs[rd1] <= result1;
                  continue_at(second_pc + 4);
                end else continue_at(second_pc);
              end
            end
            7'h13: begin
              case (funct3)
                3'h0: result = a + imm_i;
                3'h2: result = {31'b0, ($signed(a) < $signed(imm_i))};
                3'h3: result = {31'b0, (a < imm_i)};
                3'h4: result = a ^ imm_i;
                3'h6: result = a | imm_i;
                3'h7: result = a & imm_i;
                3'h1: result = a << instruction[24:20];
                3'h5: result = instruction[30] ? $signed(a) >>> instruction[24:20]
                                                : a >> instruction[24:20];
              endcase
              if (rd != 0) regs[rd] <= result;
              continue_at(pc + 4);
            end
            7'h33: begin
              if (funct7 == 7'h01 && funct3 >= 4 && b != 0 &&
                  !((funct3 == 4 || funct3 == 6) &&
                    a == 32'h8000_0000 && b == 32'hffff_ffff)) begin
                div_dividend <= ((funct3 == 4 || funct3 == 6) && a[31]) ? -a : a;
                div_divisor <= ((funct3 == 4 || funct3 == 6) && b[31]) ? -b : b;
                div_quotient <= 0;
                div_remainder <= 0;
                div_rd <= rd;
                div_is_rem <= funct3[1];
                div_negate_quotient <= (funct3 == 4 || funct3 == 6) && (a[31] ^ b[31]);
                div_negate_remainder <= (funct3 == 4 || funct3 == 6) && a[31];
                state <= DIV_INIT;
              end else begin
              if (funct7 == 7'h01) begin
                case (funct3)
                  3'h0: result = product_uu[31:0];
                  3'h1: result = product_ss[63:32];
                  3'h2: result = product_su[63:32];
                  3'h3: result = product_uu[63:32];
                  3'h4, 3'h5: result = b == 0 ? 32'hffff_ffff : a;
                  3'h6, 3'h7: result = b == 0 ? a : 0;
                endcase
              end else begin
                case (funct3)
                  3'h0: result = instruction[30] ? a - b : a + b;
                  3'h1: result = a << b[4:0];
                  3'h2: result = {31'b0, ($signed(a) < $signed(b))};
                  3'h3: result = {31'b0, (a < b)};
                  3'h4: result = a ^ b;
                  3'h5: result = instruction[30] ? $signed(a) >>> b[4:0] : a >> b[4:0];
                  3'h6: result = a | b;
                  3'h7: result = a & b;
                endcase
              end
              if (rd != 0) regs[rd] <= result;
              continue_at(pc + 4);
              end
            end
            7'h03: begin
              if (!((funct3 == 0) || (funct3 == 1) || (funct3 == 2) ||
                    (funct3 == 4) || (funct3 == 5)) ||
                  ((funct3 == 1 || funct3 == 5) && address[0]) ||
                  (funct3 == 2 && address[1:0] != 0)) state <= FAULT;
              else if (dc_valid[address[14:2]] && dc_tag[address[14:2]] == address[31:15]) begin
                result0 = extend_load(dc_data[address[14:2]], address[1:0], funct3);
                lhs1 = rs1_1 == 0 ? 0 :
                  ((rd != 0 && rs1_1 == rd) ? result0 : regs[rs1_1]);
                rhs1 = rs2_1 == 0 ? 0 :
                  ((rd != 0 && rs2_1 == rd) ? result0 : regs[rs2_1]);
                result1 = simple_result(second_inst, second_pc, lhs1, rhs1);
                case (second_inst[14:12])
                  3'h0: branch1_taken = lhs1 == rhs1;
                  3'h1: branch1_taken = lhs1 != rhs1;
                  3'h4: branch1_taken = $signed(lhs1) < $signed(rhs1);
                  3'h5: branch1_taken = $signed(lhs1) >= $signed(rhs1);
                  3'h6: branch1_taken = lhs1 < rhs1;
                  3'h7: branch1_taken = lhs1 >= rhs1;
                  default: branch1_taken = 0;
                endcase
                if (rd != 0) regs[rd] <= result0;
                if (second_hit && (is_pairable(second_inst) || is_cond_branch(second_inst))) begin
                  if (is_cond_branch(second_inst))
                    continue_at(branch1_taken ? second_pc + branch1_imm : pc + 8);
                  else begin
                    if (rd1 != 0) regs[rd1] <= result1;
                    continue_at(pc + 8);
                  end
                end else continue_at(pc + 4);
              end else begin
                memory_addr <= {address[31:2], 2'b0};
                load_lane <= address[1:0]; load_rd <= rd; load_funct3 <= funct3;
                refill_base <= address & 32'hffff_ffe0;
                refill_sent <= 0; refill_received <= 0;
                pc <= pc + 4; state <= D_REFILL;
              end
            end
            7'h23: begin
              if (!enqueue_store_legal) state <= FAULT;
              else if (store_q_count < 16) begin
                store_q_addr[store_q_tail] <= {address[31:2], 2'b0};
                store_q_data[store_q_tail] <= enqueue_store_data;
                store_q_strobe[store_q_tail] <= enqueue_store_strobe;
                if (ic_valid[address[12:2]] && ic_tag[address[12:2]] == address[31:13])
                  ic_valid[address[12:2]] <= 0;
                if (dc_valid[address[14:2]] && dc_tag[address[14:2]] == address[31:15]) begin
                  if (enqueue_store_strobe[0]) dc_data[address[14:2]][7:0] <= enqueue_store_data[7:0];
                  if (enqueue_store_strobe[1]) dc_data[address[14:2]][15:8] <= enqueue_store_data[15:8];
                  if (enqueue_store_strobe[2]) dc_data[address[14:2]][23:16] <= enqueue_store_data[23:16];
                  if (enqueue_store_strobe[3]) dc_data[address[14:2]][31:24] <= enqueue_store_data[31:24];
                end else if (enqueue_store_strobe == 4'b1111) begin
                  dc_data[address[14:2]] <= enqueue_store_data;
                  dc_tag[address[14:2]] <= address[31:15];
                  dc_valid[address[14:2]] <= 1;
                end
                lhs1 = rs1_1 == 0 ? 0 : regs[rs1_1];
                rhs1 = rs2_1 == 0 ? 0 : regs[rs2_1];
                result1 = simple_result(second_inst, second_pc, lhs1, rhs1);
                case (second_inst[14:12])
                  3'h0: branch1_taken = lhs1 == rhs1;
                  3'h1: branch1_taken = lhs1 != rhs1;
                  3'h4: branch1_taken = $signed(lhs1) < $signed(rhs1);
                  3'h5: branch1_taken = $signed(lhs1) >= $signed(rhs1);
                  3'h6: branch1_taken = lhs1 < rhs1;
                  3'h7: branch1_taken = lhs1 >= rhs1;
                  default: branch1_taken = 0;
                endcase
                if (second_hit && (is_pairable(second_inst) || is_cond_branch(second_inst))) begin
                  if (is_cond_branch(second_inst))
                    continue_at(branch1_taken ? second_pc + branch1_imm : pc + 8);
                  else begin
                    if (rd1 != 0) regs[rd1] <= result1;
                    continue_at(pc + 8);
                  end
                end else continue_at(pc + 4);
              end
            end
            default: state <= FAULT;
          endcase
          end
        end
        LOAD_ADDR: if (arvalid && arready) state <= LOAD_DATA;
        LOAD_DATA: if (rvalid && rready) begin : finish_load
          if (rresp != 0) state <= FAULT;
          else begin
            if (load_rd != 0) regs[load_rd] <= extend_load(rdata, load_lane, load_funct3);
            dc_data[memory_addr[14:2]] <= rdata;
            dc_tag[memory_addr[14:2]] <= memory_addr[31:15];
            dc_valid[memory_addr[14:2]] <= 1;
            continue_at(pc);
          end
        end
        STORE_SEND: state <= FAULT;
        STORE_RESP: state <= FAULT;
        I_REFILL: begin
          if (arvalid && arready) refill_sent <= refill_sent + 1;
          if (rvalid && rready) begin
            if (rresp != 0) state <= FAULT;
            else begin
              ic_data[refill_recv_addr[12:2]] <= rdata;
              ic_tag[refill_recv_addr[12:2]] <= refill_recv_addr[31:13];
              ic_valid[refill_recv_addr[12:2]] <= 1;
              refill_received <= refill_received + 1;
              if (refill_received == 7) state <= FETCH_ADDR;
            end
          end
        end
        D_REFILL: begin
          if (arvalid && arready) refill_sent <= refill_sent + 1;
          if (rvalid && rready) begin
            if (rresp != 0) state <= FAULT;
            else begin
              dc_data[refill_recv_addr[14:2]] <= rdata;
              dc_tag[refill_recv_addr[14:2]] <= refill_recv_addr[31:15];
              dc_valid[refill_recv_addr[14:2]] <= 1;
              refill_received <= refill_received + 1;
              if (refill_received == 7) state <= D_FINISH;
            end
          end
        end
        D_FINISH: begin
          if (load_rd != 0)
            regs[load_rd] <= extend_load(dc_data[memory_addr[14:2]], load_lane, load_funct3);
          continue_at(pc);
        end
        DIV_INIT: begin
          if (div_dividend_bits < div_divisor_bits) begin
            if (div_rd != 0)
              regs[div_rd] <= div_is_rem ?
                (div_negate_remainder ? -div_dividend : div_dividend) : 0;
            continue_at(pc + 4);
          end else begin
            div_divisor <= div_divisor << div_shift;
            div_remainder <= {1'b0, div_dividend};
            div_count <= div_shift + 1;
            state <= DIV_RUN;
          end
        end
        DIV_RUN: begin
          div_divisor <= div_divisor >> 1;
          div_quotient <= div_quotient_next;
          div_remainder <= div_remainder_next;
          div_count <= div_count - 1;
          if (div_count == 1) begin
            if (div_rd != 0) regs[div_rd] <= div_result;
            continue_at(pc + 4);
          end
        end
        default: state <= FAULT;
      endcase
      case ({write_finish, write_response})
        2'b10: writes_outstanding <= writes_outstanding + 1;
        2'b01: writes_outstanding <= writes_outstanding - 1;
        default: writes_outstanding <= writes_outstanding;
      endcase
      if (awvalid && awready) aw_sent <= 1;
      if (wvalid && wready) w_sent <= 1;
      if (write_finish) begin
        aw_sent <= 0; w_sent <= 0; store_q_head <= store_q_head + 1;
      end
      if (store_enqueue) store_q_tail <= store_q_tail + 1;
      case ({store_enqueue, write_finish})
        2'b10: store_q_count <= store_q_count + 1;
        2'b01: store_q_count <= store_q_count - 1;
        default: store_q_count <= store_q_count;
      endcase
      if (write_response && bresp != 0) state <= FAULT;
    end
  end
endmodule
