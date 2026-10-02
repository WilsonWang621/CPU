`timescale 1ns/1ps
module v2_select_wrap_tb;
  reg [7:0] ready;
  reg [39:0] owner;
  reg [4:0] head;
  wire oldest_valid,youngest_valid;
  wire [2:0] oldest,youngest;
  v2_select #(.ENTRIES(8),.SLOT_BITS(5)) old_select (
    .ready(ready),.owner(owner),.rob_head(head),.valid(oldest_valid),.index(oldest));
  v2_select #(.ENTRIES(8),.SLOT_BITS(5),.YOUNGEST(1)) young_select (
    .ready(ready),.owner(owner),.rob_head(head),.valid(youngest_valid),.index(youngest));
  integer seed=32'h6030face,step,row,age_value,min_age,max_age,expected_old,expected_young;
  integer wraps=0,ties=0;
  reg [4:0] distance;
  initial begin
    for(step=0;step<20000;step=step+1) begin
      head=5'($random(seed));ready=8'($random(seed));
      for(row=0;row<8;row=row+1) owner[row*5+:5]=5'($random(seed));
      min_age=32;max_age=-1;expected_old=-1;expected_young=-1;
      for(row=0;row<8;row=row+1) if(ready[row]) begin
        distance=owner[row*5+:5]-head;age_value=int'(distance);
        if(owner[row*5+:5]<head) wraps=wraps+1;
        if(age_value==min_age || age_value==max_age) ties=ties+1;
        if(age_value<min_age) begin min_age=age_value;expected_old=row;end
        if(age_value>max_age) begin max_age=age_value;expected_young=row;end
      end
      #1;
      if(oldest_valid!==(expected_old>=0) || youngest_valid!==(expected_young>=0) ||
         (expected_old>=0 && (int'(oldest)!=expected_old || int'(youngest)!=expected_young)))
        $fatal(1,"circular selection mismatch step=%0d head=%0d",step,head);
    end
    $display("Circular selection: PASS 20000 cases; wrapped=%0d ties=%0d",wraps,ties);
    $finish;
  end
endmodule
