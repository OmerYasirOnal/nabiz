#!/bin/zsh
# Hardware smoke check. Python is used only by this development check, not the app.
set -euo pipefail
source_dir=${0:A:h}
app_path=${1:-"$source_dir/build/Nabiz.app"}
codesign --verify --strict "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
python3 - "$app_path" <<'PYTEST'
import plistlib,subprocess,sys
app=sys.argv[1]
r=subprocess.run(['codesign','--display','--entitlements','-','--xml',app],check=True,capture_output=True)
e=plistlib.loads(r.stdout)
assert e=={'com.apple.security.app-sandbox':True,'com.apple.security.temporary-exception.iokit-user-client-class':['AppleSMCClient']},e
r=subprocess.run(['codesign','--display','--verbose=2',app],check=True,capture_output=True,text=True)
assert 'runtime' in r.stderr and 'TeamIdentifier=not set' not in r.stderr
print('PASS: App Sandbox, stable signing and minimal entitlements')
PYTEST
"$app_path/Contents/MacOS/Nabiz" --self-test
"$app_path/Contents/MacOS/Nabiz" --sample | python3 -c '
import json,sys,math
s=json.load(sys.stdin)
assert s["ramTotalGiB"]>0
assert 0<=s["ramUsedGiB"]<=s["ramTotalGiB"]
for name in ("cpu","gpu"):
    assert s[name] is None or (math.isfinite(s[name]) and 0<=s[name]<=100),name
assert s["cpuSensorMaxC"] is None or 0<s["cpuSensorMaxC"]<130
assert all(v is None or 0<=v<20000 for v in s["fanRPM"])
assert s["diskFreeGiB"] is None or s["diskFreeGiB"]>=0
print(json.dumps(s,ensure_ascii=False,indent=2))
print("PASS: signed bundle, live metrics and sensor ranges")
'

python3 - "$source_dir" "$app_path" <<'PYTEST'
from pathlib import Path
import subprocess,sys,tempfile
with tempfile.TemporaryDirectory(prefix='sandbox-denied-',dir=Path(sys.argv[1])/'build') as folder:
    fixture=Path(folder)/'fixture.txt'
    marker=b'Nabiz sandbox fixture; no personal data.'
    fixture.write_bytes(marker);fixture.chmod(0o600)
    subprocess.run([str(Path(sys.argv[2]).resolve()/'Contents/MacOS/Nabiz'),'--sandbox-test',str(fixture.resolve())],check=True)
    assert fixture.read_bytes()==marker
PYTEST
