# QA 0.14.3 — verifica sul caso reale

## Riproduzione

Autorizzata dall'utente il 6 novembre 2026, poi confermata la prosecuzione autonoma. Riunione reale di 61 minuti e 23 secondi, 1836 segmenti. Verificati il bundle realmente aperto (0.14.2 build 28), l'archivio selezionato e il modello nell'interfaccia: `claude/haiku`, gateway `http://127.0.0.1:8080/v1`. Il modello non è stato cambiato.

La prima prova usa il codice 0.14.2 sullo snapshot originale e su copie dei checkpoint, senza modificare i dati dell'utente. Risultato: 16 inferenze, 8 troncamenti, 574,38 secondi; arresto `workLimit` durante l'estrazione 10 di 12. Budget massimo richiesto cumulativo già prenotato: 176512; il successivo tentativo da 16000 avrebbe raggiunto 192512, oltre il tetto 192000. Questo è un limite preventivo dell'app, distinto dalla quota del provider e dall'uso effettivo fatturato. Le 9 estrazioni completate sono conservate.

## Correzioni

- Un successo con uso alto informa il budget delle estrazioni successive di dimensione simile. Si usa esclusivamente usage numerico; margine 20%, arrotondamento a 1024 e massimo 16000. Il dato non viene interpretato come conteggio di parole o ragionamento. I blocchi di taglia diversa hanno indicazioni separate. Non viene salvato un profilo del modello o alterata la configurazione del gateway.
- Tetto preventivo complessivo a 384000 token richiesti. Restano massimo 48 inferenze, 15 minuti per invocazione, tre tentativi per richiesta e una sola espansione del budget dopo un troncamento. Il limite non è eliminato: la precedente dimensione non copriva nemmeno le estrazioni valide di questo caso, prima della composizione per sezioni.
- Compatibilità dei checkpoint v5: le chiavi restano basate sul budget di pianificazione, non sul margine appreso. Le risposte già completate non vengono ripetute.
- Fonte `N` come criterio delle note personali. Nel caso reale gli appunti personali sono vuoti, ma alcune osservazioni pronunciate venivano restituite con kind=note. Ora sono conservate fra i fatti del parlato. Record con fonte N restano note anche se il modello li etichetta come decisioni o attività.
- Rimozione del titolo iniziale duplicato nelle risposte di sezione, anche quando letto da un vecchio checkpoint. Una risposta ridotta al solo titolo non viene accettata come sezione completa.
- Gruppi di almeno tre citazioni ravvicinate diventano intervalli con link al primo passaggio. Massimo 12 s di separazione e 60 s complessivi; fonti lontane, ignote, note e marcatori non vengono inglobati. Le fonti originali restano nei checkpoint. I gruppi con più parlanti non sono attribuiti a una sola persona.
- Errori con fase/indice, HTTP, codice da vocabolario e request ID UUID quando disponibili. Il dettaglio libero del backend e le credenziali restano esclusi.

## Risultato reale

Ripresa con lo stesso Haiku e gateway dalle 9 estrazioni disponibili: completate le estrazioni rimanenti, consolidati 229 record (57519 byte), composte 9 parti finali. Risultato `success`, 342,25 s, 14 inferenze, 2 troncamenti e 140624 token di budget richiesto. **Non è un confronto di velocità da zero:** questa esecuzione riusa 9 risposte della prima prova.

Nuova composizione dagli stessi checkpoint, dopo le correzioni di formattazione: 21 cache hit, 0 inferenze, 0,23 s. Il report passa da 154847 a 85898 byte e da 1157 a 395 link, senza richiedere nuove risposte al modello. Sette sezioni PM presenti una sola volta, nessun riferimento non verificato e nessun link alla trascrizione interrotto. Nessuna sezione di note personali inventata nel caso privo di appunti.

Verifica campionaria delle attività e dei rimandi, oltre ai controlli strutturali. Non è un audit umano completo di ogni affermazione rispetto all'ora di registrazione: resta necessaria la revisione del report come indicato nel documento.

## Pubblicazione e integrità

Il risultato è salvato nella riunione reale con `reportStatus=Completato` e nella sua cartella di output tramite lo stesso SessionStore usato da AppModel. Prima della pubblicazione: snapshot invariato, backup dei manifest e dei checkpoint precedenti, controllo del titolo e delle sezioni. Dopo: report dell'archivio uguale al file esportato; 1464 file preesistenti, inclusi 1457 audio, con SHA-256 invariato. Nel manifest della riunione sono cambiati soltanto report e reportStatus: segmenti, nomi, note, durata, revisioni e configurazione sono invariati.

Installata 0.14.3 build 29 in `~/Applications/Verbale.app`, firma verificata, e app riavviata dopo aver verificato l'assenza di registrazioni attive. Modalità automatica Teams e modello preservati. Vecchie immagini disco 0.14.1/0.14.2 smontate dopo la chiusura delle rispettive app, per evitare avvii della versione precedente. Il contatore delle richieste al modello è rimasto invariato dopo il completamento e la verifica da cache. L'app resta nella barra dei menu secondo l'impostazione esistente; la finestra di produzione non era esposta al client di automazione in questa modalità. Il salvataggio è stato quindi verificato attraverso il backend reale e i file; il rendering e le interazioni sono coperti dai controlli Preview isolati, senza dichiarare una verifica visiva del report nella finestra di produzione.

## Regressioni e artefatti

- 103 controlli core passati dopo le ultime modifiche; include il vecchio limite riprodotto su 12 estrazioni, budget appreso, provenienza delle note, diagnostica sicura, intestazioni duplicate e citazioni vicine/lontane.
- Integrazione con gateway reale su porte temporanee e upstream simulato passata; nessuna modifica o riavvio del gateway in uso.
- 92 controlli dell'interfaccia Preview, tutti veri. Build arm64, firma dell'app installata e checksum del DMG verificati.
- `verbale-cli generate-report` conserva snapshot, checkpoint, metriche e report separati; `publish-report` controlla l'originale prima di scrivere attraverso SessionStore. Nessuna trascrizione, risposta, credenziale o dato personale nei log OSLog.

Le prove reali e i backup sensibili restano in `.build/report-real-esaote-20261106/`, esclusi dalla distribuzione e dal repository. Il report è già nella cartella scelta dall'utente. Qui si documentano solo misure e comportamento, senza trascrizioni o contenuto del progetto.
