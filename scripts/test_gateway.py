#!/usr/bin/env python3
"""Exercise Verbale against the actual gateway, with a fake local upstream only."""
import argparse, json, os, shutil, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--project', type=Path, default=Path.home()/'dev/llm-api')
args = parser.parse_args()
output = ROOT/'.build/gateway-integration'
output.mkdir(parents=True, exist_ok=True)
metadata = output/'metadata.json'
metadata.unlink(missing_ok=True)
node = shutil.which('node')
if not node: raise SystemExit('Node.js 24+ richiesto per il gateway.')
with (output/'fixture.log').open('w') as log:
    fixture = subprocess.Popen([node, str(ROOT/'Tests/VerbaleCoreTests/Fixtures/gateway.mjs'), str(args.project), str(output)], stdout=log, stderr=log)
    try:
        for _ in range(100):
            if fixture.poll() is not None: raise RuntimeError('Fixture non avviata: consulta .build/gateway-integration/fixture.log')
            if metadata.exists(): break
            time.sleep(.05)
        else: raise RuntimeError('Avvio fixture scaduto')
        result = subprocess.run(['sh', 'scripts/test.sh', '--gateway-metadata', str(metadata)], cwd=ROOT)
    finally:
        fixture.terminate()
        try: fixture.wait(timeout=5)
        except subprocess.TimeoutExpired: fixture.kill(); fixture.wait()
if (output/'audit.json').exists():
    audit = json.loads((output/'audit.json').read_text())
    if audit['redirectLeaks'] != 0: raise SystemExit('FAIL: token inviato al target del redirect')
    # One successful checkpointed report, two truncated attempts, and a 6000→16000 recovery.
    if audit.get('groqCalls') != 1: raise SystemExit('FAIL: numero di richieste Groq inatteso')
    if audit['reports'] != 7: raise SystemExit('FAIL: numero di richieste modello inatteso: '+str(audit['reports']))
    if audit.get('growthBudgets') != [6000, 16000]: raise SystemExit('FAIL: crescita budget per fase non verificata')
    print('PASS gateway fixture: no redirects leaked; checkpoint avoided duplicate model work; fixture stopped')
else: raise SystemExit('Audit della fixture mancante')
raise SystemExit(result.returncode)
