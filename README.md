# Verbale

App macOS per registrare e trascrivere riunioni in italiano e inglese, con output in una cartella selezionabile. SwiftUI, Core Audio e Parakeet locale. Nessuna integrazione Brainy. Versione corrente: **0.16.2**.

## Avvio

Apri `dist/Verbale.app`. Il pacchetto locale è firmato ad-hoc; non è una release notarizzata per distribuzione pubblica.

1. In **Modelli locali**, scarica i modelli Trascrizione e Rilevamento del parlato, oppure importa i GGUF corrispondenti. Il download ASR è circa 941 MB; non sono inclusi nel DMG.
2. In **Riunione**, scegli la cartella di destinazione e le sorgenti audio. I dispositivi si scelgono in Impostazioni.
3. Avvia la registrazione e concedi i permessi richiesti da macOS per microfono e audio di sistema.
4. Termina per avviare e completare la trascrizione. Per ridurre i consumi durante la call, la modalità iniziale salva l’audio e rimanda testo e interlocutori al termine. In **Impostazioni → Registrazione → Trascrizione** puoi scegliere l’elaborazione durante la registrazione. **Apri cartella** mostra Markdown, JSON e note.

Se una sorgente selezionata non ha prodotto blocchi audio, la trascrizione mostra una segnalazione esplicita anche per le vecchie sessioni. Dopo 30 secondi senza blocchi di sistema, un avviso nella finestra, nel widget e nel menu invita a verificare uscita e permessi senza interrompere il microfono; una riunione silenziosa può produrre lo stesso avviso. Quando Teams espone un’uscita attiva diversa da quella scelta, Verbale segnala la differenza senza cambiare la scelta manuale.

**Salva anche l’audio è attivo di default**, anche aggiornando dalla 0.1. Puoi togliere la spunta dalla pagina Riunione, dalle Impostazioni o dal widget: la scelta viene ricordata tra gli avvii e vale per le prossime sessioni. Durante registrazione ed elaborazione l'opzione è bloccata, così non cambia la politica della sessione già avviata.

### Elenco interlocutori

L’elenco mostra una sola riga per ogni nome assegnato, raccogliendo i diversi gruppi vocali della stessa persona anche fra microfono e audio di sistema. Un clic apre il primo intervento; la matita aggiorna il nome in tutti i suoi passaggi. Il menu accanto alla persona offre **Ricorda questa voce** e **Assegna nome da profilo**, applicando il nome a tutti i gruppi e alle sorgenti raccolti nella riga. I profili si scelgono da un elenco ricercabile, anche quando si aggiungono campioni a un profilo esistente. Per cambiare persona a un solo passaggio usa la matita accanto al testo. Identificativi, cronologia e provenienza rimangono separati; le proposte incerte non vengono raggruppate con le identità assegnate.

### Gestione dell’archivio e nomi riconosciuti

In **Archivio**, ogni riunione ha i pulsanti matita (modifica titolo) e cestino (rimozione con conferma). Il titolo si modifica anche dall’intestazione della riunione; cartella e percorsi audio rimangono gli stessi. Rimuovere dall’archivio sposta la copia interna nel Cestino del Mac e conserva i file esportati nella cartella scelta.

**Separa soltanto** distingue le voci senza cercare nomi. **Separa e riconosci voci salvate** esegue già la separazione prima del riconoscimento: non serve eseguire entrambi i pulsanti. **Cerca altre voci** è un approfondimento facoltativo per preparare proposte locali da rivedere, utile anche oltre il limite di 8 voci della separazione normale.

Il riconoscimento dei profili salvati è attivo come impostazione iniziale e viene eseguito al termine dell’elaborazione, se i modelli vocali sono disponibili. Una preferenza già salvata viene rispettata. Le corrispondenze sicure assegnano il nome alla trascrizione; una proposta incerta mostra il nome con un punto interrogativo arancione. Clicca sull’icona per confermare quel passaggio o correggerlo. Le proposte incerte restano da confermare nei dati esportati.

### Uso con gli altoparlanti: riduzione dell’eco

In **Riunione → Come ascolti** oppure **Impostazioni → Audio e ascolto**, scegli **Altoparlanti · riduci eco** e lascia attivi **Microfono** e **Audio di sistema**. Seleziona l’uscita su cui ascolti realmente Teams. La preferenza viene ricordata e fissata nella singola sessione, anche per gli avvii automatici Teams. Con una sola sorgente il trattamento non si applica. Le sessioni precedenti mantengono l’acquisizione diretta; il default resta **Cuffie / acquisizione diretta**.

La trascrizione del microfono usa il filtro adattivo lineare **WebRTC AEC3**, con l’audio di sistema come riferimento allineato ai timestamp. Il trattamento lavora sui blocchi durevoli prima dell’ASR, fuori dal thread dell’interfaccia, usando fino a due blocchi precedenti per adattare il filtro e un blocco successivo come contesto; non cambia quello che ascolti né quello che Teams invia agli altri. Non silenzia il microfono quando parlano i partecipanti remoti. Compensa il ritardo interno di 64 campioni del runtime fissato per conservare durata e timestamp. Il riferimento mancante lascia passare il microfono originale nei relativi frame e aggiunge una segnalazione alla sessione; file dichiarati ma corrotti interrompono l’elaborazione con audio recuperabile.

Un controllo successivo esclude dalla trascrizione del microfono solo sequenze di almeno 5 parole e 20 caratteri che coincidono con la sorgente di sistema anche nei tempi (tolleranza di 0,8 secondi per parola). Accordi brevi e ripetizioni in momenti diversi vengono conservati. Gli originali esclusi e i riferimenti ai segmenti di sistema rimangono in `echo-duplicates.json` e nel manifest: il controllo è conservativo, può lasciare frammenti brevi e non sostituisce il filtro audio. Una frase identica pronunciata esattamente insieme potrebbe essere classificata come rientro; la copia originale rimane verificabile.

Con **Salva anche l’audio** sono esportati originali e blocchi `audio/cleaned_<id>.caf`; `meeting.json` collega ogni originale al suo `cleanedFilename`. Se disabiliti il salvataggio audio, valgono le stesse regole di pulizia della copia temporanea e di recupero in caso di errore. I file originali non vengono sovrascritti dalla cancellazione dell’eco.

Il filtro richiede alcuni secondi per adattarsi. Volume elevato, distorsione, percorsi audio non corrispondenti e cambi di dispositivo possono lasciare eco residua. I controlli sintetici verificano anche due sorgenti contemporanee, silenzio reale, buchi nel riferimento, durata e conservazione degli originali; serve comunque una prova acustica sul Mac nella stanza effettiva. Non è una promessa di eliminazione completa dell’eco.

Per una prova su due file già sincronizzati (massimo 60 secondi, output nuovo):

```sh
verbale-cli clean-echo microfono.wav sistema.wav microfono-ripulito.caf
```

Il comando ricampiona in mono a 16 kHz e assume che i due file inizino allo stesso istante. La pipeline dell’app usa invece i timestamp effettivi dei blocchi.

### Vista widget

