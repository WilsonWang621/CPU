`timescale 1ns/1ps
module v2_alu_tb;
  reg [5:0] op;
  reg [31:0] a,b,pc,imm,expected;
  wire [31:0] result;
  alu dut(op,a,b,pc,imm,result);
  initial begin
    for(integer sample=0;sample<256;sample=sample+1) begin
      a=sample%8==0 ? 32'hffffffff:$random;
      b=sample%8==1 ? 32'h80000000:$random;
      pc=$random;imm=$random;
      for(integer code=0;code<64;code=code+1) begin
        op=6'(code);
        case(code)
          0:expected=a+b;
          1:expected=a-b;
          2:expected=a<<b[4:0];
          3:expected=$signed(a)<$signed(b);
          4:expected=a<b;
          5:expected=a^b;
          6:expected=a>>b[4:0];
          7:expected=$signed(a)>>>b[4:0];
          8:expected=a|b;
          9:expected=a&b;
          10:expected=imm;
          11:expected=pc+imm;
          default:expected=0;
        endcase
        #1;
        if(result!==expected) $fatal(1,"ALU mismatch op=%0d a=%h b=%h got=%h expected=%h",code,a,b,result,expected);
      end
    end
    $display("Area-v2 ALU: PASS 16384 checks");$finish;
  end
endmodule
