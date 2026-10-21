// Generated SRAM wrappers; do not edit.
module sram_fakeram_8x39_m39 (
    input clk, en, we,
    input [0:0] wmask,
    input [2:0] addr,
    input [38:0] wdata,
    output [38:0] rdata);
    fakeram_asap7_8x39 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[38:0]), .rd_out(rdata[38:0]));
endmodule

module sram_fakeram_64x20_m20 (
    input clk, en, we,
    input [0:0] wmask,
    input [5:0] addr,
    input [19:0] wdata,
    output [19:0] rdata);
    fakeram_asap7_64x20 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[19:0]), .rd_out(rdata[19:0]));
endmodule

module sram_fakeram_128x32_m8 (
    input clk, en, we,
    input [3:0] wmask,
    input [6:0] addr,
    input [31:0] wdata,
    output [31:0] rdata);
    fakeram_asap7_128x8 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[7:0]), .rd_out(rdata[7:0]));
    fakeram_asap7_128x8 lane_1 (
        .clk(clk), .ce_in(en & (~we | wmask[1])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[15:8]), .rd_out(rdata[15:8]));
    fakeram_asap7_128x8 lane_2 (
        .clk(clk), .ce_in(en & (~we | wmask[2])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[23:16]), .rd_out(rdata[23:16]));
    fakeram_asap7_128x8 lane_3 (
        .clk(clk), .ce_in(en & (~we | wmask[3])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[31:24]), .rd_out(rdata[31:24]));
endmodule

module sram_fakeram_1024x32_m8 (
    input clk, en, we,
    input [3:0] wmask,
    input [9:0] addr,
    input [31:0] wdata,
    output [31:0] rdata);
    fakeram_asap7_1024x8 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[7:0]), .rd_out(rdata[7:0]));
    fakeram_asap7_1024x8 lane_1 (
        .clk(clk), .ce_in(en & (~we | wmask[1])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[15:8]), .rd_out(rdata[15:8]));
    fakeram_asap7_1024x8 lane_2 (
        .clk(clk), .ce_in(en & (~we | wmask[2])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[23:16]), .rd_out(rdata[23:16]));
    fakeram_asap7_1024x8 lane_3 (
        .clk(clk), .ce_in(en & (~we | wmask[3])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[31:24]), .rd_out(rdata[31:24]));
endmodule