Apri **Widget** dalla finestra principale, dalla barra dei menu o con **⇧⌘M**. È un pannello compatto e spostabile con avvio/arresto, timer, livelli delle due sorgenti, stato di salvataggio audio e screenshot. La puntina lo mantiene sopra le altre finestre; puoi disattivarla. La freccia riapre la finestra principale, la X nasconde solo il widget e non interrompe una registrazione. Non è un'estensione WidgetKit del Centro notifiche.

Il modello riconosce automaticamente IT/EN. Il testo progressivo viene elaborato su finestre con contesto; la coda audio è durevole sul disco e non richiede un server.

### Avvio automatico con Teams desktop

In **Impostazioni → Chiamate Teams, in automatico**, attiva **Registra automaticamente tutte le chiamate Teams desktop**. L'opzione è disattivata di default e viene ricordata. Prima configura cartella, modelli e sorgenti ed esegui una registrazione manuale per concedere i permessi macOS. Le sorgenti e i dispositivi selezionati sono ricordati fra gli avvii.

Verbale deve essere in esecuzione: questa versione non si avvia da sola al login. Con l'automazione attiva parte nella sola barra dei menu. Rileva la chiamata con due osservazioni distanti almeno 2 secondi, nasconde dashboard e widget e registra nella destinazione configurata. L'icona neutra a livelli diventa piena durante la registrazione; il menu mostra esplicitamente stato, durata, errori e arresto. **Mostra Verbale** riapre la dashboard su richiesta. La chiusura della dashboard lascia l'app attiva nella barra dei menu.

L'arresto avviene dopo 20 secondi consecutivi senza il segnale di chiamata, per tollerare riconnessioni brevi. Un arresto manuale non provoca un riavvio nella stessa chiamata. Disattivare l'automazione termina solo la sessione avviata automaticamente; una sessione manuale non viene arrestata alla fine di Teams. Se una finalizzazione è in corso, il nuovo avvio attende finché il segnale della chiamata è ancora attivo. Un errore di avvio non viene ritentato in continuazione: è consultabile dal menu. Il mancato accesso al segnale viene segnalato e non viene interpretato come fine chiamata.

Il rilevamento legge l'asserzione energetica locale **Microsoft Teams Call in progress**, associata al processo Teams tramite bundle ID, usando `IOPMCopyAssertionsByProcess`. Non legge conversazioni, log o contenuti Teams, non usa il microfono come indicatore e non richiede Accessibilità, Graph o credenziali Microsoft. Non dipende dallo stato muto. Il nome dell'asserzione è un dettaglio di Teams e può cambiare: il rilevamento è sperimentale e va convalidato con chiamate reali nella versione Teams installata. Non si attiva per Teams nel browser o solo perché Teams è aperto. Non vengono usate euristiche generiche sull'audio per compensare un segnale assente.

**Condivisione dell'intero schermo:** l'automazione non apre finestre o widget e rimuove l'icona dal Dock. Non garantisce invisibilità: l'icona nella barra dei menu, eventuali menu aperti e gli indicatori macOS possono essere condivisi. Apple descrive `NSWindow.SharingType.none` come una costante legacy da non usare per escludere contenuti dalla cattura; non la usiamo come falsa garanzia di protezione. [Riferimento Apple](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).

Per diagnosticare il solo segnale, senza registrare: `verbale-cli teams-status` restituisce `active`, `inactive` o `unavailable`.

**Conservazione:** per impostazione predefinita l'audio temporaneo è eliminato dopo completamento ed esportazione riusciti. Puoi esportare anche l'audio, oppure conservare la copia temporanea per rielaborazione. In caso di errore rimane recuperabile in `~/Library/Application Support/Verbale/Sessions`. L'archivio interno conserva metadati, note e trascrizione per la riapertura; puoi rimuovere questa copia dall'Archivio senza cancellare gli output esportati.

**Interlocutori:** installa il modello opzionale di diarizzazione e conserva l’audio. Dalla trascrizione scegli **Separa interlocutori**; puoi rinominarli e creare profili per riconoscerli nelle riunioni successive. La versione 0.10 legge l’audio a blocchi e rimuove il precedente limite di 30 minuti. Vedi **Profili vocali locali** in fondo a questo documento.

**Screenshot:** durante la registrazione, premi Screenshot e seleziona l'area. Le immagini sono collegate al timestamp nel Markdown. I permessi dello schermo sono separati dai permessi audio.

**Momenti segnati:** durante la registrazione usa **Segna momento** dalla riunione, dal widget (bandierina con contatore) o dalla barra dei menu. Puoi indicare Punto importante, Decisione o Azione. I marcatori mantengono il tempo della registrazione, sono visibili accanto alle note e vengono esportati nel Markdown e in `markers.json`. Puoi rimuoverli dalla lista; sono indicazioni dell’utente, non decisioni confermate automaticamente.

**Correzioni:** dopo l’elaborazione premi la matita accanto a un segmento per correggere il testo, scegliere un interlocutore esistente o crearne uno nuovo. Il segmento mantiene ID e timestamp; il testo precedente e l’allineamento originale delle parole sono conservati nella cronologia, consultabile dalla stessa finestra ed esportata in `corrections.json`. Dopo una correzione testuale non vengono attribuiti timestamp alle singole parole modificate. Per evitare sovrascritture, dopo correzioni manuali la separazione automatica dei parlanti è disabilitata; puoi continuare ad assegnarli per segmento.

**Formato report:** nella scheda Report scegli **Operativo** (predefinito) per il lavoro quotidiano oppure **Esteso** per il resoconto più analitico. Il formato operativo estrae decisioni, attività, rischi e fatti rilevanti; l’app compone sezioni e tabelle localmente, con una sola sintesi esecutiva aggiuntiva per le riunioni lunghe. Responsabili e scadenze mancanti restano espliciti. I due formati hanno checkpoint separati e la scelta vale dalla prossima generazione.

**Report:** Verbale usa esclusivamente il gateway llm-api. Nelle Impostazioni verifica il collegamento e scegli un alias Claude, Codex, Groq o locale. La trascrizione, le note personali e i marcatori vengono inviati al backend scelto su richiesta; audio e immagini non vengono inviati. Il token locale è nel Portachiavi; le credenziali dei provider sono gestite dal gateway. I riferimenti riconosciuti diventano link alle fonti, quelli sconosciuti sono segnalati. La corrispondenza semantica richiede revisione; le modifiche ai contenuti rendono il report precedente **Da rigenerare**. La trascrizione funziona anche senza gateway.

## Progetti e attività da seguire

Una riunione conclusa può essere associata a un progetto dal selettore sopra Trascrizione, Note, Report e **Attività**. **Nuovo progetto…** crea il progetto e lo assegna alla riunione. Puoi creare progetti anche dalla nuova pagina **Da seguire**.

1. Genera il report in formato **Operativo**. Le attività estratte conservano i campi originali e i riferimenti stabili ai passaggi della trascrizione; non entrano automaticamente nel registro.
2. Nella scheda **Attività**, premi **Rivedi…**. Verifica descrizione, responsabile, dipendenze e stato. Una proposta o un impegno incerto richiede comunque conferma del PM.
3. Scegli **Crea nuova attività** oppure **Aggiorna** una delle attività dello stesso progetto. Le possibili corrispondenze sono suggerimenti lessicali: la scelta rimane manuale. Aggiornando un’attività vengono mostrati i valori già confermati, da modificare esplicitamente in base alla nuova riunione.
4. Le date relative, come «venerdì», rimangono testuali. Attiva **Data confermata dal PM** e scegli la data perché l’attività compaia nei filtri temporali.
5. In **Da seguire**, filtra per progetto e per attività aperte, scadute, entro sette giorni, bloccate, senza responsabile o tutte. Clicca un’attività per modificarla e consultarne la cronologia e le fonti.

