// Keep the commit decode local to one architectural word. The global commit
// event drives the local decoder rather than each bit's feedback mux.
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
  generate
    if(CONTROL_TREE) begin: distributed
      wire [1:0] write_enable;
      assign write_enable[0]=commit_valid[0] && commit_rd[4:0]==5'(REGISTER);
      assign write_enable[1]=commit_valid[1] && commit_rd[9:5]==5'(REGISTER);
      v2_priority_register #(.PORTS(2)) data_word (
        .clk,.clear(rst || REGISTER==0),.enable(write_enable),.data(commit_values),.value(value));
    end else begin: direct
      logic [31:0] stored;
      assign value=stored;
      always_ff @(posedge clk) begin
        if(rst || REGISTER==0) stored<=0;
        else begin
          if(commit_valid[0] && commit_rd[4:0]==5'(REGISTER)) stored<=commit_values[31:0];
          if(commit_valid[1] && commit_rd[9:5]==5'(REGISTER)) stored<=commit_values[63:32];
        end
      end
    end
  endgenerate
endmodule
