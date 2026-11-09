#!/usr/bin/env python3
"""Build a private comparison from local evaluation results; agreement is not ground truth."""
import pathlib,json,difflib,re,argparse
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);args=p.parse_args();root=args.root.resolve();corpus=json.loads((root/'corpus.json').read_text());variants=['parakeet','parakeet-quality','whisper-glossary','qwen-glossary'];results={v:{r['clip']:r for r in json.loads((root/v/'results.json').read_text())['results']} for v in variants}
def tokens(text):return re.findall(r'\w+',text.casefold())
lines=['# Confronto locale degli estratti reali','', 'Le differenze fra modelli non costituiscono un riferimento umano e non sono conteggiate come errori certi. I file audio sono copie locali.',''];cases=[]
for item in corpus:
 if item['synthetic']:continue
 key=item['id'];lines += ['## '+key,'',f"Estratto originale: {item['sourceStart']}–{item['sourceStart']+60} secondi.",'',f"[Ascolta la copia audio](<{item['audio']}>)",'']
 base=tokens(results['parakeet'][key]['text'])
 for variant in variants:
  row=results[variant][key];lines += ['### '+variant,'',row['text'].strip(),'']
  if variant=='parakeet':continue
  other=tokens(row['text'])
  for tag,a,b,c,d in difflib.SequenceMatcher(None,base,other,autojunk=False).get_opcodes():
   if tag=='equal':continue
   cases.append({'clip':key,'variant':variant,'baseline':' '.join(base[a:b]),'candidate':' '.join(other[c:d]),'baselineTokenRange':[a,b],'requiresAudioVerification':True})
(root/'real-review.md').write_text('\n'.join(lines));(root/'real-disagreements.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2));print('Prepared',len(cases),'disagreements for audio verification; no WER assigned to real clips')