La scadenza odierna non è considerata in ritardo. Le attività completate sono escluse dai filtri operativi e restano disponibili in **Tutte**. La mancata citazione in una riunione successiva non chiude un’attività. Rigenerare il report non sostituisce le modifiche confermate dal PM; una proposta già acquisita non può essere confermata due volte. Descrizioni identiche nello stesso progetto richiedono un aggiornamento esplicito o una descrizione che distingua le attività.

Il registro locale è salvato atomicamente in `~/Library/Application Support/Verbale/project-ledger.json`, separato dai report, con permessi 0600. Conserva revisioni, testo originale delle scadenze e copie dei passaggi citati. Rimuovere una riunione dall’archivio conserva il registro e le citazioni già acquisite; il collegamento alla trascrizione non è più disponibile. Una riunione con attività confermate mantiene il progetto assegnato. Errori di salvataggio sono visibili e non pubblicano modifiche come se fossero riuscite; un registro non leggibile blocca le modifiche e conserva il file originale.

Il primo MVP non include sincronizzazione, notifiche, invii esterni o integrazioni con task manager. Le proposte strutturate richiedono una nuova generazione del report operativo; i report estesi non le producono. Il registro complessivo non è incluso nell’esportazione della singola riunione: per conservarlo su un altro Mac occorre includere il file del registro nel backup.

## Build riproducibile

### Prova audio Android

È disponibile un [progetto Android diagnostico separato](mobile/android-probe/README.md), preparato per verificare sul Galaxy S25 quali sorgenti audio siano realmente catturabili durante telefonate, WhatsApp e Teams. L’APK locale è `dist/Verbale-ProvaAudio-0.1.0.apk`. Offre prove distinte del microfono e dell’audio interno, riascolto e diagnostica locale; non è ancora la versione mobile completa e non garantisce la cattura delle due voci. Build, lint, controlli WAV e prova del servizio su emulatore passano; la compatibilità con chiamate sul Samsung reale resta da misurare.

### macOS

Requisiti: Mac Apple Silicon, macOS 14.2+, Swift 5.10+ (verificato con Swift 6.4), clang, CMake, git e Python 3. La build verificata usa Command Line Tools e shader Metal incorporati, senza compilatore `metal` separato.

```sh
git clone https://github.com/limg88/verbale.git
cd verbale
python3 scripts/build.py
sh scripts/test.sh
python3 scripts/build.py --skip-native --dmg
```

Lo script recupera il runtime e il submodule ggml fissati se assenti; non installa strumenti globali e non aggiorna automaticamente le versioni. Il repository GitHub è privato e richiede un accesso autorizzato per il clone.

L’icona dell’app è la V con onda sonora verde menta. Il master è `Resources/AppIcon.png`; la build genera `AppIcon.icns` con tutte le risoluzioni macOS tramite `sips` e `iconutil` e lo include anche nel pacchetto Preview.

- Runtime: `2eac2e77d9c7ef8899f7a86a46e693ac5ac1a5cd`
- ggml: `e705c5fed490514458bdd2eaddc43bd098fcce9b`
- Catalogo modelli: revisione Hugging Face `07a08a3a405d20c5434b9a1442f6e6cf571f57ad`, con dimensioni e SHA-256 in `Sources/VerbaleCore/Resources/models.json`.
- Codice runtime MIT; licenze dei pesi separate e riportate nel catalogo e nel pacchetto.

Per una distribuzione Developer ID usa `--sign "Developer ID Application: ..."` e completa notarizzazione/stapling con il tuo account Apple. Nessuna credenziale di firma è inclusa. La build locale non richiede un account Apple.

## CLI e controlli

```sh
verbale-cli transcribe audio.wav asr.gguf vad.gguf cartella-output /percorso/libparakeet.dylib
```

`verbale-cli` si trova nella directory indicata da `swift build --scratch-path .build/swift --show-bin-path`. Accetta file audio leggibili da AVFoundation e crea la stessa struttura di output della UI. La CLI è uno strumento di sviluppo; i percorsi modello espliciti sono a carico del chiamante. La UI verifica invece i digest del catalogo.

`scripts/test.sh` usa un eseguibile di controllo indipendente da XCTest, perché la toolchain Command Line Tools disponibile non include XCTest. Verifica recupero con journal troncato, esportazione, disco assente, allegati mancanti, collisioni, ricampionamento, conservazione dell'audio esportato dopo la pulizia e rimozione esplicita della spunta audio.

Verifica anche conferma iniziale Teams, riconnessioni, chiamate consecutive, assenza di avvii duplicati, segnale indisponibile e identità/livello dell'asserzione. Sono 19 controlli, inclusi archivi precedenti, cronologia correzioni, marcatori, ancore esportate e generazione report con note tramite un trasporto simulato, senza contattare servizi esterni.

La build isolata `python3 scripts/build.py --skip-native --preview` accetta `--check-background-ui` sul proprio eseguibile: esegue 11 controlli delle finestre, della modalità senza Dock e della revisione con dati dimostrativi, senza acquisire audio o avviare il monitor. Verifica navigazione alle fonti, correzione tramite il coordinatore e persistenza del report da rigenerare; scrive l'esito in `.build/preview-profile/background-ui-checks.json` e un’immagine della vista in `review-ui.png`. Il flag non è attivo nel bundle distribuito.

## Stato e limiti

Compilati e verificati: app Release, libreria nativa CPU/Metal, output Markdown/JSON, test di persistenza/ricampionamento, trascrizione inglese di riferimento e italiana sintetica. Le misure di questi brevi file non sostituiscono un benchmark su riunioni reali.

Da convalidare con l'utente: permessi TCC della nuova identità, acquisizione reale mic+sistema, Bluetooth, stop/riavvio hardware, registrazioni di 60 minuti, diarizzazione su voci reali e servizi report effettivi. Non è stata avviata alcuna registrazione di microfono o chiamate durante lo sviluppo.

Limiti espliciti: download con indicatore di attività ma senza pausa/ripresa persistente; hotkey della finestra e menu bar, senza registrazione di scorciatoie globali; nessuna importazione degli archivi dell'app originale; assenza di benchmark WER/DER esteso e di certificazione su macOS 14.2. Il salvataggio periodico può diventare lento su volumi remoti: in quel caso la copia interna rimane recuperabile.

L'app non è stata ancora notarizzata. Usare la versione locale come prima build di collaudo.

## Struttura

- `Sources/Verbale`: UI e coordinamento delle sessioni.
- `Sources/VerbaleCore`: dati, audio nativo, modelli, motore e report.
- `Sources/CParakeet`: bridge dinamico con contratti ABI verificati.
- `native/parakeet.cpp`: sorgente upstream fissato, senza modifiche applicative.
- `scripts`: build e verifiche.

Nota lifecycle: il bridge, legato alla revisione fissata, chiama l'hook interno `pk::shutdown_backend` dopo l'ultimo contesto e prima di scaricare la libreria. Serve a rispettare l'ordine di distruzione fra buffer, backend e registro Metal; è coperto dalla prova GPU con uscita regolare. Un aggiornamento del runtime deve riverificare questo contratto.

