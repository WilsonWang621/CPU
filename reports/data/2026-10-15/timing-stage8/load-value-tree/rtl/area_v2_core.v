// Frozen stage8 experiment.
module alu (
  input wire [5:0] op,
  input wire [31:0] a,
  input wire [31:0] b,
  input wire [31:0] pc,
  input wire [31:0] imm,
  output reg [31:0] result
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire subtract=op==OP_SUB || op==OP_SLT || op==OP_SLTU;
  wire [31:0] arithmetic_value,pc_value;
  wire no_borrow;
  v2_prefix_adder #(.WIDTH(32)) add_operands (
    .a(a),.b(b^{32{subtract}}),.carry_in(subtract),.sum(arithmetic_value),.carry_out(no_borrow));
  v2_prefix_adder #(.WIDTH(32)) add_pc (
    .a(pc),.b(imm),.carry_in(1'b0),.sum(pc_value),.carry_out());
  always @* begin
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

module branch_unit (
  input wire [5:0] op,
  input wire [31:0] a,
  input wire [31:0] b,
  input wire [31:0] pc,
  input wire [31:0] imm,
  output reg [31:0] result,
  output reg [31:0] next_pc,
  output reg  taken,
  output reg  misaligned
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
reg [31:0] target;
  always @* begin
    result = pc + 32'd4;
    target = pc + imm;
    case (op)
      OP_JAL: taken = 1'b1;
      OP_JALR: begin
        taken = 1'b1;

        target = (a + imm) & 32'hfffffffe;
      end
      OP_BEQ:  taken = a == b;
      OP_BNE:  taken = a != b;
      OP_BLT:  taken = $signed(a) < $signed(b);
      OP_BGE:  taken = $signed(a) >= $signed(b);
      OP_BLTU: taken = a < b;
      OP_BGEU: taken = a >= b;
      default: taken = 1'b0;
    endcase
    next_pc = taken ? target : result;
    misaligned = taken && (target[1:0] != 2'b00);
  end
endmodule

module cpu_top #(
  parameter integer ROB_ENTRIES=32, IQ_ENTRIES=4, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CHECKPOINTS=3, RENAME_WIDTH=2, COMMIT_WIDTH=2, INTEGER_PORTS=2,
  parameter integer ICACHE_BYTES=1024, DCACHE_BYTES=2048, DCACHE_LINE_BYTES=64, D_MSHRS=4,
  parameter integer FETCH_QUEUE_ENTRIES=8, BHT_ENTRIES=256, BTB_ENTRIES=32, LOCAL_HISTORY_BITS=1, HISTORY_ENTRIES=64,
  parameter integer MAX_MEM_OUTSTANDING=64, RAM_BYTES=268435456,
  parameter integer CONTROL_TREE=0, ROB_WRITE_TREE=0, CACHE_TREE=0, COMMIT_TREE=0, REGISTER_REDIRECT=0
) (
  input wire  clk,
  input wire  rst,
  output wire  mem_req_valid,
  output wire  mem_req_write,
  output wire [31:0] mem_req_addr,
  output wire [31:0] mem_req_wdata,
  output wire [3:0] mem_req_wstrb,
  input wire  mem_req_ready,
  input wire  mem_rsp_valid,
  input wire [31:0] mem_rsp_rdata,
  input wire  mem_rsp_error,
  output wire  mem_rsp_ready,
  output wire  halted,
  output wire  faulted,
  output reg [31:0] fault_pc,
  output reg [31:0] fault_inst,
  output reg  fault_inst_valid,
  output reg [3:0] fault_cause,
  output reg [31:0] fault_addr,
  output reg [3:0] retire_valid,
  output reg [127:0] retire_pc,
  output reg [127:0] retire_inst,
  output reg [19:0] retire_rd,
  output reg [127:0] retire_value,
  output reg [3:0] retire_store,
  output reg [127:0] retire_addr,
  output reg [127:0] retire_wdata,
  output reg [15:0] retire_wstrb,
  output reg [63:0] cycle_count,
  output reg [63:0] retired_count,
  output reg [63:0] branch_miss_count,
  output wire [63:0] load_replay_count,
  output wire [63:0] icache_miss_count,
  output wire [63:0] dcache_miss_count
);
genvar address_lane,bank,bit_id,cp,d,first,group,l,lane,p,port_id,q,r,row,s,w;
function automatic [RW+1-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction

function automatic [RW-1:0] narrow_1;
  input [63:0] value;
  begin narrow_1=value; end
endfunction

function automatic [8-1:0] narrow_2;
  input [63:0] value;
  begin narrow_2=value; end
endfunction

function automatic [QW-1:0] narrow_3;
  input [63:0] value;
  begin narrow_3=value; end
endfunction

function automatic [ST-1:0] narrow_4;
  input [63:0] value;
  begin narrow_4=value; end
endfunction

function automatic [CPW-1:0] narrow_5;
  input [63:0] value;
  begin narrow_5=value; end
endfunction

function automatic [LT-1:0] narrow_6;
  input [63:0] value;
  begin narrow_6=value; end
endfunction

function automatic signed [31:0] narrow_7;
  input [63:0] value;
  begin narrow_7=value; end
endfunction

function automatic [2-1:0] narrow_8;
  input [63:0] value;
  begin narrow_8=value; end
endfunction

function automatic [1-1:0] narrow_9;
  input [63:0] value;
  begin narrow_9=value; end
endfunction

function automatic [ST+1-1:0] narrow_10;
  input [63:0] value;
  begin narrow_10=value; end
endfunction

function automatic [64-1:0] narrow_11;
  input [63:0] value;
  begin narrow_11=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer HB=LOCAL_HISTORY_BITS>0 ? LOCAL_HISTORY_BITS:1;
localparam integer RW=$clog2(ROB_ENTRIES), QW=$clog2(IQ_ENTRIES);
localparam integer LT=$clog2(LOAD_SLOTS), ST=$clog2(STORE_SLOTS), CPW=$clog2(CHECKPOINTS);
localparam integer RETIRE_META_BITS=RETIRE_META_T_WIDTH;
localparam integer ISSUE_BITS=ISSUE_T_WIDTH;
localparam RUN=0, DRAIN=1, DONE=2, FAULT=3;
localparam integer WAKE_BITS=3+3*RW;
localparam integer REC_BITS=2*RW+3;
localparam integer ROB_REC_GROUPS=(ROB_ENTRIES+3)/4;
localparam integer STORE_REC_GROUPS=(STORE_SLOTS+3)/4;
localparam integer LOAD_REC_GROUPS=(LOAD_SLOTS+3)/4;
localparam integer REC_LEAVES=ROB_REC_GROUPS+3+STORE_REC_GROUPS+LOAD_REC_GROUPS+1;
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
localparam integer ROB_T_WDATA_LSB=0, ROB_T_WDATA_WIDTH=32;
localparam integer ROB_T_ADDRESS_LSB=ROB_T_WDATA_LSB+ROB_T_WDATA_WIDTH, ROB_T_ADDRESS_WIDTH=32;
localparam integer ROB_T_FAULT_ADDRESS_LSB=ROB_T_ADDRESS_LSB+ROB_T_ADDRESS_WIDTH, ROB_T_FAULT_ADDRESS_WIDTH=32;
localparam integer ROB_T_INST_LSB=ROB_T_FAULT_ADDRESS_LSB+ROB_T_FAULT_ADDRESS_WIDTH, ROB_T_INST_WIDTH=32;
localparam integer ROB_T_PC_LSB=ROB_T_INST_LSB+ROB_T_INST_WIDTH, ROB_T_PC_WIDTH=32;
localparam integer ROB_T_MASK_LSB=ROB_T_PC_LSB+ROB_T_PC_WIDTH, ROB_T_MASK_WIDTH=4;
localparam integer ROB_T_STORE_SLOT_LSB=ROB_T_MASK_LSB+ROB_T_MASK_WIDTH, ROB_T_STORE_SLOT_WIDTH=((ST-1)-(0)+1);
localparam integer ROB_T_FAULT_LSB=ROB_T_STORE_SLOT_LSB+ROB_T_STORE_SLOT_WIDTH, ROB_T_FAULT_WIDTH=4;
localparam integer ROB_T_RD_LSB=ROB_T_FAULT_LSB+ROB_T_FAULT_WIDTH, ROB_T_RD_WIDTH=5;
localparam integer ROB_T_EXITING_LSB=ROB_T_RD_LSB+ROB_T_RD_WIDTH, ROB_T_EXITING_WIDTH=1;
localparam integer ROB_T_STORE_LSB=ROB_T_EXITING_LSB+ROB_T_EXITING_WIDTH, ROB_T_STORE_WIDTH=1;
localparam integer ROB_T_IV_LSB=ROB_T_STORE_LSB+ROB_T_STORE_WIDTH, ROB_T_IV_WIDTH=1;
localparam integer ROB_T_DONE_LSB=ROB_T_IV_LSB+ROB_T_IV_WIDTH, ROB_T_DONE_WIDTH=1;
localparam integer ROB_T_VALID_LSB=ROB_T_DONE_LSB+ROB_T_DONE_WIDTH, ROB_T_VALID_WIDTH=1;
localparam integer ROB_T_WIDTH=ROB_T_VALID_LSB+ROB_T_VALID_WIDTH;
localparam integer RETIRE_META_T_STORE_SLOT_LSB=0, RETIRE_META_T_STORE_SLOT_WIDTH=((ST-1)-(0)+1);
localparam integer RETIRE_META_T_RD_LSB=RETIRE_META_T_STORE_SLOT_LSB+RETIRE_META_T_STORE_SLOT_WIDTH, RETIRE_META_T_RD_WIDTH=5;
localparam integer RETIRE_META_T_FAULT_LSB=RETIRE_META_T_RD_LSB+RETIRE_META_T_RD_WIDTH, RETIRE_META_T_FAULT_WIDTH=4;
localparam integer RETIRE_META_T_STORE_LSB=RETIRE_META_T_FAULT_LSB+RETIRE_META_T_FAULT_WIDTH, RETIRE_META_T_STORE_WIDTH=1;
localparam integer RETIRE_META_T_EXITING_LSB=RETIRE_META_T_STORE_LSB+RETIRE_META_T_STORE_WIDTH, RETIRE_META_T_EXITING_WIDTH=1;
localparam integer RETIRE_META_T_DONE_LSB=RETIRE_META_T_EXITING_LSB+RETIRE_META_T_EXITING_WIDTH, RETIRE_META_T_DONE_WIDTH=1;
localparam integer RETIRE_META_T_WIDTH=RETIRE_META_T_DONE_LSB+RETIRE_META_T_DONE_WIDTH;
localparam integer ISSUE_T_IMM_LSB=0, ISSUE_T_IMM_WIDTH=32;
localparam integer ISSUE_T_B_LSB=ISSUE_T_IMM_LSB+ISSUE_T_IMM_WIDTH, ISSUE_T_B_WIDTH=32;
localparam integer ISSUE_T_A_LSB=ISSUE_T_B_LSB+ISSUE_T_B_WIDTH, ISSUE_T_A_WIDTH=32;
localparam integer ISSUE_T_CHECKPOINT_LSB=ISSUE_T_A_LSB+ISSUE_T_A_WIDTH, ISSUE_T_CHECKPOINT_WIDTH=((CPW-1)-(0)+1);
localparam integer ISSUE_T_SIZE_LSB=ISSUE_T_CHECKPOINT_LSB+ISSUE_T_CHECKPOINT_WIDTH, ISSUE_T_SIZE_WIDTH=2;
localparam integer ISSUE_T_HISTORY_LSB=ISSUE_T_SIZE_LSB+ISSUE_T_SIZE_WIDTH, ISSUE_T_HISTORY_WIDTH=((HB-1)-(0)+1);
localparam integer ISSUE_T_PREDICTION_LSB=ISSUE_T_HISTORY_LSB+ISSUE_T_HISTORY_WIDTH, ISSUE_T_PREDICTION_WIDTH=30;
localparam integer ISSUE_T_PC_LSB=ISSUE_T_PREDICTION_LSB+ISSUE_T_PREDICTION_WIDTH, ISSUE_T_PC_WIDTH=30;
localparam integer ISSUE_T_OP_LSB=ISSUE_T_PC_LSB+ISSUE_T_PC_WIDTH, ISSUE_T_OP_WIDTH=6;
localparam integer ISSUE_T_SOURCE_B_LSB=ISSUE_T_OP_LSB+ISSUE_T_OP_WIDTH, ISSUE_T_SOURCE_B_WIDTH=RW;
localparam integer ISSUE_T_SOURCE_A_LSB=ISSUE_T_SOURCE_B_LSB+ISSUE_T_SOURCE_B_WIDTH, ISSUE_T_SOURCE_A_WIDTH=RW;
localparam integer ISSUE_T_RID_LSB=ISSUE_T_SOURCE_A_LSB+ISSUE_T_SOURCE_A_WIDTH, ISSUE_T_RID_WIDTH=RW;
localparam integer ISSUE_T_GENERATION_LSB=ISSUE_T_RID_LSB+ISSUE_T_RID_WIDTH, ISSUE_T_GENERATION_WIDTH=1;
localparam integer ISSUE_T_SIGN_EXTEND_LSB=ISSUE_T_GENERATION_LSB+ISSUE_T_GENERATION_WIDTH, ISSUE_T_SIGN_EXTEND_WIDTH=1;
localparam integer ISSUE_T_USE_IMM_LSB=ISSUE_T_SIGN_EXTEND_LSB+ISSUE_T_SIGN_EXTEND_WIDTH, ISSUE_T_USE_IMM_WIDTH=1;
localparam integer ISSUE_T_READY_B_LSB=ISSUE_T_USE_IMM_LSB+ISSUE_T_USE_IMM_WIDTH, ISSUE_T_READY_B_WIDTH=1;
localparam integer ISSUE_T_READY_A_LSB=ISSUE_T_READY_B_LSB+ISSUE_T_READY_B_WIDTH, ISSUE_T_READY_A_WIDTH=1;
localparam integer ISSUE_T_VALID_LSB=ISSUE_T_READY_A_LSB+ISSUE_T_READY_A_WIDTH, ISSUE_T_VALID_WIDTH=1;
localparam integer ISSUE_T_WIDTH=ISSUE_T_VALID_LSB+ISSUE_T_VALID_WIDTH;
localparam integer STORE_T_INST_LSB=0, STORE_T_INST_WIDTH=32;
localparam integer STORE_T_PC_LSB=STORE_T_INST_LSB+STORE_T_INST_WIDTH, STORE_T_PC_WIDTH=32;
localparam integer STORE_T_DATA_LSB=STORE_T_PC_LSB+STORE_T_PC_WIDTH, STORE_T_DATA_WIDTH=32;
localparam integer STORE_T_ADDRESS_LSB=STORE_T_DATA_LSB+STORE_T_DATA_WIDTH, STORE_T_ADDRESS_WIDTH=32;
localparam integer STORE_T_MASK_LSB=STORE_T_ADDRESS_LSB+STORE_T_ADDRESS_WIDTH, STORE_T_MASK_WIDTH=4;
localparam integer STORE_T_RID_LSB=STORE_T_MASK_LSB+STORE_T_MASK_WIDTH, STORE_T_RID_WIDTH=RW;
localparam integer STORE_T_DONE_LSB=STORE_T_RID_LSB+STORE_T_RID_WIDTH, STORE_T_DONE_WIDTH=1;
localparam integer STORE_T_ISSUED_LSB=STORE_T_DONE_LSB+STORE_T_DONE_WIDTH, STORE_T_ISSUED_WIDTH=1;
localparam integer STORE_T_COMMITTED_LSB=STORE_T_ISSUED_LSB+STORE_T_ISSUED_WIDTH, STORE_T_COMMITTED_WIDTH=1;
localparam integer STORE_T_VALID_LSB=STORE_T_COMMITTED_LSB+STORE_T_COMMITTED_WIDTH, STORE_T_VALID_WIDTH=1;
localparam integer STORE_T_WIDTH=STORE_T_VALID_LSB+STORE_T_VALID_WIDTH;
localparam integer LOAD_T_ADDRESS_LSB=0, LOAD_T_ADDRESS_WIDTH=32;
localparam integer LOAD_T_SIZE_LSB=LOAD_T_ADDRESS_LSB+LOAD_T_ADDRESS_WIDTH, LOAD_T_SIZE_WIDTH=2;
localparam integer LOAD_T_RID_LSB=LOAD_T_SIZE_LSB+LOAD_T_SIZE_WIDTH, LOAD_T_RID_WIDTH=RW;
localparam integer LOAD_T_SIGN_EXTEND_LSB=LOAD_T_RID_LSB+LOAD_T_RID_WIDTH, LOAD_T_SIGN_EXTEND_WIDTH=1;
localparam integer LOAD_T_CANCELED_LSB=LOAD_T_SIGN_EXTEND_LSB+LOAD_T_SIGN_EXTEND_WIDTH, LOAD_T_CANCELED_WIDTH=1;
localparam integer LOAD_T_VALID_LSB=LOAD_T_CANCELED_LSB+LOAD_T_CANCELED_WIDTH, LOAD_T_VALID_WIDTH=1;
localparam integer LOAD_T_WIDTH=LOAD_T_VALID_LSB+LOAD_T_VALID_WIDTH;
wire [RETIRE_META_T_WIDTH-1:0] retirement_meta [0:(2)-1];
  wire [ROB_ENTRIES*RETIRE_META_BITS-1:0] retirement_words;
wire [31:0] retirement_value [0:(2)-1];
reg [1:0] state;
reg [ROB_T_WIDTH-1:0] rob [0:(ROB_ENTRIES)-1];
reg [31:0] values [0:(ROB_ENTRIES)-1];
  wire [31:0] architectural [0:(32)-1];
  wire [ROB_ENTRIES*32-1:0] result_words;
  wire [ROB_ENTRIES*6-1:0] result_status_words;
  wire [32*32-1:0] architectural_words;
wire [31:0] source_result [0:(4)-1];
  wire [31:0] source_architectural [0:(4)-1];
wire [5:0] source_status [0:(4)-1];
reg [ISSUE_T_WIDTH-1:0] queue [0:(3)*(IQ_ENTRIES)-1];
  reg [ISSUE_T_WIDTH-1:0] dispatch_payload [0:(2)-1];
  wire [31:0] dispatch_address [0:1];
  for(address_lane=0;address_lane<2;address_lane=address_lane+1) begin: prepare_dispatch_address
    v2_prefix_adder #(.WIDTH(32)) add (
      .a(dispatch_payload[address_lane][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),.b(dispatch_payload[address_lane][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]),
      .carry_in(1'b0),.sum(dispatch_address[address_lane]),.carry_out());
  end
reg [STORE_T_WIDTH-1:0] stores [0:(STORE_SLOTS)-1];
reg [LOAD_T_WIDTH-1:0] loads [0:(LOAD_SLOTS)-1];
reg [RW-1:0] head;
  reg [RW-1:0] tail;
reg  tail_generation;
  wire [RW:0] allocation_end={tail_generation,tail}+narrow_0(dispatch_count);
  wire [2*(RW+1)-1:0] dispatch_order;
reg [RW:0] rob_count;
reg [ST-1:0] store_head;
  reg [ST-1:0] store_tail;
reg [ST:0] store_count;
reg [CHECKPOINTS-1:0] checkpoint_valid;
reg [RW-1:0] checkpoint_owner [0:(CHECKPOINTS)-1];
reg [CPW-1:0] free_checkpoint;
reg  checkpoint_available;
wire [1:0] fetch_valid;
  wire [1:0] fetch_iv;
  reg [1:0] pop_count;
wire [63:0] fetch_pc;
  wire [63:0] fetch_inst;
  wire [63:0] fetch_prediction;
wire [7:0] fetch_fault;
wire [2*HB-1:0] fetch_history;
wire [DECODED_T_WIDTH-1:0] decoded [0:(2)-1];
wire  frontend_idle;
  wire  stop_frontend;
  wire  redirect;
  wire  flush_all;
  wire  exit_head;
  wire  fault_head;
wire [31:0] redirect_pc;
wire [RW-1:0] redirect_rid;
wire [CPW-1:0] redirect_checkpoint;
wire  train_valid;
  wire  train_taken;
wire [5:0] train_op;
wire [31:0] train_pc;
  wire [31:0] train_target;
wire [1:0] client_req_valid;
  wire [1:0] client_req_ready;
  wire [1:0] client_req_write;
  wire [1:0] client_rsp_valid;
  wire [1:0] client_rsp_ready;
  wire [1:0] client_rsp_error;
wire [63:0] client_req_addr;
  wire [63:0] client_req_data;
  wire [63:0] client_rsp_data;
wire [7:0] client_req_mask;
wire  bus_req_valid;
  wire  bus_req_ready;
  wire  bus_req_write;
  wire  bus_rsp_ready;
  wire  controller_idle;
wire [31:0] bus_req_addr;
  wire [31:0] bus_req_data;
wire [3:0] bus_req_mask;
wire  cache_idle;
  wire  cache_load_valid;
  wire  cache_load_ready;
  wire  cache_load_hit;
wire [31:0] cache_load_address;
  wire [31:0] cache_load_data;
wire [LT-1:0] cache_load_tag;
  wire [LT-1:0] cache_result_tag;
wire  cache_result_valid;
  wire  cache_result_error;
wire [31:0] cache_result_data;
wire  cache_store_valid;
  wire  cache_store_ready;
  wire  cache_store_done;
  wire  cache_store_error;
wire [ST-1:0] cache_store_tag;
  wire [ST-1:0] cache_store_done_tag;
wire [31:0] cache_store_address;
  wire [31:0] cache_store_data;
wire [3:0] cache_store_mask;
reg [1:0] rename_valid;
  reg [1:0] commit_valid;
reg [9:0] rename_rd;
  reg [9:0] commit_rd;
wire [2*RW-1:0] rename_slot;
  wire [2*RW-1:0] commit_slot;
wire [19:0] source_register;
wire [3:0] source_pending;
wire [4*RW-1:0] source_slot;
reg  save_checkpoint;
  reg  save_after_lane;
reg [1:0] dispatch_valid;
  reg [1:0] dispatch_prepare;
  reg [1:0] rename_prepare;
reg [1:0] dispatch_bank [0:(2)-1];
reg [QW-1:0] dispatch_index [0:(2)-1];
reg [RW-1:0] dispatch_rid [0:(2)-1];
  wire [RW-1:0] commit_rid [0:(2)-1];
reg [1:0] dispatch_count;
  reg [1:0] commit_count;
reg [2:0] used_bank;
reg [2:0] free_queue_valid;
reg [QW-1:0] free_queue [0:(3)-1];
  wire [QW-1:0] selected [0:(3)-1];
reg [QW:0] occupancy [0:(3)-1];
wire [2:0] select_valid;
  reg [2:0] issue_fire;
wire [2:0] selected_valid;
wire [IQ_ENTRIES-1:0] select_ready [0:(3)-1];
wire [IQ_ENTRIES*(RW+1)-1:0] select_owner [0:(3)-1];
wire [STORE_SLOTS-1:0] store_forward_candidates;
  wire [STORE_SLOTS-1:0] store_send_candidates;
wire [STORE_SLOTS*ST-1:0] store_owners;
wire [ISSUE_T_WIDTH-1:0] executing [0:(3)-1];
reg  steer;
reg  load_available;
reg [LT-1:0] free_load;
reg [2:0] wb_valid;
reg [RW-1:0] wb_rid [0:(3)-1];
  wire [2:0] wb_good;
  wire [3*RW-1:0] wb_slots;
  wire [95:0] wb_values;
  wire [6*32-1:0] load_value_copies;
  v2_distribution #(.WIDTH(32),.LEAVES(6)) distribute_load_result (
    .data_in(wb_value[2]),.data_out(load_value_copies));

  wire [6*WAKE_BITS-1:0] wake_copies;
  v2_distribution #(.WIDTH(WAKE_BITS),.LEAVES(6)) distribute_wakeup (
    .data_in({wb_good,wb_slots}),.data_out(wake_copies));

  for(w=0;w<3;w=w+1) begin: writeback_ports

    assign wb_good[w]=wb_valid[w] && rob[wb_rid[w]][ROB_T_RD_LSB+:ROB_T_RD_WIDTH]!=0 &&
      (w!=0 ? wb_fault[w]==0 :
       (mdu_result_valid || is_alu(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]) ||
        (executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_JAL && executing[0][ISSUE_T_IMM_LSB+(1):ISSUE_T_IMM_LSB+(0)]==0) ||
        (executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_JALR &&
         !(executing[0][ISSUE_T_A_LSB+(1)]^executing[0][ISSUE_T_IMM_LSB+(1)]^(executing[0][ISSUE_T_A_LSB+(0)]&executing[0][ISSUE_T_IMM_LSB+(0)])))));
    assign wb_slots[w*RW+:RW]=wb_rid[w];
    assign wb_values[w*32+:32]=wb_value[w];
  end
reg [31:0] wb_value [0:(3)-1];
  reg [31:0] wb_address [0:(3)-1];
reg [3:0] wb_fault [0:(3)-1];
wire [31:0] alu_result [0:(2)-1];
  wire [31:0] branch_value;
  wire [31:0] branch_next;
wire  branch_taken;
  wire  branch_bad;
  wire  branch_fire;
  wire  branch_capture;
reg  branch_pending;
  reg  branch_bad_q;
  reg  branch_taken_q;
  reg  branch_recovery_q;
reg [31:0] branch_next_q;
  reg [31:0] branch_pc_q;
reg [29:0] branch_prediction_q;
reg [HB-1:0] branch_history_q;
reg [RW-1:0] branch_rid_q;
reg  branch_generation_q;
reg [CPW-1:0] branch_checkpoint_q;
reg [5:0] branch_op_q;
wire [31:0] execute_pc [0:(2)-1];
  wire [31:0] execute_b [0:(2)-1];
wire  mdu_valid;
  wire  mdu_ready;
  wire  mdu_mul_ready;
  wire  mdu_div_ready;
  wire  mdu_result_valid;
  wire  mdu_result_ready;
wire [31:0] mdu_result;
wire [7:0] mdu_result_tag;
reg [255:0] mdu_kill;
wire  memory_allowed;
  wire  memory_complete;
  wire  store_allocate;
  wire  load_allocate;
wire [31:0] memory_address;
  wire [31:0] memory_data;
  wire [31:0] load_word;
  wire [31:0] load_result;
reg [31:0] prepared_address [0:(IQ_ENTRIES)-1];
  wire [IQ_ENTRIES*32-1:0] prepared_address_words;
  wire [IQ_ENTRIES-1:0] memory_address_grant;
wire [3:0] memory_mask;
  reg [3:0] memory_fault;
wire  memory_exit;
  wire  forward_match;
  reg  forward_full;
wire [ST-1:0] forward_slot;
  wire [STORE_SLOTS-1:0] forward_grant;
  wire [STORE_SLOTS*36-1:0] forwarding_words;
  wire [35:0] forwarding_payload;
  wire [STORE_SLOTS-1:0] forwarding_full_grants;
  for(s=0;s<STORE_SLOTS;s=s+1) begin: forwarding_coverage
    assign forwarding_full_grants[s]=forward_grant[s] &&
      (stores[s][STORE_T_MASK_LSB+:STORE_T_MASK_WIDTH] & memory_mask)==memory_mask;
  end

  for(s=0;s<STORE_SLOTS;s=s+1) begin: forward_payloads
    assign forwarding_words[s*36+:36]={stores[s][STORE_T_MASK_LSB+:STORE_T_MASK_WIDTH],stores[s][STORE_T_DATA_LSB+:STORE_T_DATA_WIDTH]};
  end
  v2_grant_read #(.ENTRIES(STORE_SLOTS),.WORD_BITS(36)) read_forward_payload (
    .grant(forward_grant),.words(forwarding_words),.value(forwarding_payload));
wire  store_pop;
  wire  store_send_valid;
wire [ST-1:0] store_send_slot;
reg [ST:0] squashed_stores;
wire  exit_send;
  wire  exit_accept;

  wire [REC_BITS-1:0] recovery_control={flush_all,redirect,(redirect_rid<head),redirect_rid,head};
  wire [REC_BITS*REC_LEAVES-1:0] recovery_copies;
  generate
    if(CONTROL_TREE) begin: distributed_recovery
      v2_distribution #(.WIDTH(REC_BITS),.LEAVES(REC_LEAVES)) tree (
        .data_in(recovery_control),.data_out(recovery_copies));
    end else begin: direct_recovery
      assign recovery_copies={REC_LEAVES{recovery_control}};
    end
  endgenerate
  function automatic recovery_younger(input [RW-1:0] rid,input [REC_BITS-1:0] controls);
    recovery_younger = controls[2*RW+1] &&
      ((rid<controls[0+:RW])==controls[2*RW] ? rid>controls[RW+:RW]:rid<controls[0+:RW]);
  endfunction

  function automatic [31:0] extend_load(input [31:0] word_value,
      input [1:0] offset,
  input [1:0] size,input  sign_extend);
