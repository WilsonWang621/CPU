module frontend_test_top #(
  parameter integer FETCH_WIDTH=4, FETCH_QUEUE_ENTRIES=32,
  parameter integer FETCH_REQUESTS=16, LINE_BYTES=32,
  parameter integer PREDICTOR_MODE=2,HISTORY_BITS=8,BHT_ENTRIES=64
)(
  input logic clk,rst,stop,redirect_valid,
  input logic [31:0] redirect_pc,redirect_branch_pc,redirect_inst,
  input logic [15:0] redirect_history,
  input logic [511:0] redirect_ras_snapshot,
  input logic [4:0] redirect_ras_count,
  input logic redirect_taken,
  output logic [3:0] out_valid,out_inst_valid,out_taken,
  output logic [3:0] out_bimodal_taken,out_gshare_taken,
  output logic [127:0] out_pc,out_inst,out_prediction,out_fault_addr,
  output logic [15:0] out_fault,
  output logic [63:0] out_history,
  output logic [2047:0] out_ras,
  output logic [19:0] out_ras_count,
  input logic [2:0] pop_count,
  input logic [3:0] train_valid,
  input logic [127:0] train_pc,train_inst,train_next_pc,
  input logic [3:0] train_taken,
  input logic [3:0] train_bimodal_taken,train_gshare_taken,
  input logic [63:0] train_history,
  output logic req_valid,
  input logic req_ready,
  output logic [31:0] req_addr,
  output logic [2:0] req_count,
  output logic [7:0] req_tag,
  input logic rsp_valid,
  output logic rsp_ready,
  input logic [127:0] rsp_data,
  input logic [7:0] rsp_tag,
  input logic rsp_error,
  input logic [3:0] rsp_error_mask,
  output logic idle
);
  cpu_pkg::fetch_t packets [4];
  frontend #(.FETCH_WIDTH(FETCH_WIDTH),.FETCH_QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES),
    .FETCH_REQUESTS(FETCH_REQUESTS),.LINE_BYTES(LINE_BYTES),.BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(64),
    .PREDICTOR_MODE(PREDICTOR_MODE),.HISTORY_BITS(HISTORY_BITS)) dut (
    .clk,.rst,.stop,.redirect_valid,.redirect_pc,.redirect_branch_pc,.redirect_inst,
    .redirect_history,.redirect_ras_snapshot,.redirect_ras_count,.redirect_taken,
    .out_valid,.out_packet(packets),.pop_count,.train_valid,.train_pc,.train_inst,
    .train_next_pc,.train_taken,.train_history,.train_bimodal_taken,.train_gshare_taken,
    .req_valid,.req_ready,.req_addr,
    .req_count,.req_tag,.rsp_valid,.rsp_ready,.rsp_data,.rsp_tag,.rsp_error,.rsp_error_mask,.idle
  );
  for(genvar lane=0;lane<4;lane=lane+1) begin: flatten
    assign out_pc[lane*32+:32]=packets[lane].pc;
    assign out_inst[lane*32+:32]=packets[lane].inst;
    assign out_prediction[lane*32+:32]=packets[lane].predicted_pc;
    assign out_fault_addr[lane*32+:32]=packets[lane].fault_addr;
    assign out_inst_valid[lane]=packets[lane].inst_valid;
    assign out_taken[lane]=packets[lane].predicted_taken;
    assign out_bimodal_taken[lane]=packets[lane].bimodal_taken;
    assign out_gshare_taken[lane]=packets[lane].gshare_taken;
    assign out_fault[lane*4+:4]=packets[lane].fault;
    assign out_history[lane*16+:16]=packets[lane].history;
    assign out_ras[lane*512+:512]=packets[lane].ras_snapshot;
    assign out_ras_count[lane*5+:5]=packets[lane].ras_count;
  end
endmodule
