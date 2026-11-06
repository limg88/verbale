#!/usr/bin/env python3
"""Offline ASR comparison. Prepare corpus/model paths explicitly; never uploads audio."""
import argparse,json,pathlib,os,time,re,resource,subprocess

def wer(reference,hypothesis):
    a=re.findall(r'\w+',reference.lower());b=re.findall(r'\w+',hypothesis.lower());d=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        n=[i]
        for j,y in enumerate(b,1):n.append(min(n[-1]+1,d[j]+1,d[j-1]+(x!=y)))
        d=n
    raw={'errors':d[-1],'referenceWords':len(a),'wer':d[-1]/max(1,len(a))}
    def normalize(text):
        for number,word in [('10','dieci'),('11','undici')]:text=re.sub(r'\b'+number+r'\b',word,text)
        return text
    if reference!=normalize(reference) or hypothesis!=normalize(hypothesis):
        normalized=wer(normalize(reference),normalize(hypothesis));raw['normalizedWER']=normalized.get('normalizedWER',normalized['wer'])
    else:raw['normalizedWER']=raw['wer']
    return raw

def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--engine',choices=['parakeet','parakeet-quality','whisper','qwen'],required=True);p.add_argument('--glossary',action='store_true');a=p.parse_args();root=a.root.resolve()
    os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1',HF_HOME=str(root/'hf'))
    corpus=json.loads((root/'corpus.json').read_text());models=json.loads((root/'models.lock.json').read_text());variant=a.engine+('-glossary' if a.glossary else '');out=root/variant;out.mkdir(exist_ok=True,mode=0o700)
    load_start=time.perf_counter();model=None
    if a.engine=='whisper':import mlx_whisper
    elif a.engine=='qwen':
        from mlx_audio.stt import load
        model=load(models['mlx-community/Qwen3-ASR-1.7B-8bit']['path'])
    load_seconds=time.perf_counter()-load_start;rows=[]
    for item in corpus:
        started=time.perf_counter();error=None;text='';words=[]
        try:
            if a.engine.startswith('parakeet'):
                support=pathlib.Path.home()/'Library/Application Support/Verbale/Models';destination=out/item['id']/str(time.time_ns())
                cmd=[str(pathlib.Path.cwd()/'.build/swift/debug/verbale-cli'),'transcribe-quality' if a.engine=='parakeet-quality' else 'transcribe-live',item['audio'],str(support/'tdt-0.6b-v3-q8_0.gguf'),str(support/'silero-vad-f16.gguf'),str(destination)]
                with (out/(item['id']+'.log')).open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
                file=next(f for f in destination.glob('*/meeting.json') if f.parent.name!='.recovery');m=json.loads(file.read_text());text=' '.join(s['text'] for s in sorted(m['segments'],key=lambda s:s['start']));words=[w for s in m['segments'] for w in s.get('words',[])]
            elif a.engine=='whisper':
                r=mlx_whisper.transcribe(item['audio'],path_or_hf_repo=models['mlx-community/whisper-large-v3-turbo']['path'],language=item['language'],initial_prompt=item['glossary'] if a.glossary else None,word_timestamps=True,verbose=None)
                text=r['text'];words=[w for s in r.get('segments',[]) for w in s.get('words',[])]
            else:
                r=model.generate(item['audio'],language='Italian' if item['language']=='it' else 'English',hotwords=[s.strip() for s in item['glossary'].split(',')] if a.glossary else None,max_tokens=2048,verbose=False);text=r.text
            metrics=wer(item['reference'],text) if item.get('reference') else None
        except Exception as ex:error=type(ex).__name__+': '+str(ex);metrics=None
        row={'clip':item['id'],'engine':variant,'text':text,'words':words,'seconds':time.perf_counter()-started,'metrics':metrics,'error':error,'synthetic':item['synthetic']};rows.append(row)
        (out/'results.json').write_text(json.dumps({'modelLoadSeconds':load_seconds,'peakRSSBytes':max(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss),'results':rows},ensure_ascii=False,indent=2));print(variant,item['id'],round(row['seconds'],2),'s',metrics or '',error or '',flush=True)
    if any(r['error'] for r in rows):raise SystemExit(1)
if __name__=='__main__':main()