reg [31:0] shifted;
    begin
      shifted=word_value>>(8*offset);
      case(size)
        0:extend_load = {{24{sign_extend && shifted[7]}},shifted[7:0]};
        1:extend_load = {{16{sign_extend && shifted[15]}},shifted[15:0]};
        default:extend_load = shifted;
      endcase
    end
  endfunction
  assign halted=state==DONE;
  assign faulted=state==FAULT;
  assign load_replay_count=0;
  assign exit_head=state==RUN && rob_count!=0 && retirement_meta[0][RETIRE_META_T_DONE_LSB+:RETIRE_META_T_DONE_WIDTH] && retirement_meta[0][RETIRE_META_T_EXITING_LSB+:RETIRE_META_T_EXITING_WIDTH] && retirement_meta[0][RETIRE_META_T_FAULT_LSB+:RETIRE_META_T_FAULT_WIDTH]==0;
  assign fault_head=state==RUN && rob_count!=0 && retirement_meta[0][RETIRE_META_T_DONE_LSB+:RETIRE_META_T_DONE_WIDTH] && retirement_meta[0][RETIRE_META_T_FAULT_LSB+:RETIRE_META_T_FAULT_WIDTH]!=0;

  assign flush_all=state!=RUN;
  assign stop_frontend=flush_all;
  assign exit_send=state==DRAIN && store_count==0 && cache_idle && frontend_idle && controller_idle;
  assign exit_accept=exit_send && mem_req_ready;
  assign mem_req_valid=state!=DONE && (exit_send || bus_req_valid);
  assign mem_req_write=exit_send || bus_req_write;
  assign mem_req_addr=exit_send ? 32'h80000000:bus_req_addr;
  assign mem_req_wdata=exit_send ? retirement_value[0]:bus_req_data;
  assign mem_req_wstrb=exit_send ? 4'hf:bus_req_mask;
  assign bus_req_ready=mem_req_ready && !exit_send && state!=DONE;
  assign mem_rsp_ready=bus_rsp_ready;
  for(row=0;row<ROB_ENTRIES;row=row+1) begin: result_read_words
    assign retirement_words[row*RETIRE_META_BITS+:RETIRE_META_BITS]=
      {rob[row][ROB_T_DONE_LSB+:ROB_T_DONE_WIDTH],rob[row][ROB_T_EXITING_LSB+:ROB_T_EXITING_WIDTH],rob[row][ROB_T_STORE_LSB+:ROB_T_STORE_WIDTH],rob[row][ROB_T_FAULT_LSB+:ROB_T_FAULT_WIDTH],rob[row][ROB_T_RD_LSB+:ROB_T_RD_WIDTH],rob[row][ROB_T_STORE_SLOT_LSB+:ROB_T_STORE_SLOT_WIDTH]};
    assign result_words[row*32+:32]=values[row];
    assign result_status_words[row*6+:6]={rob[row][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH],rob[row][ROB_T_DONE_LSB+:ROB_T_DONE_WIDTH],rob[row][ROB_T_FAULT_LSB+:ROB_T_FAULT_WIDTH]};
  end
  for(lane=0;lane<2;lane=lane+1) begin: retirement_reads
    assign commit_rid[lane]=head+narrow_1(lane);
    wire [RETIRE_META_BITS-1:0] meta_word;
    assign retirement_meta[lane]=meta_word;
    v2_retire_read #(.ENTRIES(ROB_ENTRIES),.WORD_BITS(RETIRE_META_BITS),.LANE(lane),.CONTROL_TREE(COMMIT_TREE)) read_metadata (.clk(clk),.rst(rst),.advance(commit_count),.words(retirement_words),.value(meta_word));
    v2_retire_read #(.ENTRIES(ROB_ENTRIES),.LANE(lane),.CONTROL_TREE(COMMIT_TREE)) read_value (.clk(clk),.rst(rst),.advance(commit_count),.words(result_words),.value(retirement_value[lane]));
  end
  for(row=0;row<32;row=row+1) begin: architectural_read_words
    assign architectural_words[row*32+:32]=architectural[row];
  end
  for(port_id=0;port_id<4;port_id=port_id+1) begin: operand_reads
    v2_read #(.ENTRIES(ROB_ENTRIES)) read_result (
      .index(source_slot[port_id*RW+:RW]),.words(result_words),.value(source_result[port_id]));
    v2_read #(.ENTRIES(ROB_ENTRIES),.WORD_BITS(6)) read_status (
      .index(source_slot[port_id*RW+:RW]),.words(result_status_words),.value(source_status[port_id]));
    v2_read #(.ENTRIES(32)) read_architectural (
      .index(source_register[port_id*5+:5]),.words(architectural_words),.value(source_architectural[port_id]));
  end
  v2_frontend #(.CACHE_BYTES(ICACHE_BYTES),.QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES),
    .BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(BTB_ENTRIES),.LOCAL_HISTORY_BITS(LOCAL_HISTORY_BITS),
    .HISTORY_ENTRIES(HISTORY_ENTRIES),.RAM_BYTES(RAM_BYTES),.CACHE_TREE(CACHE_TREE)) frontend (.clk(clk),.rst(rst),.stop(stop_frontend),.redirect(redirect),.redirect_pc(redirect_pc),.pop_count(pop_count),
    .packet_valid(fetch_valid),.packet_pc(fetch_pc),.packet_inst(fetch_inst),.packet_prediction(fetch_prediction),
    .packet_fault(fetch_fault),.packet_inst_valid(fetch_iv),.packet_history(fetch_history),.train_history(branch_history_q),.train_valid(train_valid),.train_taken(train_taken),.train_op(train_op),.train_pc(train_pc),.train_target(train_target),
    .mem_req_valid(client_req_valid[0]),.mem_req_ready(client_req_ready[0]),.mem_req_addr(client_req_addr[31:0]),
    .mem_rsp_valid(client_rsp_valid[0]),.mem_rsp_ready(client_rsp_ready[0]),.mem_rsp_data(client_rsp_data[31:0]),
    .mem_rsp_error(client_rsp_error[0]),.idle(frontend_idle),.miss_count(icache_miss_count));
  assign client_req_write[0]=0;assign client_req_data[31:0]=0;assign client_req_mask[3:0]=0;
  v2_dcache #(.CACHE_BYTES(DCACHE_BYTES),.LINE_BYTES(DCACHE_LINE_BYTES),.MSHRS(D_MSHRS),.LOAD_SLOTS(LOAD_SLOTS),.STORE_SLOTS(STORE_SLOTS),
    .CREDITS(MAX_MEM_OUTSTANDING),.RAM_BYTES(RAM_BYTES),.CACHE_TREE(CACHE_TREE)) dcache (.clk(clk),.rst(rst),.load_valid(cache_load_valid),.load_address(cache_load_address),.load_tag(cache_load_tag),
    .load_ready(cache_load_ready),.load_hit(cache_load_hit),.load_data(cache_load_data),
    .result_valid(cache_result_valid),.result_ready(1'b1),.result_tag(cache_result_tag),
    .result_data(cache_result_data),.result_error(cache_result_error),
    .store_valid(cache_store_valid),.store_ready(cache_store_ready),.store_address(cache_store_address),
    .store_data(cache_store_data),.store_mask(cache_store_mask),.store_tag(cache_store_tag),
    .store_done(cache_store_done),.store_done_tag(cache_store_done_tag),.store_error(cache_store_error),
    .mem_req_valid(client_req_valid[1]),.mem_req_ready(client_req_ready[1]),.mem_req_write(client_req_write[1]),
    .mem_req_addr(client_req_addr[63:32]),.mem_req_data(client_req_data[63:32]),.mem_req_mask(client_req_mask[7:4]),
    .mem_rsp_valid(client_rsp_valid[1]),.mem_rsp_ready(client_rsp_ready[1]),.mem_rsp_data(client_rsp_data[63:32]),
    .mem_rsp_error(client_rsp_error[1]),.idle(cache_idle),.miss_count(dcache_miss_count));
  memory_controller #(.MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING)) memory_bus (.clk(clk),.rst(rst),.s_req_valid(client_req_valid),.s_req_ready(client_req_ready),.s_req_write(client_req_write),
    .s_req_addr(client_req_addr),.s_req_wdata(client_req_data),.s_req_wstrb(client_req_mask),
    .s_rsp_valid(client_rsp_valid),.s_rsp_ready(client_rsp_ready),.s_rsp_rdata(client_rsp_data),.s_rsp_error(client_rsp_error),
    .mem_req_valid(bus_req_valid),.mem_req_ready(bus_req_ready),.mem_req_write(bus_req_write),
    .mem_req_addr(bus_req_addr),.mem_req_wdata(bus_req_data),.mem_req_wstrb(bus_req_mask),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(bus_rsp_ready),.mem_rsp_rdata(mem_rsp_rdata),.mem_rsp_error(mem_rsp_error),.idle(controller_idle));
  for(d=0;d<2;d=d+1) begin: decode_lanes
    decoder decoder_i(.inst(fetch_inst[d*32+:32]),.dec(decoded[d]));
    assign source_register[(d*2)*5+:5]=decoded[d][DECODED_T_RS1_LSB+:DECODED_T_RS1_WIDTH];
    assign source_register[(d*2+1)*5+:5]=decoded[d][DECODED_T_RS2_LSB+:DECODED_T_RS2_WIDTH];
    assign rename_slot[d*RW+:RW]=dispatch_rid[d];
    assign commit_slot[d*RW+:RW]=commit_rid[d];
    assign dispatch_order[d*(RW+1)+:(RW+1)]={tail_generation,tail}+narrow_0(d);
  end
  v2_rename #(.SLOT_BITS(RW),.CHECKPOINTS(CHECKPOINTS),.COMMIT_TREE(COMMIT_TREE)) rename_maps (.clk(clk),.rst(rst),.dispatch_valid(rename_valid),.prepare_valid(rename_prepare),.dispatch_rd(rename_rd),.dispatch_slot(rename_slot),.source_register(source_register),.source_pending(source_pending),.source_slot(source_slot),.commit_valid(commit_valid),.commit_rd(commit_rd),.commit_slot(commit_slot),
    .save_valid(save_checkpoint),.save_after_lane(save_after_lane),.save_index(free_checkpoint),
    .restore_valid(redirect),.restore_index(redirect_checkpoint));
  for(p=0;p<2;p=p+1) begin: integer_units
    assign execute_pc[p]={executing[p][ISSUE_T_PC_LSB+:ISSUE_T_PC_WIDTH],2'b0};
    assign execute_b[p]=executing[p][ISSUE_T_USE_IMM_LSB+:ISSUE_T_USE_IMM_WIDTH] ? executing[p][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]:executing[p][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH];
    alu alu_i(.op(executing[p][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]),.a(executing[p][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),.b(execute_b[p]),
      .pc(execute_pc[p]),.imm(executing[p][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]),.result(alu_result[p]));
  end
  branch_unit branch_i(.op(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]),.a(executing[0][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),.b(executing[0][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]),
    .pc(execute_pc[0]),.imm(executing[0][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]),.result(branch_value),.next_pc(branch_next),
    .taken(branch_taken),.misaligned(branch_bad));
  muldiv mdu(.clk(clk),.rst(rst),.kill(flush_all),.kill_mask(mdu_kill),.req_valid(mdu_valid),.req_ready(mdu_ready),
    .mul_ready(mdu_mul_ready),.div_ready(mdu_div_ready),.req_op(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]),
    .req_a(executing[0][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),.req_b(executing[0][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]),.req_tag(narrow_2(executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])),
    .rsp_valid(mdu_result_valid),.rsp_ready(mdu_result_ready),.rsp_result(mdu_result),.rsp_tag(mdu_result_tag));
  for(bank=0;bank<3;bank=bank+1) begin: balanced_selection
    wire [IQ_ENTRIES*ISSUE_BITS-1:0] payloads;
    wire [ISSUE_BITS-1:0] selected_payload;
    wire [IQ_ENTRIES-1:0] direct_grant;
    wire [IQ_ENTRIES*((ISSUE_BITS+31)/32)-1:0] payload_grants;
    if(bank==2) begin: unused_direct_grant
      assign direct_grant=0;
      wire [(QW+1)*((ISSUE_BITS+31)/32+1)-1:0] next_controls;
      v2_distribution #(.WIDTH(QW+1),.LEAVES((ISSUE_BITS+31)/32+1)) controls (
        .data_in({prepared_selection.next_valid,prepared_selection.next_index}),.data_out(next_controls));
      for(group=0;group<(ISSUE_BITS+31)/32;group=group+1) begin: payload_copy
        v2_registered_grant #(.ENTRIES(IQ_ENTRIES),.INDEX_BITS(QW)) local_grant (.clk(clk),.rst(rst),.valid(next_controls[group*(QW+1)+QW]),.index(next_controls[group*(QW+1)+:QW]),
          .grant(payload_grants[group*IQ_ENTRIES+:IQ_ENTRIES]));

      end
      v2_registered_grant #(.ENTRIES(IQ_ENTRIES),.INDEX_BITS(QW)) address_copy (.clk(clk),.rst(rst),.valid(next_controls[((ISSUE_BITS+31)/32)*(QW+1)+QW]),
        .index(next_controls[((ISSUE_BITS+31)/32)*(QW+1)+:QW]),.grant(memory_address_grant));

    end else begin: distribute_grants
      v2_distribution #(.WIDTH(IQ_ENTRIES),.LEAVES((ISSUE_BITS+31)/32)) tree (
        .data_in(direct_grant),.data_out(payload_grants));
    end

    for(q=0;q<IQ_ENTRIES;q=q+1) begin: candidate
      assign select_ready[bank][q]=queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH] && (bank==2 || (queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH] && queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]));
      assign select_owner[bank][q*(RW+1)+:(RW+1)]={queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_GENERATION_LSB+:ISSUE_T_GENERATION_WIDTH],queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]};
      assign payloads[q*ISSUE_BITS+:ISSUE_BITS]=queue[(bank)*(IQ_ENTRIES)+(q)];
    end
    if(bank==2) begin: prepared_selection
      wire [IQ_ENTRIES-1:0] next_candidates;
      wire [IQ_ENTRIES*(RW+1)-1:0] next_owners;
      wire next_valid;
      wire [QW-1:0] next_index;
reg  grant_valid;
reg [QW-1:0] grant_index;
      for(q=0;q<IQ_ENTRIES;q=q+1) begin: next_row
        wire lane0=dispatch_valid[0] && dispatch_bank[0]==2 && dispatch_index[0]==narrow_3(q);
        wire lane1=dispatch_valid[1] && dispatch_bank[1]==2 && dispatch_index[1]==narrow_3(q);
        wire [REC_BITS-1:0] controls=recovery_copies[(ROB_REC_GROUPS+2)*REC_BITS+:REC_BITS];
        wire removed=(issue_fire[2] && selected[2]==narrow_3(q)) ||
          recovery_younger(queue[(2)*(IQ_ENTRIES)+(q)][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH],controls) || controls[REC_BITS-1];
        assign next_candidates[q]=(queue[(2)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH] && !removed) || lane0 || lane1;
        assign next_owners[q*(RW+1)+:(RW+1)]=lane1 ? dispatch_order[(RW+1)+:(RW+1)]:
          lane0 ? dispatch_order[0+:(RW+1)]:select_owner[2][q*(RW+1)+:(RW+1)];
      end

      v2_select #(.ENTRIES(IQ_ENTRIES),.SLOT_BITS(RW+1),.EXTENDED_ORDER(1)) choose_next (
        .ready(next_candidates),.owner(next_owners),.rob_head({(RW+1){1'b0}}),.valid(next_valid),.index(next_index));
      always @(posedge clk) begin
        if(rst) begin grant_valid<=0;grant_index<=0;end
        else begin grant_valid<=next_valid;grant_index<=next_index;end
      end
      assign selected_valid[bank]=grant_valid;
      assign selected[bank]=grant_index;
    end else begin: current_selection
      v2_parallel_select #(.ENTRIES(IQ_ENTRIES),.SLOT_BITS(RW+1)) choose (
        .ready(select_ready[bank]),.owner(select_owner[bank]),.rob_head({(RW+1){1'b0}}),
        .valid(selected_valid[bank]),.index(selected[bank]),.grant(direct_grant));
    end
    for(first=0;first<ISSUE_BITS;first=first+32) begin: read_payload
      wire [IQ_ENTRIES*(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)-1:0] slice_words;
      for(row=0;row<IQ_ENTRIES;row=row+1) begin: slice_row
        assign slice_words[row*(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)]=
          payloads[row*ISSUE_BITS+first+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)];
      end
        v2_grant_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)) read_slice (
          .grant(payload_grants[(first/32)*IQ_ENTRIES+:IQ_ENTRIES]),.words(slice_words),
          .value(selected_payload[first+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)]));

    end
    assign executing[bank]=selected_payload;
    assign select_valid[bank]=selected_valid[bank] && (bank!=2 || (executing[bank][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH] && executing[bank][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]));
  end
  for(s=0;s<STORE_SLOTS;s=s+1) begin: store_candidates
    assign store_owners[s*ST+:ST]=narrow_4(s);
    assign store_forward_candidates[s]=stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH] && stores[s][STORE_T_ADDRESS_LSB+(31):STORE_T_ADDRESS_LSB+(2)]==memory_address[31:2] &&
                                       (|(stores[s][STORE_T_MASK_LSB+:STORE_T_MASK_WIDTH] & memory_mask));
    assign store_send_candidates[s]=stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH] && stores[s][STORE_T_COMMITTED_LSB+:STORE_T_COMMITTED_WIDTH] && !stores[s][STORE_T_ISSUED_LSB+:STORE_T_ISSUED_WIDTH];
  end
  v2_circular_grant #(.ENTRIES(STORE_SLOTS),.INDEX_BITS(ST)) choose_forward (
    .ready(store_forward_candidates),.head(store_head),.valid(forward_match),.index(forward_slot),.grant(forward_grant));
  v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST)) choose_store (
    .ready(store_send_candidates),.owner(store_owners),.rob_head(store_head),.valid(store_send_valid),.index(store_send_slot));
  always @* begin: select_instructions
    free_queue_valid=0;
    begin: loop_21
integer bank;
for(bank=0;bank<3;bank=bank+1) begin
      free_queue[bank]=0;occupancy[bank]=0;
      begin: loop_20
integer q;
for(q=0;q<IQ_ENTRIES;q=q+1) begin
        if(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]) begin
          occupancy[bank]=occupancy[bank]+1'b1;
        end else if(!free_queue_valid[bank]) begin free_queue_valid[bank]=1;free_queue[bank]=narrow_3(q);end
      end
end
    end
end
    checkpoint_available=0;free_checkpoint=0;
    begin: loop_19
integer c;
for(c=0;c<CHECKPOINTS;c=c+1)
      if(!checkpoint_valid[c] && !checkpoint_available) begin checkpoint_available=1;free_checkpoint=narrow_5(c);end
end
    load_available=0;free_load=0;
    begin: loop_18
integer l;
for(l=0;l<LOAD_SLOTS;l=l+1)
      if(!loads[l][LOAD_T_VALID_LSB+:LOAD_T_VALID_WIDTH] && !load_available) begin load_available=1;free_load=narrow_6(l);end
end
    mdu_kill=~0;
    begin: loop_17
integer r;
for(r=0;r<ROB_ENTRIES;r=r+1) mdu_kill[r]=!rob[r][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH];
end
  end

  assign branch_capture=select_valid[0] && is_branch(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]) &&
                        !flush_all && !mdu_result_valid && !(redirect && (((executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head)==(redirect_rid<head) ? (executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])>redirect_rid:(executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head));
  always @(posedge clk) begin
    if(rst) begin branch_pending<=0;branch_recovery_q<=0;end
    else begin
      branch_pending<=branch_capture;
      branch_recovery_q<=branch_capture && !branch_bad && branch_next!={executing[0][ISSUE_T_PREDICTION_LSB+:ISSUE_T_PREDICTION_WIDTH],2'b0};
    end
    branch_bad_q<=branch_bad;branch_taken_q<=branch_taken;
    branch_next_q<=branch_next;branch_pc_q<=execute_pc[0];
    branch_prediction_q<=executing[0][ISSUE_T_PREDICTION_LSB+:ISSUE_T_PREDICTION_WIDTH];
    branch_history_q<=executing[0][ISSUE_T_HISTORY_LSB+:ISSUE_T_HISTORY_WIDTH];
    branch_rid_q<=executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH];branch_checkpoint_q<=executing[0][ISSUE_T_CHECKPOINT_LSB+:ISSUE_T_CHECKPOINT_WIDTH];
    branch_generation_q<=executing[0][ISSUE_T_GENERATION_LSB+:ISSUE_T_GENERATION_WIDTH];
    branch_op_q<=executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH];
  end
  assign branch_fire=branch_pending && !flush_all;

  assign redirect=REGISTER_REDIRECT ? (branch_recovery_q && !flush_all):
    (branch_fire && !branch_bad_q && branch_next_q!={branch_prediction_q,2'b0});
  assign redirect_pc=branch_next_q;
  assign redirect_rid=branch_rid_q;
  assign redirect_checkpoint=branch_checkpoint_q;
  assign train_valid=branch_fire && !branch_bad_q;
  assign train_op=branch_op_q;
  assign train_taken=branch_taken_q;
  assign train_pc=branch_pc_q;
  assign train_target=branch_next_q;
  assign mdu_valid=select_valid[0] && is_mdu(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]) && !flush_all &&
                   !mdu_result_valid && !(redirect && (((executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head)==(redirect_rid<head) ? (executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])>redirect_rid:(executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head));
  assign mdu_result_ready=!flush_all;

  for(q=0;q<IQ_ENTRIES;q=q+1) begin: memory_address_words
    assign prepared_address_words[q*32+:32]=prepared_address[q];
  end
  v2_grant_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(32)) read_memory_address (
    .grant(memory_address_grant),.words(prepared_address_words),.value(memory_address));

  assign memory_data=executing[2][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]<<(8*memory_address[1:0]);
  assign memory_mask=(executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]==0 ? 4'b0001:executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]==1 ? 4'b0011:4'b1111)<<memory_address[1:0];
  assign memory_exit=executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_STORE && memory_address==32'h80000000 && executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]==2;
  always @* begin: memory_ordering
    memory_fault=0;
    if((executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]==1 && memory_address[0]) || (executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]==2 && memory_address[1:0]!=0))
      memory_fault=executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_LOAD ? FAULT_LOAD_ALIGN:FAULT_STORE_ALIGN;
    else if(memory_address>=RAM_BYTES && !memory_exit)
      memory_fault=executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_LOAD ? FAULT_LOAD_RANGE:FAULT_STORE_RANGE;
    forward_full=|forwarding_full_grants;squashed_stores=0;
    begin: loop_16
