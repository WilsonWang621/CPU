// Simulation-only invariant over real dispatch, wakeup, squash and reuse.
// The oracle is the architectural effective-address rule, base + immediate.
module v2_memory_address_monitor #(
  parameter integer ENTRIES=8, WORD_BITS=188,
  parameter integer VALID_LSB=187, READY_LSB=186, A_LSB=64, IMM_LSB=0
)(
  input wire clk,rst,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  input wire [ENTRIES*32-1:0] addresses
);
  integer checks=0,wakes=0;
  reg [ENTRIES-1:0] waiting=0;
  always @(posedge clk) begin
    for(integer q=0;q<ENTRIES;q=q+1) begin
      if(!rst && words[q*WORD_BITS+VALID_LSB] && words[q*WORD_BITS+READY_LSB]) begin
        assert(addresses[q*32+:32]==words[q*WORD_BITS+A_LSB+:32]+words[q*WORD_BITS+IMM_LSB+:32])
          else $fatal(1,"effective address mismatch in memory IQ row %0d",q);
        checks=checks+1;
        if(waiting[q]) wakes=wakes+1;
      end
      waiting[q]=!rst && words[q*WORD_BITS+VALID_LSB] && !words[q*WORD_BITS+READY_LSB];
    end
  end
  final $fdisplay(32'h80000002,"Memory address invariant: PASS checks=%0d wake_transitions=%0d",checks,wakes);
endmodule

bind cpu_top v2_memory_address_monitor #(
  .ENTRIES(IQ_ENTRIES),.WORD_BITS(ISSUE_T_WIDTH),
  .VALID_LSB(ISSUE_T_VALID_LSB),.READY_LSB(ISSUE_T_READY_A_LSB),
  .A_LSB(ISSUE_T_A_LSB),.IMM_LSB(ISSUE_T_IMM_LSB)
) memory_address_monitor (
  .clk(clk),.rst(rst),.words(balanced_selection[2].payloads),.addresses(prepared_address_words)
);
