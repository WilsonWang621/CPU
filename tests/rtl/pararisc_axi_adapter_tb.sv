module pararisc_axi_adapter_tb;
  reg clock=0,reset=1,req_valid=0,req_write=0,resp_ready=0;
  reg [31:0] req_addr=0,req_data=0;
  reg [3:0] req_mask=0;
  wire req_ready,resp_valid,resp_error;
  wire [31:0] resp_data;
  wire [31:0] araddr,awaddr,wdata;
  wire [3:0] wstrb;
  wire arvalid,awvalid,wvalid,rready,bready;
  reg arready=0,awready=0,wready=0,rvalid=0,bvalid=0;
  reg [31:0] rdata=0;
  reg [1:0] rresp=0,bresp=0;
  pararisc_axi_adapter dut(.*);
  always #5 clock=~clock;
  reg [31:0] reads[0:511],aws[0:511],ws[0:511];
  reg [3:0] masks[0:511];
  integer rn=0,rh=0,an=0,wn=0,bh=0,accepted=0,returned=0,cycles=0;
  integer aw_stalls=0,w_stalls=0,blocked_b=0;
  reg held_ar=0,held_aw=0,held_w=0;
  reg [31:0] held_araddr,held_awaddr,held_wdata;
  reg [3:0] held_wstrb;
  function automatic writing(input integer i);writing=(i%3)!=0;endfunction
  function automatic [3:0] mask(input integer i);mask=4'(1+(i%15));endfunction
  always @(negedge clock) if(!reset) begin
    arready=($urandom%4)!=0;awready=($urandom%5)==0;wready=($urandom%3)==0;
    resp_ready=($urandom%4)!=0;
  end
  always @(posedge clock) if(!reset) begin
    cycles=cycles+1;
    if(cycles>15000) $fatal(1,"AXI timeout accepted=%0d returned=%0d",accepted,returned);
    if(held_ar && (!arvalid || araddr!==held_araddr)) $fatal(1,"AR changed under backpressure");
    if(held_aw && (!awvalid || awaddr!==held_awaddr)) $fatal(1,"AW changed under backpressure");
    if(held_w && (!wvalid || wdata!==held_wdata || wstrb!==held_wstrb)) $fatal(1,"W changed under backpressure");
    held_ar=arvalid&&!arready;held_aw=awvalid&&!awready;held_w=wvalid&&!wready;
    held_araddr=araddr;held_awaddr=awaddr;held_wdata=wdata;held_wstrb=wstrb;
    if(held_aw) aw_stalls=aw_stalls+1;
    if(held_w) w_stalls=w_stalls+1;
    if(bvalid && !bready) blocked_b=blocked_b+1;
    if(req_valid&&req_ready) accepted=accepted+1;
    if(resp_valid&&resp_ready) begin
      if(returned>=accepted) $fatal(1,"unowned response");
      if(writing(returned)) begin
        if(resp_data!==0 || resp_error!==((returned%16)==1)) $fatal(1,"write response out of order %0d",returned);
      end else begin
        if(resp_data!==(32'(returned*4)^32'h12345678) || resp_error!==((returned%8)==0))
          $fatal(1,"read response out of order %0d data=%h",returned,resp_data);
      end
      returned=returned+1;
    end
    if(arvalid&&arready) begin reads[rn]=araddr;rn=rn+1;end
    if(awvalid&&awready) begin aws[an]=awaddr;an=an+1;end
    if(wvalid&&wready) begin ws[wn]=wdata;masks[wn]=wstrb;wn=wn+1;end
    if(rvalid&&rready) begin rh=rh+1;rvalid<=0;end
    if(bvalid&&bready) begin bh=bh+1;bvalid<=0;end
    if(!rvalid && rh<rn && ($urandom%3)==0) begin
      rvalid<=1;rdata<=reads[rh]^32'h12345678;rresp<=reads[rh][4:2]==0 ? 2:0;
    end
    // Write responses can become visible before older read responses.
    if(!bvalid && bh<an && bh<wn) begin
      if(ws[bh]!==((aws[bh]>>2)^32'hbad01234) || masks[bh]!==mask(aws[bh]>>2)) $fatal(1,"AW/W pairing wrong");
      bvalid<=1;bresp<=aws[bh][5:2]==1 ? 3:0;
    end
  end
  initial begin
    repeat(3) @(negedge clock);reset=0;
    for(integer i=0;i<240;i=i+1) begin
      @(negedge clock);req_valid=1;req_write=writing(i);req_addr=32'(i*4);req_data=32'(i)^32'hbad01234;req_mask=mask(i);
      @(posedge clock);while(!req_ready) @(posedge clock);
      @(negedge clock);req_valid=0;
    end
    wait(returned==240);@(negedge clock);
    if(aw_stalls==0 || w_stalls==0 || blocked_b==0) $fatal(1,"missing backpressure coverage");
    $display("AXI adapter: PASS 240 mixed requests; AW stalls=%0d W stalls=%0d B waits=%0d",aw_stalls,w_stalls,blocked_b);$finish;
  end
endmodule
