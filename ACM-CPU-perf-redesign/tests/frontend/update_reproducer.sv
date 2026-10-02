module update_dynamic #(
  parameter integer ENTRIES=16, WIDTH=896,
  parameter integer AW=$clog2(ENTRIES)
)(
  input logic clk,rst,allocate,update,set_flag,
  input logic [AW-1:0] allocate_index,update_index,flag_index,
  input logic [WIDTH-1:0] allocate_data,
  input logic [31:0] update_data,
  output logic [ENTRIES*WIDTH-1:0] state
);
  logic [WIDTH-1:0] q [ENTRIES],d [ENTRIES];
  for(genvar n=0;n<ENTRIES;n=n+1) assign state[n*WIDTH+:WIDTH]=q[n];
  always_comb begin
    for(integer n=0;n<ENTRIES;n=n+1) d[n]=q[n];
    if(allocate) d[allocate_index]=allocate_data;
    if(update) d[update_index][35:4]=update_data;
    if(set_flag) d[flag_index][0]=1'b1;
  end
  always_ff @(posedge clk)
    for(integer n=0;n<ENTRIES;n=n+1) if(rst) q[n]<='0;else q[n]<=d[n];
endmodule
module update_decoded #(
  parameter integer ENTRIES=16, WIDTH=896,
  parameter integer AW=$clog2(ENTRIES)
)(
  input logic clk,rst,allocate,update,set_flag,
  input logic [AW-1:0] allocate_index,update_index,flag_index,
  input logic [WIDTH-1:0] allocate_data,
  input logic [31:0] update_data,
  output logic [ENTRIES*WIDTH-1:0] state
);
  logic [WIDTH-1:0] q [ENTRIES],d [ENTRIES];
  for(genvar n=0;n<ENTRIES;n=n+1) assign state[n*WIDTH+:WIDTH]=q[n];
  always_comb begin
    for(integer n=0;n<ENTRIES;n=n+1) begin
      d[n]=q[n];
      if(allocate && int'(allocate_index)==n) d[n]=allocate_data;
      if(update && int'(update_index)==n) d[n][35:4]=update_data;
      if(set_flag && int'(flag_index)==n) d[n][0]=1'b1;
    end
  end
  always_ff @(posedge clk)
    for(integer n=0;n<ENTRIES;n=n+1) if(rst) q[n]<='0;else q[n]<=d[n];
endmodule
