// Keep the commit decode local to one architectural word. The global commit
// event drives the local decoder rather than each bit's feedback mux.
(* keep_hierarchy=1 *)
module v2_arch_word #(
  parameter integer REGISTER=1
)(
  input wire clk,rst,
  input wire [1:0] commit_valid,
  input wire [9:0] commit_rd,
  input wire [63:0] commit_values,
  output logic [31:0] value
);
  always_ff @(posedge clk) begin
    if(rst || REGISTER==0) value<=0;
    else begin
      if(commit_valid[0] && commit_rd[4:0]==5'(REGISTER)) value<=commit_values[31:0];
      if(commit_valid[1] && commit_rd[9:5]==5'(REGISTER)) value<=commit_values[63:32];
    end
  end
endmodule
