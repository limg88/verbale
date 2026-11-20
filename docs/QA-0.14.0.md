# QA 0.14.0 — risorse e report PM

## Evidenza dal filmato

Registrazione schermo del 5 novembre 2026, durata 337,26 s. Processo Verbale PID 50334, avviato da `/Volumes/Verbale 13/Verbale.app`. Nei sei campioni a distanza di un minuto RES è circa 1191–1275 M e CPU 44,4–57,0%. Le due immagini a 10 e 320 s mostrano 1240 M e 50,2/52,2%. Non si osserva crescita monotona della memoria in questa finestra. Il video non permette di attribuire il carico alle singole funzioni o conoscere la configurazione delle sorgenti. La colonna VIRT (416 G) non misura RAM fisica utilizzata. Il confronto con il limite dichiarato dall'autore di Logbook richiederebbe stesso hardware, sorgenti e funzioni attive; non è un benchmark comparativo.

Frame e misure locali in `.build/performance-analysis/` (non distribuiti). Nessuna registrazione utente modificata e nessun audio inviato a servizi remoti.

## Interventi

- Ogni buffer audio notificava `AppModel.objectWillChange`, invalidando anche trascrizione e archivio. Ora uno stato separato notifica solo i misuratori; il calcolo RMS e le notifiche sono limitati a 10 Hz per sorgente sulla coda audio, senza modificare conversione, campioni, durata, journal o finestre ASR. Le notifiche tardive di sessioni terminate vengono ignorate.
- Ogni esportazione ricalcolava due SHA-256 per ciascun file audio già presente. La cache verifica identità dispositivo/inode, dimensione, mtime e ctime a precisione nanosecondi di entrambi i file e ricalcola i digest quando qualcosa cambia. Massimo 8192 coppie, poi svuotamento. Non conserva audio in memoria. Le nuove copie continuano a essere verificate prima del commit atomico.
- Stop manuale e ripresa rilasciano sempre ASR/VAD/AEC; in precedenza l'unload esplicito allo stop era riservato all'avvio automatico (l'analisi vocale opzionale poteva già liberare ASR). Anche gli errori di avvio rilasciano i motori. Il caricamento ASR/VAD/diarizzazione è transazionale: un VAD non valido non lascia ASR caricato.

## Misure riproducibili

`verbale-checks --benchmark-exports`: 1440 blocchi sintetici da 320000 byte, 1440 segmenti, 460,8 MB complessivi, come due ore a 16 kHz float mono, un export iniziale e cinque export ripetuti dello stesso snapshot. Compilazione debug e stessa macchina, esclusi generazione e primo export dalla misura. Prima: CPU 2,681486 s, wall 3,032621 s. Dopo: CPU 0,822140 s, wall 0,837014 s. Riduzione CPU circa 69%, wall circa 72%. Il primo export ripetuto della versione nuova include ancora la verifica necessaria a riempire la cache. Questa è una misura del percorso export, non del consumo totale in call. Un carico con due sorgenti, AEC, UI e ASR va misurato durante una call rappresentativa dopo l'installazione; non si promette una percentuale complessiva.

`verbale-checks --benchmark-engine <asr> <vad> <audio-sintetico>`: due cicli load/trascrizione/unload del runtime nativo e un caricamento con VAD mancante, senza acquisire dispositivi. RSS KiB misurato con `ps` nello stesso processo:

| Fase | RSS KiB |
| --- | ---: |
| Baseline | 15264 |
| Primo caricamento | 969424 |
| Prima trascrizione | 1009648 |
| Primo unload | 87104 |
| Secondo caricamento | 1008112 |
| Seconda trascrizione | 1010064 |
| Secondo unload | 87472 |
| Errore VAD e rollback | 87504 |

Il processo diagnostico scende quindi da circa 986 MiB a 85 MiB dopo unload. Non è una previsione dell'intera app: archivio, viste, AppKit e altri servizi hanno memoria propria. Parte delle cache di sistema resta residente; unload non significa azzerare RSS.

## Report

Prompt `v4-pm`: sintesi per il PM, fatti/avanzamenti, decisioni, tabella attività/responsabile/scadenza/stato/dipendenze/fonti, rischi/problemi, opportunità, punti da chiarire. Contratto esplicito per evidenze, negazioni, correzioni, proposte vs impegni, note personali vs parlato e titolari/date non indicati. Il parlante non diventa automaticamente responsabile.

Call brevi: una richiesta finale direttamente sulle fonti, senza restituire la precedente estrazione da 250 parole. Call lunghe: estrazione e consolidamento secondo lo stesso contratto, poi composizione finale distinta. Tolto il vincolo generico di 250 parole che poteva far perdere incarichi; dimensioni e output restano limitati, risposte troncate rifiutate. Corretto anche il margine del separatore fra schede per garantire avanzamento nel consolidamento al limite esatto. Checkpoint versionati: la vecchia sintesi non viene riutilizzata come report nuovo. I report esistenti non vengono sovrascritti automaticamente.

Test trasporto simulato: fonti/contratto effettivamente inviati in tutte le fasi, call brevi/lunghe, composizione finale, budget esatto, rimandi, checkpoint, 429 e ripresa, limite output e cancellazione. Non è una valutazione della qualità linguistica di uno specifico modello: dipende dal backend selezionato e richiede revisione del report generato.

## Regressione

- Suite core completa con fixture native diarizzazione/embedding: 92 PASS, nessun FAIL.
- Preview isolata: 92 controlli, tutti passati; controllo che 1000 aggiornamenti di livello notifichino i misuratori 1000 volte e l'AppModel zero volte; navigazione, correzioni, report con tabella PM, impostazioni e riconoscimento voci.
- Integrità cache: modifica della copia con stessa dimensione e mtime ripristinato, sostituzione del sorgente, ripristino del contenuto e ricopia dopo rimozione.
- Build e DMG arm64 con runtime nativo già verificato; firma locale ad hoc.
