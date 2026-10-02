// Generated from the actual core formulas by prove_rat_reconstruction.py.
// Mapping each architectural register is independent, so one arbitrary 5-bit
// register index quantifies all 32 without duplicating the SAT search.
module rat_reconstruction_equivalence #(
  parameter integer ROB_ENTRIES=4, PW=7, RW=$clog2(ROB_ENTRIES)
)(
  input logic [RW-1:0] head_q,
  input logic [RW:0] recovery_age,
  input logic recovery_keep,redirect,
  input logic [4:0] arch,
  input logic [ROB_ENTRIES-1:0] valid_raw,writes_raw,
  input logic [ROB_ENTRIES*5-1:0] rd_raw,
  input logic [ROB_ENTRIES*PW-1:0] pdst_raw,
  input logic [PW-1:0] committed,
  output logic equivalent
);
  typedef logic [RW-1:0] rid_t;
  typedef logic [PW-1:0] preg_t;
  logic [ROB_ENTRIES-1:0] rob_col_valid,rob_col_dec_writes_rd,recovery_survivor;
  logic [4:0] rob_col_dec_rd [ROB_ENTRIES];
  preg_t rob_col_pdst [ROB_ENTRIES];
  logic [RW:0] rob_age [ROB_ENTRIES];
  preg_t reconstructed,chronological;
  integer index,cutoff;
function automatic logic [RW:0] distance(input rid_t r,input rid_t h);
    logic signed [RW+1:0] delta;
    begin
      delta=$signed({2'b00,r})-$signed({2'b00,h});
      if(delta[RW+1]) delta=delta+(RW+2)'(ROB_ENTRIES);
      return (RW+1)'(delta);
    end
  endfunction
  assign rob_col_valid=valid_raw;
  assign rob_col_dec_writes_rd=writes_raw;
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: columns
    assign rob_col_dec_rd[row]=rd_raw[row*5+:5];
    assign rob_col_pdst[row]=pdst_raw[row*PW+:PW];
    assign rob_age[row]=distance(rid_t'(row),head_q);
assign recovery_survivor[row]=rob_col_valid[row] && rob_col_dec_writes_rd[row] &&
      rob_age[row]<recovery_age+(RW+1)'(recovery_keep);
  end
  always_comb begin
        reconstructed=committed;
        if(redirect) begin
          for(integer row=0;row<ROB_ENTRIES;row=row+1)
            if(rid_t'(row)>=head_q && recovery_survivor[row] && rob_col_dec_rd[row]==5'(arch))
              reconstructed=rob_col_pdst[row];
          for(integer row=0;row<ROB_ENTRIES;row=row+1)
            if(rid_t'(row)<head_q && recovery_survivor[row] && rob_col_dec_rd[row]==5'(arch))
              reconstructed=rob_col_pdst[row];
        end
    if(arch==0) reconstructed='0;
  end
  // The reference advances a circular pointer in chronological order. It does
  // not use the two physical segments or the core's circular-age function.
  always_comb begin
    chronological=arch==0 ? preg_t'(0):committed;
    index=int'(head_q);cutoff=int'(recovery_age)+int'(recovery_keep);
    for(integer age=0;age<ROB_ENTRIES;age=age+1) begin
      if(redirect && arch!=0 && age<cutoff && valid_raw[index] && writes_raw[index] &&
         rd_raw[index*5+:5]==arch) chronological=pdst_raw[index*PW+:PW];
      index=index==ROB_ENTRIES-1 ? 0:index+1;
    end
    equivalent=1;
    if(int'(head_q)<ROB_ENTRIES && cutoff<=ROB_ENTRIES)
      equivalent=reconstructed==chronological;
  end
endmodule
