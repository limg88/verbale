# Qualità della trascrizione: seguito dell’esplorazione — Verbale 0.13.0

5 novembre 2026. Le prove usano direttamente audio delle registrazioni già presenti, su copie locali. Nessun audio è stato inviato a servizi remoti e nessun dispositivo di registrazione è stato avviato dai test.

## Stato delle fasi

| Fase | Risultato |
|---|---|
| Confini e duplicazioni | Consegnata nella 0.12.5 e mantenuta |
| Segmentazione e contesto | Disponibili nel secondo passaggio: pause brevi unite, VAD fino a 29,6 s e padding gestito una sola volta per arrivare a finestre ASR fino a 30 s. La registrazione live mantiene i parametri precedenti |
| Secondo passaggio | Disponibile nell’app come «Riascolta e confronta…», con anteprima persistente e applicazione selettiva |
| Glossario | Provato con Whisper e Qwen nel banco di valutazione locale. Non è una funzione del decoder Parakeet integrato e non è ancora un’opzione nell’app |
| Motori alternativi | Confrontati localmente Parakeet, Whisper large-v3-turbo e Qwen3-ASR 1.7B. Whisper e Qwen non sono inclusi nel DMG; nessun cambio automatico del motore |
| Passaggi incerti | Analisi per punteggi di confidenza, intera trascrizione o singolo passaggio; filtro testuale, ascolto, selezione e ripristino |

## Funzioni disponibili nell’app

Dalla Trascrizione, «Riascolta e confronta…» prepara proposte senza modificare il testo attuale. Dal menu di un passaggio si può ritrascrivere solo quello. Le correzioni testuali precedentemente accettate sono escluse; i punteggi di confidenza servono a dare una priorità, non rappresentano una probabilità certificata di errore.

Le proposte eliminano cambi cosmetici e tagli di frase riconducibili ai confini. La vista mostra prima/dopo e consente l’ascolto, l’applicazione delle sole proposte scelte e il ripristino. L’analisi è annullabile. Con audio dichiarato ma non disponibile viene segnalato un errore; con lacune nella timeline vengono esclusi e segnalati i passaggi interessati, mantenendo disponibili quelli validi.

Nomi, timestamp dei segmenti e identificativi dei collegamenti restano invariati. L’allineamento parola per parola dei passaggi modificati viene rimosso, come per una correzione testuale manuale, e può essere ripristinato con la revisione precedente. La modifica delle parole non conferma la voce: riconoscimenti automatici e conferme umane restano distinti. L’analisi vocale corrente viene aggiornata insieme al testo e ripristinata insieme alla revisione, quando presente.

La revisione è persistita in `transcription-refinement.json` anche accanto al trascritto esportato. Le revisioni applicate precedenti sono conservate nell’archivio interno quando viene preparata una nuova analisi. Il ripristino automatico rifiuta stati con modifiche successive del testo o delle identità; preserva note, marcatori e titolo e segnala il report come da aggiornare. Le copie di ripristino non duplicano note personali, report o screenshot e non contengono embedding vocali.

## Prove del secondo passaggio sulle call presenti

| Registrazione | Sorgente | Intervallo | Segmenti selezionati | Proposte finali | File originali verificati |
|---|---|---|---:|---:|---:|
| 66B6910F | Sistema | 00:00–02:00 | 59 | 16 | 318 |
| C1BE978F | Sistema | 02:30–04:30 | 35 | 8 | 392 |
| 2D4D3CAA | Sistema | 14:00–16:00 | 54 | 24 | 1322 |
| 4B9B0365 | Microfono con riduzione eco | 00:00–02:00 | 38 | 12 | 45 |

I test verificano che la preparazione lasci invariata la riunione, escluda correzioni manuali, applichi selettivamente su una copia in memoria, conservi nomi/identificativi/tempi e ripristini tutte le parole e gli allineamenti originali. Hash degli audio e byte del manifest sono stati confrontati prima/dopo: nessuna modifica rilevata nei 2077 file controllati.

Nel caso microfono, due passaggi della registrazione precedente sono esclusi per lacune nella timeline: non vengono «riparati» inventando audio o riscrivendo il testo.