### Controlli della riduzione eco

`scripts/test.sh` compila il runtime AEC3 fissato e verifica anche il caso con due sorgenti simultanee, la preservazione della voce locale, i timestamp, i riferimenti assenti o corrotti, l’export delle tracce originali/ripulite, i duplicati testuali e il relativo audit. Per una verifica con due trascrizioni JSON ottenute da parlato sintetico sovrapposto: `sh scripts/test.sh --echo-speech-json trascrizione-sistema.json trascrizione-microfono-ripulito.json` (la fixture locale usa la frase italiana che inizia con «Vorrei»).

Misure di sviluppo, non benchmark acustici: circa 32 dB di attenuazione nell’intervallo con solo eco della fixture sintetica a banda larga; circa 20,5 dB nell’intervallo con solo eco della fixture di parlato, con livello della voce locale durante la sovrapposizione pari a circa 0,93 dell’originale. Il parlato è stato generato localmente e l’eco simulata con due ritardi: non sono misure di una chiamata reale o della stanza dell’utente.

### Correzioni dell’acquisizione continua (0.5.1)

Le due sorgenti vengono preparate prima di scegliere un’epoca comune; il tap di sistema viene avviato prima del motore microfono. La conversione continua rispetta il numero di frame richiesti da AVAudioConverter, scarica tutti i buffer disponibili e finalizza la coda del filtro allo stop. I timestamp dei blocchi avanzano con il numero di campioni salvati, senza riancorarsi a ogni callback: evita gli intervalli e le sovrapposizioni artificiali osservati nella prova reale. Discontinuità effettive dei timestamp hardware rimangono errori di acquisizione, anziché essere nascoste. Le nuove sessioni dichiarano `captureTimelineVersion: 2`.

La diarizzazione conserva l’ID del primo gruppo di ciascun segmento e rimappa gli ID del registro eco su tutti i gruppi risultanti. All’apertura di un archivio o dopo una nuova diarizzazione, se incontra riferimenti legacy non più validi, tenta di ricostruirli dalle parole originali e dai timestamp, mantenendo i vecchi ID in `previousSystemSegments` e marcando `referenceStatus`. Se le evidenze non bastano, li segnala come `unresolved`; non inventa collegamenti.

La prova su una copia della registrazione reale ha mostrato un miglioramento dell’attenuazione nei tratti remoti esaminati ricostruendo la timeline continua, con lo stesso filtro lineare. Non è una misura dell’ERLE su ogni intervento o una garanzia di eliminazione di ogni rientro. L’avvio hardware coordinato richiede ancora verifica nella prossima registrazione reale; i test non avviano microfono o chiamate.

La regressione include una voce locale dieci volte più bassa durante il parlato sovrapposto: il filtro lineare la conserva nella fixture, mentre la soppressione residua più aggressiva sperimentata non supera il controllo ed è esclusa dal pacchetto. Il runtime continua a compensare 64 campioni di ritardo. Il nuovo campo `echoProcessingVersion: 1` distingue questo trattamento; la correzione della timeline è indicata separatamente da `captureTimelineVersion: 2`.

### Report lunghi e limiti del servizio

Durante la generazione viene mostrata la parte in lavorazione o il tempo di attesa imposto dal servizio. **Sospendi** interrompe il lavoro; **Genera report** riprende riutilizzando le parti completate, anche dopo un riavvio, se fonti, endpoint e modello sono invariati. I checkpoint contengono sintesi della riunione e restano nella cartella privata della sessione (`report-jobs`), senza chiavi API; non vengono esportati.

Gli errori distinguono limiti temporanei, quota giornaliera, chiave non valida e richieste troppo grandi. Le attese automatiche sono limitate a circa un minuto per tentativo e quattro tentativi per richiesta: una quota esaurita richiede di attendere il ripristino o aggiornare il piano del provider. I limiti si applicano all’account e possono essere condivisi con altre applicazioni.

### Gateway locale condiviso (llm-api)

In **Impostazioni → Dalla conversazione al report** scegli la cartella del progetto separato e il suo URL base (default `http://127.0.0.1:8080/v1`). Il collegamento predisposto in `/Users/giovanni.limatola/dev/llm-api` include `config.json`, un token privato stabile in `work/verbale-token` e `start-verbale.command`. Il file `VERBALE.md` in quella cartella documenta avvio e utilizzo da altre app.

Premi **Avvia gateway** per aprirlo nel Terminale, poi **Importa token locale** e **Verifica e aggiorna modelli**. La verifica legge health e alias senza invocare modelli; il token viene salvato in una voce Portachiavi separata dalla chiave API Groq. Seleziona il modello dall’elenco: gli alias locali compaiono solo dopo averli configurati nel gateway. Il login del backend e la disponibilità effettiva sono verificati dal gateway quando generi il report. È possibile inserire un token diverso manualmente.

Il gateway rimane utilizzabile dalle altre app anche chiudendo Verbale: arrestalo con Ctrl-C nella sua finestra Terminale. Verbale non installa servizi globali, non scarica modelli e non avvia automaticamente il gateway durante la registrazione. Con un alias Claude/Codex il testo viene elaborato dal servizio del relativo client; con un alias Ollama/LM Studio dipende dal modello configurato sul server locale.

Per questa modalità Verbale omette temperature, trasferisce max_tokens e attende fino a 330 secondi per richiesta (mantieni il timeout del gateway sotto questo valore). I redirect HTTP sono bloccati. Sono distinti token gateway errato, login backend, quota, concorrenza, timeout e output incompleto. Le parti completate sono recuperabili tramite i checkpoint locali.

Validazione del collegamento: `python3 scripts/test_gateway.py --project /percorso/llm-api`. Richiede Node.js 24+ e avvia soltanto il gateway e un server modello fittizio su porte loopback temporanee. Verifica anche che i redirect non inoltrino credenziali e che la ripresa non replichi le chiamate già completate; arresta i servizi di prova al termine.

### Groq tramite gateway (0.8.0)

Le integrazioni dirette Groq/API compatibile e Claude abbonamento sono state rimosse da Verbale. Claude, Codex, Groq e modelli locali si selezionano nello stesso elenco del gateway. Il client di Verbale accetta soltanto URL loopback e non avvia più Claude Code né legge chiavi API dei provider.

Il gateway pubblica gli alias `groq/gpt-oss-20b` e `groq/gpt-oss-120b`. La configurazione locale predisposta usa `GROQ_API_KEY`, oppure la precedente voce Portachiavi di Verbale (`io.verbale.reports`, account `api-key`) come fallback su macOS: la chiave non viene copiata in file e non viene letta durante health/discovery. Eventuali autorizzazioni del Portachiavi si gestiscono nel normale dialogo macOS. La vecchia credenziale viene conservata per evitare perdita di configurazione.

Le attese Groq da header sono centralizzate nel gateway. Il client distingue limiti temporanei (ritentativi limitati) da quote giornaliere o di spesa (nessun retry immediato), e usa il limite di input dichiarato dal gateway per suddividere i report. Riavvia il gateway dopo l’aggiornamento e premi **Verifica e aggiorna modelli**.

