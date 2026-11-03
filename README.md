# Verbale

App macOS per registrare e trascrivere riunioni in italiano e inglese, con output in una cartella selezionabile. SwiftUI, Core Audio e Parakeet locale. Nessuna integrazione Brainy. Versione corrente: **0.3.0**.

## Avvio

Apri `dist/Verbale.app`. Il pacchetto locale è firmato ad-hoc; non è una release notarizzata per distribuzione pubblica.

1. In **Modelli locali**, scarica i modelli Trascrizione e Rilevamento del parlato, oppure importa i GGUF corrispondenti. Il download ASR è circa 941 MB; non sono inclusi nel DMG.
2. In **Riunione**, scegli la cartella di destinazione e le sorgenti audio. I dispositivi si scelgono in Impostazioni.
3. Avvia la registrazione e concedi i permessi richiesti da macOS per microfono e audio di sistema.
4. Termina per finalizzare la trascrizione. **Apri cartella** mostra Markdown, JSON e note.

**Salva anche l’audio è attivo di default**, anche aggiornando dalla 0.1. Puoi togliere la spunta dalla pagina Riunione, dalle Impostazioni o dal widget: la scelta viene ricordata tra gli avvii e vale per le prossime sessioni. Durante registrazione ed elaborazione l'opzione è bloccata, così non cambia la politica della sessione già avviata.

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

**Interlocutori:** installa anche il modello di diarizzazione e conserva l'audio prima di registrare. Dopo la finalizzazione scegli **Separa gli interlocutori**; puoi rinominarli. La versione 0.1 limita questo passaggio offline a 30 minuti. Non identifica automaticamente persone fra riunioni.

**Screenshot:** durante la registrazione, premi Screenshot e seleziona l'area. Le immagini sono collegate al timestamp nel Markdown. I permessi dello schermo sono separati dai permessi audio.

**Report:** nelle Impostazioni inserisci endpoint base e modello, poi scegli Genera report. Solo il testo viene inviato al servizio indicato, su richiesta; la chiave è nel Portachiavi. È possibile usare un endpoint locale compatibile. La trascrizione funziona senza questa configurazione.

## Build riproducibile

Requisiti: Mac Apple Silicon, macOS 14.2+, Swift 5.10+ (verificato con Swift 6.4), clang, CMake, git e Python 3. La build verificata usa Command Line Tools e shader Metal incorporati, senza compilatore `metal` separato.

```sh
git clone https://github.com/limg88/verbale.git
cd verbale
python3 scripts/build.py
sh scripts/test.sh
python3 scripts/build.py --skip-native --dmg
```

Lo script recupera il runtime e il submodule ggml fissati se assenti; non installa strumenti globali e non aggiorna automaticamente le versioni. Il repository GitHub è privato e richiede un accesso autorizzato per il clone.

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

Verifica anche conferma iniziale Teams, riconnessioni, chiamate consecutive, assenza di avvii duplicati, segnale indisponibile e identità/livello dell'asserzione. La build isolata `python3 scripts/build.py --skip-native --preview` accetta `--check-background-ui` sul proprio eseguibile: esegue controlli delle finestre e della modalità senza Dock, senza acquisire audio o avviare il monitor, e scrive l'esito in `.build/preview-profile/background-ui-checks.json`. Il flag non è attivo nel bundle distribuito.

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
