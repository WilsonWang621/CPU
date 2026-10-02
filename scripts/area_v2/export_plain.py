#!/usr/bin/env python3
"""Emit this core's explicit packed-word RTL; no external HDL converter.

The record layouts are lowered to named bit offsets and the two-dimensional
queues to linear arrays. The checked-in output is the course-toolchain input.
This is deliberately limited to the constructs used by area_v2/*.sv.
"""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'verilog/area_v2'
DEST = ROOT / 'verilog/area_v2_core.v'


def no_comments(s):
    return re.sub(r'//[^\n]*|/\*.*?\*/', '', s, flags=re.S)


def brackets(s, pos):
    start = pos
    depth = 0
    for pos in range(pos, len(s)):
        depth += s[pos] == '['
        depth -= s[pos] == ']'
        if depth == 0:
            return s[start+1:pos], pos+1
    raise ValueError('unbalanced subscript')


def split_top(s, separator=','):
    parts = []; start = 0; depth = 0
    for i, c in enumerate(s):
        if c in '([{': depth += 1
        if c in ')]}': depth -= 1
        if c == separator and depth == 0:
            parts.append(s[start:i]); start = i+1
    parts.append(s[start:])
    return parts


def width(hi, lo):
    try: return str(int(hi)-int(lo)+1)
    except ValueError: return f'(({hi})-({lo})+1)'


def records(text, schemas):
    def lower(m):
        body, typename = m.groups(); fields = []
        for statement in body.split(';'):
            statement = statement.strip()
            if not statement: continue
            f = re.fullmatch(r'(logic|op_t|rid_t)\s*(?:\[([^:]+):([^\]]+)\])?\s*(.*)', statement)
            if not f: raise ValueError(statement)
            kind, hi, lo, names = f.groups()
            w = width(hi, lo) if hi else ('6' if kind == 'op_t' else 'RW' if kind == 'rid_t' else '1')
            for name in names.split(','): fields.append((name.strip(), w))
        schemas[typename] = fields
        return ''
    return re.sub(r'typedef\s+struct\s+packed\s*\{(.*?)\}\s*(\w+)\s*;', lower, text, flags=re.S)


def layout(schemas):
    lines = []
    for typ, fields in schemas.items():
        offset = '0'
        for name, w in reversed(fields):
            prefix = typ.upper()+'_'+name.upper()
            lines += [f'localparam integer {prefix}_LSB={offset}, {prefix}_WIDTH={w};']
            offset = f'{prefix}_LSB+{prefix}_WIDTH'
        lines += [f'localparam integer {typ.upper()}_WIDTH={offset};']
    return '\n'.join(lines)+'\n'


