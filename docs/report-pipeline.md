# Aggiornamento 0.15.0 — 6 novembre 2026

Il percorso predefinito è ora `ProjectReport` (v6-operational); `ReportService.generateExtended` conserva il percorso v5 descritto sotto, selezionabile nell’interfaccia. Le note storiche seguenti documentano lo stato al momento delle rispettive verifiche.

Il modello estrae record tipizzati con campi facoltativi per le attività. Tutti i record validati sono impaginati localmente; una sola chiamata produce fino a sei punti esecutivi per meeting con più blocchi. Per la sola sintesi, se i record superano l’input disponibile viene usata una selezione bilanciata di record interi: le sezioni dettagliate continuano a contenere tutti i record estratti. Non si garantisce l’esaustività semantica dell’estrazione automatica.

Il gateway espone additivamente `report_input_limit_bytes` (48000 per CLI Claude, limite generico invariato) e `report_low_effort`. Il client invia `reasoning_effort: low` soltanto quando dichiarato; il gateway lo traduce nel flag CLI per la singola richiesta, senza cambiare le altre app o il modello. I token di ragionamento sono metadati numerici opzionali del provider: non vengono ricostruiti dalla lunghezza del testo né salvati contenuti del ragionamento.

Richieste sequenziali con limiti globali esistenti; blocchi falliti per troncamento/413/timeout vengono divisi senza eliminare fonti e senza ripetere il blocco grande alla ripresa. Checkpoint distinti per prompt, fonti, endpoint, modello e profilo di ragionamento. I fallimenti non sovrascrivono il report esistente.

---

# Pipeline report: diagnosi e verifica del 5 novembre 2026

## Stato di partenza e limiti delle evidenze

La baseline è il contenuto del workspace letto prima delle modifiche, non HEAD: il repository conteneva già numerose modifiche e file non tracciati, compresi ReportPrompt, ReportTransport e LocalGateway. La regressione sul budget iniziale è stata eseguita sulla baseline: `FAIL initial phase budget`, perché richiedeva 4000 anziché i nuovi 6000 token. Il primo tentativo di compilazione non eseguiva test: mancavano le variabili delle cache locali indicate da scripts/test.sh; con quelle variabili la compilazione e la verifica funzionano.

La baseline conferma:

- blocchi di fonti fino a 14000 byte, limitati dalla discovery del gateway;
- meeting breve: rapporto diretto, 4000 token;
- meeting lungo: estrazioni sequenziali da 2200, consolidamenti da 2200, eventuali compattazioni da 1400, composizione finale da 4000;
- troncamento HTTP 422/output_limit_exceeded o finish_reason=length: raddoppio fino a 16000, fino a quattro tentativi per passaggio; ogni nuovo passaggio riparte dal budget iniziale;
- checkpoint atomici dei passaggi riusciti, ripresa e cancellazione.

Il bundle `dist/Verbale.app/Contents/Info.plist` dichiara 0.14.1, build 27. README documenta per quella versione il retry fino a 16000. Non esiste `/Applications/Verbale.app` né una copia nominata Verbale in `~/Applications`; non è stata stabilita l'identità della build eventualmente avviata da un'altra posizione. Versione e data del bundle non provano l'identità del codice binario. Questa modifica è compilata nello scratch SwiftPM, non distribuita né installata; il bundle dist rimane quello precedente.

Il gateway separato è stato consultato soltanto su file di protocollo, capabilities, configurazione e diagnostica, senza lettura dei token, avvio, riavvio o richieste al servizio. Il contratto dichiara input_limit_bytes=14000 per Claude e output_limit_exceeded come 422. La configurazione locale dichiara maxConcurrency=2 e maxOutputTokens=32768; Verbale mantiene una sola inferenza attiva e il proprio tetto a 16000. Il modello e la destinazione restano quelli selezionati dall'utente (nel contesto fornito, claude/haiku via CLI).

## Diagnosi

Il troncamento confermato è un esaurimento dell'output consentito. I budget iniziali piccoli provocavano rigenerazioni integrali: per esempio 2200+4400+8800 per ogni passaggio che richiede più di 4400 token. La ripetizione del budget iniziale a ogni fusione moltiplicava quel costo.

Le schede erano testo libero, senza schema o limite alla crescita delle informazioni distinte. Il prompt di sistema richiedeva tutte le sezioni del rapporto anche nei passaggi intermedi (pur condizionandole al REPORT FINALE). Il consolidamento riscriveva ripetutamente tutte le informazioni; una scheda troppo grande richiedeva un'ulteriore chiamata di compattazione. Il codice non misurava dimensioni effettive, duplicazioni, usage e durata per fase: non è possibile affermare retroattivamente quanto abbiano inciso ciascuno di questi fattori sulle dieci richieste osservate.

Le 10 richieste, 7 troncamenti e circa 51000 token riportati nel contesto sono un'istantanea, non un benchmark. I token di output possono comprendere ragionamento, ma non sono disponibili evidenze per attribuire tutto il consumo al ragionamento o per ricavare la lunghezza visibile del rapporto.

