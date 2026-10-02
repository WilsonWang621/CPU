// Check the registered grant against the oldest currently live memory row.
module v2_memory_select_monitor #(
  parameter integer ENTRIES=8,SLOT_BITS=6,INDEX_BITS=3,WORD_BITS=188,
  parameter integer READY_A_LSB=186,READY_B_LSB=185
)(
  input wire clk,rst,
  input wire [ENTRIES-1:0] candidates,
  input wire [ENTRIES*SLOT_BITS-1:0] owners,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  input wire granted,
  input wire [INDEX_BITS-1:0] selected
);
  integer checks=0,waiting=0;
  integer expected_index,oldest,difference;
  reg expected_valid;
  always @(posedge clk) begin
    expected_valid=0;expected_index=0;oldest=0;
    for(integer q=0;q<ENTRIES;q=q+1) begin
      difference=(int'(owners[q*SLOT_BITS+:SLOT_BITS])-oldest)&((1<<SLOT_BITS)-1);
      if(candidates[q] && (!expected_valid || (difference&(1<<(SLOT_BITS-1)))!=0)) begin
        expected_valid=1;expected_index=q;oldest=int'(owners[q*SLOT_BITS+:SLOT_BITS]);
      end
    end
    if(!rst) begin
      assert(granted==expected_valid && (!expected_valid || int'(selected)==expected_index))
        else $fatal(1,"memory grant mismatch valid=%d/%d index=%d/%d",granted,expected_valid,selected,expected_index);
      if(expected_valid) begin
        checks=checks+1;
        if(!words[expected_index*WORD_BITS+READY_A_LSB] || !words[expected_index*WORD_BITS+READY_B_LSB])
          waiting=waiting+1;
      end
    end
  end
  final $fdisplay(32'h80000002,"Memory selection invariant: PASS checks=%0d waiting=%0d",checks,waiting);
endmodule

bind cpu_top v2_memory_select_monitor #(
  .ENTRIES(IQ_ENTRIES),.SLOT_BITS(RW+1),.INDEX_BITS(QW),.WORD_BITS(ISSUE_T_WIDTH),
  .READY_A_LSB(ISSUE_T_READY_A_LSB),.READY_B_LSB(ISSUE_T_READY_B_LSB)
) memory_selection_monitor (
  .clk(clk),.rst(rst),.candidates(select_ready[2]),.owners(select_owner[2]),
  .words(balanced_selection[2].payloads),.granted(selected_valid[2]),.selected(selected[2])
);
