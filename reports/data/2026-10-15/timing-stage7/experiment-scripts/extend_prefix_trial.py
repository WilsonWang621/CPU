from pathlib import Path
b=Path('build/frequency-stage7/build_mul2_trial.py').read_text().replace('address-mul2/rtl','address-mul2-prefix/rtl')
old="(root/'muldiv.sv').write_text(source)"
new="""source=source.replace('wire [31:0] product_high=sum3+carry3;',
    'wire [31:0] product_high;\\n'
    '  v2_prefix_adder #(.WIDTH(32)) product_final_add (.a(sum3),.b(carry3),.carry_in(1\\\'b0),.sum(product_high),.carry_out());')
(root/'muldiv.sv').write_text(source)"""
assert old in b;b=b.replace(old,new)
needle="(root/'cpu_top.sv').write_text(core)"
replacement='''
core=core.replace('if(address_update) prepared_address[q]<=next_value_a+address_immediate;',
    'if(address_update) prepared_address[q]<=address_sum;')
core=core.replace('wire address_update=',
    "wire [31:0] address_sum;\\n"
    "        v2_prefix_adder #(.WIDTH(32)) effective_address_add (.a(next_value_a),.b(address_immediate),.carry_in(1'b0),.sum(address_sum),.carry_out());\\n"
    '        wire address_update=')
(root/'cpu_top.sv').write_text(core)
alu=Path('verilog/area_v2/alu.sv').read_text()
alu=alu.replace('  always_comb begin',\"\"\"
  wire subtract=op==OP_SUB || op==OP_SLT || op==OP_SLTU;
  wire [31:0] arithmetic_value,pc_value;
  wire no_borrow;
  v2_prefix_adder #(.WIDTH(32)) add_operands (
    .a(a),.b(b^{32{subtract}}),.carry_in(subtract),.sum(arithmetic_value),.carry_out(no_borrow));
  v2_prefix_adder #(.WIDTH(32)) add_pc (
    .a(pc),.b(imm),.carry_in(1'b0),.sum(pc_value),.carry_out());
  always_comb begin\"\"\")
alu=alu.replace('result = a + b;', 'result = arithmetic_value;').replace('result = a - b;', 'result = arithmetic_value;')
alu=alu.replace("result = {31'b0, $signed(a) < $signed(b)};", "result = {31'b0, a[31]!=b[31] ? a[31]:!no_borrow};")
alu=alu.replace("result = {31'b0, a < b};", "result = {31'b0, !no_borrow};")
alu=alu.replace('result = pc + imm;', 'result = pc_value;')
(root/'alu.sv').write_text(alu)
'''
assert needle in b;b=b.replace(needle,replacement)
b=b.replace("else core if path.name=='cpu_top.sv' else path.read_text()", "else core if path.name=='cpu_top.sv' else alu if path.name=='alu.sv' else path.read_text()")
Path('build/frequency-stage7/build_prefix_trial.py').write_text(b)