Le 60 proposte non sono 60 errori dimostrati: maggiore contesto può produrre ipotesi migliori o peggiori. Per questo la release propone un confronto e conserva la versione precedente. La registrazione in diretta non usa automaticamente questa modalità.

## Confronto locale dei modelli e del glossario

Sono state eseguite 30 prove: sei varianti su tre estratti reali da un minuto e due campioni sintetici con testo noto. Gli estratti reali sono stati ricavati direttamente dalle call presenti; le relative trascrizioni automatiche non sono state trattate come riferimento corretto. La ricerca nelle cronologie non ha trovato correzioni lessicali indipendenti utilizzabili per un riferimento completo: le differenze salvate sono prevalentemente suddivisioni e tagli dei passaggi.

| Variante | WER normalizzato sul solo controllo sintetico italiano, 40 parole | Controllo inglese, 24 parole | Picco RSS del processo, circa |
|---|---:|---:|---:|
| Parakeet live | 2,5% | 0% | 1,80 GiB |
| Parakeet secondo passaggio | 5% | 0% | 1,80 GiB |
| Whisper turbo | 5% | 0% | 1,74 GiB |
| Whisper turbo + glossario | 0% | 0% | 1,84 GiB |
| Qwen 1.7B | 7,5% | 0% | 2,70 GiB |
| Qwen 1.7B + glossario | 5% | 0% | 2,68 GiB |

La normalizzazione ignora maiuscole e punteggiatura e tratta `10`/`dieci` e `11`/`undici` come equivalenti, per tutti i motori. Gli esiti grezzi e normalizzati sono entrambi conservati. Questi 64 vocaboli sintetici costituiscono un controllo funzionale, non un campione sufficiente a classificare i modelli sulle riunioni. Il test evidenzia che il glossario può aiutare su termini come «Kestrel», ma maggiore contesto o un modello più grande non migliorano automaticamente ogni frase.

Parakeet live viene valutato con blocchi da 5 s, contesto adiacente e riconciliazione dei confini; il secondo passaggio usa blocchi di proprietà da 25 s con contesto e segmentazione estesi. Gli altri motori usano le rispettive implementazioni locali. La memoria RSS è indicativa del processo, non del consumo complessivo del Mac. I tempi grezzi includono avvii/importazioni e cache differenti e non vengono usati come classifica.

Per le call reali sono conservati trascritti affiancati e disaccordi fra i motori. Non è stato inventato un WER basato sul consenso dei modelli. Non serve caricare nuove registrazioni o preparare manualmente file per consultare questi confronti.

## Evidenze e ripetibilità

- `.build/checks-0.13.0.log`: regressioni, incluse quelle vocali native e i casi di correzione, ripristino, annullamento e audio mancante.
- `.build/preview-profile/background-ui-checks.json`: verifiche dell’interfaccia; `.build/preview-profile/transcript-refinement.png`: vista reale prima/dopo.
- `.build/refinement-tests/20261105-154525/`: prove finali sulle tre sorgenti di sistema.
- `.build/refinement-tests/microphone-final-vad/`: prova finale sul microfono e registro dei passaggi esclusi.
- `.build/asr-eval/`: corpus, estratti locali, trascritti dei sei esperimenti, modelli/revisioni bloccati, dipendenze e risultati.
- `.build/asr-eval/real-review.md`: confronto privato dei trascritti delle call con collegamenti ai relativi estratti audio.
- `.build/asr-eval/real-disagreements.json`: differenze da verificare, non errori certificati.

Script: `scripts/evaluate_asr_models.py`, `scripts/build_asr_comparison.py`; CLI: `check-transcript-refinement`, `transcribe-live`, `transcribe-quality`.

I modelli di test sono scaricati in `.build/asr-eval/hf`, con revisioni registrate in `models.lock.json`. Python e i pesi sperimentali rimangono nell’ambiente di valutazione e non vengono distribuiti nel DMG.

Fonti primarie per le implementazioni sperimentali: [Whisper MLX](https://github.com/ml-explore/mlx-examples/tree/main/whisper), [Qwen3-ASR MLX](https://github.com/Neywa-Labs/mlx-audio/tree/main/mlx_audio/stt/models/qwen3_asr), [modello Qwen](https://huggingface.co/Qwen/Qwen3-ASR-1.7B).
