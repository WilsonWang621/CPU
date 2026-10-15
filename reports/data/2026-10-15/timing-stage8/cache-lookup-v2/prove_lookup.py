from pathlib import Path
import subprocess,sys
sys.path.insert(0,'scripts')
from toolchain import enter_appimage,DEFAULT_APPIMAGE,packaged_tool
enter_appimage(DEFAULT_APPIMAGE)
p=Path('build/frequency-stage8/cache-lookup-v2').resolve()
commands=[f'read_verilog -sv -D SYNTHESIS "{p}/rtl/area_v2_core.v" "{p}/lookup_miter.v"',
'hierarchy -check -top lookup_miter','proc','setattr -mod -unset keep_hierarchy','flatten','opt',
'sat -verify -prove bad 0 -show-inputs -show-outputs -timeout 60']
(p/'prove-lookup.ys').write_text('\n'.join(commands)+'\n')
subprocess.run([packaged_tool('yosys'),'-Q','-T','-s',str(p/'prove-lookup.ys')],check=True)
