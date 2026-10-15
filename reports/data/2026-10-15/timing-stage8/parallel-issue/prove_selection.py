from pathlib import Path
import subprocess,sys
sys.path.insert(0,'scripts')
from toolchain import enter_appimage,DEFAULT_APPIMAGE,packaged_tool
enter_appimage(DEFAULT_APPIMAGE)
p=Path('build/frequency-stage8/parallel-issue').resolve()
commands=[f'read_verilog -sv "{p}/rtl/area_v2_core.v" "{p}/selection_miter.v"',
'hierarchy -check -top selection_miter','proc','setattr -mod -unset keep_hierarchy','flatten','opt',
'sat -verify -prove bad 0 -show-inputs -show-outputs -timeout 60']
(p/'prove-selection.ys').write_text('\n'.join(commands)+'\n')
subprocess.run([packaged_tool('yosys'),'-Q','-T','-s',str(p/'prove-selection.ys')],check=True)
