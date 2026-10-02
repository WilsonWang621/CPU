module v2_load_hit_tb;
  logic clk=0,rst=1,request_valid=0;
  logic [31:0] base=0,offset=0;
  logic [1:0] size=2;
  logic sign_extend=0,data_write_valid=0;
  logic [8:0] data_write_address=0;
  logic [31:0] data_write_value=0;
  logic [3:0] data_write_mask=0;
  logic tag_write_valid=0,tag_write_way=0;
  logic [4:0] tag_write_set=0;
  logic [7:0] tag_write_tag=0,tag_write_words=0;
  logic response_valid,response_fault,miss;
  logic [31:0] response_value;
  v2_load_hit dut(.*);
  task automatic tick;
    #1;clk=1;#1;clk=0;
  endtask
  task automatic expect_value(input logic [31:0] expected);
    #1;assert (!miss) else $fatal(1,"unexpected miss");tick();
    assert (response_valid && !response_fault && response_value==expected)
      else $fatal(1,"hit value expected=%h actual=%h",expected,response_value);
  endtask
  initial begin
    tick();rst=0;
    base=32'h9474;request_valid=1;
    #1;assert (miss) else $fatal(1,"cold request was not a miss");tick();
    assert (!response_valid) else $fatal(1,"cold miss produced a hit");
    request_valid=0;data_write_valid=1;data_write_address={5'd3,1'b0,3'd5};
    data_write_value=32'hdeadbeef;data_write_mask=15;
    tag_write_valid=1;tag_write_way=0;tag_write_set=3;tag_write_tag='h25;tag_write_words='h20;tick();
    data_write_valid=0;tag_write_valid=0;request_valid=1;expect_value(32'hdeadbeef);
    request_valid=0;data_write_valid=1;data_write_address={5'd3,1'b1,3'd5};
    data_write_value=32'h80ff7f01;tag_write_valid=1;tag_write_way=1;tag_write_tag='h41;tick();
    request_valid=1;data_write_valid=0;tag_write_valid=0;base=32'h10474;expect_value(32'h80ff7f01);
    size=0;offset=3;sign_extend=1;expect_value(32'hffffff80);
    size=1;offset=2;expect_value(32'hffff80ff);
    sign_extend=0;expect_value(32'h000080ff);
    request_valid=0;data_write_valid=1;data_write_value=32'h00330000;data_write_mask=4;tick();
    request_valid=1;data_write_valid=0;size=2;offset=0;expect_value(32'h80337f01);
    offset=1;tick();assert(response_valid && response_fault) else $fatal(1,"alignment check");
    base=32'h40000;offset=0;tick();assert(response_valid && response_fault) else $fatal(1,"full address range check");
    base=32'h10470;#1;assert(miss) else $fatal(1,"word validity check");
    $display("PASS load hit: cold miss, both ways, byte mask, sign extension, range and alignment");
    $finish;
  end
endmodule
