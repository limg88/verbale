# Collaudo 0.16.2 — interazioni e salvataggi

Intervento sulle note, sulle revisioni e sul rendering della trascrizione. Non modifica i modelli o il percorso di inferenza nativa.

- Build Release con script esistente, `--jobs 2`; pacchetto locale firmato ad-hoc. Nessuna release GitHub e nessun riavvio dell’app utente.
- Core: 123 controlli superati. Nuovi controlli su export di documenti invariati, ripristino allegati mancanti, copia dei nuovi allegati, verifica integrale nell’export ordinario e attribuzioni indicizzate con match duplicati/rifiutati.
- Preview isolata: 132 controlli superati, inclusi i controlli UI esistenti più digitazione, navigazione prima del salvataggio, flush prima del report, errore di scrittura, riprova e note durante registrazione simulata. Esiti finali in `.build/preview-profile/background-ui-checks.json` e `interaction-verification.json`.
- Microbenchmark Release su copie temporanee dell’archivio: `.build/logbook-performance/results-after-interactions.json`. Originali invariati, verificati con SHA-256. Nessun audio acquisito o modello caricato.

## Misure

Cinque ripetizioni, cache prevalentemente calda, stessa macchina. Attribuzioni di 1.961 segmenti con 1.831 match: mediana 20,49 ms con ricerca lineare, 0,25 ms con indice già costruito. Non include la costruzione dell’indice e non misura l’intero rendering UI.

Percorso precedente salvataggio/export/rilettura archivio: 286,40 ms. Percorso di revisione senza rilettura archivio: 140,46 ms. Entrambi i microbenchmark escludono audio e screenshot. Il secondo percorso lavora sul disk actor; il riscontro visuale precede il completamento durevole.

Nel controllo UI finale, 1.000 modifiche delle note richiedono circa 1,79 ms complessivi e producono zero notifiche dell’AppModel globale e zero scritture per battuta. La misura riguarda il percorso dei dati, non la simulazione di 1.000 eventi tastiera/rendering.

## Limiti

- L’archivio viene ancora caricato integralmente all’avvio. Timer e coda restano nell’AppModel globale; l’indice riduce il lavoro ripetuto nella trascrizione senza sostituire tutto lo stato osservabile.
- Le note della registrazione attiva vengono accorpate, ma il checkpoint resta sul percorso MainActor già proprietario della cattura, evitando scritture concorrenti di snapshot audio. Le revisioni dei documenti conclusi sono salvate in background.
- I checkpoint della trascrizione conservano il confronto JSON integrale. Il riuso delle finestre audio e la verifica dei modelli non cambiano in questa versione.
- L’export delle sole revisioni verifica presenza e identità dei riferimenti degli allegati già esportati; non ne ricalcola il contenuto. L’export ordinario mantiene la verifica integrale e rileva le modifiche esterne. Audio aggiunto/mancante o destinazione nuova ricadono nel percorso completo.
- Restano avvisi AppKit/AttributeGraph presenti anche nei collaudi delle versioni precedenti; i controlli UI terminano e il collaudo non riproduce un freeze.
- Non è stato eseguito un benchmark runtime di Logbook, né un test end-to-end di una call Teams reale. I risultati non dimostrano una riduzione della memoria di inferenza o la scomparsa di ogni lag.
