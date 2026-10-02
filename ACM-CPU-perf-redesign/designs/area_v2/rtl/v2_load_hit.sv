// Timing prototype for the candidate's one-cycle hit path: full 32-bit AGU,
// 2 KiB / 2-way / 32-byte sector lookup, one data read port, byte extraction,
// and a registered result. External logic owns misses and arbitrates writes.
// This module alone is NOT a cache controller or an implementation of the LSU.
module v2_load_hit (
  input logic clk,rst,request_valid,
  input logic [31:0] base,offset,
  input logic [1:0] size,
  input logic sign_extend,
  input logic data_write_valid,
  input logic [8:0] data_write_address,
  input logic [31:0] data_write_value,
  input logic [3:0] data_write_mask,
  input logic tag_write_valid,tag_write_way,
  input logic [4:0] tag_write_set,
  input logic [7:0] tag_write_tag,tag_write_words,
  output logic response_valid,response_fault,miss,
  output logic [31:0] response_value
);
  (* ram_style="registers" *) logic [31:0] data_words [512];
  (* ram_style="registers" *) logic [15:0] tags0 [32],tags1 [32];
  logic [31:0] tag_valid0,tag_valid1;
  logic [31:0] address,word_value,shifted,value;
  logic [15:0] tag0,tag1;
  logic hit0,hit1,fault;
  logic [8:0] read_address;
  assign address=base+offset;
  assign tag0=tags0[address[9:5]];
  assign tag1=tags1[address[9:5]];
  assign hit0=tag_valid0[address[9:5]] && tag0[15:8]==address[17:10] && tag0[{1'b0,address[4:2]}];
  assign hit1=tag_valid1[address[9:5]] && tag1[15:8]==address[17:10] && tag1[{1'b0,address[4:2]}];
  assign read_address={address[9:5],!hit0,address[4:2]};
  assign word_value=data_words[read_address];
  assign shifted=word_value >> (8*address[1:0]);
  assign value=size==0 ? {{24{sign_extend && shifted[7]}},shifted[7:0]} :
               size==1 ? {{16{sign_extend && shifted[15]}},shifted[15:0]} : shifted;
  assign fault=(|address[31:18]) || size==3 ||
               (size==2 && (|address[1:0])) || (size==1 && address[0]);
  assign miss=request_valid && !fault && !(hit0 || hit1);
  always_ff @(posedge clk) begin
    if (rst) begin
      tag_valid0<=0;tag_valid1<=0;
      response_valid<=0;response_fault<=0;
    end else begin
      response_valid<=request_valid && (fault || hit0 || hit1);
      response_fault<=request_valid && fault;
      if (request_valid) response_value<=value;
      if (tag_write_valid) begin
        if (tag_write_way) begin
          tag_valid1[tag_write_set]<=1;
          tags1[tag_write_set]<={tag_write_tag,tag_write_words};
        end else begin
          tag_valid0[tag_write_set]<=1;
          tags0[tag_write_set]<={tag_write_tag,tag_write_words};
        end
      end
      for (integer b=0;b<4;b=b+1)
        if (data_write_valid && data_write_mask[b])
          data_words[data_write_address][b*8+:8]<=data_write_value[b*8+:8];
    end
  end
endmodule