### Desktop quotidiano (0.9.0)

**Nuova riunione:** scegli titolo facoltativo, sorgenti, modalità di ascolto e cartella; la spunta **Conserva l’audio** resta visibile. Premi **Avvia registrazione** in alto a destra. Durante l’acquisizione trovi timer, livelli audio, marcatori e screenshot; **Termina e salva** resta nell’intestazione.

**Riunione salvata:** usa le schede **Trascrizione**, **Note** e **Report**. La trascrizione occupa lo spazio disponibile, con correzioni per passaggio e gestione degli interlocutori espandibile. Le note vengono salvate automaticamente. Il report si genera dalla propria scheda, dove puoi scegliere il modello del gateway, copiarlo e aprire i rimandi alle fonti. Le opzioni di registrazione non vengono riproposte quando consulti una riunione conclusa.

**Archivio:** cerca in titoli, trascrizioni e note, poi apri la riga. La rimozione della copia interna è nel menu contestuale e mantiene la conferma esistente.

**Impostazioni:** Registrazione per salvataggio e Teams, Report per il gateway, Avanzate per dispositivi, copie interne e widget. I modelli di trascrizione si gestiscono dalle impostazioni o dalla preparazione iniziale. Il widget resta disponibile nella barra laterale e con ⇧⌘M. Le scorciatoie di acquisizione e il comportamento automatico Teams sono conservati.

Analisi e scelte di interfaccia: [docs/DESKTOP-UX.md](docs/DESKTOP-UX.md).


## Profili vocali locali (0.10)

1. Prepara i modelli opzionali **Interlocutori** e **Profili vocali** in Modelli. Il secondo occupa circa 26,5 MB; entrambi vengono verificati contro il catalogo fissato.
2. Apri una riunione con audio conservato. In **Trascrizione → Interlocutori**, usa **Separa interlocutori** se occorre distinguere i parlanti. Le correzioni e i nomi manuali vengono conservati.
3. Dal menu con l’icona della persona accanto a un passaggio scegli **Ricorda questa voce**. Ascolta e seleziona 2–6 campioni distinti di 3–8 secondi, con la stessa persona e senza sovrapposizioni. Conferma la verifica e assegna un nome, oppure aggiungi i campioni a un profilo esistente. Non basta rinominare un interlocutore per creare un profilo.
4. Puoi attivare il riconoscimento al termine delle prossime registrazioni da **Impostazioni → Voci**. Per una riunione già salvata usa **Riconosci voci salvate**. Nella trascrizione puoi confermare o rifiutare le associazioni. Un rifiuto ripristina il parlante anonimo e viene rispettato nelle analisi successive della riunione.

L’analisi legge al massimo otto secondi audio per volta (cinque per la diarizzazione) e non ha il precedente limite di 30 minuti. Al termine della registrazione il riconoscimento avviene prima dell’eventuale pulizia dei temporanei; per rianalizzare o creare un profilo in seguito serve l’audio conservato. Con gli altoparlanti si usa il microfono ripulito dall’eco, senza ripiegare silenziosamente sulla traccia grezza. Per il profilo del microfono vengono esclusi anche i passaggi in cui parla la sorgente di sistema. I tratti con più voci rilevate restano anonimi.

I profili si trovano in `~/Library/Application Support/Verbale/VoiceProfiles/profiles.json` (cartella privata 0700, file 0600). Contengono nome, caratteristiche numeriche normalizzate della voce, impronta esatta del modello e metadati dei campioni, senza copie audio. Non vengono esportati con la riunione né inviati a llm-api. I nomi assegnati compaiono invece nella trascrizione e nel report. Rinomina, disattiva ed elimina i profili dalle impostazioni; eliminare un profilo non modifica i nomi storici.

Il riconoscimento è prudente e sperimentale: confronto con il centro dei campioni del profilo, esclusione dei modelli incompatibili, soglia di somiglianza 0,55 e margine 0,05 per proporre un nome; almeno due campioni indipendenti tutti sopra 0,80 e con margine 0,15 per assegnarlo automaticamente. Sono soglie di prodotto iniziali, **non percentuali di accuratezza**. Voci sconosciute o risultati in conflitto rimangono senza nome. I profili non vengono creati né aggiornati automaticamente; microfoni diversi, rumore e sovrapposizioni richiedono revisione e altri campioni verificati.

I controlli includono persistenza, permessi, modelli incompatibili, vettori non validi, ambiguità, consenso, correzioni, conferma/rifiuto, lettura di audio su timeline di due ore, tracce AEC e esclusione di sovrapposizioni. La prova nativa usa esclusivamente la fixture pubblica LibriSpeech a due parlanti inclusa in parakeet.cpp, non chiamate personali. Per ripeterla:

```sh
VERBALE_TEST_VOICE_MODEL=/percorso/wespeaker-resnet34-voxceleb.gguf \
VERBALE_TEST_DIAR_MODEL=/percorso/nemotron-3-diarization-q8_0.gguf \
sh scripts/test.sh
```

La fixture verifica integrazione e discriminazione tra due voci; non misura l’accuratezza su riunioni reali o su persone mai incontrate. La convalida con chiamate dell’utente resta necessaria.


### Correzioni del flusso profili (0.10.2)

La selezione si ferma a sei campioni, con indicazioni sul requisito che manca per salvare. Dopo il salvataggio il nome viene assegnato anche all’interlocutore della riunione corrente e riportato nei file esportati. Il nome manuale ha precedenza sul riconoscimento e richiede la rigenerazione dei report precedenti. Se il passaggio non ha un parlante distinto, il nome viene assegnato solo a quel passaggio, senza nominare tutta la sorgente.

Per i profili creati con versioni precedenti, usa il menu con l’icona della persona accanto a un passaggio: **Assegna nome da profilo → nome della persona**. Non occorre ripetere la creazione del profilo né conservare di nuovo i campioni audio.


### Qualità dei campioni e variabilità della voce (0.10.3)

Ogni passaggio proposto viene valutato localmente, senza caricare modelli di trascrizione: livello medio, porzioni a basso livello in finestre di 20 ms, saturazione e durata. **Segnale consigliato** indica un volume regolare con poche pause; **Da verificare all’ascolto** evidenzia volume basso, pause, passaggi brevi o picchi saturi. Sono controlli del segnale, non una misura del rumore di fondo, dell’identità della persona o delle sovrapposizioni: l’ascolto resta necessario. Non viene mostrata una percentuale di identità o una stima SNR inventata.

Le differenze fra caratteristiche vocali estratte non provano che si tratti di persone diverse. La conferma esplicita dell’utente permette di salvare campioni variabili o aggiungerli al profilo esistente. Il profilo mantiene tutti i campioni verificati; se una coppia ha somiglianza inferiore a 0,50, viene segnalato **Campioni variabili** e i risultati del riconoscimento restano proposte da confermare, anche con un punteggio alto. Non si abbassano le soglie per nominare automaticamente una persona. L’assegnazione manuale del nome nella riunione resta disponibile.

Rimangono bloccati file mancanti/incompleti, modello incompatibile, vettori non validi, intervalli sovrapposti o duplicati e audio quasi assente o frequentemente saturo. Gli errori di estrazione indicano il timestamp interessato.


## Ricerca sperimentale di altre voci (0.11)