def lower(source, package):
    s = no_comments(source)
    # Optional verification scopes contain no functional state.
    s = re.sub(r'`ifdef V2_VERIFY.*?`endif', '', s, flags=re.S)
    s = re.sub(r'`ifndef SYNTHESIS.*?`endif', '', s, flags=re.S)
    schemas = {}; package = records(package, schemas); s = records(s, schemas)
    def enum(m):
        hi, body, name = m.groups()
        values = []
        for i, n in enumerate(body.split(',')): values.append(f'{n.strip()}={i}')
        aliases[name] = f'[{hi}:0]'
        return 'localparam '+', '.join(values)+';'
    aliases = {'op_t': '[5:0]', 'rid_t': '[RW-1:0]'}
    package = re.sub(r'typedef enum logic \[([^:]+):0\]\s*\{(.*?)\}\s*(\w+)\s*;', enum, package, flags=re.S)
    s = re.sub(r'typedef enum logic \[([^:]+):0\]\s*\{(.*?)\}\s*(\w+)\s*;', enum, s, flags=re.S)
    package = re.sub(r'\bpackage\s+cpu_pkg\s*;|\bendpackage\b', '', package)
    s = re.sub(r'typedef logic \[RW-1:0\] rid_t\s*;', '', s)
    # A record port must use a literal width: body localparams are not in ANSI scope.
    decoded_width = sum(int(w) for _, w in schemas['decoded_t'])
    s = s.replace('cpu_pkg::decoded_t',f'logic [{decoded_width-1}:0]')
    s = s.replace('cpu_pkg::op_t','logic [5:0]')
    # Record variables and array dimensions are gathered before replacing types.
    variables = {'dec': 'decoded_t'} if re.search(r'\bmodule decoder\b', s) else {}
    array_dimensions = {}
    type_names = ['logic', *aliases, *schemas]
    decl = re.compile(r'\b('+'|'.join(type_names)+r')\b\s*(\[[^\]]+\])?\s*([^;]+);')
    def declaration(m):
        typ, packed, body = m.groups()
        # Don't consume an ANSI port list as a body declaration.
        if '\n);' in m.group(0) or re.search(r'\b(input|output)\b', body): return m.group(0)
        out=[]
        for item in split_top(body):
            match=re.fullmatch(r'\s*(\w+)\s*((?:\[[^\]]+\]\s*)*)(?:\s*=\s*(.*))?',item,flags=re.S)
            if not match: return m.group(0)
            name, dimensions, init=match.groups()
            dims=re.findall(r'\[([^\]]+)\]',dimensions)
            if typ in schemas: variables[name]=typ
            if dims:
                assert all(':' not in d for d in dims),dims
                array_dimensions[name]=dims
                dimensions='[0:('+')*('.join(dims)+')-1]'
            out.append(name+(' '+dimensions if dimensions else '')+((' = '+init) if init else ''))
        packed = packed or (aliases.get(typ) if typ in aliases else f'[{typ.upper()}_WIDTH-1:0]' if typ in schemas else '')
        return 'logic '+packed+' '+', '.join(out)+';'
    s=decl.sub(declaration,s)
    # Expand the shared operation/fault definitions into each module.
    s=s.replace('import cpu_pkg::*;',package+'\n'+layout(schemas))
    if 'import cpu_pkg' not in source:
        pos=s.index(');')+2;s=s[:pos]+'\n'+package+'\n'+layout(schemas)+s[pos:]
    # Replace record members, including a slice of a member, in one pass.
    def member(m):
        name=m.group(0); pos=m.end(); expression=name; subs=[]
        while pos<len(s) and s[pos].isspace():pos+=1
        while pos<len(s) and s[pos]=='[':
            sub,pos=brackets(s,pos);subs.append(sub)
            while pos<len(s) and s[pos].isspace():pos+=1
        dims=array_dimensions.get(name,[])
        if len(dims)>1 and len(subs)>=len(dims):
            index=subs[0]
            for d,x in zip(dims[1:],subs[1:]):index=f'({index})*({d})+({x})'
            expression+='['+index+']'
            for x in subs[len(dims):]:expression+='['+x+']'
        else: expression+=''.join('['+x+']' for x in subs)
        if name not in variables or pos>=len(s) or s[pos]!='.':return None
        field=re.match(r'\.(\w+)',s[pos:]).group(1);pos+=len(field)+1
        prefix=variables[name].upper()+'_'+field.upper()
        if field not in dict(schemas[variables[name]]):raise ValueError(field)
        if pos<len(s) and s[pos]=='[':
            sub,pos=brackets(s,pos)
            parts=split_top(sub,':')
            if len(parts)==2 and '+' not in parts[0][-1:]:
                expression+=f'[{prefix}_LSB+({parts[0]}):{prefix}_LSB+({parts[1]})]'
            elif len(parts)==1: expression+=f'[{prefix}_LSB+({sub})]'
            else: raise ValueError(sub)
        else:expression+=f'[{prefix}_LSB+:{prefix}_WIDTH]'
        return m.start(),pos,expression
    edits=[]
    for m in re.finditer(r'\b(?:'+'|'.join(variables)+r')\b',s):
        e=member(m)
        if e:edits.append(e)
    for a,b,r in reversed(edits):s=s[:a]+r+s[b:]
    # Flatten non-record multidimensional arrays (the checkpoint RAT).
    for name,dims in array_dimensions.items():
        if len(dims)<2:continue
        edits=[]
        for m in re.finditer(r'\b'+name+r'\b',s):
            pos=m.end();subs=[]
            while pos<len(s) and s[pos].isspace():pos+=1
            for _ in dims:
                if pos<len(s) and s[pos]=='[':sub,pos=brackets(s,pos);subs.append(sub)
            if len(subs)==len(dims):
                index=subs[0]
                for d,x in zip(dims[1:],subs[1:]):index=f'({index})*({d})+({x})'
                edits.append((m.start(),pos,name+'['+index+']'))
        for a,b,r in reversed(edits):s=s[:a]+r+s[b:]
    # Functions use traditional result assignment rather than SV return.
    def function(m):
        text=m.group(0);name=re.search(r'function automatic (?:logic\s*(?:\[[^\]]+\])?|rid_t)\s+(\w+)\(',text).group(1)
        return re.sub(r'\breturn\s+',name+' = ',text)
    s=re.sub(r'function automatic.*?endfunction',function,s,flags=re.S)
    for name, packed in aliases.items():
        s=re.sub(r'\b'+name+r"\s*'",('RW' if name=='rid_t' else '6')+"'",s)
        s=re.sub(r'\b'+name+r'\b','logic '+packed,s)
    s=re.sub(r'\blogic\b','reg',s)
    s=s.replace('always_comb','always @*').replace('always_ff','always')
    s=re.sub(r"'0\b",'0',s)
    # Classify declarations by actual procedural assignments. Other outputs
    # and continuous-assignment nets are wires, as required by Verilog.
    assigned=set()
    lhs=re.compile(r'\b(\w+)\s*(?:\[[^;]+?\]\s*)*(?:<=|=(?!=))')
    for m in lhs.finditer(s):
        prefix=s[max(0,s.rfind(';',0,m.start())+1):m.start()]
        if not re.search(r'\b(assign|parameter|localparam)\b',prefix):assigned.add(m.group(1))
    # Split body declarations so mixed procedural/module outputs can differ.
    def classify(m):
        packed,body=m.groups();out=[]
        for item in split_top(body):
            name=re.match(r'\s*(\w+)',item).group(1)
            out.append(('reg' if name in assigned else 'wire')+' '+(packed or '')+' '+item.strip()+';')
        return '\n  '.join(out)
    # Only full declarations, not port groups/function arguments.
    s=re.sub(r'(?m)^\s*reg\s*(\[[^\]]+\])?\s*([^;]+);',classify,s)
    def port(m):
        direction,packed,body=m.groups();names=[x.strip() for x in body.split(',')]
        return ',\n  '.join(direction+' '+('reg' if n in assigned else 'wire')+' '+(packed or '')+' '+n for n in names)
    s=re.sub(r'\b(input|output)\s+reg\s*(\[[^\]]+\])?\s*((?:\w+\s*,\s*)*\w+)(?=\s*[,\)])',port,s)
    s=re.sub(r'\n\s*\n\s*\n','\n\n',s)
    assert not re.search(r'\b(typedef|import|package|struct|return|logic)\b',s)
    return s


def main():
    package=(SOURCE/'cpu_pkg.sv').read_text()
    files=sorted(p for p in SOURCE.glob('*.sv') if p.name!='cpu_pkg.sv')
    output='// Area-v2 packed-word implementation. Generated by scripts/area_v2/export_plain.py.\n'
    output+='// Architecture adapted from Galuisss/ACM-CPU, designs/area_v2.\n'
    output+='\n'.join(lower(p.read_text(),package) for p in files)
    DEST.write_text(output)
    metadata={'sources_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [SOURCE/'cpu_pkg.sv',*files]},
              'output_sha256':hashlib.sha256(DEST.read_bytes()).hexdigest(),'external_converter_required':False}
    DEST.with_suffix('.json').write_text(json.dumps(metadata,indent=2)+'\n')

if __name__=='__main__':main()
