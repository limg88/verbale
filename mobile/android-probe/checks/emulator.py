"""Run only against the task-owned, headless/no-host-audio emulator on port 5584."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
adb='/opt/homebrew/share/android-commandlinetools/platform-tools/adb'
def run(*args,timeout=30):
 p=subprocess.run([adb,'-s','emulator-5584',*args],text=True,capture_output=True,timeout=timeout)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 return p.stdout
assert run('emu','avd','name').splitlines()[0]=='verbale-audio-probe','Refusing any other device'
assert run('shell','getprop','sys.boot_completed').strip()=='1'
for artifact in ['app/build/outputs/apk/debug/app-debug.apk','app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
 print(run('install','-r',str(root/artifact)).strip())
for permission in ['android.permission.RECORD_AUDIO','android.permission.POST_NOTIFICATIONS']:
 run('shell','pm','grant','io.verbale.probe',permission)
output=run('shell','am','instrument','-w','io.verbale.probe.test/io.verbale.probe.ProbeInstrumentation',timeout=45)
(root/'build/emulator-checks.txt').write_text(output)
print(output)
assert 'PASS foreground capture' in output and 'FAIL' not in output, 'Emulator integration failed'