integer s;
for(s=0;s<STORE_SLOTS;s=s+1) begin
      if(stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH] && !stores[s][STORE_T_COMMITTED_LSB+:STORE_T_COMMITTED_WIDTH] && ((redirect && (((stores[s][STORE_T_RID_LSB+:STORE_T_RID_WIDTH])<head)==(redirect_rid<head) ? (stores[s][STORE_T_RID_LSB+:STORE_T_RID_WIDTH])>redirect_rid:(stores[s][STORE_T_RID_LSB+:STORE_T_RID_WIDTH])<head)) || flush_all))
        squashed_stores=squashed_stores+1'b1;
    end
end

  end
  assign cache_store_valid=store_send_valid && state!=DONE && state!=FAULT;
  assign cache_store_tag=store_send_slot;
  assign cache_store_address={stores[store_send_slot][STORE_T_ADDRESS_LSB+(31):STORE_T_ADDRESS_LSB+(2)],2'b0};
  assign cache_store_data=stores[store_send_slot][STORE_T_DATA_LSB+:STORE_T_DATA_WIDTH];
  assign cache_store_mask=stores[store_send_slot][STORE_T_MASK_LSB+:STORE_T_MASK_WIDTH];
  assign store_pop=store_count!=0 && stores[store_head][STORE_T_DONE_LSB+:STORE_T_DONE_WIDTH];
  assign memory_allowed=select_valid[2] && !flush_all && !(redirect && (((executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head)==(redirect_rid<head) ? (executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])>redirect_rid:(executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head)) && !cache_result_valid;
  assign cache_load_valid=memory_allowed && executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_LOAD && memory_fault==0 &&
                         !forward_match && load_available;
  assign cache_load_address={memory_address[31:2],2'b0};
  assign cache_load_tag=free_load;
  assign load_word=forward_full ? forwarding_payload[31:0]:cache_load_data;
  assign load_result=extend_load(load_word,memory_address[1:0],executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH],executing[2][ISSUE_T_SIGN_EXTEND_LSB+:ISSUE_T_SIGN_EXTEND_WIDTH]);
  assign load_allocate=cache_load_valid && cache_load_ready && !cache_load_hit;
  assign store_allocate=memory_allowed && executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_STORE && memory_fault==0 && !memory_exit && narrow_7(store_count)<STORE_SLOTS;
  assign memory_complete=memory_allowed && (memory_fault!=0 || memory_exit || store_allocate ||
                          (executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_LOAD && (forward_full || (cache_load_valid && cache_load_ready && cache_load_hit))));
  always @* begin: completion
    wb_valid=0;issue_fire=0;
    begin: loop_15
integer w;
for(w=0;w<3;w=w+1) begin wb_rid[w]=executing[w][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH];wb_value[w]=0;wb_fault[w]=0;wb_address[w]=0;end
end
    if(!flush_all) begin
      if(mdu_result_valid) begin
        wb_valid[0]=rob[narrow_1(mdu_result_tag)][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH] && !(redirect && (((narrow_1(mdu_result_tag))<head)==(redirect_rid<head) ? (narrow_1(mdu_result_tag))>redirect_rid:(narrow_1(mdu_result_tag))<head));
        wb_rid[0]=narrow_1(mdu_result_tag);wb_value[0]=mdu_result;
      end else if(select_valid[0] && !(redirect && (((executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head)==(redirect_rid<head) ? (executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])>redirect_rid:(executing[0][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head))) begin
        if(is_mdu(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH])) issue_fire[0]=mdu_ready;
        else begin
          issue_fire[0]=1;wb_valid[0]=1;
          wb_value[0]=is_branch(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]) ? branch_value:alu_result[0];
          if(is_branch(executing[0][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]) && branch_bad) begin wb_fault[0]=FAULT_TARGET_ALIGN;wb_address[0]=branch_next;end
        end
      end
      if(INTEGER_PORTS==2 && select_valid[1] && !(redirect && (((executing[1][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head)==(redirect_rid<head) ? (executing[1][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])>redirect_rid:(executing[1][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH])<head))) begin
        issue_fire[1]=1;wb_valid[1]=1;wb_value[1]=alu_result[1];
      end
      if(cache_result_valid) begin
        wb_rid[2]=loads[cache_result_tag][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH];
        wb_valid[2]=loads[cache_result_tag][LOAD_T_VALID_LSB+:LOAD_T_VALID_WIDTH] && !loads[cache_result_tag][LOAD_T_CANCELED_LSB+:LOAD_T_CANCELED_WIDTH] &&
                    rob[loads[cache_result_tag][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH]][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH] && !(redirect && (((loads[cache_result_tag][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH])<head)==(redirect_rid<head) ? (loads[cache_result_tag][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH])>redirect_rid:(loads[cache_result_tag][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH])<head));
        wb_value[2]=extend_load(cache_result_data,loads[cache_result_tag][LOAD_T_ADDRESS_LSB+(1):LOAD_T_ADDRESS_LSB+(0)],
          loads[cache_result_tag][LOAD_T_SIZE_LSB+:LOAD_T_SIZE_WIDTH],loads[cache_result_tag][LOAD_T_SIGN_EXTEND_LSB+:LOAD_T_SIGN_EXTEND_WIDTH]);
        wb_fault[2]=cache_result_error ? FAULT_LOAD_BUS:FAULT_NONE;
        wb_address[2]=loads[cache_result_tag][LOAD_T_ADDRESS_LSB+:LOAD_T_ADDRESS_WIDTH];
      end else begin
        issue_fire[2]=memory_complete || load_allocate;
        wb_valid[2]=memory_complete;
        wb_value[2]=executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_LOAD ? load_result:executing[2][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH];
        wb_fault[2]=memory_fault;wb_address[2]=memory_address;
      end
    end
  end
  always @* begin: retirement
reg  blocked_retirement;
  reg  committed_store;
    blocked_retirement=0;committed_store=0;commit_count=0;commit_valid=0;commit_rd=0;
    begin: loop_14
integer lane;
for(lane=0;lane<2;lane=lane+1) begin
      if(lane<COMMIT_WIDTH && !blocked_retirement && state==RUN && narrow_7(rob_count)>lane &&
         retirement_meta[lane][RETIRE_META_T_DONE_LSB+:RETIRE_META_T_DONE_WIDTH] && retirement_meta[lane][RETIRE_META_T_FAULT_LSB+:RETIRE_META_T_FAULT_WIDTH]==0 && !retirement_meta[lane][RETIRE_META_T_EXITING_LSB+:RETIRE_META_T_EXITING_WIDTH] &&

         (lane==0 || !redirect || redirect_rid!=head) &&
         (!committed_store || !retirement_meta[lane][RETIRE_META_T_STORE_LSB+:RETIRE_META_T_STORE_WIDTH])) begin
        commit_count=commit_count+1'b1;
        commit_valid[lane]=retirement_meta[lane][RETIRE_META_T_RD_LSB+:RETIRE_META_T_RD_WIDTH]!=0;
        commit_rd[lane*5+:5]=retirement_meta[lane][RETIRE_META_T_RD_LSB+:RETIRE_META_T_RD_WIDTH];
        if(retirement_meta[lane][RETIRE_META_T_STORE_LSB+:RETIRE_META_T_STORE_WIDTH]) committed_store=1;
      end else blocked_retirement=1;
    end
end
  end
  always @* begin: dispatch_control
reg  blocked_dispatch;
    integer bank_choice;

    blocked_dispatch=0;
    dispatch_prepare=0;dispatch_valid=0;dispatch_count=0;rename_prepare=0;rename_valid=0;rename_rd=0;used_bank=0;
    save_checkpoint=0;save_after_lane=0;
    begin: loop_13
integer lane;
for(lane=0;lane<2;lane=lane+1) begin
      dispatch_rid[lane]=tail+narrow_1(lane);dispatch_bank[lane]=0;dispatch_index[lane]=0;bank_choice=0;
      if(lane<RENAME_WIDTH && !blocked_dispatch && fetch_valid[lane] && narrow_7(rob_count)+lane<ROB_ENTRIES) begin
        if(decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH]==OP_LOAD || decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH]==OP_STORE) bank_choice=2;
        else if(is_branch(decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH]) || is_mdu(decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH]) || INTEGER_PORTS==1) bank_choice=0;
        else if(used_bank[0] || !free_queue_valid[0]) bank_choice=1;
        else if(used_bank[1] || !free_queue_valid[1]) bank_choice=0;
        else bank_choice=(occupancy[1]<occupancy[0] || (occupancy[1]==occupancy[0] && steer)) ? 1:0;
        if(fetch_fault[lane*4+:4]!=0 || decoded[lane][DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH]) begin
          dispatch_prepare[lane]=1;dispatch_count=dispatch_count+1'b1;
          dispatch_bank[lane]=3;
        end else if(!used_bank[bank_choice] && free_queue_valid[bank_choice] &&
                    (!is_branch(decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH]) || (checkpoint_available && !save_checkpoint))) begin
          dispatch_prepare[lane]=1;dispatch_count=dispatch_count+1'b1;
          dispatch_bank[lane]=narrow_8(bank_choice);dispatch_index[lane]=free_queue[bank_choice];used_bank[bank_choice]=1;
          rename_prepare[lane]=decoded[lane][DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH];rename_rd[lane*5+:5]=decoded[lane][DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] ? decoded[lane][DECODED_T_RD_LSB+:DECODED_T_RD_WIDTH]:5'd0;
          if(is_branch(decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH])) begin save_checkpoint=1;save_after_lane=narrow_9(lane);end
        end else blocked_dispatch=1;
      end else blocked_dispatch=1;
    end
end
    dispatch_valid=dispatch_prepare & {2{!flush_all && !redirect}};
    rename_valid=rename_prepare & {2{!flush_all && !redirect}};
    if(flush_all || redirect) begin dispatch_count=0;save_checkpoint=0;end
    pop_count=dispatch_count;
  end
  always @* begin: capture_sources
reg [RW-1:0] source_id;
reg [4:0] register_id;
reg  pending;
  reg  ready_value;
reg [2:0] bypass_matches;
  reg [2:0] bypass_chosen;
reg [31:0] source_value;
    source_id=0;register_id=0;pending=0;ready_value=0;source_value=0;bypass_matches=0;bypass_chosen=0;
    begin: loop_12
integer lane;
for(lane=0;lane<2;lane=lane+1) begin
      dispatch_payload[lane]=0;dispatch_payload[lane][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]=1;dispatch_payload[lane][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]=dispatch_rid[lane];
      dispatch_payload[lane][ISSUE_T_GENERATION_LSB+:ISSUE_T_GENERATION_WIDTH]=dispatch_order[lane*(RW+1)+RW];
      dispatch_payload[lane][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]=decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH];dispatch_payload[lane][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]=decoded[lane][DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH];
      dispatch_payload[lane][ISSUE_T_PC_LSB+:ISSUE_T_PC_WIDTH]=fetch_pc[lane*32+2+:30];
      dispatch_payload[lane][ISSUE_T_HISTORY_LSB+:ISSUE_T_HISTORY_WIDTH]=fetch_history[lane*HB+:HB];
      dispatch_payload[lane][ISSUE_T_PREDICTION_LSB+:ISSUE_T_PREDICTION_WIDTH]=fetch_prediction[lane*32+2+:30];
      dispatch_payload[lane][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]=decoded[lane][DECODED_T_MEM_SIZE_LSB+:DECODED_T_MEM_SIZE_WIDTH];dispatch_payload[lane][ISSUE_T_SIGN_EXTEND_LSB+:ISSUE_T_SIGN_EXTEND_WIDTH]=decoded[lane][DECODED_T_LOAD_SIGNED_LSB+:DECODED_T_LOAD_SIGNED_WIDTH];
      dispatch_payload[lane][ISSUE_T_USE_IMM_LSB+:ISSUE_T_USE_IMM_WIDTH]=decoded[lane][DECODED_T_USE_IMM_LSB+:DECODED_T_USE_IMM_WIDTH];dispatch_payload[lane][ISSUE_T_CHECKPOINT_LSB+:ISSUE_T_CHECKPOINT_WIDTH]=free_checkpoint;
      begin: loop_11
integer source_number;
for(source_number=0;source_number<2;source_number=source_number+1) begin
        register_id=source_register[(lane*2+source_number)*5+:5];
        source_id=source_slot[(lane*2+source_number)*RW+:RW];
        pending=source_pending[lane*2+source_number] && register_id!=0 &&
                (source_number==0 ? decoded[lane][DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH]:decoded[lane][DECODED_T_USES_RS2_LSB+:DECODED_T_USES_RS2_WIDTH]);
        ready_value=!pending || (source_status[lane*2+source_number][5:4]==2'b11 &&
                                source_status[lane*2+source_number][3:0]==0);
        source_value=pending ? source_result[lane*2+source_number]:
                     (register_id==0 ? 32'd0:source_architectural[lane*2+source_number]);
        begin: loop_10
integer w;
for(w=0;w<3;w=w+1)
          bypass_matches[w]=pending && wb_good[w] && wb_rid[w]==source_id;
end
        bypass_chosen[2]=bypass_matches[2];
        bypass_chosen[1]=bypass_matches[1] && !bypass_matches[2];
        bypass_chosen[0]=bypass_matches[0] && !(bypass_matches[1] || bypass_matches[2]);
        ready_value=ready_value || |bypass_matches;
        source_value=(source_value & {32{!(|bypass_matches)}}) |
          (wb_value[0] & {32{bypass_chosen[0]}}) |
          (wb_value[1] & {32{bypass_chosen[1]}}) |
          (load_value_copies[5*32+:32] & {32{bypass_chosen[2]}});

        if(lane==1 && rename_prepare[0] && source_id==dispatch_rid[0] && pending) ready_value=0;
        if(source_number==0) begin
          dispatch_payload[lane][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]=source_value;dispatch_payload[lane][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]=ready_value;
          dispatch_payload[lane][ISSUE_T_SOURCE_A_LSB+:ISSUE_T_SOURCE_A_WIDTH]=source_id;
        end else begin
          dispatch_payload[lane][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]=source_value;dispatch_payload[lane][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]=ready_value;
          dispatch_payload[lane][ISSUE_T_SOURCE_B_LSB+:ISSUE_T_SOURCE_B_WIDTH]=source_id;
        end
      end
end
    end
end
  end
  always @(posedge clk) begin: control_state
    if(rst) begin
      state<=RUN;head<=0;tail<=0;tail_generation<=0;rob_count<=0;store_head<=0;store_tail<=0;store_count<=0;steer<=0;
      fault_pc<=0;fault_inst<=0;fault_inst_valid<=0;fault_cause<=0;fault_addr<=0;
      cycle_count<=0;retired_count<=0;branch_miss_count<=0;
      retire_valid<=0;retire_pc<=0;retire_inst<=0;retire_rd<=0;retire_value<=0;
      retire_store<=0;retire_addr<=0;retire_wdata<=0;retire_wstrb<=0;
    end else begin
      retire_valid<=0;retire_store<=0;
      if(state!=DONE && state!=FAULT) cycle_count<=cycle_count+1;
      head<=head+narrow_1(commit_count);
      if(redirect) begin tail<=redirect_rid+1'b1;rob_count<=narrow_0(narrow_1((redirect_rid)-head))+1-narrow_0(commit_count);end
      else begin tail<=tail+narrow_1(dispatch_count);rob_count<=rob_count+narrow_0(dispatch_count)-narrow_0(commit_count);end
      if(redirect) tail_generation<=branch_generation_q ^ (&redirect_rid);
      else tail_generation<=allocation_end[RW];
      store_count<=store_count+narrow_10(store_allocate)-narrow_10(store_pop)-squashed_stores;
      store_head<=store_head+narrow_4(store_pop);store_tail<=store_tail+narrow_4(store_allocate)-narrow_4(squashed_stores);
      if(dispatch_count!=0) steer<=!steer;
      if(redirect) branch_miss_count<=branch_miss_count+1;
      retired_count<=retired_count+narrow_11(commit_count)+narrow_11(exit_accept);
      begin: loop_9
integer lane;
for(lane=0;lane<2;lane=lane+1)
        if(narrow_7(commit_count)>lane) begin
          retire_valid[lane]<=1;retire_pc[lane*32+:32]<=rob[commit_rid[lane]][ROB_T_PC_LSB+:ROB_T_PC_WIDTH];
          retire_inst[lane*32+:32]<=rob[commit_rid[lane]][ROB_T_INST_LSB+:ROB_T_INST_WIDTH];retire_rd[lane*5+:5]<=retirement_meta[lane][RETIRE_META_T_RD_LSB+:RETIRE_META_T_RD_WIDTH];
          retire_value[lane*32+:32]<=retirement_meta[lane][RETIRE_META_T_RD_LSB+:RETIRE_META_T_RD_WIDTH]==0 ? 32'd0:retirement_value[lane];
          retire_store[lane]<=retirement_meta[lane][RETIRE_META_T_STORE_LSB+:RETIRE_META_T_STORE_WIDTH];
          retire_addr[lane*32+:32]<=rob[commit_rid[lane]][ROB_T_ADDRESS_LSB+:ROB_T_ADDRESS_WIDTH];
          retire_wdata[lane*32+:32]<=rob[commit_rid[lane]][ROB_T_WDATA_LSB+:ROB_T_WDATA_WIDTH];
          retire_wstrb[lane*4+:4]<=rob[commit_rid[lane]][ROB_T_MASK_LSB+:ROB_T_MASK_WIDTH];
        end
end
      if(exit_head) state<=DRAIN;
      if(exit_accept) begin
        state<=DONE;retire_valid<=1;retire_store<=1;retire_pc[31:0]<=rob[head][ROB_T_PC_LSB+:ROB_T_PC_WIDTH];retire_inst[31:0]<=rob[head][ROB_T_INST_LSB+:ROB_T_INST_WIDTH];
        retire_rd[4:0]<=0;retire_value[31:0]<=0;retire_addr[31:0]<=32'h80000000;
        retire_wdata[31:0]<=retirement_value[0];retire_wstrb[3:0]<=15;
      end
      if(fault_head) begin
        state<=FAULT;fault_pc<=rob[head][ROB_T_PC_LSB+:ROB_T_PC_WIDTH];fault_inst<=rob[head][ROB_T_INST_LSB+:ROB_T_INST_WIDTH];fault_inst_valid<=rob[head][ROB_T_IV_LSB+:ROB_T_IV_WIDTH];
        fault_cause<=retirement_meta[0][RETIRE_META_T_FAULT_LSB+:RETIRE_META_T_FAULT_WIDTH];fault_addr<=rob[head][ROB_T_FAULT_ADDRESS_LSB+:ROB_T_FAULT_ADDRESS_WIDTH];
      end
      if(cache_store_error) begin
        state<=FAULT;fault_cause<=FAULT_STORE_BUS;fault_pc<=stores[cache_store_done_tag][STORE_T_PC_LSB+:STORE_T_PC_WIDTH];
        fault_inst<=stores[cache_store_done_tag][STORE_T_INST_LSB+:STORE_T_INST_WIDTH];fault_inst_valid<=1;fault_addr<=stores[cache_store_done_tag][STORE_T_ADDRESS_LSB+:STORE_T_ADDRESS_WIDTH];
      end
    end
  end
  for(r=0;r<ROB_ENTRIES;r=r+1) begin: rob_rows
    wire [REC_BITS-1:0] controls=recovery_copies[(r/4)*REC_BITS+:REC_BITS];
    always @(posedge clk) begin
      if(rst) begin rob[r][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH]<=0;rob[r][ROB_T_DONE_LSB+:ROB_T_DONE_WIDTH]<=0;end
      else begin
        begin: loop_8
integer lane;
for(lane=0;lane<2;lane=lane+1)
          if(narrow_7(commit_count)>lane && commit_rid[lane]==narrow_1(r)) rob[r][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH]<=0;
end
        begin: loop_7
integer w;
for(w=0;w<3;w=w+1)
          if(wb_valid[w] && wb_rid[w]==narrow_1(r)) begin
            rob[r][ROB_T_DONE_LSB+:ROB_T_DONE_WIDTH]<=1;rob[r][ROB_T_FAULT_LSB+:ROB_T_FAULT_WIDTH]<=wb_fault[w];
            if(!ROB_WRITE_TREE) begin rob[r][ROB_T_FAULT_ADDRESS_LSB+:ROB_T_FAULT_ADDRESS_WIDTH]<=wb_address[w];values[r]<=(w==2 ? load_value_copies[(2*r/ROB_ENTRIES)*32+:32]:wb_value[w]);end
          end
end
        if(memory_complete && executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]==narrow_1(r) && executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_STORE) begin
          if(!ROB_WRITE_TREE) begin rob[r][ROB_T_ADDRESS_LSB+:ROB_T_ADDRESS_WIDTH]<=memory_address;rob[r][ROB_T_WDATA_LSB+:ROB_T_WDATA_WIDTH]<=memory_data;end
          rob[r][ROB_T_MASK_LSB+:ROB_T_MASK_WIDTH]<=memory_mask;
          rob[r][ROB_T_EXITING_LSB+:ROB_T_EXITING_WIDTH]<=memory_exit;rob[r][ROB_T_STORE_SLOT_LSB+:ROB_T_STORE_SLOT_WIDTH]<=store_tail;
        end
        if(recovery_younger(narrow_1(r),controls) ||
           (controls[REC_BITS-1] && narrow_1(r)!=controls[0+:RW])) rob[r][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH]<=0;
        begin: loop_6
integer lane;
for(lane=0;lane<2;lane=lane+1)
          if(dispatch_valid[lane] && dispatch_rid[lane]==narrow_1(r)) begin
            rob[r][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH]<=1;rob[r][ROB_T_DONE_LSB+:ROB_T_DONE_WIDTH]<=dispatch_bank[lane]==3;rob[r][ROB_T_EXITING_LSB+:ROB_T_EXITING_WIDTH]<=0;
            rob[r][ROB_T_FAULT_LSB+:ROB_T_FAULT_WIDTH]<=fetch_fault[lane*4+:4]!=0 ? fetch_fault[lane*4+:4]:decoded[lane][DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] ? FAULT_ILLEGAL:FAULT_NONE;
            if(!ROB_WRITE_TREE) begin
              rob[r][ROB_T_FAULT_ADDRESS_LSB+:ROB_T_FAULT_ADDRESS_WIDTH]<=fetch_pc[lane*32+:32];rob[r][ROB_T_ADDRESS_LSB+:ROB_T_ADDRESS_WIDTH]<=0;rob[r][ROB_T_WDATA_LSB+:ROB_T_WDATA_WIDTH]<=0;
            end
            rob[r][ROB_T_MASK_LSB+:ROB_T_MASK_WIDTH]<=0;
          end
end
      end
    end
    if(ROB_WRITE_TREE) begin: distributed_data_write
      wire [5:0] write_control;
      wire [23:0] byte_control;
      for(w=0;w<3;w=w+1) begin: completion_control
        assign write_control[w]=wb_valid[w] && wb_rid[w]==narrow_1(r);
      end
      assign write_control[3]=memory_complete && executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]==narrow_1(r) && executing[2][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]==OP_STORE;
      for(lane=0;lane<2;lane=lane+1) begin: allocation_control
        assign write_control[4+lane]=dispatch_valid[lane] && dispatch_rid[lane]==narrow_1(r);
      end
      v2_distribution #(.WIDTH(6),.LEAVES(4)) tree (
        .data_in(write_control),.data_out(byte_control));
      for(bit_id=0;bit_id<32;bit_id=bit_id+1) begin: data_bit
        wire [5:0] controls=byte_control[(bit_id/8)*6+:6];
        always @(posedge clk) begin
          if(!rst) begin
            begin: loop_5
integer w;
for(w=0;w<3;w=w+1)
              if(controls[w]) begin
                rob[r][ROB_T_FAULT_ADDRESS_LSB+(bit_id)]<=wb_address[w][bit_id];values[r][bit_id]<=(w==2 ? load_value_copies[(2*r/ROB_ENTRIES)*32+bit_id]:wb_value[w][bit_id]);
              end
end
            if(controls[3]) begin rob[r][ROB_T_ADDRESS_LSB+(bit_id)]<=memory_address[bit_id];rob[r][ROB_T_WDATA_LSB+(bit_id)]<=memory_data[bit_id];end
            begin: loop_4
integer lane;
for(lane=0;lane<2;lane=lane+1)
              if(controls[4+lane]) begin
                rob[r][ROB_T_FAULT_ADDRESS_LSB+(bit_id)]<=fetch_pc[lane*32+bit_id];rob[r][ROB_T_ADDRESS_LSB+(bit_id)]<=0;rob[r][ROB_T_WDATA_LSB+(bit_id)]<=0;
              end
end
          end
        end
      end
    end

    always @(posedge clk) begin
      if(!rst && !rob[r][ROB_T_VALID_LSB+:ROB_T_VALID_WIDTH])
        begin: loop_3
