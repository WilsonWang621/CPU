from pathlib import Path
p=Path('build/frequency-stage7/build_redirect_trial.py')
s=p.read_text().replace('all-trees-redirect/rtl','address-radix4/rtl')
s=s.replace("source=Path('verilog/area_v2/muldiv.sv').read_text()", "source=Path('verilog/area_v2/muldiv.sv').read_text().replace('parameter integer DIV_STEP_BITS=4','parameter integer DIV_STEP_BITS=2')")
add='''
core=Path('verilog/area_v2/cpu_top.sv').read_text()
core=core.replace('logic [31:0] memory_address,memory_data,load_word,load_result;',
    'logic [31:0] memory_address,memory_data,load_word,load_result;\\n'
    '  logic [31:0] prepared_address [IQ_ENTRIES];\\n'
    '  wire [IQ_ENTRIES*32-1:0] prepared_address_words;')
core=core.replace('assign memory_address=executing[2].a+executing[2].imm;',\"\"\"
  for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: memory_address_words
    assign prepared_address_words[q*32+:32]=prepared_address[q];
  end
  v2_iq_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(32)) read_memory_address (
    .index(selected[2]),.words(prepared_address_words),.value(memory_address));
\"\"\")
needle=''' + repr('''      always_ff @(posedge clk) begin
        queue[bank][q].ready_a<=next_ready_a;queue[bank][q].a<=next_value_a;
        queue[bank][q].ready_b<=next_ready_b;queue[bank][q].b<=next_value_b;
      end
''')+'''
assert core.count(needle)==1
core=core.replace(needle,needle+\"\"\"
      if(bank==2) begin: address_prepare
        wire [31:0] address_immediate=queue[bank][q].valid ? queue[bank][q].imm:
          (prepare_lane[1] ? dispatch_payload[1].imm:dispatch_payload[0].imm);
        wire address_update=(!queue[bank][q].valid && |prepare_lane) ||
                            (queue[bank][q].valid && !queue[bank][q].ready_a);
        always_ff @(posedge clk)
          if(address_update) prepared_address[q]<=next_value_a+address_immediate;
      end
\"\"\")
(root/'cpu_top.sv').write_text(core)
'''
s=s.replace("(root/'muldiv.sv').write_text(source)", "(root/'muldiv.sv').write_text(source)\n"+add)
s=s.replace("source if path.name=='muldiv.sv' else path.read_text()", "source if path.name=='muldiv.sv' else core if path.name=='cpu_top.sv' else path.read_text()")
Path('build/frequency-stage7/build_address_trial.py').write_text(s)
