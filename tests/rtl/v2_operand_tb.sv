`timescale 1ns/1ps
module v2_operand_tb;
  reg live=0,prepare=0,old_ready=0,initial_ready=0;
  reg [4:0] source=0;
  reg [31:0] old_value=0,initial_value=0;
  reg [2:0] wb_good=0;
  reg [14:0] wb_slots=0;
  reg [95:0] wb_values=0;
  wire next_ready;
  wire [31:0] next_value;
  reg expected_ready;
  reg [31:0] expected_value;
  integer seed=32'h391b592,step,w,wake=0,hold=0;
  v2_operand dut(.live(live),.prepare(prepare),.old_ready(old_ready),.initial_ready(initial_ready),
    .source(source),.old_value(old_value),.initial_value(initial_value),
    .wb_good(wb_good),.wb_slots(wb_slots),.wb_values(wb_values),
    .next_ready(next_ready),.next_value(next_value));
  initial begin
    for(step=0;step<40000;step=step+1) begin
      live=($random(seed)&3)!=0;prepare=$random(seed);initial_ready=$random(seed);
      source=$random(seed);initial_value=$random(seed);wb_good=$random(seed);
      for(w=0;w<3;w=w+1) begin
        wb_slots[w*5+:5]=($random(seed)&1)!=0 ? source:5'($random(seed));
        wb_values[w*32+:32]=$random(seed);
      end
      expected_ready=old_ready;expected_value=old_value;
      if(live) begin
        for(w=0;w<3;w=w+1)
          if(!old_ready && wb_good[w] && source==wb_slots[w*5+:5]) begin
            expected_ready=1;expected_value=wb_values[w*32+:32];wake=wake+1;
          end
        if(old_ready) hold=hold+1;
      end else if(prepare) begin expected_ready=initial_ready;expected_value=initial_value;end
      #1;
      if(next_ready!==expected_ready || next_value!==expected_value)
        $fatal(1,"operand update mismatch cycle=%0d",step);
      old_ready=expected_ready;old_value=expected_value;
      #1;
    end
    if(wake<1000 || hold<1000) $fatal(1,"insufficient wake/hold coverage");
    $display("Operand wakeup: PASS cycles=%0d matching_ports=%0d ready_holds=%0d",step,wake,hold);
    $finish;
  end
endmodule