integer lane;
for(lane=0;lane<2;lane=lane+1)
          if(dispatch_rid[lane]==narrow_1(r)) begin
            rob[r][ROB_T_PC_LSB+:ROB_T_PC_WIDTH]<=fetch_pc[lane*32+:32];rob[r][ROB_T_INST_LSB+:ROB_T_INST_WIDTH]<=fetch_inst[lane*32+:32];rob[r][ROB_T_IV_LSB+:ROB_T_IV_WIDTH]<=fetch_iv[lane];
            rob[r][ROB_T_RD_LSB+:ROB_T_RD_WIDTH]<=rename_rd[lane*5+:5];rob[r][ROB_T_STORE_LSB+:ROB_T_STORE_WIDTH]<=decoded[lane][DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH]==OP_STORE;
          end
end
    end
  end
  wire [8*76-1:0] architectural_commits;
  v2_distribution #(.WIDTH(76),.LEAVES(COMMIT_TREE ? 8:1)) architectural_commit_tree (
    .data_in({commit_valid,commit_rd,retirement_value[1],retirement_value[0]}),
    .data_out(architectural_commits[0+:(COMMIT_TREE ? 8:1)*76]));
  if(!COMMIT_TREE) begin: direct_architectural_commit
    assign architectural_commits[76+:7*76]={7{architectural_commits[0+:76]}};
  end
  for(r=0;r<32;r=r+1) begin: architectural_registers
    wire [75:0] local_commit=architectural_commits[(r/4)*76+:76];
    wire [31:0] register_value;
    assign architectural[r]=register_value;
    v2_arch_word #(.REGISTER(r),.CONTROL_TREE(COMMIT_TREE)) word_register (.clk(clk),.rst(rst),.commit_valid(local_commit[74+:2]),.commit_rd(local_commit[64+:10]),
      .commit_values(local_commit[0+:64]),.value(register_value));
  end
  for(bank=0;bank<3;bank=bank+1) begin: issue_banks
    wire [REC_BITS-1:0] controls=recovery_copies[(ROB_REC_GROUPS+bank)*REC_BITS+:REC_BITS];
    for(q=0;q<IQ_ENTRIES;q=q+1) begin: rows
      wire [1:0] prepare_lane;
      wire next_ready_a,next_ready_b;
      wire [31:0] next_value_a,next_value_b;
      for(lane=0;lane<2;lane=lane+1) begin: preparation
        assign prepare_lane[lane]=dispatch_prepare[lane] && dispatch_bank[lane]==narrow_8(bank) && dispatch_index[lane]==narrow_3(q);
      end
      v2_operand #(.SLOT_BITS(RW)) operand_a (
        .live(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]),.prepare(|prepare_lane),
        .old_ready(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]),.old_value(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),.source(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SOURCE_A_LSB+:ISSUE_T_SOURCE_A_WIDTH]),
        .initial_ready(prepare_lane[1] ? dispatch_payload[1][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]:dispatch_payload[0][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]),
        .initial_value(prepare_lane[1] ? dispatch_payload[1][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]:dispatch_payload[0][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),
        .wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),.wb_slots(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+:3*RW]),.wb_values({load_value_copies[(2+bank)*32+:32],wb_values[63:0]}),.next_ready(next_ready_a),.next_value(next_value_a));
      v2_operand #(.SLOT_BITS(RW)) operand_b (
        .live(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]),.prepare(|prepare_lane),
        .old_ready(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]),.old_value(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]),.source(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SOURCE_B_LSB+:ISSUE_T_SOURCE_B_WIDTH]),
        .initial_ready(prepare_lane[1] ? dispatch_payload[1][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]:dispatch_payload[0][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]),
        .initial_value(prepare_lane[1] ? dispatch_payload[1][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]:dispatch_payload[0][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]),
        .wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),.wb_slots(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+:3*RW]),.wb_values({load_value_copies[(2+bank)*32+:32],wb_values[63:0]}),.next_ready(next_ready_b),.next_value(next_value_b));
      always @(posedge clk) begin
        queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]<=next_ready_a;queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]<=next_value_a;
        queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_B_LSB+:ISSUE_T_READY_B_WIDTH]<=next_ready_b;queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_B_LSB+:ISSUE_T_B_WIDTH]<=next_value_b;
      end

      if(bank==2) begin: address_prepare
        wire [31:0] live_value,live_sum;
        v2_operand #(.SLOT_BITS(RW)) address_operand (
          .live(1'b1),.prepare(1'b0),.old_ready(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]),
          .old_value(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_A_LSB+:ISSUE_T_A_WIDTH]),.source(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SOURCE_A_LSB+:ISSUE_T_SOURCE_A_WIDTH]),
          .initial_ready(1'b0),.initial_value(32'b0),
          .wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),
          .wb_slots(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+:3*RW]),
          .wb_values({load_value_copies[(2+bank)*32+:32],wb_values[63:0]}),.next_ready(),.next_value(live_value));
        v2_prefix_adder #(.WIDTH(32)) effective_address_add (
          .a(live_value),.b(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]),.carry_in(1'b0),.sum(live_sum),.carry_out());
        wire [31:0] address_sum=queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH] ? live_sum:
          (prepare_lane[1] ? dispatch_address[1]:dispatch_address[0]);

        wire address_update=(!queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH] && |prepare_lane) ||
                            (queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH] && !queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_READY_A_LSB+:ISSUE_T_READY_A_WIDTH]);
        always @(posedge clk)
          if(address_update) prepared_address[q]<=address_sum;
      end
      always @(posedge clk) begin
        if(rst) queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]<=0;
        else begin
          if((issue_fire[bank] && selected[bank]==narrow_3(q)) ||
             recovery_younger(queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH],controls) || controls[REC_BITS-1]) queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]<=0;
          begin: loop_2
integer lane;
for(lane=0;lane<2;lane=lane+1)
            if(dispatch_valid[lane] && dispatch_bank[lane]==narrow_8(bank) && dispatch_index[lane]==narrow_3(q))
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]<=1;
end
        end
      end
      always @(posedge clk) begin

        if(!queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_VALID_LSB+:ISSUE_T_VALID_WIDTH]) begin
          begin: loop_1
integer lane;
for(lane=0;lane<2;lane=lane+1)
            if(dispatch_prepare[lane] && dispatch_bank[lane]==narrow_8(bank) && dispatch_index[lane]==narrow_3(q)) begin
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]<=dispatch_payload[lane][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH];queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH]<=dispatch_payload[lane][ISSUE_T_OP_LSB+:ISSUE_T_OP_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_GENERATION_LSB+:ISSUE_T_GENERATION_WIDTH]<=dispatch_payload[lane][ISSUE_T_GENERATION_LSB+:ISSUE_T_GENERATION_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SOURCE_A_LSB+:ISSUE_T_SOURCE_A_WIDTH]<=dispatch_payload[lane][ISSUE_T_SOURCE_A_LSB+:ISSUE_T_SOURCE_A_WIDTH];queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SOURCE_B_LSB+:ISSUE_T_SOURCE_B_WIDTH]<=dispatch_payload[lane][ISSUE_T_SOURCE_B_LSB+:ISSUE_T_SOURCE_B_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_PC_LSB+:ISSUE_T_PC_WIDTH]<=dispatch_payload[lane][ISSUE_T_PC_LSB+:ISSUE_T_PC_WIDTH];queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_PREDICTION_LSB+:ISSUE_T_PREDICTION_WIDTH]<=dispatch_payload[lane][ISSUE_T_PREDICTION_LSB+:ISSUE_T_PREDICTION_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_HISTORY_LSB+:ISSUE_T_HISTORY_WIDTH]<=dispatch_payload[lane][ISSUE_T_HISTORY_LSB+:ISSUE_T_HISTORY_WIDTH];queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_CHECKPOINT_LSB+:ISSUE_T_CHECKPOINT_WIDTH]<=dispatch_payload[lane][ISSUE_T_CHECKPOINT_LSB+:ISSUE_T_CHECKPOINT_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH]<=dispatch_payload[lane][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH];queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_SIGN_EXTEND_LSB+:ISSUE_T_SIGN_EXTEND_WIDTH]<=dispatch_payload[lane][ISSUE_T_SIGN_EXTEND_LSB+:ISSUE_T_SIGN_EXTEND_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_USE_IMM_LSB+:ISSUE_T_USE_IMM_WIDTH]<=dispatch_payload[lane][ISSUE_T_USE_IMM_LSB+:ISSUE_T_USE_IMM_WIDTH];
              queue[(bank)*(IQ_ENTRIES)+(q)][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH]<=dispatch_payload[lane][ISSUE_T_IMM_LSB+:ISSUE_T_IMM_WIDTH];
            end
end
        end
      end
    end
  end
  for(cp=0;cp<CHECKPOINTS;cp=cp+1) begin: checkpoint_rows
    wire [REC_BITS-1:0] controls=recovery_copies[(REC_LEAVES-1)*REC_BITS+:REC_BITS];
    always @(posedge clk) begin
      if(rst) begin checkpoint_valid[cp]<=0;checkpoint_owner[cp]<=0;end
      else begin
        if((branch_fire && branch_checkpoint_q==narrow_5(cp)) ||
           recovery_younger(checkpoint_owner[cp],controls) || controls[REC_BITS-1])
          checkpoint_valid[cp]<=0;
        if(save_checkpoint && free_checkpoint==narrow_5(cp)) begin
          checkpoint_valid[cp]<=1;checkpoint_owner[cp]<=dispatch_rid[save_after_lane];
        end
      end
    end
  end
  for(s=0;s<STORE_SLOTS;s=s+1) begin: store_rows
    wire [REC_BITS-1:0] controls=recovery_copies[(ROB_REC_GROUPS+3+s/4)*REC_BITS+:REC_BITS];
    always @(posedge clk) begin
      if(rst) stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH]<=0;
      else begin
        if(store_pop && store_head==narrow_4(s)) stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH]<=0;
        if(cache_store_valid && cache_store_ready && store_send_slot==narrow_4(s)) stores[s][STORE_T_ISSUED_LSB+:STORE_T_ISSUED_WIDTH]<=1;
        if(cache_store_done && cache_store_done_tag==narrow_4(s)) stores[s][STORE_T_DONE_LSB+:STORE_T_DONE_WIDTH]<=1;
        begin: loop_0
integer lane;
for(lane=0;lane<2;lane=lane+1)
          if(narrow_7(commit_count)>lane && retirement_meta[lane][RETIRE_META_T_STORE_LSB+:RETIRE_META_T_STORE_WIDTH] && retirement_meta[lane][RETIRE_META_T_STORE_SLOT_LSB+:RETIRE_META_T_STORE_SLOT_WIDTH]==narrow_4(s)) stores[s][STORE_T_COMMITTED_LSB+:STORE_T_COMMITTED_WIDTH]<=1;
end
        if(!stores[s][STORE_T_COMMITTED_LSB+:STORE_T_COMMITTED_WIDTH] &&
           (recovery_younger(stores[s][STORE_T_RID_LSB+:STORE_T_RID_WIDTH],controls) || controls[REC_BITS-1])) stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH]<=0;
        if(store_allocate && store_tail==narrow_4(s)) begin
          stores[s][STORE_T_VALID_LSB+:STORE_T_VALID_WIDTH]<=1;stores[s][STORE_T_COMMITTED_LSB+:STORE_T_COMMITTED_WIDTH]<=0;stores[s][STORE_T_ISSUED_LSB+:STORE_T_ISSUED_WIDTH]<=0;stores[s][STORE_T_DONE_LSB+:STORE_T_DONE_WIDTH]<=0;
          stores[s][STORE_T_RID_LSB+:STORE_T_RID_WIDTH]<=executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH];stores[s][STORE_T_ADDRESS_LSB+:STORE_T_ADDRESS_WIDTH]<=memory_address;stores[s][STORE_T_DATA_LSB+:STORE_T_DATA_WIDTH]<=memory_data;stores[s][STORE_T_MASK_LSB+:STORE_T_MASK_WIDTH]<=memory_mask;
          stores[s][STORE_T_PC_LSB+:STORE_T_PC_WIDTH]<=rob[executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]][ROB_T_PC_LSB+:ROB_T_PC_WIDTH];stores[s][STORE_T_INST_LSB+:STORE_T_INST_WIDTH]<=rob[executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH]][ROB_T_INST_LSB+:ROB_T_INST_WIDTH];
        end
      end
    end
  end
  for(l=0;l<LOAD_SLOTS;l=l+1) begin: load_rows
    wire [REC_BITS-1:0] controls=recovery_copies[(ROB_REC_GROUPS+3+STORE_REC_GROUPS+l/4)*REC_BITS+:REC_BITS];
    always @(posedge clk) begin
      if(rst) loads[l][LOAD_T_VALID_LSB+:LOAD_T_VALID_WIDTH]<=0;
      else begin
        if(cache_result_valid && cache_result_tag==narrow_6(l)) loads[l][LOAD_T_VALID_LSB+:LOAD_T_VALID_WIDTH]<=0;
        if(recovery_younger(loads[l][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH],controls) || controls[REC_BITS-1]) loads[l][LOAD_T_CANCELED_LSB+:LOAD_T_CANCELED_WIDTH]<=1;
        if(load_allocate && free_load==narrow_6(l)) begin
          loads[l][LOAD_T_VALID_LSB+:LOAD_T_VALID_WIDTH]<=1;loads[l][LOAD_T_CANCELED_LSB+:LOAD_T_CANCELED_WIDTH]<=0;loads[l][LOAD_T_RID_LSB+:LOAD_T_RID_WIDTH]<=executing[2][ISSUE_T_RID_LSB+:ISSUE_T_RID_WIDTH];
          loads[l][LOAD_T_ADDRESS_LSB+:LOAD_T_ADDRESS_WIDTH]<=memory_address;loads[l][LOAD_T_SIZE_LSB+:LOAD_T_SIZE_WIDTH]<=executing[2][ISSUE_T_SIZE_LSB+:ISSUE_T_SIZE_WIDTH];loads[l][LOAD_T_SIGN_EXTEND_LSB+:LOAD_T_SIGN_EXTEND_WIDTH]<=executing[2][ISSUE_T_SIGN_EXTEND_LSB+:ISSUE_T_SIGN_EXTEND_WIDTH];
        end
      end
    end
  end

  initial begin
    if(ROB_ENTRIES<8 || ROB_ENTRIES>128 || (ROB_ENTRIES&(ROB_ENTRIES-1))!=0 ||
       IQ_ENTRIES<2 || (IQ_ENTRIES&(IQ_ENTRIES-1))!=0 || CHECKPOINTS<2 || RENAME_WIDTH<1 || RENAME_WIDTH>2 ||
       COMMIT_WIDTH<1 || COMMIT_WIDTH>2 || INTEGER_PORTS<1 || INTEGER_PORTS>2 ||
       LOAD_SLOTS<2 || (LOAD_SLOTS&(LOAD_SLOTS-1))!=0 || STORE_SLOTS<2 ||
       (STORE_SLOTS&(STORE_SLOTS-1))!=0 || RAM_BYTES<4096 || (RAM_BYTES&(RAM_BYTES-1))!=0)
      $fatal(1,"invalid Area-v2 dimensions");
  end
endmodule

