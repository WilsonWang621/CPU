module predictor_test_top #(
  parameter integer PREDICTOR_MODE=2,HISTORY_BITS=8,BHT_ENTRIES=64
)(
  input logic clk,rst,advance,
  input logic [31:0] query_pc,
  input logic [2:0] query_count,
  output logic [127:0] prediction,
  output logic [3:0] predicted_taken,
  output logic [3:0] bimodal_taken,gshare_taken,
  output logic [63:0] history,
  output logic [2047:0] ras,
  output logic [19:0] ras_count,
  output logic [2:0] predicted_count,
  output logic [31:0] next_pc,
  input logic redirect_valid,
  input logic [31:0] redirect_branch_pc,redirect_inst,
  input logic [15:0] redirect_history,
  input logic [511:0] redirect_ras_snapshot,
  input logic [4:0] redirect_ras_count,
  input logic redirect_taken,
  input logic [3:0] train_valid,
  input logic [127:0] train_pc,train_inst,train_next_pc,
  input logic [3:0] train_taken,
  input logic [3:0] train_bimodal_taken,train_gshare_taken,
  input logic [63:0] train_history
);
  logic [31:0] predictions [4];
  logic [15:0] histories [4];
  logic [511:0] snapshots [4];
  logic [4:0] counts [4];
  branch_predictor #(.BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(64),.RAS_DEPTH(4),
    .PREDICTOR_MODE(PREDICTOR_MODE),.HISTORY_BITS(HISTORY_BITS)) dut (
    .clk,.rst,.advance,.query_pc,.query_count,.predicted_pc(predictions),
    .predicted_taken,.bimodal_taken,.gshare_taken,.history(histories),.ras_snapshot(snapshots),.ras_count(counts),
    .predicted_count,.next_pc,.redirect_valid,.redirect_branch_pc,.redirect_inst,
    .redirect_history,.redirect_ras_snapshot,.redirect_ras_count,.redirect_taken,
    .train_valid,.train_pc,.train_inst,.train_next_pc,.train_taken,.train_history,
    .train_bimodal_taken,.train_gshare_taken
  );
  for(genvar lane=0;lane<4;lane=lane+1) begin: flatten
    assign prediction[lane*32+:32]=predictions[lane];
    assign history[lane*16+:16]=histories[lane];
    assign ras[lane*512+:512]=snapshots[lane];
    assign ras_count[lane*5+:5]=counts[lane];
  end
endmodule
