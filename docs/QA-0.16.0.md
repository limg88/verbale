# QA 0.16.0 — code e reattività

## Intervento

Due corsie seriali persistenti (trascrizione e report), esecuzione utility e worker/disk actor separati dal MainActor. Le elaborazioni non leggono o scrivono AppModel.current. La UI protegge solo il target del lavoro; la navigazione usa un blocco distinto. Le impostazioni del report sono catturate alla richiesta; il token rimane solo in memoria e viene recuperato dalle credenziali alla ripresa dopo un riavvio, senza salvarlo nella coda.

La finalizzazione della registrazione passa i blocchi rimasti alla coda; l’eventuale elaborazione live già iniziata viene arrestata e conservata prima del passaggio. Nuove registrazioni mettono in pausa il worker ASR prima del caricamento dei modelli live. Teams attivo o non verificabile mantiene le trascrizioni in attesa; risposte vecchie del probe sono ignorate. Una richiesta nativa già in corso può completarsi prima della pausa. I report remoti hanno una corsia indipendente.

Il worker recupera il journal, elabora solo i blocchi non processati e salva ciascun checkpoint; le esportazioni intermedie sono raggruppate. ASR e AEC conservano finestre e proprietà dei passaggi esistenti. Analisi vocale automatica nello stesso lavoro, con correzioni manuali conservate; errori opzionali delle voci diventano avvisi anziché perdere l’ASR completato. Un errore o una sospensione conserva i dati parziali. Report pubblicati solo dopo verifica delle fonti effettive e della revisione; un output precedente non è sostituito da una risposta fallita.

Conferma/rifiuto delle voci: lookup lineari tramite indici, stato ottimistico immediato, scritture asincrone serializzate e coalescenza dei click ravvicinati. Salvataggio locale fallito: ripristino dello stato salvato e errore esplicito. Esportazione fallita: conferme conservate nel privato, problema associato alla relativa riunione. Chiusura dell’app attende i salvataggi.

Cestino nel dettaglio, stessa conferma e rimozione reversibile già presenti nell’archivio. Target con lavori pendenti protetti, anche durante l’arresto del worker. Navigazione e rimozione di altre riunioni restano disponibili. La cronologia delle attività concluse della riunione rimossa viene ripulita.

## Verifiche automatiche

121 gruppi core superati, zero FAIL. Suite core: ordine per tipo, due corsie indipendenti, duplicati, dipendenza report/ASR, errori isolati, stato Teams attivo/sconosciuto, cattura che ferma l’ASR, risposta stale, cancellazione, shutdown/riavvio, permessi 0600, credenziali escluse dalla serializzazione, backup della coda corrotta. Worker con ASR simulato: recupero journal, blocchi già processati, annullamento a metà e ripresa senza duplicati, altre riunioni invariate, persistenza report e rifiuto di fonti cambiate.

Test voci su 2000 passaggi: metà confermati senza modificare l’altro profilo, rifiuto che conserva le conferme e ripristina gli speaker originali. Tempo osservato per il solo aggiornamento in memoria circa 2,3 ms nel test debug; non è un benchmark della latenza completa dell’app o dell’esportazione.

109 controlli Preview superati, zero fallimenti. Preview isolata: conferme e rifiuti visibili prima dell’esportazione; con quattro lavori si apre una seconda riunione; un lavoro sincrono simulato di 350 ms non blocca il main actor; completamenti non sostituiscono la selezione o le note della riunione consultata. Cancellazione del target protetta mentre un’altra riunione resta rimovibile. Ispezionata desktop-background-jobs.png a 1000×680, incluso cestino nel dettaglio e barra scorrevole delle attività. Le fixture non avviano acquisizione o provider reali.

## Verifica nativa isolata

Solo dopo la fine dell’asserzione Teams: copie isolate di cinque blocchi di sistema della registrazione Costacurta. Primo intervallo 120–140 s: silenzio, VAD senza segmenti (non prova dell’inferenza ASR). Secondo intervallo 600–620 s: cinque blocchi elaborati, otto segmenti, circa 2,75 s complessivi. Originale e SHA dei file sorgente invariati; nessun dato pubblicato nell’archivio dell’utente. Artefatti .build/work-queue-real-costacurta-speech/verification.json e log omonimo. La coda diagnostica resta soggetta al probe Teams durante la prova. Non eseguito un nuovo meeting intero o un report su provider reale per questi interventi.

Worker report verificato anche con il gateway reale e backend simulato: token in memoria, contratto operativo, salvataggio privato ed esportazione report. Audit fixture: sette richieste locali, una Groq simulata, nessuna credenziale inviata al target del redirect. Nessuna inferenza reale di report.

Versione 0.16.0 build 34. Firma codesign --verify --deep --strict e checksum DMG hdiutil verify superati; esiti in .build/work-queue-verification.json. L’app dell’utente non è stata chiusa o sostituita. Restano i limiti del segnale Teams e della cancellazione cooperativa delle chiamate native; il test non certifica ogni combinazione di driver o pressione di sistema.