module decoder (
  input wire [31:0] inst,
  output reg [60:0] dec
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  always @* begin
    dec = 0;
    dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_ADD;
    dec[DECODED_T_RS1_LSB+:DECODED_T_RS1_WIDTH] = inst[19:15];
    dec[DECODED_T_RS2_LSB+:DECODED_T_RS2_WIDTH] = inst[24:20];
    dec[DECODED_T_RD_LSB+:DECODED_T_RD_WIDTH] = inst[11:7];
    dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b0;
    case (inst[6:0])
      7'b0110111, 7'b0010111: begin
        dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = inst[6:0] == 7'b0110111 ? OP_LUI : OP_AUIPC;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {inst[31:12], 12'b0};
        dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b1;
      end
      7'b1101111: begin
        dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_JAL;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {{11{inst[31]}}, inst[31], inst[19:12], inst[20],
                   inst[30:21], 1'b0};
        dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b1;
      end
      7'b1100111: begin
        dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_JALR;
        dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b1;
        dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b1;
        dec[DECODED_T_USE_IMM_LSB+:DECODED_T_USE_IMM_WIDTH] = 1'b1;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {{20{inst[31]}}, inst[31:20]};
        dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = inst[14:12] != 3'b000;
      end
      7'b1100011: begin
        dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b1;
        dec[DECODED_T_USES_RS2_LSB+:DECODED_T_USES_RS2_WIDTH] = 1'b1;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {{19{inst[31]}}, inst[31], inst[7], inst[30:25],
                   inst[11:8], 1'b0};
        case (inst[14:12])
          3'b000: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_BEQ;
          3'b001: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_BNE;
          3'b100: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_BLT;
          3'b101: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_BGE;
          3'b110: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_BLTU;
          3'b111: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_BGEU;
          default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
        endcase
      end
      7'b0000011: begin
        dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_LOAD;
        dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b1;
        dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b1;
        dec[DECODED_T_USE_IMM_LSB+:DECODED_T_USE_IMM_WIDTH] = 1'b1;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {{20{inst[31]}}, inst[31:20]};
        dec[DECODED_T_MEM_SIZE_LSB+:DECODED_T_MEM_SIZE_WIDTH] = inst[13:12];
        dec[DECODED_T_LOAD_SIGNED_LSB+:DECODED_T_LOAD_SIGNED_WIDTH] = !inst[14];
        case (inst[14:12])
          3'b000, 3'b001, 3'b010, 3'b100, 3'b101: ;
          default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
        endcase
      end
      7'b0100011: begin
        dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_STORE;
        dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b1;
        dec[DECODED_T_USES_RS2_LSB+:DECODED_T_USES_RS2_WIDTH] = 1'b1;
        dec[DECODED_T_USE_IMM_LSB+:DECODED_T_USE_IMM_WIDTH] = 1'b1;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {{20{inst[31]}}, inst[31:25], inst[11:7]};
        dec[DECODED_T_MEM_SIZE_LSB+:DECODED_T_MEM_SIZE_WIDTH] = inst[13:12];
        case (inst[14:12])
          3'b000, 3'b001, 3'b010: ;
          default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
        endcase
      end
      7'b0010011: begin
        dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b1;
        dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b1;
        dec[DECODED_T_USE_IMM_LSB+:DECODED_T_USE_IMM_WIDTH] = 1'b1;
        dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {{20{inst[31]}}, inst[31:20]};
        case (inst[14:12])
          3'b000: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_ADD;
          3'b010: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_SLT;
          3'b011: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_SLTU;
          3'b100: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_XOR;
          3'b110: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_OR;
          3'b111: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_AND;
          3'b001: begin
            dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_SLL;
            dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {27'b0, inst[24:20]};
            dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = inst[31:25] != 7'b0000000;
          end
          3'b101: begin
            dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = inst[30] ? OP_SRA : OP_SRL;
            dec[DECODED_T_IMM_LSB+:DECODED_T_IMM_WIDTH] = {27'b0, inst[24:20]};
            dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = (inst[31:25] != 7'b0000000) &&
                          (inst[31:25] != 7'b0100000);
          end
          default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
        endcase
      end
      7'b0110011: begin
        dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b1;
        dec[DECODED_T_USES_RS2_LSB+:DECODED_T_USES_RS2_WIDTH] = 1'b1;
        dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b1;
        if (inst[31:25] == 7'b0000001) begin
          case (inst[14:12])
            3'b000: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_MUL;
            3'b001: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_MULH;
            3'b010: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_MULHSU;
            3'b011: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_MULHU;
            3'b100: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_DIV;
            3'b101: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_DIVU;
            3'b110: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_REM;
            3'b111: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_REMU;
            default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
          endcase
        end else begin
          case (inst[14:12])
            3'b000: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = inst[30] ? OP_SUB : OP_ADD;
            3'b001: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_SLL;
            3'b010: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_SLT;
            3'b011: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_SLTU;
            3'b100: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_XOR;
            3'b101: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = inst[30] ? OP_SRA : OP_SRL;
            3'b110: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_OR;
            3'b111: dec[DECODED_T_OP_LSB+:DECODED_T_OP_WIDTH] = OP_AND;
            default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
          endcase
          dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = (inst[31:25] != 7'b0000000) &&
                        !((inst[31:25] == 7'b0100000) &&
                          ((inst[14:12] == 3'b000) ||
                           (inst[14:12] == 3'b101)));
        end
      end
      default: dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH] = 1'b1;
    endcase

    dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] && dec[DECODED_T_RD_LSB+:DECODED_T_RD_WIDTH] != 5'd0;
    if (dec[DECODED_T_ILLEGAL_LSB+:DECODED_T_ILLEGAL_WIDTH]) begin
      dec[DECODED_T_USES_RS1_LSB+:DECODED_T_USES_RS1_WIDTH] = 1'b0;
      dec[DECODED_T_USES_RS2_LSB+:DECODED_T_USES_RS2_WIDTH] = 1'b0;
      dec[DECODED_T_WRITES_RD_LSB+:DECODED_T_WRITES_RD_WIDTH] = 1'b0;
      dec[DECODED_T_USE_IMM_LSB+:DECODED_T_USE_IMM_WIDTH] = 1'b0;
    end
  end
endmodule



module memory_controller #(
    parameter integer MAX_MEM_OUTSTANDING = 64
) (
    input wire  clk,
  input wire  rst,
    input wire [1:0] s_req_valid,
    output reg [1:0] s_req_ready,
    input wire [1:0] s_req_write,
    input wire [63:0] s_req_addr,
  input wire [63:0] s_req_wdata,
    input wire [7:0] s_req_wstrb,
    output reg [1:0] s_rsp_valid,
    input wire [1:0] s_rsp_ready,
    output reg [63:0] s_rsp_rdata,
    output reg [1:0] s_rsp_error,
    output wire  mem_req_valid,
    input wire  mem_req_ready,
    output reg  mem_req_write,
    output reg [31:0] mem_req_addr,
  output reg [31:0] mem_req_wdata,
    output reg [3:0] mem_req_wstrb,
    input wire  mem_rsp_valid,
    output reg  mem_rsp_ready,
    input wire [31:0] mem_rsp_rdata,
    input wire  mem_rsp_error,
    output wire  idle
);
function automatic signed [31:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer PW = MAX_MEM_OUTSTANDING > 1 ? $clog2(MAX_MEM_OUTSTANDING) : 1;
localparam integer CW = $clog2(MAX_MEM_OUTSTANDING+1);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
reg  owners [0:(MAX_MEM_OUTSTANDING)-1];
reg [PW-1:0] head;
  reg [PW-1:0] tail;
reg [CW-1:0] count;
reg  request_valid;
  reg  request_owner;
  reg  next_owner;
  wire  selected;
wire  request_fire;
  wire  response_fire;
  wire  input_fire;
  wire  space;

    always @* begin
        s_rsp_valid = 2'b00;
        s_rsp_rdata = 64'b0;
        s_rsp_error = 2'b00;
        mem_rsp_ready = 1'b0;
        if (!rst && count != 0) begin
            s_rsp_valid[owners[head]] = mem_rsp_valid;
            s_rsp_rdata[32*owners[head] +: 32] = mem_rsp_rdata;
            s_rsp_error[owners[head]] = mem_rsp_error;
            mem_rsp_ready = s_rsp_ready[owners[head]];
        end
    end
    assign response_fire = mem_rsp_valid && mem_rsp_ready;
    assign space = narrow_0(count) < MAX_MEM_OUTSTANDING || response_fire;
    assign mem_req_valid = !rst && request_valid && space;
    assign request_fire = mem_req_valid && mem_req_ready;
    assign selected = s_req_valid[next_owner] ? next_owner : !next_owner;
    assign input_fire = s_req_valid[selected] && s_req_ready[selected];
    assign idle = count == 0 && !request_valid && !(|s_req_valid);
    always @* begin
        s_req_ready = 2'b00;
        if (!rst && (!request_valid || request_fire) && s_req_valid[selected])
            s_req_ready[selected] = 1'b1;
    end

    always @(posedge clk) begin
        if (rst) begin
            head <= 0;
            tail <= 0;
            count <= 0;
            request_valid <= 1'b0;
            request_owner <= 1'b0;
            next_owner <= 1'b0;
            mem_req_write <= 1'b0;
            mem_req_addr <= 0;
            mem_req_wdata <= 0;
            mem_req_wstrb <= 0;
            begin: loop_0
integer n;
for(n = 0; n < MAX_MEM_OUTSTANDING; n = n+1) owners[n] <= 1'b0;
end
        end else begin
            case ({request_fire, response_fire})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: begin end
            endcase
            if (request_fire) begin
                owners[tail] <= request_owner;
                tail <= narrow_0(tail) == MAX_MEM_OUTSTANDING-1 ? 0 : tail + 1'b1;
                request_valid <= 1'b0;
            end
            if (response_fire)
                head <= narrow_0(head) == MAX_MEM_OUTSTANDING-1 ? 0 : head + 1'b1;
            if (input_fire) begin
                request_valid <= 1'b1;
                request_owner <= selected;
                next_owner <= !selected;
                mem_req_write <= s_req_write[selected];
                mem_req_addr <= s_req_addr[32*selected +: 32];
                mem_req_wdata <= s_req_wdata[32*selected +: 32];
                mem_req_wstrb <= s_req_wstrb[4*selected +: 4];
            end
        end
    end
    initial if (MAX_MEM_OUTSTANDING < 1) $fatal(1, "invalid memory owner FIFO capacity");
endmodule

module muldiv #(
  parameter integer DIV_STEP_BITS=2
)(
  input wire  clk,
  input wire  rst,
  input wire  kill,
  input wire [255:0] kill_mask,
  input wire  req_valid,
  output wire  req_ready,
  output wire  mul_ready,
  output wire  div_ready,
  input wire [5:0] req_op,
  input wire [31:0] req_a,
  input wire [31:0] req_b,
  input wire [7:0] req_tag,
  output wire  rsp_valid,
  input wire  rsp_ready,
  output wire [31:0] rsp_result,
  output wire [7:0] rsp_tag
);
genvar stage;
function automatic [2-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction

function automatic [STEP_W-1:0] narrow_1;
  input [63:0] value;
  begin narrow_1=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DIV_STEPS=32/DIV_STEP_BITS;
localparam integer STEP_W=$clog2(DIV_STEPS);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
reg [2:0] mul_valid_q;
  wire [2:0] mul_live;
  wire [2:0] mul_remaining;
wire  mul_ready0;
  wire  mul_ready1;
  wire  mul_ready2;
wire [1:0] mul_head;
reg [7:0] mul_tag_q [0:(3)-1];
wire [31:0] mul_result_q [0:(3)-1];
wire [31:0] mul_computed;
  wire [31:0] correction_a;
  wire [31:0] correction_b;
wire  grant_new_mul;
reg  div_busy_q;
  reg  div_done_q;
reg [7:0] div_tag_q;
wire [31:0] quotient_q;
  wire [31:0] divisor_q;
  wire [31:0] div_result_q;
wire [32:0] remainder_q;
reg [STEP_W-1:0] step_q;
reg  quotient_negative_q;
  reg  remainder_negative_q;
  reg  remainder_operation_q;
reg [31:0] quotient_next;
reg [32:0] remainder_next;
  reg [32:0] shifted;
wire [31:0] div_a_q;
  wire [31:0] div_b_q;
  wire [31:0] completed_quotient;
  wire [31:0] completed_remainder;
reg  div_signed_q;
reg  cache_valid_q;
  reg  cache_signed_q;
  wire  cache_hit;
wire [31:0] cache_a_q;
  wire [31:0] cache_b_q;
  wire [31:0] cache_quotient_q;
  wire [31:0] cache_remainder_q;
reg  shortcut;
reg [31:0] shortcut_quotient;
  reg [31:0] shortcut_remainder;
  integer leading_steps;
reg  out_valid_q;
  reg  prefer_div_q;
  wire  out_space;
  wire  grant_mul;
  wire  grant_div;
wire [31:0] out_result_q;
reg [7:0] out_tag_q;
wire  request_mul;
  wire  request_div;
  wire  signed_divide;
  wire  a_negative;
  wire  b_negative;
wire [31:0] a_magnitude;
  wire [31:0] b_magnitude;
wire  div_live;
  wire  div_result_live;
reg  pipeline_valid_q;
  reg  pipeline_low_q;
reg [7:0] pipeline_tag_q;
  wire pipeline_live=pipeline_valid_q && !kill_mask[pipeline_tag_q];
  wire pipeline_ready=!pipeline_live || mul_ready0;
  wire pipeline_consume=pipeline_live && mul_ready0;
  wire pipeline_accept=req_valid && req_ready && request_mul;
  wire [31:0] pp00_q,pp01_q,pp10_q,pp11_q,pcorr_a_q,pcorr_b_q;
  wire [17:0] product_middle={2'b0,pp00_q[31:16]}+{2'b0,pp01_q[15:0]}+{2'b0,pp10_q[15:0]};
  wire [31:0] term0=pp11_q,term1={16'b0,pp01_q[31:16]},term2={16'b0,pp10_q[31:16]};
  wire [31:0] term3={30'b0,product_middle[17:16]}+32'd2;
  wire [31:0] term4=~pcorr_a_q,term5=~pcorr_b_q;
  wire [31:0] sum0=term0^term1^term2;
  wire [31:0] carry0=((term0&term1)|(term0&term2)|(term1&term2))<<1;
  wire [31:0] sum1=term3^term4^term5;
  wire [31:0] carry1=((term3&term4)|(term3&term5)|(term4&term5))<<1;
  wire [31:0] sum2=sum0^carry0^sum1;
  wire [31:0] carry2=((sum0&carry0)|(sum0&sum1)|(carry0&sum1))<<1;
  wire [31:0] sum3=sum2^carry2^carry1;
  wire [31:0] carry3=((sum2&carry2)|(sum2&carry1)|(carry2&carry1))<<1;
  wire [31:0] product_high;
  v2_prefix_adder #(.WIDTH(32)) product_final_add (.a(sum3),.b(carry3),.carry_in(1'b0),.sum(product_high),.carry_out());
  always @(posedge clk) begin
    if(rst || kill) begin pipeline_valid_q<=0;pipeline_low_q<=0;pipeline_tag_q<=0;end
    else if(pipeline_ready) begin
      pipeline_valid_q<=pipeline_accept;
      if(pipeline_accept) begin pipeline_low_q<=req_op==OP_MUL;pipeline_tag_q<=req_tag;end
    end
  end
  assign request_mul=req_op>=OP_MUL && req_op<=OP_MULHU;
  assign request_div=req_op>=OP_DIV && req_op<=OP_REMU;
  assign signed_divide=req_op==OP_DIV || req_op==OP_REM;
  assign a_negative=signed_divide && req_a[31];
  assign b_negative=signed_divide && req_b[31];
  wire [31:0] negated_a;
  v2_prefix_adder #(.WIDTH(32)) negate_a (.a(~req_a),.b(32'd0),.carry_in(1'b1),.sum(negated_a),.carry_out());
  assign a_magnitude=a_negative ? negated_a:req_a;
  wire [31:0] negated_b;
  v2_prefix_adder #(.WIDTH(32)) negate_b (.a(~req_b),.b(32'd0),.carry_in(1'b1),.sum(negated_b),.carry_out());
  assign b_magnitude=b_negative ? negated_b:req_b;
  assign div_live=div_busy_q && !kill_mask[div_tag_q];
  assign div_result_live=div_done_q && !kill_mask[div_tag_q];
  assign rsp_valid=out_valid_q && !kill_mask[out_tag_q] && !kill && !rst;
  assign rsp_result=out_result_q;
  assign rsp_tag=out_tag_q;
  assign out_space=!out_valid_q || kill_mask[out_tag_q] || rsp_ready;
  for(stage=0;stage<3;stage=stage+1) begin : g_live
    assign mul_live[stage]=mul_valid_q[stage] && !kill_mask[mul_tag_q[stage]];
    assign mul_remaining[stage]=mul_live[stage] && !(grant_mul && mul_head==narrow_0(stage));
  end
  assign mul_head=mul_live[2] ? 2'd2 : mul_live[1] ? 2'd1 : 2'd0;
  assign grant_div=out_space && div_result_live && (!(|mul_live) || prefer_div_q);
  assign grant_mul=out_space && (|mul_live) && (!div_result_live || !prefer_div_q);
  assign mul_ready2=!mul_remaining[2];
  assign mul_ready1=!mul_remaining[1] || mul_ready2;
  assign mul_ready0=!mul_remaining[0] || mul_ready1;

  assign mul_ready=!rst && !kill && pipeline_ready;
  assign div_ready=!rst && !kill && !div_live && (!div_result_live || grant_div);
  assign req_ready=!kill_mask[req_tag] &&
    ((request_mul && mul_ready) || (request_div && div_ready));

  assign grant_new_mul=out_space && !grant_mul && !grant_div && pipeline_consume;

  assign correction_a=req_a[31] && (req_op==OP_MULH || req_op==OP_MULHSU) ? req_b:32'd0;
  assign correction_b=req_b[31] && req_op==OP_MULH ? req_a:32'd0;
  assign mul_computed=pipeline_low_q ? {product_middle[15:0],pp00_q[15:0]}:product_high;
  assign cache_hit=cache_valid_q && cache_a_q==req_a && cache_b_q==req_b && cache_signed_q==signed_divide;
  assign completed_quotient=quotient_negative_q ? (~quotient_next+32'd1) : quotient_next;
  assign completed_remainder=remainder_negative_q ? (~remainder_next[31:0]+32'd1) : remainder_next[31:0];

  always @* begin
    leading_steps=0;
    begin: loop_2
integer groups;
for(groups=1;groups<DIV_STEPS;groups=groups+1)
      if((a_magnitude>>(32-DIV_STEP_BITS*groups))==0) leading_steps=groups;
end
    shortcut=1;shortcut_quotient=0;shortcut_remainder=0;
    if(req_b==0) begin shortcut_quotient=32'hffffffff;shortcut_remainder=req_a;end
    else if(signed_divide && req_a==32'h80000000 && req_b==32'hffffffff)
      shortcut_quotient=32'h80000000;
    else if(a_magnitude<b_magnitude || a_magnitude==0) shortcut_remainder=req_a;
    else if(b_magnitude==1)
      shortcut_quotient=(a_negative^b_negative) ? (~a_magnitude+32'd1) : a_magnitude;
    else shortcut=0;
  end

  always @* begin
    quotient_next=quotient_q;
    remainder_next=remainder_q;
    shifted=0;
    if(div_live) begin: loop_1
integer bit_step;
for(bit_step=0;bit_step<DIV_STEP_BITS;bit_step=bit_step+1) begin
      shifted={remainder_next[31:0],quotient_next[31]};
      quotient_next={quotient_next[30:0],1'b0};
      if(shifted>={1'b0,divisor_q}) begin
        remainder_next=shifted-{1'b0,divisor_q};
        quotient_next[0]=1'b1;
      end else remainder_next=shifted;
    end
end
  end

  always @(posedge clk) begin
    if(rst || kill) begin
      mul_valid_q<=0;
      begin: loop_0
integer stage;
for(stage=0;stage<3;stage=stage+1) begin
        mul_tag_q[stage]<=0;
      end
end
      div_busy_q<=0;div_done_q<=0;div_tag_q<=0;
      step_q<=0;
      quotient_negative_q<=0;remainder_negative_q<=0;remainder_operation_q<=0;
      div_signed_q<=0;
      cache_valid_q<=0;cache_signed_q<=0;
      out_valid_q<=0;out_tag_q<=0;prefer_div_q<=1;
    end else begin

      if(out_space) begin
        out_valid_q<=grant_div || grant_mul || grant_new_mul;
        if(grant_div) begin
          out_tag_q<=div_tag_q;prefer_div_q<=0;
        end else if(grant_mul) begin
          out_tag_q<=mul_tag_q[mul_head];prefer_div_q<=1;
        end else if(grant_new_mul) begin
          out_tag_q<=pipeline_tag_q;prefer_div_q<=1;
        end
      end

      if(mul_ready2) begin
        mul_valid_q[2]<=mul_remaining[1];
        if(mul_remaining[1]) begin
          mul_tag_q[2]<=mul_tag_q[1];
        end
      end
      if(mul_ready1) begin
        mul_valid_q[1]<=mul_remaining[0];
        if(mul_remaining[0]) begin
          mul_tag_q[1]<=mul_tag_q[0];
        end
      end
      if(mul_ready0) begin
        mul_valid_q[0]<=pipeline_consume && !grant_new_mul;
        if(pipeline_consume && !grant_new_mul) begin
          mul_tag_q[0]<=pipeline_tag_q;
        end
      end

      if(kill_mask[div_tag_q]) begin div_busy_q<=0;div_done_q<=0;end
      if(grant_div) div_done_q<=0;
      if(div_live) begin
        step_q<=step_q+1'b1;
        if(step_q==narrow_1(DIV_STEPS-1)) begin
          div_busy_q<=0;div_done_q<=1;

          cache_valid_q<=1;cache_signed_q<=div_signed_q;
        end
      end
      if(req_valid && req_ready && request_div) begin
        div_tag_q<=req_tag;
        div_signed_q<=signed_divide;
        quotient_negative_q<=a_negative^b_negative;remainder_negative_q<=a_negative;
        remainder_operation_q<=req_op==OP_REM || req_op==OP_REMU;
        div_busy_q<=0;div_done_q<=1;
        if(cache_hit) begin

        end else if(shortcut) begin
          cache_valid_q<=1;cache_signed_q<=signed_divide;
        end else begin
          div_busy_q<=1;div_done_q<=0;step_q<=narrow_1(leading_steps);
        end
      end
    end
  end

  v2_priority_register #(.PORTS(1)) stage_pp00_q (.clk(clk),.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[15:0]}*{16'b0,req_b[15:0]}),.value(pp00_q));
  v2_priority_register #(.PORTS(1)) stage_pp01_q (.clk(clk),.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[15:0]}*{16'b0,req_b[31:16]}),.value(pp01_q));
  v2_priority_register #(.PORTS(1)) stage_pp10_q (.clk(clk),.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[31:16]}*{16'b0,req_b[15:0]}),.value(pp10_q));
  v2_priority_register #(.PORTS(1)) stage_pp11_q (.clk(clk),.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[31:16]}*{16'b0,req_b[31:16]}),.value(pp11_q));
  v2_priority_register #(.PORTS(1)) stage_pcorr_a_q (.clk(clk),.clear(rst || kill),.enable(pipeline_accept),.data(correction_a),.value(pcorr_a_q));
  v2_priority_register #(.PORTS(1)) stage_pcorr_b_q (.clk(clk),.clear(rst || kill),.enable(pipeline_accept),.data(correction_b),.value(pcorr_b_q));

  wire data_clear=rst || kill;
  wire accept_div=req_valid && req_ready && request_div;
  wire finish_div=div_live && step_q==narrow_1(DIV_STEPS-1);
  wire start_div=accept_div && !cache_hit && !shortcut;
  wire save_shortcut=accept_div && !cache_hit && shortcut;
  wire accept_mul=pipeline_consume && !grant_new_mul;
  wire [31:0] fresh_div_result=cache_hit ?
    ((req_op==OP_REM || req_op==OP_REMU) ? cache_remainder_q:cache_quotient_q):
    ((req_op==OP_REM || req_op==OP_REMU) ? shortcut_remainder:shortcut_quotient);
  v2_priority_register #(.WORD_BITS(32),.PORTS(3)) data_out_result_q (.clk(clk),.clear(data_clear),.enable({grant_div,grant_mul,grant_new_mul}),
    .data({div_result_q,mul_result_q[mul_head],mul_computed}),.value(out_result_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_div_result_q (.clk(clk),.clear(data_clear),.enable({accept_div && (cache_hit || shortcut),finish_div}),
    .data({fresh_div_result,remainder_operation_q ? completed_remainder:completed_quotient}),.value(div_result_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_quotient_q (.clk(clk),.clear(data_clear),.enable({start_div,div_live}),
    .data({a_magnitude<<(leading_steps*DIV_STEP_BITS),quotient_next}),.value(quotient_q));
  v2_priority_register #(.WORD_BITS(33),.PORTS(2)) data_remainder_q (.clk(clk),.clear(data_clear),.enable({start_div,div_live}),
    .data({33'd0,remainder_next}),.value(remainder_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_divisor_q (.clk(clk),.clear(data_clear),.enable({start_div}),
    .data({b_magnitude}),.value(divisor_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_div_a_q (.clk(clk),.clear(data_clear),.enable({accept_div}),
    .data({req_a}),.value(div_a_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_div_b_q (.clk(clk),.clear(data_clear),.enable({accept_div}),
    .data({req_b}),.value(div_b_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_a_q (.clk(clk),.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({req_a,div_a_q}),.value(cache_a_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_b_q (.clk(clk),.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({req_b,div_b_q}),.value(cache_b_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_quotient_q (.clk(clk),.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({shortcut_quotient,completed_quotient}),.value(cache_quotient_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_remainder_q (.clk(clk),.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({shortcut_remainder,completed_remainder}),.value(cache_remainder_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_mul_result_0 (.clk(clk),.clear(data_clear),.enable({mul_ready0 && accept_mul}),
    .data({mul_computed}),.value(mul_result_q[0]));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_mul_result_1 (.clk(clk),.clear(data_clear),.enable({mul_ready1 && mul_remaining[0]}),
    .data({mul_result_q[0]}),.value(mul_result_q[1]));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_mul_result_2 (.clk(clk),.clear(data_clear),.enable({mul_ready2 && mul_remaining[1]}),
    .data({mul_result_q[1]}),.value(mul_result_q[2]));

  initial begin
    if(DIV_STEP_BITS!=2 && DIV_STEP_BITS!=4) $fatal(1,"DIV_STEP_BITS must be 2 or 4");
  end
endmodule



(* keep_hierarchy=1 *)
module v2_arch_word #(
  parameter integer REGISTER=1, CONTROL_TREE=0
)(
  input wire clk,rst,
  input wire [1:0] commit_valid,
  input wire [9:0] commit_rd,
  input wire [63:0] commit_values,
  output wire [31:0] value
);
function automatic [5-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  generate
    if(CONTROL_TREE) begin: distributed
      wire [1:0] write_enable;
      assign write_enable[0]=commit_valid[0] && commit_rd[4:0]==narrow_0(REGISTER);
      assign write_enable[1]=commit_valid[1] && commit_rd[9:5]==narrow_0(REGISTER);
      v2_priority_register #(.PORTS(2)) data_word (.clk(clk),.clear(rst || REGISTER==0),.enable(write_enable),.data(commit_values),.value(value));
    end else begin: direct
reg [31:0] stored;
      assign value=stored;
      always @(posedge clk) begin
        if(rst || REGISTER==0) stored<=0;
        else begin
          if(commit_valid[0] && commit_rd[4:0]==narrow_0(REGISTER)) stored<=commit_values[31:0];
          if(commit_valid[1] && commit_rd[9:5]==narrow_0(REGISTER)) stored<=commit_values[63:32];
        end
      end
    end
  endgenerate
endmodule



(* keep_hierarchy=1 *)
module v2_cache_read #(
  parameter integer ENTRIES=64,WORD_BITS=32,INDEX_BITS=$clog2(ENTRIES),INDEX_GROUP=0
)(
  input wire [INDEX_BITS-1:0] index,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  v2_read #(.ENTRIES(ENTRIES),.WORD_BITS(WORD_BITS),.INDEX_BITS(INDEX_BITS),.INDEX_GROUP(INDEX_GROUP)) read_word (
    .index(index),.words(words),.value(value));
endmodule



module v2_dcache #(
  parameter integer CACHE_BYTES=2048, LINE_BYTES=64, MSHRS=4, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CREDITS=64, RAM_BYTES=268435456,
  parameter integer LT=$clog2(LOAD_SLOTS), ST=$clog2(STORE_SLOTS), CACHE_TREE=0
)(
  input wire  clk,
  input wire  rst,
  input wire  load_valid,
  input wire [31:0] load_address,
  input wire [LT-1:0] load_tag,
  output reg  load_ready,
  output wire  load_hit,
  output wire [31:0] load_data,
  output wire  result_valid,
  input wire  result_ready,
  output reg [LT-1:0] result_tag,
  output wire [31:0] result_data,
  output reg  result_error,
  input wire  store_valid,
  output reg  store_ready,
  input wire [31:0] store_address,
  input wire [31:0] store_data,
  input wire [3:0] store_mask,
  input wire [ST-1:0] store_tag,
  output wire  store_done,
  output wire  store_error,
  output wire [ST-1:0] store_done_tag,
  output wire  mem_req_valid,
  output wire  mem_req_write,
  input wire  mem_req_ready,
  output wire [31:0] mem_req_addr,
  output wire [31:0] mem_req_data,
  output wire [3:0] mem_req_mask,
  input wire  mem_rsp_valid,
  output wire  mem_rsp_ready,
  input wire [31:0] mem_rsp_data,
  input wire  mem_rsp_error,
  output reg  idle,
  output reg [63:0] miss_count
);
genvar bank,byte_id,line,m,row,set_index,w,way;
function automatic [1-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction

function automatic signed [31:0] narrow_1;
  input [63:0] value;
  begin narrow_1=value; end
endfunction

function automatic [LT-1:0] narrow_2;
  input [63:0] value;
  begin narrow_2=value; end
endfunction

function automatic [MB-1:0] narrow_3;
  input [63:0] value;
  begin narrow_3=value; end
endfunction

function automatic [WW+1-1:0] narrow_4;
  input [63:0] value;
  begin narrow_4=value; end
endfunction

function automatic [BANK_BITS-1:0] narrow_5;
  input [63:0] value;
  begin narrow_5=value; end
endfunction

function automatic [BANK_WORD_BITS-1:0] narrow_6;
  input [63:0] value;
  begin narrow_6=value; end
endfunction

function automatic [LB-1:0] narrow_7;
  input [63:0] value;
  begin narrow_7=value; end
endfunction

function automatic [SB-1:0] narrow_8;
  input [63:0] value;
  begin narrow_8=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer OFFSET=$clog2(LINE_BYTES), WORDS=LINE_BYTES/4, WW=OFFSET-2;
localparam integer SETS=CACHE_BYTES/(2*LINE_BYTES), SB=$clog2(SETS), LB=SB+1, LINES=2*SETS;
localparam integer RB=$clog2(RAM_BYTES), TB=RB-SB-OFFSET, MB=$clog2(MSHRS);
localparam integer FW=$clog2(CREDITS);
localparam integer WRITE_BANKS=CACHE_BYTES/4>=128 ? 8:2;
localparam integer BANK_WORDS=CACHE_BYTES/(4*WRITE_BANKS);
localparam integer BANK_BITS=$clog2(WRITE_BANKS), BANK_WORD_BITS=$clog2(BANK_WORDS);
localparam integer PENDING_BITS=37+BANK_WORD_BITS;
localparam integer WRITE_GROUP_WORDS=CACHE_TREE ? 16:BANK_WORDS;
localparam integer WRITE_GROUPS=(BANK_WORDS+WRITE_GROUP_WORDS-1)/WRITE_GROUP_WORDS;
localparam integer WRITE_CONTROL_BITS=36+BANK_WORD_BITS;
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
localparam integer MISS_T_FAILED_LSB=0, MISS_T_FAILED_WIDTH=((WORDS-1)-(0)+1);
localparam integer MISS_T_RETURNED_LSB=MISS_T_FAILED_LSB+MISS_T_FAILED_WIDTH, MISS_T_RETURNED_WIDTH=((WW)-(0)+1);
localparam integer MISS_T_ISSUED_LSB=MISS_T_RETURNED_LSB+MISS_T_RETURNED_WIDTH, MISS_T_ISSUED_WIDTH=((WW)-(0)+1);
localparam integer MISS_T_CRITICAL_LSB=MISS_T_ISSUED_LSB+MISS_T_ISSUED_WIDTH, MISS_T_CRITICAL_WIDTH=((WW-1)-(0)+1);
localparam integer MISS_T_ADDRESS_LSB=MISS_T_CRITICAL_LSB+MISS_T_CRITICAL_WIDTH, MISS_T_ADDRESS_WIDTH=((RB-OFFSET-1)-(0)+1);
localparam integer MISS_T_PHYSICAL_LSB=MISS_T_ADDRESS_LSB+MISS_T_ADDRESS_WIDTH, MISS_T_PHYSICAL_WIDTH=((LB-1)-(0)+1);
localparam integer MISS_T_VALID_LSB=MISS_T_PHYSICAL_LSB+MISS_T_PHYSICAL_WIDTH, MISS_T_VALID_WIDTH=1;
localparam integer MISS_T_WIDTH=MISS_T_VALID_LSB+MISS_T_VALID_WIDTH;
localparam integer WAITER_T_WORD_INDEX_LSB=0, WAITER_T_WORD_INDEX_WIDTH=((WW-1)-(0)+1);
localparam integer WAITER_T_PHYSICAL_LSB=WAITER_T_WORD_INDEX_LSB+WAITER_T_WORD_INDEX_WIDTH, WAITER_T_PHYSICAL_WIDTH=((LB-1)-(0)+1);
localparam integer WAITER_T_ERROR_LSB=WAITER_T_PHYSICAL_LSB+WAITER_T_PHYSICAL_WIDTH, WAITER_T_ERROR_WIDTH=1;
localparam integer WAITER_T_VALID_LSB=WAITER_T_ERROR_LSB+WAITER_T_ERROR_WIDTH, WAITER_T_VALID_WIDTH=1;
localparam integer WAITER_T_WIDTH=WAITER_T_VALID_LSB+WAITER_T_VALID_WIDTH;
localparam integer OWNER_T_WORD_INDEX_LSB=0, OWNER_T_WORD_INDEX_WIDTH=((WW-1)-(0)+1);
localparam integer OWNER_T_SLOT_LSB=OWNER_T_WORD_INDEX_LSB+OWNER_T_WORD_INDEX_WIDTH, OWNER_T_SLOT_WIDTH=((MB-1)-(0)+1);
localparam integer OWNER_T_TAG_LSB=OWNER_T_SLOT_LSB+OWNER_T_SLOT_WIDTH, OWNER_T_TAG_WIDTH=((ST-1)-(0)+1);
localparam integer OWNER_T_WRITE_LSB=OWNER_T_TAG_LSB+OWNER_T_TAG_WIDTH, OWNER_T_WRITE_WIDTH=1;
localparam integer OWNER_T_WIDTH=OWNER_T_WRITE_LSB+OWNER_T_WRITE_WIDTH;
wire [WRITE_CONTROL_BITS*WRITE_GROUPS-1:0] distributed_writes [0:(WRITE_BANKS)-1];
reg [MISS_T_WIDTH-1:0] misses [0:(MSHRS)-1];
reg [WAITER_T_WIDTH-1:0] waiters [0:(LOAD_SLOTS)-1];
reg [OWNER_T_WIDTH-1:0] owners [0:(CREDITS)-1];
  reg [OWNER_T_WIDTH-1:0] out_owner;
reg [FW-1:0] head;
  reg [FW-1:0] tail;
reg [FW:0] count;
reg  out_valid;
reg [31:0] out_address;
  reg [31:0] out_data;
reg [3:0] out_mask;
  (* ram_style="registers" *) reg [31:0] data [0:(CACHE_BYTES/4)-1];
reg [TB-1:0] tags [0:(LINES)-1];
reg [LINES-1:0] tag_valid;
reg [WORDS-1:0] word_valid [0:(LINES)-1];
  wire [WORDS-1:0] word_valid_next [LINES];
reg [WAITER_T_WIDTH-1:0] waiter_next [0:(LOAD_SLOTS)-1];
reg  return_valid_next;
  reg  return_error_next;
reg  return_pending;
reg [LT-1:0] return_tag_next;
reg [LB+WW-1:0] return_address_next;
  reg [LB+WW-1:0] return_address;
reg [SETS-1:0] replacement;
reg [LINES-1:0] locked;
wire [SB-1:0] load_set;
  wire [SB-1:0] store_set;
wire [LB-1:0] load_line;
  wire [LB-1:0] store_line;
  reg [LB-1:0] selected_line;
wire  load_tag_hit;
  wire  store_tag_hit;
wire [1:0] load_matches;
  wire [1:0] store_matches;
reg  victim_valid;
  reg  free_valid;
  reg  merge_valid;
  reg  allocate;
reg [MB-1:0] free_slot;
  reg [MB-1:0] merge_slot;
  reg [MB-1:0] selected_slot;
  reg [MB-1:0] send_slot;
reg  send_valid;
  reg  send_fill;
  reg  load_accept;
  reg  store_accept;
  wire  request_fire;
  wire  response_fire;
  wire  out_space;
reg [MB-1:0] round_robin;
reg [WW-1:0] send_word;
wire [LB-1:0] response_line;
wire [WW-1:0] response_word;
wire  fill_fire;
  reg  data_write_valid;
reg [LB+WW-1:0] data_write_address;
  reg [LB+WW-1:0] data_read_address;
reg [31:0] data_write_value;
reg [3:0] data_write_mask;
reg [WRITE_BANKS-1:0] pending_valid;
reg [BANK_WORD_BITS-1:0] pending_address [0:(WRITE_BANKS)-1];
reg [31:0] pending_data [0:(WRITE_BANKS)-1];
reg [3:0] pending_mask [0:(WRITE_BANKS)-1];
  wire [WRITE_BANKS*PENDING_BITS-1:0] pending_words;
  wire [PENDING_BITS-1:0] read_pending;
reg [MSHRS-1:0] release_miss;
  assign load_set=load_address[SB+OFFSET-1:OFFSET];
  assign store_set=store_address[SB+OFFSET-1:OFFSET];
  for(way=0;way<2;way=way+1) begin: tag_read

    assign store_matches[way]=tag_valid[{store_set,narrow_0(way)}] && tags[{store_set,narrow_0(way)}]==store_address[RB-1:SB+OFFSET];
  end
  assign load_tag_hit=|load_matches;
  assign store_tag_hit=|store_matches;
  assign load_line={load_set,!load_matches[0]};
  assign store_line={store_set,!store_matches[0]};
  wire [LINES*TB-1:0] lookup_tags;
  wire [LINES*WORDS-1:0] lookup_words;
  for(line=0;line<LINES;line=line+1) begin: lookup_payload
    assign lookup_tags[line*TB+:TB]=tags[line];
    assign lookup_words[line*WORDS+:WORDS]=word_valid[line];
  end
  v2_cache_lookup #(.SETS(SETS),.TAG_BITS(TB),.WORDS(WORDS)) lookup (
    .address(load_address[RB-1:2]),.tags(lookup_tags),.valid(tag_valid),.word_valid(lookup_words),
    .match_bits(load_matches),.hit(load_hit));

  assign mem_req_valid=!rst && out_valid && narrow_1(count)<CREDITS;
  assign mem_req_write=out_owner[OWNER_T_WRITE_LSB+:OWNER_T_WRITE_WIDTH];
  assign mem_req_addr=out_address;
  assign mem_req_data=out_data;
  assign mem_req_mask=out_mask;
  assign request_fire=mem_req_valid && mem_req_ready;
  assign mem_rsp_ready=1;
  assign response_fire=mem_rsp_valid && count!=0;
  assign response_line=misses[owners[head][OWNER_T_SLOT_LSB+:OWNER_T_SLOT_WIDTH]][MISS_T_PHYSICAL_LSB+:MISS_T_PHYSICAL_WIDTH];
  assign response_word=owners[head][OWNER_T_WORD_INDEX_LSB+:OWNER_T_WORD_INDEX_WIDTH];
  assign fill_fire=response_fire && !owners[head][OWNER_T_WRITE_LSB+:OWNER_T_WRITE_WIDTH];
  assign store_done=response_fire && owners[head][OWNER_T_WRITE_LSB+:OWNER_T_WRITE_WIDTH];
  assign store_done_tag=owners[head][OWNER_T_TAG_LSB+:OWNER_T_TAG_WIDTH];
  assign store_error=store_done && mem_rsp_error;
  assign out_space=!out_valid || request_fire;

  always @* begin: returning_load
    return_valid_next=0;return_tag_next=0;return_error_next=0;return_address_next=0;
    begin: loop_5
integer w;
for(w=0;w<LOAD_SLOTS;w=w+1)
      if(!return_valid_next && waiter_next[w][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH] &&
          (waiter_next[w][WAITER_T_ERROR_LSB+:WAITER_T_ERROR_WIDTH] || word_valid_next[waiter_next[w][WAITER_T_PHYSICAL_LSB+:WAITER_T_PHYSICAL_WIDTH]][waiter_next[w][WAITER_T_WORD_INDEX_LSB+:WAITER_T_WORD_INDEX_WIDTH]])) begin
        return_valid_next=1;return_tag_next=narrow_2(w);return_error_next=waiter_next[w][WAITER_T_ERROR_LSB+:WAITER_T_ERROR_WIDTH];
        return_address_next={waiter_next[w][WAITER_T_PHYSICAL_LSB+:WAITER_T_PHYSICAL_WIDTH],waiter_next[w][WAITER_T_WORD_INDEX_LSB+:WAITER_T_WORD_INDEX_WIDTH]};
      end
end
  end
  always @(posedge clk) begin
    if(rst) begin return_pending<=0;result_tag<=0;result_error<=0;return_address<=0;end
    else begin
      return_pending<=return_valid_next;result_tag<=return_tag_next;result_error<=return_error_next;
      return_address<=return_address_next;
    end
  end
  assign result_valid=!rst && return_pending;
  always @* begin
    locked=0;
    free_valid=0;free_slot=0;merge_valid=0;merge_slot=0;
    release_miss=0;
    begin: loop_4
integer m;
for(m=0;m<MSHRS;m=m+1) begin
      if(misses[m][MISS_T_VALID_LSB+:MISS_T_VALID_WIDTH]) begin
        locked[misses[m][MISS_T_PHYSICAL_LSB+:MISS_T_PHYSICAL_WIDTH]]=1;
        if(load_tag_hit && misses[m][MISS_T_PHYSICAL_LSB+:MISS_T_PHYSICAL_WIDTH]==load_line) begin merge_valid=1;merge_slot=narrow_3(m);end
        release_miss[m]=misses[m][MISS_T_RETURNED_LSB+:MISS_T_RETURNED_WIDTH]==narrow_4(WORDS);
        begin: loop_3
integer w;
for(w=0;w<LOAD_SLOTS;w=w+1)
          if(waiters[w][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH] && waiters[w][WAITER_T_PHYSICAL_LSB+:WAITER_T_PHYSICAL_WIDTH]==misses[m][MISS_T_PHYSICAL_LSB+:MISS_T_PHYSICAL_WIDTH]) release_miss[m]=0;
end
      end else if(!free_valid) begin free_valid=1;free_slot=narrow_3(m);end
    end
end
    selected_line=load_line;victim_valid=load_tag_hit;
    if(!load_tag_hit) begin
      if(!tag_valid[{load_set,1'b0}] && !locked[{load_set,1'b0}]) begin selected_line={load_set,1'b0};victim_valid=1;end
      else if(!tag_valid[{load_set,1'b1}] && !locked[{load_set,1'b1}]) begin selected_line={load_set,1'b1};victim_valid=1;end
      else if(!locked[{load_set,replacement[load_set]}]) begin selected_line={load_set,replacement[load_set]};victim_valid=1;end
      else if(!locked[{load_set,!replacement[load_set]}]) begin selected_line={load_set,!replacement[load_set]};victim_valid=1;end
    end
    selected_slot=merge_valid ? merge_slot:free_slot;
    load_ready=!rst && !result_valid && (load_hit || (!waiters[load_tag][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH] &&
                (merge_valid || (free_valid && victim_valid))));
    load_accept=load_valid && load_ready;
    allocate=load_accept && !load_hit && !merge_valid;
    store_ready=!rst && out_space && narrow_1(count)<CREDITS-1 && !fill_fire &&
                (!store_tag_hit || !locked[store_line]) &&
                !(allocate && store_tag_hit && selected_line==store_line);
    store_accept=store_valid && store_ready;
    send_valid=0;send_slot=0;
    begin: loop_2
integer offset;
for(offset=0;offset<MSHRS;offset=offset+1)
      if(!send_valid && misses[narrow_3(round_robin+narrow_3(offset))][MISS_T_VALID_LSB+:MISS_T_VALID_WIDTH] &&
           misses[narrow_3(round_robin+narrow_3(offset))][MISS_T_ISSUED_LSB+:MISS_T_ISSUED_WIDTH]<narrow_4(WORDS)) begin
        send_valid=1;send_slot=narrow_3(round_robin+narrow_3(offset));
      end
end
    send_fill=!rst && out_space && narrow_1(count)<CREDITS-1 && !store_accept && send_valid;
    send_word=misses[send_slot][MISS_T_CRITICAL_LSB+:MISS_T_CRITICAL_WIDTH]+misses[send_slot][MISS_T_ISSUED_LSB+(WW-1):MISS_T_ISSUED_LSB+(0)];

    data_write_valid=(fill_fire && !mem_rsp_error) || (!fill_fire && store_accept && store_tag_hit);
    data_write_address=fill_fire ? {response_line,response_word}:{store_line,store_address[OFFSET-1:2]};
    data_write_value=fill_fire ? mem_rsp_data:store_data;
    data_write_mask=fill_fire ? 4'b1111:store_mask;
    data_read_address=result_valid ? return_address:
                                     {load_line,load_address[OFFSET-1:2]};
  end
  always @* begin: quiescent_state
    idle=!out_valid && count==0;
    begin: loop_1
integer m;
for(m=0;m<MSHRS;m=m+1) if(misses[m][MISS_T_VALID_LSB+:MISS_T_VALID_WIDTH]) idle=0;
end
    begin: loop_0
integer w;
for(w=0;w<LOAD_SLOTS;w=w+1) if(waiters[w][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH]) idle=0;
end
  end

  wire [(CACHE_BYTES/4)*32-1:0] data_words;
  wire [WRITE_BANKS*32-1:0] bank_words;
  wire [31:0] read_word;

  for(bank=0;bank<WRITE_BANKS;bank=bank+1) begin: write_stages
    v2_cache_read #(.ENTRIES(BANK_WORDS),.INDEX_GROUP(CACHE_TREE ? 16:0)) read_bank (
      .index(data_read_address[BANK_WORD_BITS-1:0]),
      .words(data_words[bank*BANK_WORDS*32+:BANK_WORDS*32]),.value(bank_words[bank*32+:32]));
    wire select_bank=data_write_address[LB+WW-1:BANK_WORD_BITS]==narrow_5(bank);
    wire accept=data_write_valid && select_bank;
    always @(posedge clk) begin
      if(rst) pending_valid[bank]<=0;
      else begin
        pending_valid[bank]<=accept;
        if(select_bank) begin
          pending_address[bank]<=data_write_address[BANK_WORD_BITS-1:0];
          pending_data[bank]<=data_write_value;
          pending_mask[bank]<=data_write_mask;
        end
      end
    end
    assign pending_words[bank*PENDING_BITS+:PENDING_BITS]=
      {pending_valid[bank],pending_address[bank],pending_mask[bank],pending_data[bank]};
    v2_distribution #(.WIDTH(WRITE_CONTROL_BITS),.LEAVES(WRITE_GROUPS)) write_tree (
      .data_in({pending_mask[bank] & {4{pending_valid[bank]}},pending_address[bank],pending_data[bank]}),
      .data_out(distributed_writes[bank]));
  end
  for(row=0;row<CACHE_BYTES/4;row=row+1) begin: data_rows
    wire [WRITE_CONTROL_BITS-1:0] local_write=
      distributed_writes[row/BANK_WORDS][((row%BANK_WORDS)/WRITE_GROUP_WORDS)*WRITE_CONTROL_BITS+:WRITE_CONTROL_BITS];
    assign data_words[row*32+:32]=data[row];
    for(byte_id=0;byte_id<4;byte_id=byte_id+1) begin: byte_write
      always @(posedge clk)
        if(!rst && local_write[32+BANK_WORD_BITS+byte_id] &&
           local_write[32+:BANK_WORD_BITS]==narrow_6(row%BANK_WORDS))
          data[row][byte_id*8+:8]<=local_write[byte_id*8+:8];
    end
  end
  v2_cache_read #(.ENTRIES(WRITE_BANKS)) read_data (
    .index(data_read_address[LB+WW-1:BANK_WORD_BITS]),.words(bank_words),.value(read_word));
  v2_read #(.ENTRIES(WRITE_BANKS),.WORD_BITS(PENDING_BITS)) read_write_stage (
    .index(data_read_address[LB+WW-1:BANK_WORD_BITS]),.words(pending_words),.value(read_pending));
  for(byte_id=0;byte_id<4;byte_id=byte_id+1) begin: pending_forward
    wire bypass=read_pending[PENDING_BITS-1] && read_pending[32+byte_id] &&
                read_pending[36+:BANK_WORD_BITS]==data_read_address[BANK_WORD_BITS-1:0];
    assign load_data[byte_id*8+:8]=bypass ? read_pending[byte_id*8+:8]:read_word[byte_id*8+:8];
  end
  assign result_data=load_data;
  always @(posedge clk) begin
    if(rst) begin
      head<=0;tail<=0;count<=0;out_valid<=0;out_owner<=0;
      out_address<=0;out_data<=0;out_mask<=0;round_robin<=0;miss_count<=0;
    end else begin
      case({request_fire,response_fire})
        2'b10:count<=count+1;
        2'b01:count<=count-1;
        default:;
      endcase
      if(request_fire) begin owners[tail]<=out_owner;tail<=tail+1'b1;out_valid<=0;end
      if(response_fire) head<=head+1'b1;
      if(store_accept) begin
        out_valid<=1;out_owner<=0;out_owner[OWNER_T_WRITE_LSB+:OWNER_T_WRITE_WIDTH]<=1;out_owner[OWNER_T_TAG_LSB+:OWNER_T_TAG_WIDTH]<=store_tag;
        out_address<=store_address;out_data<=store_data;out_mask<=store_mask;
      end else if(send_fill) begin
        out_valid<=1;out_owner<=0;out_owner[OWNER_T_SLOT_LSB+:OWNER_T_SLOT_WIDTH]<=send_slot;out_owner[OWNER_T_WORD_INDEX_LSB+:OWNER_T_WORD_INDEX_WIDTH]<=send_word;
        out_address<={{(32-RB){1'b0}},misses[send_slot][MISS_T_ADDRESS_LSB+:MISS_T_ADDRESS_WIDTH],send_word,2'b0};
        out_data<=0;out_mask<=0;round_robin<=send_slot+1'b1;
      end
      if(allocate && !load_tag_hit) miss_count<=miss_count+1;
    end
  end
  for(m=0;m<MSHRS;m=m+1) begin: miss_rows
    always @(posedge clk) begin
      if(rst) misses[m]<=0;
      else begin
        if(release_miss[m]) misses[m][MISS_T_VALID_LSB+:MISS_T_VALID_WIDTH]<=0;
        if(send_fill && send_slot==narrow_3(m)) misses[m][MISS_T_ISSUED_LSB+:MISS_T_ISSUED_WIDTH]<=misses[m][MISS_T_ISSUED_LSB+:MISS_T_ISSUED_WIDTH]+1;
        if(fill_fire && owners[head][OWNER_T_SLOT_LSB+:OWNER_T_SLOT_WIDTH]==narrow_3(m)) begin
          misses[m][MISS_T_RETURNED_LSB+:MISS_T_RETURNED_WIDTH]<=misses[m][MISS_T_RETURNED_LSB+:MISS_T_RETURNED_WIDTH]+1;
          if(mem_rsp_error) misses[m][MISS_T_FAILED_LSB+(response_word)]<=1;
        end
        if(allocate && free_slot==narrow_3(m)) begin
          misses[m][MISS_T_VALID_LSB+:MISS_T_VALID_WIDTH]<=1;misses[m][MISS_T_PHYSICAL_LSB+:MISS_T_PHYSICAL_WIDTH]<=selected_line;
          misses[m][MISS_T_ADDRESS_LSB+:MISS_T_ADDRESS_WIDTH]<=load_address[RB-1:OFFSET];misses[m][MISS_T_CRITICAL_LSB+:MISS_T_CRITICAL_WIDTH]<=load_address[OFFSET-1:2];
          misses[m][MISS_T_ISSUED_LSB+:MISS_T_ISSUED_WIDTH]<=0;misses[m][MISS_T_RETURNED_LSB+:MISS_T_RETURNED_WIDTH]<=0;misses[m][MISS_T_FAILED_LSB+:MISS_T_FAILED_WIDTH]<=0;
        end
      end
    end
  end
  for(w=0;w<LOAD_SLOTS;w=w+1) begin: waiter_rows
    always @* begin
        waiter_next[w]=waiters[w];
        if(result_valid && result_ready && result_tag==narrow_2(w)) waiter_next[w][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH]=0;
        if(fill_fire && mem_rsp_error && waiters[w][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH] && waiters[w][WAITER_T_PHYSICAL_LSB+:WAITER_T_PHYSICAL_WIDTH]==response_line &&
            waiters[w][WAITER_T_WORD_INDEX_LSB+:WAITER_T_WORD_INDEX_WIDTH]==response_word) waiter_next[w][WAITER_T_ERROR_LSB+:WAITER_T_ERROR_WIDTH]=1;
        if(load_accept && !load_hit && load_tag==narrow_2(w)) begin
          waiter_next[w][WAITER_T_VALID_LSB+:WAITER_T_VALID_WIDTH]=1;waiter_next[w][WAITER_T_PHYSICAL_LSB+:WAITER_T_PHYSICAL_WIDTH]=selected_line;waiter_next[w][WAITER_T_WORD_INDEX_LSB+:WAITER_T_WORD_INDEX_WIDTH]=load_address[OFFSET-1:2];
          waiter_next[w][WAITER_T_ERROR_LSB+:WAITER_T_ERROR_WIDTH]=(merge_valid && misses[merge_slot][MISS_T_FAILED_LSB+(load_address[OFFSET-1:2])]) ||
            (fill_fire && mem_rsp_error && response_line==selected_line && response_word==load_address[OFFSET-1:2]);
        end
    end
    always @(posedge clk) begin
      if(rst) waiters[w]<=0;
      else waiters[w]<=waiter_next[w];
    end
  end
  for(line=0;line<LINES;line=line+1) begin: metadata
reg [WORDS-1:0] valid_next;
    assign word_valid_next[line]=valid_next;
    always @* begin
      valid_next=word_valid[line];
      if(allocate && !load_tag_hit && selected_line==narrow_7(line)) valid_next=0;
      if(fill_fire && response_line==narrow_7(line)) valid_next[response_word]=!mem_rsp_error;
      if(store_accept && store_tag_hit && store_line==narrow_7(line) && store_mask==15)
        valid_next[store_address[OFFSET-1:2]]=1;
    end
    always @(posedge clk) begin
      if(rst) begin tag_valid[line]<=0;word_valid[line]<=0;end
      else begin
        word_valid[line]<=valid_next;
        if(allocate && !load_tag_hit && selected_line==narrow_7(line)) begin
          tag_valid[line]<=1;tags[line]<=load_address[RB-1:SB+OFFSET];
        end
      end
    end
  end
  for(set_index=0;set_index<SETS;set_index=set_index+1) begin: lru
    always @(posedge clk) begin
      if(rst) replacement[set_index]<=0;
      else begin
        if(load_accept && load_set==narrow_8(set_index)) replacement[set_index]<=!selected_line[0];
        if(store_accept && store_tag_hit && store_set==narrow_8(set_index)) replacement[set_index]<=!store_line[0];
      end
    end
  end
  initial begin
    if(LINE_BYTES<16 || (LINE_BYTES&(LINE_BYTES-1))!=0 || CACHE_BYTES<4*LINE_BYTES || (CACHE_BYTES&(CACHE_BYTES-1))!=0 || MSHRS<2 || (MSHRS&(MSHRS-1))!=0 ||
       CREDITS<2 || (CREDITS&(CREDITS-1))!=0) $fatal(1,"invalid cache dimensions");
  end
endmodule



module v2_distribution #(
  parameter integer WIDTH=1, LEAVES=2
)(
  input wire [WIDTH-1:0] data_in,
  output wire [WIDTH*LEAVES-1:0] data_out
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer LEFT=LEAVES/2, RIGHT=LEAVES-LEFT;
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  generate
    if(LEAVES==1) begin: leaf
      assign data_out=data_in;
    end else begin: branch

      wire [WIDTH-1:0] inverted_left,inverted_right,left_value,right_value;
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) left_first (
        .data_in(data_in),.data_out(inverted_left));
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) left_second (
        .data_in(inverted_left),.data_out(left_value));
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) right_first (
        .data_in(data_in),.data_out(inverted_right));
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) right_second (
        .data_in(inverted_right),.data_out(right_value));
      v2_distribution #(.WIDTH(WIDTH),.LEAVES(LEFT)) left_tree (
        .data_in(left_value),.data_out(data_out[0+:WIDTH*LEFT]));
      v2_distribution #(.WIDTH(WIDTH),.LEAVES(RIGHT)) right_tree (
        .data_in(right_value),.data_out(data_out[WIDTH*LEFT+:WIDTH*RIGHT]));
    end
  endgenerate
endmodule


(* keep_hierarchy=1 *)
module v2_distribution_inverter #(parameter integer WIDTH=1)(
  input wire [WIDTH-1:0] data_in,
  output wire [WIDTH-1:0] data_out
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  assign data_out=~data_in;
endmodule

module v2_frontend #(
  parameter integer CACHE_BYTES=1024, QUEUE_ENTRIES=8, BHT_ENTRIES=256, BTB_ENTRIES=32,
  parameter integer LOCAL_HISTORY_BITS=1, HISTORY_ENTRIES=64,
  parameter integer RAM_BYTES=268435456, HB=(LOCAL_HISTORY_BITS>0 ? LOCAL_HISTORY_BITS:1), CACHE_TREE=0
)(
  input wire  clk,
  input wire  rst,
  input wire  stop,
  input wire  redirect,
  input wire [31:0] redirect_pc,
  input wire [1:0] pop_count,
  output reg [1:0] packet_valid,
  output reg [63:0] packet_pc,
  output reg [63:0] packet_inst,
  output reg [63:0] packet_prediction,
  output reg [7:0] packet_fault,
  output reg [1:0] packet_inst_valid,
  output reg [2*HB-1:0] packet_history,
  input wire [HB-1:0] train_history,
  input wire  train_valid,
  input wire  train_taken,
  input wire [5:0] train_op,
  input wire [31:0] train_pc,
  input wire [31:0] train_target,
  output wire  mem_req_valid,
  input wire  mem_req_ready,
  output wire [31:0] mem_req_addr,
  input wire  mem_rsp_valid,
  output wire  mem_rsp_ready,
  input wire [31:0] mem_rsp_data,
  input wire  mem_rsp_error,
  output wire  idle,
  output reg [63:0] miss_count
);
genvar h,p,row;
function automatic [BW-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction

function automatic [LB-1:0] narrow_1;
  input [63:0] value;
  begin narrow_1=value; end
endfunction

function automatic [QW-1:0] narrow_2;
  input [63:0] value;
  begin narrow_2=value; end
endfunction

function automatic [TW-1:0] narrow_3;
  input [63:0] value;
  begin narrow_3=value; end
endfunction

function automatic signed [31:0] narrow_4;
  input [63:0] value;
  begin narrow_4=value; end
endfunction

function automatic [QW+1-1:0] narrow_5;
  input [63:0] value;
  begin narrow_5=value; end
endfunction

function automatic [CB-3-1:0] narrow_6;
  input [63:0] value;
  begin narrow_6=value; end
endfunction

function automatic [HI-1:0] narrow_7;
  input [63:0] value;
  begin narrow_7=value; end
endfunction

function automatic [HB-1:0] narrow_8;
  input [63:0] value;
  begin narrow_8=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer CB=$clog2(CACHE_BYTES), LINES=CACHE_BYTES/32, LB=$clog2(LINES);
localparam integer QW=$clog2(QUEUE_ENTRIES), BW=$clog2(BHT_ENTRIES), TW=$clog2(BTB_ENTRIES);
localparam integer PACKET_BITS=PACKET_T_WIDTH;
localparam integer HI=$clog2(HISTORY_ENTRIES);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
localparam integer PACKET_T_PRED_LSB=0, PACKET_T_PRED_WIDTH=32;
localparam integer PACKET_T_INST_LSB=PACKET_T_PRED_LSB+PACKET_T_PRED_WIDTH, PACKET_T_INST_WIDTH=32;
localparam integer PACKET_T_PC_LSB=PACKET_T_INST_LSB+PACKET_T_INST_WIDTH, PACKET_T_PC_WIDTH=32;
localparam integer PACKET_T_HISTORY_LSB=PACKET_T_PC_LSB+PACKET_T_PC_WIDTH, PACKET_T_HISTORY_WIDTH=((HB-1)-(0)+1);
localparam integer PACKET_T_IV_LSB=PACKET_T_HISTORY_LSB+PACKET_T_HISTORY_WIDTH, PACKET_T_IV_WIDTH=1;
localparam integer PACKET_T_FAULT_LSB=PACKET_T_IV_LSB+PACKET_T_IV_WIDTH, PACKET_T_FAULT_WIDTH=4;
localparam integer PACKET_T_WIDTH=PACKET_T_FAULT_LSB+PACKET_T_FAULT_WIDTH;
reg [PACKET_T_WIDTH-1:0] fifo [0:(QUEUE_ENTRIES)-1];
  reg [PACKET_T_WIDTH-1:0] incoming [0:(2)-1];
  wire [PACKET_T_WIDTH-1:0] read_packet [0:(2)-1];
  wire [QUEUE_ENTRIES*PACKET_BITS-1:0] queue_words;
  wire [(CACHE_BYTES/8)*64-1:0] even_words,odd_words;
reg [QW-1:0] head;
  reg [QW-1:0] tail;
reg [QW:0] count;
reg [1:0] push;
reg [31:0] pc;
  reg [31:0] next_pc;
  wire [29:0] next_word;
  wire [28:0] next_pair;
  wire [31:0] sequential_pc [2];
  v2_increment #(.BITS(30)) step_word(.value(pc[31:2]),.result(next_word));
  v2_increment #(.BITS(29)) step_pair(.value(pc[31:3]),.result(next_pair));
  assign sequential_pc[0]={next_word,pc[1:0]};
  assign sequential_pc[1]={next_pair,pc[2:0]};
reg  blocked;
  reg  next_blocked;
  (* ram_style="registers" *) reg [31:0] even_data [0:(CACHE_BYTES/8)-1], odd_data [0:(CACHE_BYTES/8)-1];
reg [31:0] even_target [0:(CACHE_BYTES/8)-1];
  reg [31:0] odd_target [0:(CACHE_BYTES/8)-1];
reg [31:CB] tags [0:(LINES)-1];
reg [LINES-1:0] tag_valid;
reg [7:0] valid_words [0:(LINES)-1];
  reg [7:0] failed_words [0:(LINES)-1];
reg  busy;
reg [31:0] fill_line;
reg [2:0] critical;
reg [3:0] issued;
  reg [3:0] returned;
wire [2:0] send_word;
  wire [2:0] return_word;
wire [31:0] return_address;
reg  allocate;
wire [LB-1:0] fetch_line;
wire  line_hit;
  wire  word_ready [0:(2)-1];
  wire  word_error [0:(2)-1];
wire [31:0] fetch_pc [0:(2)-1];
  wire [31:0] fetch_inst [0:(2)-1];
  reg [31:0] prediction [0:(2)-1];
  wire [31:0] fetch_target [0:(2)-1];
wire [63:0] even_read;
  wire [63:0] odd_read;
wire [CB-4:0] even_index;
  wire [CB-4:0] odd_index;
  (* ram_style="registers" *) reg [1:0] bht [0:(BHT_ENTRIES)-1];
reg [BHT_ENTRIES-1:0] bht_valid;
  (* ram_style="registers" *) reg [29:TW] btb_tag [0:(BTB_ENTRIES)-1];
  (* ram_style="registers" *) reg [29:0] btb_target [0:(BTB_ENTRIES)-1];
reg [BTB_ENTRIES-1:0] btb_valid;
wire [1:0] counter [0:(2)-1];
  wire [1:0] train_counter;
reg [31:0] fill_immediate;
  reg [31:0] fill_target;
reg [HB-1:0] local_history [0:(HISTORY_ENTRIES)-1];
wire [HB-1:0] fetch_history [0:(2)-1];
wire [BW-1:0] fetch_bht [0:(2)-1];
wire [BW-1:0] train_bht;
wire [TW-1:0] train_btb;
  assign train_bht=LOCAL_HISTORY_BITS==0 ? train_pc[BW+1:2]:
    (train_pc[BW+1:2]<<LOCAL_HISTORY_BITS) | narrow_0(train_history);
  assign train_btb=train_pc[TW+1:2];
  assign train_counter=bht_valid[train_bht] ? bht[train_bht]:2'd1;
  assign fetch_pc[0]=pc;
  assign fetch_pc[1]=sequential_pc[0];
  assign even_index=pc[2] ? fetch_pc[1][CB-1:3]:pc[CB-1:3];
  assign odd_index=pc[CB-1:3];
  for(row=0;row<CACHE_BYTES/8;row=row+1) begin: instruction_words
    assign even_words[row*64+:64]={even_target[row],even_data[row]};
    assign odd_words[row*64+:64]={odd_target[row],odd_data[row]};
  end
  v2_read #(.ENTRIES(CACHE_BYTES/8),.WORD_BITS(64),.INDEX_GROUP(CACHE_TREE ? 16:0)) read_even (.index(even_index),.words(even_words),.value(even_read));
  v2_read #(.ENTRIES(CACHE_BYTES/8),.WORD_BITS(64),.INDEX_GROUP(CACHE_TREE ? 16:0)) read_odd (.index(odd_index),.words(odd_words),.value(odd_read));
  assign fetch_inst[0]=pc[2] ? odd_read[31:0]:even_read[31:0];
  assign fetch_inst[1]=pc[2] ? even_read[31:0]:odd_read[31:0];
  assign fetch_target[0]=pc[2] ? odd_read[63:32]:even_read[63:32];
  assign fetch_target[1]=pc[2] ? even_read[63:32]:odd_read[63:32];
  assign fetch_line=pc[CB-1:5];
  wire [LINES-1:0] line_matches;
  for(row=0;row<LINES;row=row+1) begin: instruction_tags
    assign line_matches[row]=fetch_line==narrow_1(row) && tag_valid[row] && tags[row]==pc[31:CB];
  end
  assign line_hit=|line_matches;
  for(row=0;row<QUEUE_ENTRIES;row=row+1) begin: packet_words
    assign queue_words[row*PACKET_BITS+:PACKET_BITS]=fifo[row];
  end
  for(p=0;p<2;p=p+1) begin: predict
    wire [QW-1:0] read_index=head+narrow_2(p);
    v2_read #(.ENTRIES(QUEUE_ENTRIES),.WORD_BITS(PACKET_BITS)) read_queue (
      .index(read_index),.words(queue_words),.value(read_packet[p]));
    wire [BTB_ENTRIES-1:0] target_hits;
    wire [BTB_ENTRIES*30-1:0] target_words;
    wire [29:0] target;
    for(row=0;row<BTB_ENTRIES;row=row+1) begin: target_row
      assign target_hits[row]=fetch_pc[p][TW+1:2]==narrow_3(row) && btb_valid[row] &&
                              btb_tag[row]==fetch_pc[p][31:TW+2];
      assign target_words[row*30+:30]=btb_target[row];
    end
    v2_read #(.ENTRIES(BTB_ENTRIES),.WORD_BITS(30)) read_target (
      .index(fetch_pc[p][TW+1:2]),.words(target_words),.value(target));
    assign word_ready[p]=line_hit && (valid_words[fetch_line][fetch_pc[p][4:2]] || failed_words[fetch_line][fetch_pc[p][4:2]]);
    assign word_error[p]=failed_words[fetch_line][fetch_pc[p][4:2]];
    assign fetch_history[p]=LOCAL_HISTORY_BITS==0 ? 0:local_history[fetch_pc[p][HI+1:2]];
    assign fetch_bht[p]=LOCAL_HISTORY_BITS==0 ? fetch_pc[p][BW+1:2]:
      (fetch_pc[p][BW+1:2]<<LOCAL_HISTORY_BITS) | narrow_0(fetch_history[p]);
    assign counter[p]=bht_valid[fetch_bht[p]] ? bht[fetch_bht[p]]:2'd1;
    always @* begin
      prediction[p]=sequential_pc[p];
      case(fetch_inst[p][6:0])
        7'h6f: prediction[p]=fetch_target[p];
        7'h63: if(counter[p][1]) prediction[p]=fetch_target[p];
        7'h67: if(|target_hits) prediction[p]={target,2'b0};
        default: ;
      endcase
    end
  end
  always @* begin
    packet_valid=0;packet_pc=0;packet_inst=0;packet_prediction=0;packet_fault=0;packet_inst_valid=0;packet_history=0;
    begin: loop_2
integer p;
for(p=0;p<2;p=p+1) begin

      packet_valid[p]=narrow_4(count)>p;
      packet_pc[p*32+:32]=read_packet[p][PACKET_T_PC_LSB+:PACKET_T_PC_WIDTH];
      packet_inst[p*32+:32]=read_packet[p][PACKET_T_INST_LSB+:PACKET_T_INST_WIDTH];
      packet_prediction[p*32+:32]=read_packet[p][PACKET_T_PRED_LSB+:PACKET_T_PRED_WIDTH];
      packet_fault[p*4+:4]=read_packet[p][PACKET_T_FAULT_LSB+:PACKET_T_FAULT_WIDTH];
      packet_inst_valid[p]=read_packet[p][PACKET_T_IV_LSB+:PACKET_T_IV_WIDTH];
      packet_history[p*HB+:HB]=read_packet[p][PACKET_T_HISTORY_LSB+:PACKET_T_HISTORY_WIDTH];
    end
end
  end
  always @* begin: fetch_next
    push=0;next_pc=pc;next_blocked=blocked;allocate=0;
    begin: loop_1
integer p;
for(p=0;p<2;p=p+1) begin
      incoming[p]=0;incoming[p][PACKET_T_PC_LSB+:PACKET_T_PC_WIDTH]=fetch_pc[p];incoming[p][PACKET_T_PRED_LSB+:PACKET_T_PRED_WIDTH]=prediction[p];
      incoming[p][PACKET_T_HISTORY_LSB+:PACKET_T_HISTORY_WIDTH]=fetch_history[p];
      incoming[p][PACKET_T_INST_LSB+:PACKET_T_INST_WIDTH]=fetch_inst[p];incoming[p][PACKET_T_IV_LSB+:PACKET_T_IV_WIDTH]=1;
    end
end
    if(!stop && !redirect && !blocked && narrow_4(count)<QUEUE_ENTRIES) begin
      if(pc[1:0]!=0 || pc>=RAM_BYTES) begin
        incoming[0][PACKET_T_FAULT_LSB+:PACKET_T_FAULT_WIDTH]=pc[1:0]!=0 ? FAULT_FETCH_ALIGN:FAULT_FETCH_RANGE;
        incoming[0][PACKET_T_IV_LSB+:PACKET_T_IV_WIDTH]=0;incoming[0][PACKET_T_INST_LSB+:PACKET_T_INST_WIDTH]=0;push=1;next_blocked=1;
      end else if(word_ready[0]) begin
        push=1;next_pc=prediction[0];
        if(word_error[0]) begin
          incoming[0][PACKET_T_FAULT_LSB+:PACKET_T_FAULT_WIDTH]=FAULT_FETCH_BUS;incoming[0][PACKET_T_IV_LSB+:PACKET_T_IV_WIDTH]=0;incoming[0][PACKET_T_INST_LSB+:PACKET_T_INST_WIDTH]=0;next_blocked=1;
        end else if(prediction[0]==sequential_pc[0] && pc[4:2]!=7 && word_ready[1] &&
                    narrow_4(count)<QUEUE_ENTRIES-1) begin
          push=2;next_pc=prediction[1];
          if(word_error[1]) begin
            incoming[1][PACKET_T_FAULT_LSB+:PACKET_T_FAULT_WIDTH]=FAULT_FETCH_BUS;incoming[1][PACKET_T_IV_LSB+:PACKET_T_IV_WIDTH]=0;incoming[1][PACKET_T_INST_LSB+:PACKET_T_INST_WIDTH]=0;next_blocked=1;
          end
        end
      end else if(!busy) allocate=1;
    end
  end
  assign send_word=critical+issued[2:0];
  assign return_word=critical+returned[2:0];
  assign return_address=fill_line+{27'b0,return_word,2'b0};

  always @* begin
    fill_immediate=0;
    case(mem_rsp_data[6:0])
      7'h6f: fill_immediate={{11{mem_rsp_data[31]}},mem_rsp_data[31],mem_rsp_data[19:12],mem_rsp_data[20],mem_rsp_data[30:21],1'b0};
      7'h63: fill_immediate={{19{mem_rsp_data[31]}},mem_rsp_data[31],mem_rsp_data[7],mem_rsp_data[30:25],mem_rsp_data[11:8],1'b0};
      default: ;
    endcase
    fill_target=return_address+fill_immediate;
  end
  assign mem_req_valid=!rst && busy && issued<8;
  assign mem_req_addr=fill_line+{27'b0,send_word,2'b0};
  assign mem_rsp_ready=1;
  assign idle=!busy;
  always @(posedge clk) begin
    if(rst) begin
      head<=0;tail<=0;count<=0;pc<=0;blocked<=0;
      busy<=0;issued<=0;returned<=0;critical<=0;fill_line<=0;miss_count<=0;
      bht_valid<=0;btb_valid<=0;
    end else begin
      if(redirect) begin head<=0;tail<=0;count<=0;pc<=redirect_pc;blocked<=0;end
      else begin
        head<=head+narrow_2(pop_count);tail<=tail+narrow_2(push);
        count<=count+narrow_5(push)-narrow_5(pop_count);
        pc<=next_pc;blocked<=next_blocked;
      end
      if(allocate) begin
        busy<=1;fill_line<={pc[31:5],5'b0};critical<=pc[4:2];issued<=0;returned<=0;
        miss_count<=miss_count+1;
      end
      if(mem_req_valid && mem_req_ready) issued<=issued+1;
      if(mem_rsp_valid) begin
        returned<=returned+1;
        if(returned==7) busy<=0;
      end
      if(train_valid && train_op>=OP_BEQ && train_op<=OP_BGEU) begin
        bht_valid[train_bht]<=1;
        bht[train_bht]<=train_taken ? (train_counter==3 ? 2'd3:train_counter+2'd1):
                                                    (train_counter==0 ? 2'd0:train_counter-2'd1);
      end
      if(train_valid && train_op==OP_JALR && train_target<RAM_BYTES && train_target[1:0]==0) begin
        btb_valid[train_btb]<=1;btb_tag[train_btb]<=train_pc[31:TW+2];btb_target[train_btb]<=train_target[31:2];
      end
    end
  end
  for(row=0;row<CACHE_BYTES/8;row=row+1) begin: instruction_write
    always @(posedge clk)
      if(!rst && mem_rsp_valid && !mem_rsp_error &&
         return_address[CB-1:3]==narrow_6(row)) begin
        if(return_address[2]) begin odd_data[row]<=mem_rsp_data;odd_target[row]<=fill_target;end
        else begin even_data[row]<=mem_rsp_data;even_target[row]<=fill_target;end
      end
  end
  for(row=0;row<QUEUE_ENTRIES;row=row+1) begin: queue_write
    always @(posedge clk)
      begin: loop_0
integer p;
for(p=0;p<2;p=p+1)

        if(narrow_4(count)+p<QUEUE_ENTRIES &&
           narrow_2(tail+narrow_2(p))==narrow_2(row)) fifo[row]<=incoming[p];
end
  end
  for(row=0;row<LINES;row=row+1) begin: tag_write
reg [7:0] valid_next;
  reg [7:0] failed_next;
    always @* begin
      valid_next=valid_words[row];failed_next=failed_words[row];
      if(allocate && fetch_line==narrow_1(row)) begin valid_next=0;failed_next=0;end
      if(mem_rsp_valid && fill_line[CB-1:5]==narrow_1(row)) begin
        valid_next[return_word]=!mem_rsp_error;failed_next[return_word]=mem_rsp_error;
      end
    end
    always @(posedge clk) begin
      if(rst) tag_valid[row]<=0;
      else begin
        valid_words[row]<=valid_next;failed_words[row]<=failed_next;
        if(allocate && fetch_line==narrow_1(row)) begin
          tag_valid[row]<=1;tags[row]<=pc[31:CB];
        end
      end
    end
  end

  for(h=0;h<HISTORY_ENTRIES;h=h+1) begin: history_write
    always @(posedge clk) begin
      if(rst) local_history[h]<=0;
      else if(LOCAL_HISTORY_BITS>0 && train_valid && train_op>=OP_BEQ && train_op<=OP_BGEU &&
              train_pc[HI+1:2]==narrow_7(h)) local_history[h]<=(local_history[h]<<1) | narrow_8(train_taken);
    end
  end
  initial begin
    if(LOCAL_HISTORY_BITS<0 || LOCAL_HISTORY_BITS>=BW || HISTORY_ENTRIES<2 ||
       (HISTORY_ENTRIES&(HISTORY_ENTRIES-1))!=0) $fatal(1,"invalid local predictor dimensions");
    if(CACHE_BYTES<64 || (CACHE_BYTES&(CACHE_BYTES-1))!=0 || QUEUE_ENTRIES<2 || (QUEUE_ENTRIES&(QUEUE_ENTRIES-1))!=0)
      $fatal(1,"invalid frontend dimensions");
  end
endmodule


module v2_increment #(parameter integer BITS=30)(
  input wire [BITS-1:0] value,
  output wire [BITS-1:0] result
);
genvar bit_id,level;


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer LEVELS=$clog2(BITS);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  for(level=0;level<=LEVELS;level=level+1) begin: stage
    wire [BITS-1:0] prefix;
    if(level==0) begin: input_bits
      assign prefix=value;
    end else begin: merge
      for(bit_id=0;bit_id<BITS;bit_id=bit_id+1) begin: bits
        if(bit_id>=2**(level-1)) begin: joined
          v2_inc_join combine (
            .a(stage[level-1].prefix[bit_id]),
            .b(stage[level-1].prefix[bit_id-2**(level-1)]),.value(prefix[bit_id]));
        end else begin: unchanged
          assign prefix[bit_id]=stage[level-1].prefix[bit_id];
        end
      end
    end
  end
  assign result[0]=!value[0];
  for(bit_id=1;bit_id<BITS;bit_id=bit_id+1) begin: sum_bits
    assign result[bit_id]=value[bit_id] ^ stage[LEVELS].prefix[bit_id-1];
  end
endmodule

(* keep_hierarchy=1 *)
module v2_inc_join(input wire a,b,output wire value);
  assign value=a & b;
endmodule


(* keep_hierarchy=1 *)
module v2_iq_read #(
  parameter integer ENTRIES=8, WORD_BITS=32, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [INDEX_BITS-1:0] index,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  v2_read #(.ENTRIES(ENTRIES),.WORD_BITS(WORD_BITS),.INDEX_BITS(INDEX_BITS)) read_word (
    .index(index),.words(words),.value(value));
endmodule


(* keep_hierarchy=1 *)
module v2_operand #(parameter integer SLOT_BITS=5)(
  input wire live,prepare,old_ready,initial_ready,
  input wire [SLOT_BITS-1:0] source,
  input wire [31:0] old_value,initial_value,
  input wire [2:0] wb_good,
  input wire [3*SLOT_BITS-1:0] wb_slots,
  input wire [95:0] wb_values,
  output wire next_ready,
  output wire [31:0] next_value
);
genvar w;


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [2:0] hit,chosen;
  for(w=0;w<3;w=w+1) begin: matching
    assign hit[w]=live && !old_ready && wb_good[w] && source==wb_slots[w*SLOT_BITS+:SLOT_BITS];
  end
  assign chosen[2]=hit[2];
  assign chosen[1]=hit[1] && !hit[2];
  assign chosen[0]=hit[0] && !(hit[1] || hit[2]);
  wire initializing=!live && prepare;
  wire holding=!(initializing || |chosen);
  assign next_ready=live ? (old_ready || |hit):(prepare ? initial_ready:old_ready);
  assign next_value=(old_value & {32{holding}}) | (initial_value & {32{initializing}}) |
                    (wb_values[31:0] & {32{chosen[0]}}) |
                    (wb_values[63:32] & {32{chosen[1]}}) |
                    (wb_values[95:64] & {32{chosen[2]}});
endmodule

(* keep_hierarchy=1 *)
module v2_prefix_adder #(parameter integer WIDTH=32)(
  input wire [WIDTH-1:0] a,b,
  input wire carry_in,
  output wire [WIDTH-1:0] sum,
  output wire carry_out
);
genvar bit_id,level;


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer LEVELS=$clog2(WIDTH);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [WIDTH-1:0] initial_g;
  wire [WIDTH-1:0] bit_propagates=a^b;
  for(bit_id=0;bit_id<WIDTH;bit_id=bit_id+1) begin: initial_bit
    if(bit_id==0) begin: first
      assign initial_g[bit_id]=(a[bit_id]&b[bit_id]) | (bit_propagates[bit_id]&carry_in);
    end else begin: later
      assign initial_g[bit_id]=a[bit_id]&b[bit_id];
    end
  end
  for(level=0;level<LEVELS;level=level+1) begin: prefix_level
    wire [WIDTH-1:0] input_g,input_p,group_g,group_p;
    if(level==0) begin: first_level
      assign input_g=initial_g;
      assign input_p=bit_propagates;
    end else begin: later_level
      assign input_g=prefix_level[level-1].group_g;
      assign input_p=prefix_level[level-1].group_p;
    end
    for(bit_id=0;bit_id<WIDTH;bit_id=bit_id+1) begin: prefix_bit
      if(bit_id>=(1<<level)) begin: composed
        v2_prefix_node compose (
          .high_g(input_g[bit_id]),.high_p(input_p[bit_id]),
          .low_g(input_g[bit_id-(1<<level)]),.low_p(input_p[bit_id-(1<<level)]),
          .group_g(group_g[bit_id]),.group_p(group_p[bit_id]));
      end else begin: pass
        assign group_g[bit_id]=input_g[bit_id];
        assign group_p[bit_id]=input_p[bit_id];
      end
    end
  end
  for(bit_id=0;bit_id<WIDTH;bit_id=bit_id+1) begin: result_bit
    if(bit_id==0) begin: first
      assign sum[bit_id]=bit_propagates[bit_id]^carry_in;
    end else begin: later
      assign sum[bit_id]=bit_propagates[bit_id]^prefix_level[LEVELS-1].group_g[bit_id-1];
    end
  end
  generate if(LEVELS==0) begin: single_bit
    assign carry_out=initial_g[WIDTH-1];
  end else begin: multi_bit
    assign carry_out=prefix_level[LEVELS-1].group_g[WIDTH-1];
  end endgenerate
endmodule



(* keep_hierarchy=1 *)
module v2_prefix_node(
  input wire high_g,high_p,low_g,low_p,
  output wire group_g,group_p
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  assign group_g=high_g | (high_p & low_g);
  assign group_p=high_p & low_p;
endmodule



(* keep_hierarchy=1 *)
module v2_priority_register #(
  parameter integer WORD_BITS=32, PORTS=2, GROUP_BITS=8,
  parameter integer GROUPS=(WORD_BITS+GROUP_BITS-1)/GROUP_BITS
)(
  input wire clk,clear,
  input wire [PORTS-1:0] enable,
  input wire [PORTS*WORD_BITS-1:0] data,
  output reg [WORD_BITS-1:0] value
);
genvar bit_id;


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [(PORTS+1)*GROUPS-1:0] controls;
  v2_distribution #(.WIDTH(PORTS+1),.LEAVES(GROUPS)) control_tree (
    .data_in({clear,enable}),.data_out(controls));
  for(bit_id=0;bit_id<WORD_BITS;bit_id=bit_id+1) begin: bit_register
    wire [PORTS:0] local_control=controls[(bit_id/GROUP_BITS)*(PORTS+1)+:PORTS+1];
    always @(posedge clk) begin
      if(local_control[PORTS]) value[bit_id]<=0;
      else begin

        begin: loop_0
integer port_id;
for(port_id=0;port_id<PORTS;port_id=port_id+1)
          if(local_control[port_id]) value[bit_id]<=data[port_id*WORD_BITS+bit_id];
end
      end
    end
  end
endmodule



module v2_read #(
  parameter integer ENTRIES=8, WORD_BITS=32, INDEX_BITS=$clog2(ENTRIES), INDEX_GROUP=0
)(
  input wire [INDEX_BITS-1:0] index,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
genvar n;
function automatic [INDEX_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer LEAVES=2**$clog2(ENTRIES);
localparam integer GROUP_SIZE=INDEX_GROUP>0 ? INDEX_GROUP:ENTRIES;
localparam integer INDEX_COPIES=(ENTRIES+GROUP_SIZE-1)/GROUP_SIZE;
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [INDEX_BITS*INDEX_COPIES-1:0] local_indices;
  v2_distribution #(.WIDTH(INDEX_BITS),.LEAVES(INDEX_COPIES)) index_tree (
    .data_in(index),.data_out(local_indices));
  for(n=1;n<2*LEAVES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        wire selected=local_indices[((n-LEAVES)/GROUP_SIZE)*INDEX_BITS+:INDEX_BITS]==narrow_0(n-LEAVES);
        v2_read_mask #(.WORD_BITS(WORD_BITS)) mask_word (
          .selected(selected),.word(words[(n-LEAVES)*WORD_BITS+:WORD_BITS]),.value(word_value));
      end else begin: padding
        assign word_value=0;
      end
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule

(* keep_hierarchy=1 *)
module v2_read_mask #(parameter integer WORD_BITS=32)(
  input wire selected,
  input wire [WORD_BITS-1:0] word,
  output wire [WORD_BITS-1:0] value
);
  assign value=word & {WORD_BITS{selected}};
endmodule



module v2_rename #(
  parameter integer SLOT_BITS=5, CHECKPOINTS=4,
  parameter integer CHECKPOINT_BITS=$clog2(CHECKPOINTS), COMMIT_TREE=0
)(
  input wire  clk,
  input wire  rst,
  input wire [1:0] dispatch_valid,
  input wire [1:0] prepare_valid,
  input wire [9:0] dispatch_rd,
  input wire [2*SLOT_BITS-1:0] dispatch_slot,
  input wire [19:0] source_register,
  output wire [3:0] source_pending,
  output wire [4*SLOT_BITS-1:0] source_slot,
  input wire [1:0] commit_valid,
  input wire [9:0] commit_rd,
  input wire [2*SLOT_BITS-1:0] commit_slot,
  input wire  save_valid,
  input wire  save_after_lane,
  input wire [CHECKPOINT_BITS-1:0] save_index,
  input wire  restore_valid,
  input wire [CHECKPOINT_BITS-1:0] restore_index
);
genvar cp,port_id,r;
function automatic [1-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction

function automatic [5-1:0] narrow_1;
  input [63:0] value;
  begin narrow_1=value; end
endfunction

function automatic [CHECKPOINT_BITS-1:0] narrow_2;
  input [63:0] value;
  begin narrow_2=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer COMMIT_BITS=12+2*SLOT_BITS;
localparam integer COMMIT_GROUPS=4*(CHECKPOINTS+1);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
reg [31:0] pending_q;
  reg [31:0] pending_next;
  reg [31:0] save_pending;
reg [SLOT_BITS-1:0] tag_q [0:(32)-1];
  reg [SLOT_BITS-1:0] tag_next [0:(32)-1];
  reg [SLOT_BITS-1:0] save_tag [0:(32)-1];
reg [31:0] checkpoint_pending [0:(CHECKPOINTS)-1];
reg [SLOT_BITS-1:0] checkpoint_tag [0:(CHECKPOINTS)*(32)-1];

  wire [COMMIT_BITS*COMMIT_GROUPS-1:0] commit_controls;
  generate if(COMMIT_TREE) begin: distributed_commit
    v2_distribution #(.WIDTH(COMMIT_BITS),.LEAVES(COMMIT_GROUPS)) tree (
      .data_in({commit_valid,commit_rd,commit_slot}),.data_out(commit_controls));
  end else begin: direct_commit
    assign commit_controls={COMMIT_GROUPS{{commit_valid,commit_rd,commit_slot}}};
  end endgenerate

  always @* begin
    pending_next=pending_q;
    begin: loop_8
integer r;
for(r=0;r<32;r=r+1) tag_next[r]=tag_q[r];
end
    save_pending=0;
    begin: loop_7
integer r;
for(r=0;r<32;r=r+1) save_tag[r]=0;
end

    begin: loop_6
integer lane;
for(lane=0;lane<2;lane=lane+1) begin
      if (dispatch_valid[lane] && dispatch_rd[lane*5+:5]!=0) begin
        pending_next[dispatch_rd[lane*5+:5]]=1;
        tag_next[dispatch_rd[lane*5+:5]]=dispatch_slot[lane*SLOT_BITS+:SLOT_BITS];
      end
      if (save_after_lane==narrow_0(lane)) begin
        save_pending=pending_next;
        begin: loop_5
integer r;
for(r=0;r<32;r=r+1) save_tag[r]=tag_next[r];
end
      end
    end
end
    if (restore_valid) begin
      pending_next=checkpoint_pending[restore_index];
      begin: loop_4
integer r;
for(r=0;r<32;r=r+1) tag_next[r]=checkpoint_tag[(restore_index)*(32)+(r)];
end
    end

    begin: loop_3
integer r;
for(r=1;r<32;r=r+1)
      begin: loop_2
integer c;
for(c=0;c<2;c=c+1)
        if (commit_controls[(r/8)*COMMIT_BITS+2*SLOT_BITS+10+c] &&
            commit_controls[(r/8)*COMMIT_BITS+2*SLOT_BITS+c*5+:5]==narrow_1(r)) begin
          if (tag_next[r]==commit_controls[(r/8)*COMMIT_BITS+c*SLOT_BITS+:SLOT_BITS]) pending_next[r]=0;
          if (save_tag[r]==commit_controls[(r/8)*COMMIT_BITS+c*SLOT_BITS+:SLOT_BITS]) save_pending[r]=0;
        end
end
end
    pending_next[0]=0;save_pending[0]=0;
  end

  for(port_id=0;port_id<4;port_id=port_id+1) begin: lookup
    wire [4:0] register_id=source_register[port_id*5+:5];
    wire bypass=port_id>=2 && prepare_valid[0] && dispatch_rd[4:0]!=0 &&
                dispatch_rd[4:0]==register_id;
    wire [32*(SLOT_BITS+1)-1:0] mappings;
    wire [SLOT_BITS:0] mapping;
    for(r=0;r<32;r=r+1) begin: row
      assign mappings[r*(SLOT_BITS+1)+:SLOT_BITS+1]={pending_q[r],tag_q[r]};
    end
    v2_read #(.ENTRIES(32),.WORD_BITS(SLOT_BITS+1)) read_mapping (
      .index(register_id),.words(mappings),.value(mapping));
    assign source_pending[port_id]=bypass || mapping[SLOT_BITS];
    assign source_slot[port_id*SLOT_BITS+:SLOT_BITS]=bypass ? dispatch_slot[0+:SLOT_BITS]:mapping[SLOT_BITS-1:0];
  end

  always @(posedge clk) begin
    if (rst) pending_q<=0;
    else pending_q<=pending_next;
    begin: loop_1
integer r;
for(r=0;r<32;r=r+1) tag_q[r]<=tag_next[r];
end
  end
  for(cp=0;cp<CHECKPOINTS;cp=cp+1) begin: snapshot
    wire save_pulse=save_valid && save_index==narrow_2(cp) && !restore_valid;
    wire [31:0] save_enables;
    if(COMMIT_TREE) begin: distributed_save
      v2_distribution #(.WIDTH(1),.LEAVES(32)) tree (
        .data_in(save_pulse),.data_out(save_enables));
    end else begin: direct_save
      assign save_enables={32{save_pulse}};
    end
    for(r=0;r<32;r=r+1) begin: regmap
      wire [COMMIT_BITS-1:0] local_commit=commit_controls[((cp+1)*4+r/8)*COMMIT_BITS+:COMMIT_BITS];
      always @(posedge clk) begin
        if (rst) checkpoint_pending[cp][r]<=0;
        else begin
          begin: loop_0
integer c;
for(c=0;c<2;c=c+1)
            if (local_commit[2*SLOT_BITS+10+c] && local_commit[2*SLOT_BITS+c*5+:5]==narrow_1(r) &&
                checkpoint_tag[(cp)*(32)+(r)]==local_commit[c*SLOT_BITS+:SLOT_BITS])
              checkpoint_pending[cp][r]<=0;
end
          if (save_enables[r]) begin
            checkpoint_pending[cp][r]<=save_pending[r];
            checkpoint_tag[(cp)*(32)+(r)]<=save_tag[r];
          end
        end
      end
    end
  end
endmodule



(* keep_hierarchy=1 *)
module v2_retire_read #(
  parameter integer ENTRIES=32, WORD_BITS=32, LANE=0, CONTROL_TREE=0
)(
  input wire clk,rst,
  input wire [1:0] advance,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
genvar n,row;


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;
reg [ENTRIES-1:0] selected;
  generate if(CONTROL_TREE) begin: distributed_advance
    wire [2*((ENTRIES+7)/8)-1:0] advances;
    v2_distribution #(.WIDTH(2),.LEAVES((ENTRIES+7)/8)) tree (
      .data_in(advance),.data_out(advances));
    for(row=0;row<ENTRIES;row=row+1) begin: head_bit
      always @(posedge clk) begin
        if(rst) selected[row]<=(row==LANE);
        else case(advances[(row/8)*2+:2])
          1:selected[row]<=selected[(row+ENTRIES-1)%ENTRIES];
          2:selected[row]<=selected[(row+ENTRIES-2)%ENTRIES];
          default:;
        endcase
      end
    end
  end else begin: direct_advance
  always @(posedge clk) begin
    if(rst) selected<= {{(ENTRIES-1){1'b0}},1'b1} << LANE;
    else case(advance)
      1:selected<={selected[ENTRIES-2:0],selected[ENTRIES-1]};
      2:selected<={selected[ENTRIES-3:0],selected[ENTRIES-1:ENTRIES-2]};
      default:;
    endcase
  end
  end endgenerate
  for(n=1;n<2*ENTRIES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=ENTRIES) begin: leaf
      v2_read_mask #(.WORD_BITS(WORD_BITS)) mask_word (
        .selected(selected[n-ENTRIES]),.word(words[(n-ENTRIES)*WORD_BITS+:WORD_BITS]),.value(word_value));
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule

module v2_select #(
  parameter integer ENTRIES=8, SLOT_BITS=5, INDEX_BITS=$clog2(ENTRIES), YOUNGEST=0,
  parameter integer EXTENDED_ORDER=0
)(
  input wire [ENTRIES-1:0] ready,
  input wire [ENTRIES*SLOT_BITS-1:0] owner,
  input wire [SLOT_BITS-1:0] rob_head,
  output wire  valid,
  output wire [INDEX_BITS-1:0] index
);
genvar n;
function automatic [INDEX_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer LEAVES=2**$clog2(ENTRIES);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  for(n=1;n<2*LEAVES;n=n+1) begin: node
    wire [SLOT_BITS-1:0] position;
    wire wrapped;
    wire [INDEX_BITS-1:0] selected;
    wire winner;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        assign position=owner[(n-LEAVES)*SLOT_BITS+:SLOT_BITS];
        assign wrapped=EXTENDED_ORDER!=0 ? 1'b0:position<rob_head;
        assign winner=ready[n-LEAVES];
      end else begin: padding
        assign position=0;assign wrapped=0;assign winner=0;
      end
      assign selected=narrow_0(n-LEAVES);
    end else begin: branch
      wire same_side=node[2*n].wrapped==node[2*n+1].wrapped;

      wire [SLOT_BITS-1:0] difference=node[2*n].position-node[2*n+1].position;
      wire left_first=EXTENDED_ORDER!=0 ?
        (YOUNGEST!=0 ? !difference[SLOT_BITS-1]:(difference[SLOT_BITS-1] || difference==0)):
        YOUNGEST!=0 ?
        (same_side ? node[2*n].position>=node[2*n+1].position:node[2*n].wrapped):
        (same_side ? node[2*n].position<=node[2*n+1].position:!node[2*n].wrapped);
      wire left_wins=node[2*n].winner && (!node[2*n+1].winner || left_first);
      assign winner=node[2*n].winner || node[2*n+1].winner;
      assign selected=left_wins ? node[2*n].selected:node[2*n+1].selected;
      assign position=left_wins ? node[2*n].position:node[2*n+1].position;
      assign wrapped=left_wins ? node[2*n].wrapped:node[2*n+1].wrapped;
    end
  end
  assign valid=node[1].winner;
  assign index=node[1].selected;
endmodule


module v2_circular_priority #(
  parameter integer ENTRIES=16, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [INDEX_BITS-1:0] head,
  output wire valid,
  output reg [INDEX_BITS-1:0] index
);
genvar q;
function automatic [INDEX_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [ENTRIES-1:0] wrapped,active,winning;
  for(q=0;q<ENTRIES;q=q+1) begin: slot
    assign wrapped[q]=ready[q] && narrow_0(q)<head;
    if(q==ENTRIES-1) begin: last_slot
      assign winning[q]=active[q];
    end else begin: earlier_slot
      assign winning[q]=active[q] && !(|active[ENTRIES-1:q+1]);
    end
  end
  assign valid=|ready;
  assign active=(|wrapped) ? wrapped:ready;
  always @* begin
    index=0;
    begin: loop_0
integer q;
for(q=0;q<ENTRIES;q=q+1)
      index=index | (narrow_0(q) & {INDEX_BITS{winning[q]}});
end
  end
endmodule


(* keep_hierarchy=1 *)
module v2_order_compare #(parameter integer BITS=6)(
  input wire [BITS-1:0] a,b,
  output wire first
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [BITS-1:0] difference=a-b;
  assign first=difference[BITS-1] || a==b;
endmodule

module v2_parallel_select #(
  parameter integer ENTRIES=4, SLOT_BITS=6, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [ENTRIES*SLOT_BITS-1:0] owner,
  input wire [SLOT_BITS-1:0] rob_head,
  output wire valid,
  output reg [INDEX_BITS-1:0] index,
  output wire [ENTRIES-1:0] grant
);
genvar other,row;
function automatic [INDEX_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  for(row=0;row<ENTRIES;row=row+1) begin: candidate
    wire [ENTRIES-1:0] blocked;
    for(other=0;other<ENTRIES;other=other+1) begin: comparison
      wire first;
      if(row<other) begin: ordered_pair
        v2_order_compare #(.BITS(SLOT_BITS)) compare (
          .a(owner[row*SLOT_BITS+:SLOT_BITS]),.b(owner[other*SLOT_BITS+:SLOT_BITS]),.first(first));
      end else if(row>other) begin: inverse_pair
        assign first=!candidate[other].comparison[row].first;
      end else begin: same_row
        assign first=1;
      end
      assign blocked[other]=ready[other] && !first;
    end
    assign grant[row]=ready[row] && !(|blocked);
  end
  assign valid=|ready;
  always @* begin
    index=0;
    begin: loop_0
integer row;
for(row=0;row<ENTRIES;row=row+1)
      index=index | (narrow_0(row) & {INDEX_BITS{grant[row]}});
end
  end
endmodule


(* keep_hierarchy=1 *)
module v2_grant_read #(parameter integer ENTRIES=4, WORD_BITS=32)(
  input wire [ENTRIES-1:0] grant,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
genvar n;


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer LEAVES=2**$clog2(ENTRIES);
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  for(n=1;n<2*LEAVES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        v2_read_mask #(.WORD_BITS(WORD_BITS)) mask_word (
          .selected(grant[n-LEAVES]),.word(words[(n-LEAVES)*WORD_BITS+:WORD_BITS]),.value(word_value));
      end else begin: padding
        assign word_value=0;
      end
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule


module v2_circular_grant #(
  parameter integer ENTRIES=16, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [INDEX_BITS-1:0] head,
  output wire valid,
  output reg [INDEX_BITS-1:0] index,
  output wire [ENTRIES-1:0] grant
);
genvar q;
function automatic [INDEX_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [ENTRIES-1:0] wrapped;
  wire any_wrapped=|wrapped;
  for(q=0;q<ENTRIES;q=q+1) begin: slot
    wire highest_wrapped,highest_any;
    assign wrapped[q]=ready[q] && narrow_0(q)<head;
    if(q==ENTRIES-1) begin: last_slot
      assign highest_wrapped=wrapped[q];assign highest_any=ready[q];
    end else begin: earlier_slot
      assign highest_wrapped=wrapped[q] && !(|wrapped[ENTRIES-1:q+1]);
      assign highest_any=ready[q] && !(|ready[ENTRIES-1:q+1]);
    end
    assign grant[q]=highest_wrapped || (!any_wrapped && highest_any);
  end
  assign valid=|ready;
  always @* begin
    index=0;
    begin: loop_0
integer q;
for(q=0;q<ENTRIES;q=q+1)
      index=index | (narrow_0(q) & {INDEX_BITS{grant[q]}});
end
  end
endmodule


(* keep_hierarchy=1 *)
module v2_registered_grant #(parameter integer ENTRIES=4, INDEX_BITS=$clog2(ENTRIES))(
  input wire clk,rst,valid,
  input wire [INDEX_BITS-1:0] index,
  output reg [ENTRIES-1:0] grant
);
genvar q;
function automatic [INDEX_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  for(q=0;q<ENTRIES;q=q+1) begin: row
    always @(posedge clk)
      if(rst) grant[q]<=0;
      else grant[q]<=valid && index==narrow_0(q);
  end
endmodule


(* keep_hierarchy=1 *)
module v2_cache_lookup #(
  parameter integer SETS=16, TAG_BITS=18, WORDS=16,
  SET_BITS=$clog2(SETS), WORD_BITS=$clog2(WORDS)
)(
  input wire [TAG_BITS+SET_BITS+WORD_BITS-1:0] address,
  input wire [2*SETS*TAG_BITS-1:0] tags,
  input wire [2*SETS-1:0] valid,
  input wire [2*SETS*WORDS-1:0] word_valid,
  output wire [1:0] match_bits,
  output wire hit
);
genvar line,set_id,way;
function automatic [SET_BITS-1:0] narrow_0;
  input [63:0] value;
  begin narrow_0=value; end
endfunction


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer ADDRESS_BITS=TAG_BITS+SET_BITS+WORD_BITS;
localparam integer GROUPS=(2*SETS+3)/4;
localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  wire [ADDRESS_BITS*GROUPS-1:0] addresses;
  wire [2*SETS-1:0] line_matches,line_hits;
  wire [1:0] way_hits;
  v2_distribution #(.WIDTH(ADDRESS_BITS),.LEAVES(GROUPS)) distribute_address (
    .data_in(address),.data_out(addresses));
  for(line=0;line<2*SETS;line=line+1) begin: comparison
    wire [ADDRESS_BITS-1:0] local_address=addresses[(line/4)*ADDRESS_BITS+:ADDRESS_BITS];
    v2_cache_tag_match #(.TAG_BITS(TAG_BITS),.WORDS(WORDS)) compare (
      .selected(local_address[WORD_BITS+:SET_BITS]==narrow_0(line/2)),.valid(valid[line]),
      .tag(tags[line*TAG_BITS+:TAG_BITS]),.request_tag(local_address[WORD_BITS+SET_BITS+:TAG_BITS]),
      .word_valid(word_valid[line*WORDS+:WORDS]),.word_index(local_address[0+:WORD_BITS]),
      .match_bits(line_matches[line]),.hit(line_hits[line]));
  end
  for(way=0;way<2;way=way+1) begin: reduction
    wire [SETS-1:0] set_matches,set_hits;
    for(set_id=0;set_id<SETS;set_id=set_id+1) begin: set_result
      assign set_matches[set_id]=line_matches[set_id*2+way];
      assign set_hits[set_id]=line_hits[set_id*2+way];
    end
    assign match_bits[way]=|set_matches;
    assign way_hits[way]=|set_hits;
  end
  assign hit=match_bits[0] ? way_hits[0]:way_hits[1];
endmodule


(* keep_hierarchy=1 *)
module v2_cache_tag_match #(
  parameter integer TAG_BITS=18, WORDS=16, WORD_BITS=$clog2(WORDS)
)(
  input wire selected,valid,
  input wire [TAG_BITS-1:0] tag,request_tag,
  input wire [WORDS-1:0] word_valid,
  input wire [WORD_BITS-1:0] word_index,
  output wire match_bits,hit
);


  localparam OP_ADD=0, OP_SUB=1, OP_SLL=2, OP_SLT=3, OP_SLTU=4, OP_XOR=5, OP_SRL=6, OP_SRA=7, OP_OR=8, OP_AND=9, OP_LUI=10, OP_AUIPC=11, OP_JAL=12, OP_JALR=13, OP_BEQ=14, OP_BNE=15, OP_BLT=16, OP_BGE=17, OP_BLTU=18, OP_BGEU=19, OP_LOAD=20, OP_STORE=21, OP_MUL=22, OP_MULH=23, OP_MULHSU=24, OP_MULHU=25, OP_DIV=26, OP_DIVU=27, OP_REM=28, OP_REMU=29;

  localparam [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic is_branch(input [5:0] op);
    is_branch = op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic is_mdu(input [5:0] op);
    is_mdu = op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic is_alu(input [5:0] op);
    is_alu = op <= OP_AUIPC;
  endfunction

localparam integer DECODED_T_ILLEGAL_LSB=0, DECODED_T_ILLEGAL_WIDTH=1;
localparam integer DECODED_T_LOAD_SIGNED_LSB=DECODED_T_ILLEGAL_LSB+DECODED_T_ILLEGAL_WIDTH, DECODED_T_LOAD_SIGNED_WIDTH=1;
localparam integer DECODED_T_MEM_SIZE_LSB=DECODED_T_LOAD_SIGNED_LSB+DECODED_T_LOAD_SIGNED_WIDTH, DECODED_T_MEM_SIZE_WIDTH=2;
localparam integer DECODED_T_IMM_LSB=DECODED_T_MEM_SIZE_LSB+DECODED_T_MEM_SIZE_WIDTH, DECODED_T_IMM_WIDTH=32;
localparam integer DECODED_T_USE_IMM_LSB=DECODED_T_IMM_LSB+DECODED_T_IMM_WIDTH, DECODED_T_USE_IMM_WIDTH=1;
localparam integer DECODED_T_WRITES_RD_LSB=DECODED_T_USE_IMM_LSB+DECODED_T_USE_IMM_WIDTH, DECODED_T_WRITES_RD_WIDTH=1;
localparam integer DECODED_T_USES_RS2_LSB=DECODED_T_WRITES_RD_LSB+DECODED_T_WRITES_RD_WIDTH, DECODED_T_USES_RS2_WIDTH=1;
localparam integer DECODED_T_USES_RS1_LSB=DECODED_T_USES_RS2_LSB+DECODED_T_USES_RS2_WIDTH, DECODED_T_USES_RS1_WIDTH=1;
localparam integer DECODED_T_RD_LSB=DECODED_T_USES_RS1_LSB+DECODED_T_USES_RS1_WIDTH, DECODED_T_RD_WIDTH=5;
localparam integer DECODED_T_RS2_LSB=DECODED_T_RD_LSB+DECODED_T_RD_WIDTH, DECODED_T_RS2_WIDTH=5;
localparam integer DECODED_T_RS1_LSB=DECODED_T_RS2_LSB+DECODED_T_RS2_WIDTH, DECODED_T_RS1_WIDTH=5;
localparam integer DECODED_T_OP_LSB=DECODED_T_RS1_LSB+DECODED_T_RS1_WIDTH, DECODED_T_OP_WIDTH=6;
localparam integer DECODED_T_WIDTH=DECODED_T_OP_LSB+DECODED_T_OP_WIDTH;
localparam integer FETCH_T_GSHARE_TAKEN_LSB=0, FETCH_T_GSHARE_TAKEN_WIDTH=1;
localparam integer FETCH_T_BIMODAL_TAKEN_LSB=FETCH_T_GSHARE_TAKEN_LSB+FETCH_T_GSHARE_TAKEN_WIDTH, FETCH_T_BIMODAL_TAKEN_WIDTH=1;
localparam integer FETCH_T_PREDICTED_TAKEN_LSB=FETCH_T_BIMODAL_TAKEN_LSB+FETCH_T_BIMODAL_TAKEN_WIDTH, FETCH_T_PREDICTED_TAKEN_WIDTH=1;
localparam integer FETCH_T_RAS_COUNT_LSB=FETCH_T_PREDICTED_TAKEN_LSB+FETCH_T_PREDICTED_TAKEN_WIDTH, FETCH_T_RAS_COUNT_WIDTH=5;
localparam integer FETCH_T_RAS_SNAPSHOT_LSB=FETCH_T_RAS_COUNT_LSB+FETCH_T_RAS_COUNT_WIDTH, FETCH_T_RAS_SNAPSHOT_WIDTH=512;
localparam integer FETCH_T_HISTORY_LSB=FETCH_T_RAS_SNAPSHOT_LSB+FETCH_T_RAS_SNAPSHOT_WIDTH, FETCH_T_HISTORY_WIDTH=16;
localparam integer FETCH_T_FAULT_ADDR_LSB=FETCH_T_HISTORY_LSB+FETCH_T_HISTORY_WIDTH, FETCH_T_FAULT_ADDR_WIDTH=32;
localparam integer FETCH_T_FAULT_LSB=FETCH_T_FAULT_ADDR_LSB+FETCH_T_FAULT_ADDR_WIDTH, FETCH_T_FAULT_WIDTH=4;
localparam integer FETCH_T_INST_VALID_LSB=FETCH_T_FAULT_LSB+FETCH_T_FAULT_WIDTH, FETCH_T_INST_VALID_WIDTH=1;
localparam integer FETCH_T_PREDICTED_PC_LSB=FETCH_T_INST_VALID_LSB+FETCH_T_INST_VALID_WIDTH, FETCH_T_PREDICTED_PC_WIDTH=32;
localparam integer FETCH_T_INST_LSB=FETCH_T_PREDICTED_PC_LSB+FETCH_T_PREDICTED_PC_WIDTH, FETCH_T_INST_WIDTH=32;
localparam integer FETCH_T_PC_LSB=FETCH_T_INST_LSB+FETCH_T_INST_WIDTH, FETCH_T_PC_WIDTH=32;
localparam integer FETCH_T_WIDTH=FETCH_T_PC_LSB+FETCH_T_PC_WIDTH;

  assign match_bits=selected && valid && tag==request_tag;
  assign hit=match_bits && word_valid[word_index];
endmodule