## Strategia implementata

Gli intermedi sono JSON `facts: [{kind, text, refs}]`, con tipi fact/decision/action/risk/opportunity/question/note/conflict. Le istruzioni richiedono una voce per informazione distinta, senza sezioni vuote o riepiloghi duplicati; attività, titolari, scadenze, stato, dipendenze, negazioni e incertezze rimangono nel testo del record. Le regole sulle prove sono comuni, il formato Markdown finale viene inviato solo per la composizione finale. JSON e riferimenti alle fonti del blocco vengono validati prima del checkpoint. Non viene richiesto response_format/json_schema, non dichiarato supportato dal backend CLI.

Il consolidamento è locale e deterministico, a gruppi di tre. Unisce soltanto record con tipo e testo identici, raccogliendo le fonti senza duplicarle; conserva record con responsabili, date, qualificatori o posizioni differenti. Una tabella hash evita ricerche quadratiche fra i record. Non interpreta semanticamente le contraddizioni: le conserva per il rapporto. La crescita è lineare nei record distinti, limitata anche dal budget complessivo di output. Non ci sono più chiamate LLM di consolidamento o compattazione.

Il contenuto user, istruzioni incluse, rispetta il limite in byte dichiarato dal gateway; il system prompt rimane separato. Il limite pubblicato dal gateway è un criterio di suddivisione, non una misura dei token di contesto del modello. Se l'unione dei record non entra nella richiesta finale, viene restituito intermediateCapacity e le schede restano salvate. Questa è una limitazione esplicita sui meeting molto densi: non vengono cancellati record per farli rientrare. Una suddivisione della riunione è necessaria prima di riprovare; la sola ripresa non aumenta la capacità.

Budget iniziali basati sui byte del contenuto user completo, non su una pretesa conversione esatta byte/token:

- estrazione: min(8000, 4096 + 1024 × floor(byte/4000));
- rapporto finale: min(12000, 6000 + 2000 × floor(byte/4000));
- sempre limitati dal tetto della policy; dopo un troncamento confermato, un solo nuovo tentativo direttamente al tetto di 16000.

Per invocazione: al massimo 3 tentativi per passaggio, 48 richieste di inferenza, 192000 token di budget richiesto cumulativo e 900 secondi totali, discovery e attese incluse. I due accessi health/models sono diagnosticati ma non consumano il tetto delle inferenze o dei token. Ogni richiesta ha anche un timer cancellabile per la scadenza residua e un massimo di 330 secondi; discovery conserva i propri timeout più brevi. Una richiesta già iniziata consuma il budget prenotato anche se fallisce. I contatori ripartono quando l'utente riprende esplicitamente, riusando i checkpoint riusciti.

429 temporanei e 502/503 hanno retry limitati con Retry-After o attesa 2/4 secondi. Quote giornaliere/di utilizzo e autenticazione non vengono ritentate; attese oltre 60 secondi fermano la generazione. Un 422 senza codice di troncamento non viene trattato automaticamente come output esaurito. Timeout, indisponibilità, troncamento, limiti di lavoro, scadenza globale e capacità hanno messaggi distinti. Le risposte con finish_reason=length non entrano nei checkpoint né diventano rapporti. Si richiede finish_reason=stop per accettare una risposta completa.

Il nuovo contratto usa prompt v5-records. I checkpoint v4 vengono conservati su disco ma non riutilizzati, perché non contengono record validabili. I nuovi checkpoint mantengono identità delle fonti, endpoint, modello e prompt; file 0600, cartella 0700 e scrittura atomica. Contengono le sintesi, come prima: sono dati della riunione, distinti dalla diagnostica.

L'interfaccia usa la callback di avanzamento già collegata: Estrazione 3 di 8, Consolidamento locale con indice/gruppi/livello, Rapporto finale, oppure attesa esplicita del retry. Nessuna percentuale o previsione di completamento. I messaggi distinti degli errori raggiungono la gestione errori già presente nell'app.

## Diagnostica

OSLog: subsystem `io.verbale.reports`, category `pipeline`, righe JSON. ReportService.generate accetta anche un observer iniettabile per raccogliere metadati nei test. Non viene creato un file di log con i contenuti della riunione.

Eventi health, models, extraction, capsule, consolidation, final, retry_wait e total. Metadati: indici/numero blocchi, tentativo, budget, durata, HTTP, codice errore da vocabolario esplicito, X-Request-Id soltanto se UUID, usage numerico quando presente, byte di input/output e numero dei record. Nessun testo di errore remoto, URL, identificatore della riunione, titolo, prompt, trascrizione, risposta o credenziale. Codici sconosciuti diventano unknown. Usage mancante resta assente, non zero. Per la risposta HTTP, outputBytes misura i byte del body JSON; l'evento capsule misura i byte della scheda e consolidation quelli del JSON canonico.

