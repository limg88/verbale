# QA 0.14.1 — report troncati con Sonnet

## Diagnosi

Verbale 0.14.0 chiedeva 4000 token per la composizione finale, ma il trasporto non aumentava il budget quando era già a 4000. Il nuovo formato PM poteva superarlo: HTTP 422 `output_limit_exceeded` o `finish_reason: length` causavano quindi l'errore riportato. Non si tratta necessariamente di una quota di utilizzo o di un modello inadatto. Il gateway locale configurato consente 32768 token; il collo di bottiglia identificato era il tetto del client. La più recente riunione interrotta aveva 12 risposte intermedie nei checkpoint. Sono state lette solo per conteggio/dimensioni; nessun contenuto reale è stato inviato a un provider per questa analisi.

## Correzione

Budget iniziale invariato: 4000 per il finale, 2200 per schede e consolidamento. Solo dopo un troncamento confermato il budget raddoppia, con tetto 16000 e massimo quattro tentativi complessivi, inclusi quelli dovuti a rate limit. Un finale può quindi usare 4000 → 8000 → 16000. Non si concatena una continuazione potenzialmente incoerente: si richiede una risposta completa, e una risposta troncata non viene pubblicata né salvata come valida. Errore aggiornato per spiegare la lunghezza della risposta e i tentativi automatici, senza confonderla con la quota.

Prompt v4-pm, budget iniziali e hash dei checkpoint non cambiano. I lavori di 0.14.0 restano riutilizzabili se endpoint, modello e fonti sono invariati. Non è necessario riconoscere di nuovo le voci o ripetere la trascrizione. Per usare la correzione installare il nuovo DMG, selezionare la stessa riunione e lo stesso modello e premere Genera report.

Il tetto è una politica del client: il gateway/backend deve accettare i budget richiesti (la configurazione verificata li consente). Non sono stati modificati configurazione, processi o codice del gateway in uso. Il timeout resta 330 s per richiesta lato Verbale e 300 s nel gateway configurato.

## Verifiche

- Mock HTTP 422 e risposta 200 con `finish_reason: length`: 4000 fallisce, 8000 completa; il testo incompleto non compare nel report.
- Errore persistente: tentativi finali esattamente [4000, 8000, 16000], poi arresto. Estrazione limitata a quattro tentativi. Cancellazione, rate limit e quote mantengono i rispettivi comportamenti.
- Call lunga con estrazioni e consolidamenti completati ma finale troncato: alla ripresa solo il finale viene richiesto; una volta completato a budget maggiore anche quello viene riutilizzato dal checkpoint.
- `python3 scripts/test_gateway.py`: suite core completa e gateway reale importato dal progetto llm-api, su porte temporanee e con upstream locale simulato. Nessuna chiamata ai provider e nessun arresto del gateway utente. Audit: 6 richieste al modello locale, recupero budget [4000,8000], 1 richiesta Groq simulata, zero fughe sul redirect. Login, quote, troncamenti, cancellazione e ripresa verificati.
- Build arm64 e verifica DMG/firma locale prima della consegna. Non è stata rigenerata automaticamente la riunione reale: i suoi file e i checkpoint restano intatti.