La diarizzazione standard distingue al massimo otto voci nella stessa analisi. **Trascrizione → Interlocutori → Cerca altre voci** esegue invece analisi locali su finestre di 90 secondi, con 15 secondi di contesto ai bordi. I numeri locali non sono identità globali: le caratteristiche vocali vengono confrontate fra finestre, collegandole con somiglianza almeno 0,78 e margine 0,12. Nelle parti di contesto sovrapposte può usare anche lo stesso audio come ancora temporale: almeno due secondi puliti, copertura reciproca del 70%, margine del 25% sugli altri gruppi e nessuna forte contraddizione vocale. Un confronto ambiguo crea un gruppo distinto da verificare; non assegna un nome esistente e non forza l’appartenenza agli otto gruppi precedenti. Le soglie sono iniziali e non percentuali di accuratezza.

Il risultato rimane separato in `speaker-analysis.json` nella copia privata della sessione, senza embedding e senza invio a servizi esterni. Servono l’audio conservato e i due modelli opzionali. L’analisi è annullabile e legge blocchi di cinque secondi, mantenendo in memoria solo i modelli, gli intervalli e un numero limitato di vettori per gruppo. Non carica l’intera chiamata.

Nella revisione scegli un gruppo proposto, ascolta i campioni, seleziona i passaggi verificati e indica il nome. **Nessun passaggio è selezionato inizialmente.** Puoi usare un nome esistente o aggiungerne uno. La conferma cambia solo i nomi scelti; se occorre separare un segmento a cavallo fra due voci, conserva l’ancora originale sul primo pezzo e il contenuto precedente nella cronologia. I passaggi non selezionati mantengono il nome precedente. Non cambia parole o timestamp con un nuovo riconoscimento ASR. Il report precedente diventa da rigenerare.

**Rivedi proposte** riapre l’analisi salvata. Se trascrizione, correzioni, sorgenti o nomi sono cambiati al di fuori di questa revisione, le proposte diventano non applicabili e occorre ripetere la ricerca. Le conferme parziali aggiornano l’impronta dell’analisi per consentire di continuare.

Limiti: otto resta il massimo locale per ciascuna finestra; interventi molto brevi o sovrapposti possono non produrre un campione di tre secondi. Un gruppo senza caratteristiche sufficienti resta distinto e potrebbe duplicare una persona. Rumore, cambiamenti di microfono e variabilità della voce possono dividere o accorpare i gruppi. Il numero di **voci proposte non è un conteggio certo dei partecipanti**; verificare prima di applicare i nomi. Le correzioni preesistenti sono riferimenti da conservare, non prove che tutti i passaggi del gruppo appartengano a una persona.

Per creare una proposta da CLI senza modificare la sessione:

```sh
verbale-cli analyze-speakers /percorso/meeting.json /percorso/diarizzazione.gguf /percorso/voce.gguf /nuovo/percorso/proposte.json
```

L’output deve essere nuovo. I controlli coprono più di otto identità globali su vettori distinti noti, ambiguità, indipendenza delle proposte, selezioni parziali, conservazione di nomi e cronologia, input modificati e annullamento. Le prove native impiegano audio pubblico LibriSpeech; non costituiscono un benchmark su riunioni reali.


### Revisione rapida per persona (0.11.1)

La schermata iniziale non presenta più tutti i frammenti come persone da assegnare. Mostra al massimo cinque controlli distinti per nome, con fino a tre estratti: incongruenze fra nomi, passaggi senza nome o confronto fra varianti consistenti dello stesso nome. Quando disponibile include un estratto di riferimento. I gruppi con meno di due campioni o durata complessiva sotto 12 secondi non entrano nella revisione rapida; le varianti dello stesso nome richiedono almeno 15 secondi attribuiti a quel nome.

**Metti da parte questo controllo** registra solo la scelta di non continuare il controllo rapido su quel nome, senza approvare altri passaggi o cambiare la trascrizione. Puoi annullarla con **Riapri messi da parte**. La scelta sopravvive al riavvio e impedisce che lo stesso nome venga riproposto per tutti i suoi frammenti. **Correggi passaggi** apre invece la selezione dettagliata per applicare il nome ai soli passaggi confermati. **Analisi completa** mantiene accessibili tutti i gruppi, anche quelli incerti o troppo brevi. La revisione rapida non certifica il numero delle persone né la correttezza di tutti i nomi.

Funziona sulle analisi già salvate, senza rianalizzare l’audio. Il numero visibile dei controlli è distinto dal numero tecnico dei gruppi e nessuna fusione vocale viene fatta soltanto per ridurre la lista.


## Rivalutazione progressiva (0.12)

Confermando un nome nella revisione, il nome viene salvato subito e parte la rivalutazione degli altri interventi. Si usano solo passaggi attribuiti esplicitamente dall’utente e campioni di profili vocali che l’utente ha creato per questa stessa riunione con lo stesso modello. Un’assegnazione automatica non diventa mai da sola un esempio. Le correzioni puntuali del parlante nell’editor alimentano il riferimento quando l’analisi è ancora coerente con la riunione. Una modifica del solo testo aggiorna le proposte senza confermare l’identità della voce; i testi corretti vengono preservati durante la rivalutazione.

Si estraggono unità di 3–7,5 secondi: i riferimenti possono combinare passaggi distinti che hai confermato per la stessa persona. I candidati vengono invece uniti soltanto quando sono vicini, nella stessa sorgente e nello stesso gruppo proposto, senza aggiungere contesto non verificato. Gli interventi lunghi vengono analizzati in più unità e assegnati soltanto se tutte concordano. Se non c’è abbastanza audio utilizzabile, la conferma del nome resta salvata e il sistema chiede altro materiale esplicito.

Il confronto usa esempi vocali individuali, per tollerare varianti di canale e pronuncia. Con un solo riferimento occorrono somiglianza almeno 0,90 e margine 0,15 rispetto alle altre persone (e a un minimo per la voce sconosciuta). Con almeno due riferimenti e un secondo sostegno sopra 0,75, la soglia migliore può essere 0,80. Sono soglie iniziali, non percentuali di accuratezza. Il risultato può restare incerto. Il nome non viene esteso al resto di un gruppo senza analizzare l’audio di quei passaggi.

A ogni ciclo le precedenti predizioni vengono riconsiderate in una copia: possono essere confermate, cambiate o ritirate se la nuova informazione non le sostiene. I passaggi corretti manualmente restano protetti. Le assegnazioni automatiche compaiono come tali nella trascrizione e possono essere confermate o corrette. Nella revisione si aggiornano il numero degli interventi risolti e quelli ancora incerti. **Rivaluta con le conferme** consente di riprendere il lavoro; annullare mantiene le conferme già salvate e non applica un risultato parziale.

Le conferme per passaggio e la provenienza degli automatismi sono in `speaker-analysis.json`. I vettori audio sono separati in `speaker-learning-cache.json` nella cartella privata della sessione, permessi 0600, vincolati all’identità esatta del modello e alle sorgenti audio. Questa cache non viene esportata con la riunione né inviata al gateway; le conferme della riunione non aggiornano automaticamente i profili vocali globali. La rimozione della copia interna elimina anche la cache. La prima rivalutazione può richiedere più tempo; le successive riusano i vettori dell’audio invariato.

