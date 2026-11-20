#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/checks
javac -d build/checks app/src/main/java/io/verbale/probe/SignalStats.java app/src/main/java/io/verbale/probe/WavWriter.java app/src/main/java/io/verbale/probe/SharePaths.java checks/ProbeChecks.java
java -cp build/checks io.verbale.probe.ProbeChecks
python3 - <<'PY'
import xml.etree.ElementTree as ET
m=ET.parse('app/src/main/AndroidManifest.xml').getroot(); a='{http://schemas.android.com/apk/res/android}'
p={x.get(a+'name') for x in m.findall('uses-permission')}
assert 'android.permission.INTERNET' not in p
assert 'android.permission.READ_CONTACTS' not in p
assert 'android.permission.READ_CALL_LOG' not in p
assert 'android.permission.MANAGE_EXTERNAL_STORAGE' not in p
assert m.find('application').get(a+'allowBackup')=='false'
assert m.find('application/service').get(a+'exported')=='false'
assert m.find('application/provider').get(a+'exported')=='false'
print('PASS local-only permissions and private component configuration')
PY
