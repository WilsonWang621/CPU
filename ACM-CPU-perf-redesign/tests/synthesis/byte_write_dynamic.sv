module byte_write_probe #(parameter integer N=128)(input logic clk,
 input logic [2:0] en, input logic [2:0][$clog2(N)-1:0] addr,
 input logic [2:0][31:0] data,input logic [2:0][3:0] strobe,
 input logic [$clog2(N)-1:0] read_addr, output logic [31:0] read_data);
 logic [31:0] q[N];
 assign read_data=q[read_addr];
 always_ff @(posedge clk)
   for(integer p=0;p<3;p=p+1) if(en[p])
     for(integer b=0;b<4;b=b+1) if(strobe[p][b]) q[addr[p]][8*b+:8]<=data[p][8*b+:8];
endmodule