Per simulare il risultato su file separati, senza cambiare l’originale:

```sh
verbale-cli preview-speaker-learning meeting.json speaker-analysis.json voce.gguf nuova-cartella-preview [profiles.json]
```

I controlli nativi con due voci pubbliche verificano riduzione degli incerti dopo nuove conferme, mancata propagazione a un’altra voce nello stesso vecchio gruppo, correzione di predizioni precedenti, uso dei soli riferimenti espliciti e cache riutilizzata. Non costituiscono una misura di accuratezza su tutte le chiamate reali.


## Interfaccia e avvio della registrazione (0.12.1)

Nell’elenco Interlocutori il nome è un collegamento alla prima occorrenza della persona; l’icona della matita apre la modifica. Il campo usa una bozza locale e salva una volta con **Invio** o **Salva**, senza scrivere file a ogni carattere. Anche i nomi nella trascrizione sono cliccabili. La navigazione può essere ripetuta dopo uno scorrimento manuale e considera i diversi identificativi che condividono lo stesso nome assegnato.

Il salvataggio del nome e il relativo export avvengono fuori dal thread UI. Se la copia audio esportata è già la stessa sorgente disponibile, non viene ricalcolato due volte l’hash di quel medesimo file per ogni modifica del nome; le verifiche delle copie fra file distinti restano attive.

È possibile avviare la registrazione prima del meeting: la mancanza iniziale di buffer di sistema viene mostrata come **in attesa dell’audio di sistema**, senza arrestare la registrazione dopo 12 secondi. L’assenza dei buffer del microfono richiesto mantiene invece il controllo di errore. L’attesa iniziale è inclusa nella durata della riunione e gli eventi successivi conservano il loro offset temporale.

Le operazioni hardware CoreAudio/AVAudioEngine sono isolate su un actor dedicato. L’avvio hardware ha una scadenza di 20 secondi e l’arresto di 10: se il driver non risponde, la UI riceve un errore/stato recuperabile mentre il ripristino resta serializzato in background. I nuovi buffer non vengono più accettati dopo arresto o timeout; una nuova cattura è impedita fino al completamento del ripristino. Un arresto scaduto conserva la sessione come recuperabile. Queste scadenze non includono il tempo in cui l’utente decide il permesso Microfono.

Le regressioni simulano hardware bloccato, completamento ritardato e assenza di audio prima della chiamata, senza acquisire audio personale. I test UI verificano navigazione ripetuta e assenza di persistenza durante la digitazione. Il comportamento del driver specifico dell’utente durante una chiamata reale resta da convalidare.

### Diagnostica locale di una riunione

`verbale-cli check-meeting-voices <meeting.json> <diarizzazione.gguf> <voce.gguf> <profiles.json> <nuova-cartella-test> [--audit]` copia i file necessari in un archivio isolato e verifica separazione, riconoscimento, conferma puntuale, ri-analisi, salvataggio ed esportazione. Con `--audit` include ricerca approfondita, apprendimento progressivo, cache e confronto con passaggi già etichettati escludendo i campioni dei profili. Il comando restituisce errore se un controllo fallisce e scrive gli esiti in `checks.json`. Non modifica i dati sorgente e non contatta servizi remoti. La cartella di test contiene copie di registrazioni e trascrizioni: conservarla come gli altri dati della riunione.

### Raccordo fra blocchi di trascrizione

Dalla 0.12.5 le nuove trascrizioni riconciliano parole uguali con tempi fortemente sovrapposti fra finestre ASR adiacenti della stessa sorgente. Le ripetizioni con tempi distinti rimangono; il testo già pubblicato e le correzioni manuali non vengono riscritti. Le ipotesi scartate sono conservate nel manifest e in `transcript-boundaries.json`, esportato nella cartella della riunione. Il numero di parole riconciliate è disponibile negli avvisi della registrazione. Le trascrizioni esistenti non vengono modificate automaticamente.

La diagnostica `verbale-cli check-asr-boundaries <meeting.json> <asr.gguf> <vad.gguf> <inizio-secondi> <fine-secondi> <nuova-cartella-test>` confronta i due flussi su un estratto dell’audio di sistema, con lo stesso riconoscimento e registri separati. Verifica per hash che manifest e audio sorgenti restino invariati. Non misura il WER rispetto a un riferimento umano.

### Riascolto con più contesto

Apri una riunione con audio conservato e premi **Riascolta e confronta…** nella Trascrizione. Puoi scegliere i passaggi a bassa confidenza o l’intera trascrizione; dal menu di un passaggio puoi ritrascrivere solo quello. Il secondo passaggio locale Parakeet unisce pause brevi e usa finestre più ampie. Le correzioni testuali già accettate sono escluse. I punteggi del modello servono a dare una priorità e non certificano la presenza di un errore.

Confronta **Prima** e **Proposta**, ascolta l’audio e applica le proposte selezionate. Nomi, timestamp dei passaggi e identificativi dei collegamenti restano invariati. L’allineamento parola per parola dei passaggi cambiati viene rimosso, come per una correzione manuale; gli originali sono conservati. La modifica delle parole non conferma l’identità della voce.

**Ripristina precedente** annulla le proposte accettate nella revisione corrente, se il testo o le identità non sono stati modificati nel frattempo. Note e momenti segnati restano. La revisione corrente è salvata in `transcription-refinement.json` anche nella cartella esportata; le revisioni applicate precedenti sono conservate nell’archivio interno quando avvii una nuova analisi. Il riascolto è annullabile e non avvia una registrazione.

Whisper e Qwen con glossario sono stati confrontati nell’ambiente sperimentale locale; questa release dell’app usa Parakeet integrato e non installa Python o scarica altri motori. Il confronto e i limiti sono documentati in `docs/QA-0.13.0.md`.

### Scelta automatica del dispositivo della call

In **Impostazioni → Avanzate → Dispositivi audio**, microfono e uscita possono essere scelti separatamente:

- **Automatico · dispositivo Teams**: all’avvio di ogni registrazione usa il dispositivo esposto da Teams, dando priorità ai processi con audio attivo. Se Teams non espone una scelta univoca usa il predefinito del Mac e mostra il motivo.
- **Predefinito del Mac**: segue esplicitamente la scelta di macOS al momento dell’avvio.
- **Nome del dispositivo**: scelta manuale, sempre prioritaria. Viene ricordata tramite UID stabile, anche se macOS cambia l’identificativo numerico dopo una riconnessione. Un dispositivo manuale assente viene segnalato, senza sostituirlo automaticamente.

Le preferenze possono essere configurate anche durante una registrazione: valgono per la successiva. Il dispositivo della registrazione attuale resta fissato e i suoi nomi sono conservati nel manifest. Il passaggio automatico fra dispositivi durante una call non è implementato in questa release. Le sorgenti Microfono/Audio di sistema e la modalità Cuffie/Altoparlanti restano quelle scelte dall’utente.

Le selezioni manuali delle versioni precedenti vengono migrate quando il dispositivo è disponibile. Se non è possibile identificarlo dal vecchio ID, resta una selezione manuale non disponibile da aggiornare. Il rilevamento usa metadati Core Audio e non modifica le impostazioni di Teams o i dispositivi predefiniti del Mac.

### Prestazioni e report PM (0.14.0)

