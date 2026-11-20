# QA 0.15.1 — contesa con Teams, 6 novembre 2026

## Evidenze

Analizzata in sola lettura la riunione 545E15E3-65BE-4218-8C25-063500D5CD3C, rinominata «06112026 - Daily Standup Accenture», dalle 09:34:28 alle 10:10 circa (Europe/Rome), 2157,31 secondi. Bose Q35ii selezionate manualmente per entrambe le direzioni, modalità cuffie. 422 blocchi microfono e 432 di sistema; nessuna discontinuità superiore a 50 ms tra i timestamp dei blocchi della stessa sorgente. Questo non dimostra che Teams non si sia bloccato, né verifica il contenuto di ogni campione.

Nel codice precedente la registrazione caricava ASR e VAD prima del tap e rielaborava finestre sovrapposte durante la call. Il runtime sceglie Metal e ha un default di otto thread CPU. A ogni ricezione e risultato veniva esportata nuovamente la sessione. La contesa con una videoconferenza è plausibile; non è una prova della causa specifica del freeze.

Log privati in .build/teams-freeze-analysis: errori Bluetooth prima dell’inizio, errori HAL all’avvio e oltre 150000 errori WindowServer relativi agli indicatori nell’intervallo esaminato. Il confronto 09:20–10:20 mostra che gli errori degli indicatori erano già presenti prima della registrazione e continuavano dopo. I messaggi Verbale includono sia PID 20851 sia PID 31829 dell’anteprima; il campo processImagePath dei log da solo non identifica affidabilmente il bundle del processo storico. Nessuna attribuzione causale basata soltanto sul nome del processo o sulla correlazione temporale. Non trovato un crash report recente di Teams nella cartella esaminata; non è escluso un hang senza crash.

La pressione memoria letta durante l’analisi era bassa (61% free dichiarato da memory_pressure) e non misura la pressione al momento del blocco. Nessuna metrica retroattiva di GPU o CPU durante quel blocco.

## Modifiche

- Default nuovo «Al termine»: acquisizione e salvataggio durante la registrazione; nessun caricamento ASR/VAD, nessuna trascrizione e nessun AEC durante la cattura. Elaborazione dopo Stop se Teams non è più in chiamata, quindi attesa aggiuntiva per il testo. Se la call è ancora attiva, ripresa manuale dall’archivio al termine. La riduzione eco continua ad applicarsi prima dell’ASR nella fase successiva.
- «Durante la registrazione» disponibile nelle impostazioni; scelta fissata nel manifest della nuova riunione, senza cambiare quelle in corso. Vecchi manifest senza campo continuano a essere decodificati.
- Esportazioni ogni 30 secondi e sempre alla finalizzazione. Tutti i blocchi audio e le righe di journal interni continuano a essere salvati; nessun campione o recupero sacrificato alla frequenza delle esportazioni. Snapshot privato aggiornato per ciascun blocco.
- Global thread budget del runtime ASR a due tramite il simbolo privato della revisione già fissata; nessun cambiamento alla libreria native o all’ABI 11. GPU ancora usata quando il motore è effettivamente caricato.
- Callback tardivi dopo Stop non avviano elaborazioni autonome: la finalizzazione rilegge il journal e carica i modelli prima della trascrizione. Errore di caricamento conserva l’audio e rende disponibile Riprendi trascrizione.
- Durante la finalizzazione differita un controllo delle asserzioni Teams, fuori dal main thread e limitato a una lettura ogni due secondi, mette in pausa l’elaborazione se una call diventa attiva, anche con automazione disattivata. Una richiesta nativa già in corso può completarsi prima della pausa. Il riconoscimento voci riceve cancellazione; la sessione rimane interrotta e riprendibile dall’archivio. Non è una coda di ripresa automatica.
- Non modificati device, routing Teams, volume, configurazione Bluetooth o topologia del tap.

## Verifiche

114 PASS nella suite core, zero FAIL: nuove verifiche di preferenze, compatibilità manifest, cadenza su due ore e flush finale. Quattro prove end-to-end nel profilo Preview senza hardware: blocchi salvati senza ASR; callback tardivo non avvia ASR prematuro; finalizzazione con modello mancante conserva tutti e quattro i file; chiamata Teams durante l’elaborazione differita produce uno stato interrotto riprendibile con tutti i file audio conservati.

96 controlli Preview passati; ispezionata recording-settings.png a 1000×680, con scelta e spiegazione del compromesso visibili. La Preview non avvia il monitor Teams o l’acquisizione. Il log contiene anche avvisi AttributeGraph senza fallimenti dei controlli.

Dopo la fine della call, verificata l’assenza dell’asserzione Teams e di sessioni attive prima della prova nativa. Due cicli reali di caricamento, trascrizione di un breve blocco già salvato della Daily e rilascio, più rollback per VAD mancante: exit 0. RSS CLI circa 941–979 MiB caricata e 78–79 MiB dopo rilascio (valori ps in KiB nel file originale). Non è un benchmark di un meeting completo o una misura della RAM dell’app in registrazione.

Build 31, bundle 0.15.1; codesign --verify --deep --strict e checksum DMG verificati. Pacchetto dist/Verbale-0.15.1-arm64.dmg. Nessuna registrazione utente fermata e nessun riavvio dell’app esistente. Nessun report reale rigenerato o pubblicato durante questa analisi.

## Limite della verifica

Il freeze intermittente di Teams non è stato riprodotto in modo controllato. Le modifiche rimuovono il carico di inferenza dalla registrazione e riducono le esportazioni; non certificano la soluzione di problemi del driver Bluetooth o di WindowServer. Serve una call reale con la nuova versione e la modalità Al termine per verificare il sintomo. In caso di ricorrenza sono necessari ora esatta e campioni dei processi durante il blocco, distinguendo UI e flusso audio/video.