Total separa tempo totale, tempo nelle richieste (discovery inclusa), tempo effettivo delle attese di retry, numero di inferenze e budget richiesto. Il resto del tempo comprende elaborazione locale e checkpoint. I checkpoint hit hanno outcome=checkpoint e non sono contati come richieste. Il budget richiesto non è usage, costo fatturato o lunghezza del report.

## Confronto deterministico prima/dopo

Stesso meeting sintetico e stessa logica di gateway finto nelle due esecuzioni: caso breve, una sorgente; lungo, otto sorgenti da circa 12300 byte. Il gateway finto tronca sotto 6000 nel breve; nel lungo sotto 7000 per gli intermedi e 10000 per il finale. Restituisce piccoli record deterministici. Le soglie e il grado di compressione sono assunzioni della fixture, non misure o stime di Claude. Il confronto esclude health/models (due per invocazione, invariati).

| Fixture | Inferenze prima → dopo | Budget cumulativo prima → dopo | Passaggi ripetuti prima → dopo |
| --- | ---: | ---: | ---: |
| Breve | 2 → 1 | 12000 → 6000 | 1 → 0 |
| Lunga | 39 → 10 | 212800 → 79344 | 26 → 1 |

Nel lungo la baseline esegue 8 estrazioni, 4 consolidamenti e 1 finale, tutti con retry secondo le soglie della fixture. La nuova pipeline esegue 8 estrazioni da 7168 e il finale da 6000, poi 16000. Rimangono quattro consolidamenti locali senza inferenza. Le soglie non sono ottimizzate sui dati della diagnostica reale.

**Latenza esclusivamente simulata:** modello artificiale `2 secondi × inferenze + budget cumulativo / 1000`. Breve 16 → 8 secondi; lungo 290,8 → 99,344 secondi. Non sono latenze osservate né una promessa di accelerazione reale. I risultati numerici sono anche in report-pipeline-benchmark.json.

Riproduzione sulla versione corrente, senza gateway reale:

```sh
sh scripts/test.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang" \
swift run --disable-sandbox --cache-path .build/cache --scratch-path .build/swift verbale-checks --report-benchmark
```

Il benchmark si trova in ReportChecks.benchmark. Per il confronto è stato eseguito anche sulle copie dei tre file originali salvate prima delle modifiche; i risultati prima/dopo sono registrati nell'artefatto JSON. Il primo commit conserva il test di regressione e la fixture del benchmark precedenti all'implementazione.

## Verifica e lavoro sul servizio reale

Dodici gruppi dedicati ai report: breve senza retry, HTTP e finish_reason, retry temporanei/permanenti, massimi e scadenze, deadline e cancellazione in volo, otto estrazioni e più livelli di consolidamento locale, conservazione delle informazioni essenziali, ripresa dopo quota, finale troncato e cancellazione, invalidazione per input cambiato, permessi checkpoint, Unicode e input_limit_bytes=6000, capacità insufficiente e riferimenti non validi. Le fixture dei report e del gateway preesistenti sono aggiornate al nuovo numero di tentativi e al finish_reason completo.

Il gateway finto verifica il trasporto delle informazioni attraverso la pipeline; non prova che un LLM reale estragga o riscriva ogni dettaglio correttamente. Con nuova autorizzazione esplicita restano da misurare su claude/haiku: latenza end-to-end e per fase, troncamenti, usage effettivo, correttezza del JSON senza schema nativo, omissioni/parafrasi/duplicazioni semantiche, completezza e accuratezza del rapporto rispetto alle fonti. Nessuna inferenza reale è stata effettuata durante questo lavoro.

## Composizione per sezioni — 0.14.2

Il limite del rapporto unico descritto sopra è ora superato per l’insieme dei record: quando il JSON consolidato non entra nel budget finale, si suddivide per categorie PM e poi per dimensione effettiva della richiesta. Ogni record distinto appartiene a una sezione dettagliata. I titoli sono assemblati localmente una sola volta; le tabelle delle parti sono Markdown autonomo. Il modello riceve il contratto di evidenza e l’istruzione di produrre soltanto il corpo della sezione. Le citazioni sono risolte dopo l’assemblaggio dell’intero report.

La sintesi esecutiva usa una selezione limitata di record interi, a rotazione fra decisioni, rischi, azioni, conflitti, domande, opportunità, fatti e note. Questa selezione riguarda soltanto la sintesi, non elimina record dalle sezioni dettagliate; l’istruzione vieta deduzioni sullo stato globale o sull’assenza di temi.

Ogni parte finale è checkpointata. Gli eventi `final_overview` e `final_section` misurano le richieste per questa modalità; i limiti di lavoro, durata e tentativi continuano ad applicarsi. Resta un errore esplicito se un singolo record è più grande del limite di input: non viene troncato. Nessuna nuova inferenza di compattazione è introdotta.

Verifica aggiuntiva: 128 e 256 record con gateway finto, input limitato a 6000/14000 byte, quote a metà delle sezioni, ripresa senza ripetere estrazioni o parti completate, tutti i record presenti nell’output della fixture. Questo prova l’instradamento e la persistenza, non la qualità di estrazione di un modello reale.