I misuratori audio aggiornano solo le proprie viste, al massimo 10 volte al secondo per sorgente. Il salvataggio dei campioni rimane integrale. Le copie audio già verificate non vengono rilette a ogni esportazione se identità, dimensione, mtime e ctime dei due file non cambiano; le modifiche esterne invalidano la verifica. La cache è limitata a 8192 coppie. ASR, VAD e AEC vengono rilasciati anche dopo stop manuale, ripresa e avvio fallito. Un caricamento parziale dei modelli non trattiene il modello ASR.

I nuovi report (prompt `v4-pm`) sono orientati al project management: sintesi, fatti/avanzamenti, decisioni, attività con responsabile/scadenza/stato/dipendenze e fonti, rischi/problemi, opportunità e punti aperti. Titoli, date e incarichi non espliciti non vengono inventati; chi parla non viene automaticamente considerato il titolare. Le call lunghe mantengono questo contratto anche durante estrazione e consolidamento. I report già presenti cambiano solo quando vengono rigenerati.

Misure e limiti: [QA 0.14.0](docs/QA-0.14.0.md).

In 0.14.1, in caso di risposta troncata Verbale aumenta automaticamente il budget fino a 16000 token, con al massimo quattro tentativi per richiesta. Le parti già completate restano riutilizzabili, compresi i checkpoint del prompt v4-pm creati con 0.14.0; il modello e il formato del report non cambiano.

### Report lunghi (0.14.2)

La pipeline usa estrazioni JSON con fonti, consolidamento locale senza riscritture LLM e budget iniziali per fase. Se i record superano la capacità di una richiesta finale, il report viene composto per sezioni e parti limitate, mantenendo tutti i record nelle sezioni dettagliate. La sintesi esecutiva usa una selezione bilanciata di record interi e non sostituisce le sezioni complete. I risultati di ogni parte vengono salvati e riutilizzati alla ripresa. Le richieste restano sequenziali.

Il nuovo schema `v5-records` richiede una nuova estrazione la prima volta: i checkpoint v4 delle versioni 0.14.0/0.14.1 restano sul disco ma non vengono interpretati come record strutturati. Trascrizione, audio, nomi e report preesistenti restano invariati fino al completamento del nuovo report. Nessuna modifica al gateway è necessaria. [Verifiche della correzione](docs/QA-0.14.2.md).

### Correzione verificata su una riunione reale (0.14.3)

Il budget delle estrazioni successive si adatta all’uso numerico osservato per blocchi di dimensione simile, con margine e tetto a 16000 token. Il limite complessivo preventivo è 384000 token richiesti; restano 48 richieste e 15 minuti per invocazione. I checkpoint v5 di 0.14.2 restano compatibili.

Le note personali sono identificate dalla fonte `N`: un’osservazione della call etichettata dal modello come `note` resta un fatto del parlato, mentre contenuti degli appunti non vengono promossi a decisioni. I titoli duplicati delle sezioni vengono rimossi; citazioni consecutive a frammenti vicini sono raggruppate in intervalli che aprono il primo passaggio. Le fonti originali restano nei checkpoint.

Gli errori espongono fase, indice, HTTP, codice e ID richiesta quando disponibili, senza testo libero del backend o credenziali. [Prova reale e regressioni](docs/QA-0.14.3.md).

Per diagnostica esplicitamente autorizzata, `verbale-cli generate-report <meeting.json> <cartella-privata> <endpoint> <alias> <progetto-gateway>` usa il gateway reale su una copia e salva metriche, snapshot e report. Non eseguirlo come test automatico senza autorizzazione a usare quel modello e quei dati. `publish-report <meeting.json> <cartella-privata>` pubblica il risultato verificato tramite SessionStore solo se la riunione è invariata e completa.


### Consumi durante le call (0.15.1)

La modalità iniziale **Al termine** evita il caricamento e l’uso dei modelli ASR/VAD e il trattamento eco durante l’acquisizione. Audio e journal interni restano salvati in blocchi; l’output viene aggiornato ogni 30 secondi e sempre al termine. L’elaborazione inizia dopo Stop e può richiedere tempo, mantenendo il recupero in caso di errore. Il report resta un’operazione separata su richiesta. La preferenza è fissata per ogni nuova riunione e non cambia una registrazione in corso.

La modalità **Durante la registrazione** conserva il testo in diretta, con maggiori consumi. Il runtime ASR usa due thread CPU al posto del default upstream di otto; la GPU rimane disponibile al motore quando questo è caricato. La modifica riduce la contesa, ma non certifica l’assenza di blocchi di Teams o dei driver Bluetooth.

Se Teams segnala una chiamata mentre viene elaborata una registrazione in modalità **Al termine**, Verbale mette in pausa il lavoro e conserva i blocchi non ancora trascritti, anche quando l’avvio automatico è disattivato. Il lavoro resta in coda e riparte automaticamente dopo la call, anche mentre consulti altre riunioni. Un’inferenza nativa già iniziata termina prima della pausa; il controllo dipende dalla disponibilità del segnale Teams e non intercetta altri programmi di videoconferenza.


### Attività in background (0.16.0)

Trascrizioni e report hanno due code persistenti separate: un lavoro per tipo alla volta. Puoi aprire altre riunioni e aggiungere nuove richieste; la barra delle attività mostra titolo, avanzamento, apertura e sospensione. Un report accodato per una riunione in trascrizione attende la sua conclusione. Le impostazioni del report vengono fissate alla richiesta; nessun token viene scritto nel manifest della coda.

L’elaborazione non usa la riunione selezionata come spazio di lavoro. Durante un’attività i contenuti della sua riunione sono protetti; gli altri rimangono consultabili e modificabili. **Sospendi** conserva i risultati già salvati; puoi riprendere con **Riprendi trascrizione** o **Genera report**. Alla chiusura dell’app i lavori non completati restano in coda per il prossimo avvio. Se Teams è in chiamata, lo stato non è verificabile o parte una registrazione, la trascrizione si mette in attesa senza bloccare la navigazione. I report hanno una coda indipendente.

Le conferme delle voci aggiornano subito il testo; salvataggio ed esportazione avvengono fuori dal thread dell’interfaccia. Click ravvicinati vengono raggruppati. In caso di mancato salvataggio locale, l’app ripristina i dati salvati e mostra l’errore; un problema di sola esportazione conserva le conferme nell’archivio.

Il cestino compare anche nel dettaglio della riunione. La rimozione mantiene la conferma e il passaggio nel Cestino dell’archivio privato; gli output esportati restano conservati. Per una riunione con attività attive o in coda, sospendile prima di rimuoverla.


### Consultazione durante la registrazione (0.16.1)

Puoi aprire l’archivio e consultare trascrizioni, note e report di altre riunioni mentre registri. Una barra mostra sempre titolo e durata della registrazione attiva e permette di terminarla. **Vai alla registrazione** o la voce **Riunione** della barra laterale riportano al documento in registrazione.

Acquisizione, timer, livelli audio, marcatori, screenshot, trascrizione live e stop usano la sessione di registrazione dedicata. Aprire un’altra riunione non ne cambia la destinazione. Al termine, viene accodata soltanto la sessione registrata e il documento consultato rimane selezionato. La registrazione attiva resta protetta dalla rimozione anche quando consulti un altro verbale.
