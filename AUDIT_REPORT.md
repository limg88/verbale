# AUDIT_REPORT — Verbale 0.16.2

Data: 2026-11-14 · Branch: `audit/2026-11-14` (da `main` @ `0947754`) · Ambiente: macOS 26.6.2 arm64, Command Line Tools 27.0 (Swift 6.4), senza Xcode.

Convenzioni: `P-` performance, `U-` usabilità, `M-` manutenibilità, `X-` cross-platform, `E-` evolutive. "NON VERIFICATO" = non eseguito o non misurato; la stima viene dalla lettura del codice.

## 1. Sintesi esecutiva

1. Verbale è un'app **solo macOS arm64** (Swift Package, SwiftUI + AppKit + Core Audio + Metal). Il vincolo "deve funzionare bene su Windows e macOS" oggi non è soddisfatto e non è raggiungibile con una ricompilazione: serve una decisione di prodotto (E-33).
2. La **baseline non era verde su questa macchina**: la build fallisce con l'SDK predefinito dei Command Line Tools (27.0) e i check fallivano per una cache CMake rimasta dal vecchio percorso del repository. Con SDK 26.5 e cache rigenerata: 135/135 check, 146/146 self-check UI.
3. Corrette **6 problematiche** oggettive (un crash, un bug di nome cartella, 15 controlli senza nome accessibile, rottura CRLF su Windows, test rotti su clone pulito, 2 warning). Post-fix: 137/137 check, 146/146 UI, 0 warning Swift.
4. Il rischio principale a runtime è il **lavoro sincrono sul main thread che cresce con la durata della riunione e con l'archivio** (salvataggio dell'intero `meeting.json` a ogni blocco audio, lista archivio decodificata per intero). Non misurato su riunioni lunghe.
5. La base di codice ha buone difese (scritture atomiche, permessi 0600, redirect rifiutati, modelli verificati con SHA-256) ma **nessuna CI, nessun linter, test non standard, un `AppModel` di 1.248 righe** e circa 900 righe di codice di test nel binario di release.

| Asse | Voto | Motivazione |
|---|---|---|
| Performance | 3/5 | Liste virtualizzate, livelli audio e note isolati, lavoro pesante in coda. Restano I/O e JSON sul main a ogni blocco e ricalcoli a ogni render. |
| Usabilità | 3/5 | Stati vuoto/caricamento curati, conferme sulle rimozioni. Contrasto sotto AA su arancione/rosso, bersagli piccoli, un solo alert generico, uscita durante la registrazione senza conferma. |
| Manutenibilità | 2/5 | Build non riproducibile sulla toolchain installata, niente CI/linter, harness di test fatto a mano, righe da 300–500 caratteri, pin duplicati in 5 punti. |
| Cross-platform | 1/5 | Un solo target (macOS 14.2 arm64). Nessun percorso Windows/Linux/Intel; Android è un APK diagnostico non tracciato. |

## 2. Baseline vs post-fix

| Metrica | Baseline | Post-fix | Nota |
|---|---|---|---|
| Build release, SDK predefinito 27.0 | **KO** (`SwiftUIMacros` plugin non trovato, 56,6 s) | KO (invariato, vedi E-01) | `.build/audit/baseline/build-sdk27-FAILED.log` |
| `sh scripts/test.sh`, primo tentativo | **KO** (cache CMake di `dev/Test REA`) | OK | cache spostata in `.build/echo/CMakeCache.txt.stale-audit` |
| Build release, SDK 26.5 | OK, 74,3 s, RSS 1,17 GB | OK | tempo post-fix non rimisurato a freddo |
| Check `verbale-checks` | 135 PASS / 0 FAIL, 43,1 s (con compilazione) | 137 PASS / 0 FAIL, 14,6 s (incrementale) | tempi non confrontabili |
| Check su clone pulito | KO (header `parakeet_capi.h` assente) | 137 PASS | clone in scratchpad |
| Self-check UI (`--check-background-ui`) | 146/146, 26,5–27,3 s | 146/146 | 3 misure in baseline |
| Warning compilatore Swift | 2 (`ImplicitStrongCapture`) | 0 | restano 2 warning del linker sul percorso CLT |
| Bundle `Verbale Preview.app` | 16.532 KB | 16.580 KB | +48 KB |
| Eseguibile `Verbale` | 10.088 KB | 10.136 KB | |
| `libparakeet.dylib` / `libverbale_aec.dylib` | 3.544 / 732 KB | invariati | |
| Architetture (`lipo -archs`) | arm64 (tutti e tre) | arm64 | |
| Copertura dei test | NON VERIFICATO | NON VERIFICATO | harness eseguibile, non XCTest |
| Tempo di avvio a finestra | NON VERIFICATO | NON VERIFICATO | serve strumentazione o Instruments |
| Lighthouse | non applicabile | — | non è un'app web |

## 3. Problematiche risolte

| ID | Asse | Sev. | File:riga | Causa | Fix | Commit | Verifica |
|---|---|---|---|---|---|---|---|
| X-01 | Cross-platform | Media | `Sources/VerbaleCore/Domain.swift:95` | `DateFormatter` senza locale/calendario: con calendario buddhista la cartella di export diventa `2569-11-14_…`, con locale arabo usa cifre non ASCII | Locale `en_US_POSIX` + calendario gregoriano | `97e97bf` | Nuovo check; `sh scripts/test.sh -AppleLocale 'th_TH@calendar=buddhist'` falliva (exit 1), ora passa |
| M-01 | Manutenibilità | Bassa | `Sources/VerbaleCore/ReportTransport.swift:54,58` | `\d` ICU accetta cifre Unicode, `Double()` no: `duration("٣s")` fa force-unwrap di `nil` | Classe `[0-9]` | `1bd1da7` | Nuovo check; prima `Fatal error` (exit 133), ora PASS. Raggiungibilità da un header reale: NON VERIFICATO |
| U-01 | Usabilità | Alta | `DashboardView.swift:73,95,246,268,269`, `MeetingJobsView.swift:18`, `MeetingContentViews.swift:93`, `TranscriptReviewView.swift:48,115,190,259,262`, `VoiceProfileViews.swift:124`, `RecordingWidget.swift:41`, `TranscriptRefinementView.swift:44` | Controlli solo-icona con `.help` ma senza nome accessibile (WCAG 4.1.2) | `.accessibilityLabel`, con titolo riunione/nome profilo nelle righe | `437bb66` | Build + self-check UI 146/146. Prova con VoiceOver: NON VERIFICATO. Tocca 7 file (una riga ciascuno), oltre la soglia indicativa di 5 |
| X-02 | Cross-platform | Media | `.gitattributes` (assente) | Con `core.autocrlf=true` (default Git for Windows) `scripts/test.sh` esce in CRLF: `set: -: invalid option` | `.gitattributes` con `eol=lf` | `6394df0` | Riprodotto in un clone con `autocrlf=true`; dopo il fix `file` riporta LF |
| M-02 | Manutenibilità | Media | `scripts/test.sh:4` | Su clone pulito non inizializza il submodule `parakeet.cpp`, il cui header è incluso da `Sources/CParakeet/Bridge.c:6` | `git submodule update --init` se l'header manca | `bf617ae` | Clone pulito: 137 PASS |
| M-03 | Manutenibilità | Bassa | `Sources/Verbale/AppModel.swift:408` | 2 warning `ImplicitStrongCapture` | Cattura `[self]` esplicita (semantica invariata) | `ef531b3` | Warning 2 → 0 |

## 4. Problematiche non risolte

| ID | Asse | Sev. | Evidenza | Motivo |
|---|---|---|---|---|
| M-04 | Manutenibilità | Alta | `swiftc -typecheck` di un file con `@State` fallisce con SDK 27.0, passa con `-sdk MacOSX26.5.sdk` | Problema di toolchain (CLT senza plugin `SwiftUIMacros`). La scelta tra installare Xcode e fissare `SDKROOT` negli script è tua → E-01 |
| M-05 | Manutenibilità | Media | `.build/echo/CMakeCache.txt` e `.build/parakeet/CMakeCache.txt` puntano a `/Users/…/dev/Test REA` | Aggirato per `echo` spostando la cache; `parakeet` resta stantia (una build senza `--skip-native` fallirà). Fix negli script = cambio di comportamento → E-02 |
| X-03 | Cross-platform | Critica | `Package.swift:6`; `lipo -archs` = `arm64` | Nessun target Windows/Linux/Intel. Decisione di prodotto → E-33 |
| U-02 | Usabilità | Alta | `VerbaleApp.swift:684-691` | ⌘Q durante la registrazione ferma e chiude senza conferma. Cambio visibile → E-07 |
| U-03 | Usabilità | Alta | `AppModel.swift:396,406` | `fatalError` all'avvio se la cartella dati non è scrivibile. Cambio visibile → E-08 |
| U-04 | Usabilità | Media | Arancione di sistema su bianco ≈ 2,2:1, rosso ≈ 3,55:1 (18 + 7 punti d'uso); `Palette.accent` su scuro ≈ 2,5–3,3:1 | Sotto WCAG 1.4.3. Valori di sistema calcolati a memoria, non misurati a schermo. Cambio di colore visibile → E-16 |
| M-06 | Manutenibilità | Bassa | `ReportPipeline.swift:94,106` | `UInt64(timeout * 1e9)` con `timeout` negativo se la scadenza passa tra due letture dell'orologio. Non riproducibile senza un hook di test → E-09 |
| M-07 | Manutenibilità | Media | `SpeakerAudit.swift:58`, `SpeakerLearning.swift:196` e altri 4 | `Dictionary(uniqueKeysWithValues:)` va in trap su sidecar con ID duplicati. Scegliere tra errore e "tieni il primo" → E-10 |
| M-08 | Manutenibilità | Bassa | CVE note sul parser GGUF di ggml (2024–2026); pin `e705c5f` del 2026-05-25 | Copertura delle correzioni nel pin NON VERIFICATO. Mitigato dalla verifica SHA-256 dei modelli → E-36 |

## 5. Catalogo evolutive

Ordinate per rapporto impatto/effort. ⚡ = quick win. ⚠ = "PROBLEMATICA – richiede decisione".

| ID | Asse | Descrizione | Beneficio atteso | Imp. | Effort | Rischio | Dipende da | Proposta |
|---|---|---|---|---|---|---|---|---|
| E-01 ⚡⚠ | M | Build rotta con SDK 27.0 dei CLT | Build riproducibile sulla macchina di sviluppo | A | S | Basso | — | In `build.py`/`test.sh` rilevare l'assenza del plugin `SwiftUIMacros` e usare `MacOSX26.sdk` se presente, con messaggio esplicito; in alternativa documentare Xcode come requisito. Aggiornare il README |
| E-04 ⚡ | P | `@Published` riassegnati con lo stesso valore ogni 1–2 s (`AppModel.swift:555-560`, `341-365`) | Niente re-render di tutta la dashboard a riposo | A | S | Basso | — | Helper `setIfChanged` per `status` e `teamsStatus`; spostare `elapsed` in un `ObservableObject` dedicato come `AudioLevelState` |
| E-05 ⚡ | P | Ricerca archivio su tutti i segmenti, 3 volte per render, senza debounce (`DashboardView.swift:21-24`) | Digitazione fluida con archivi grandi | A | S | Basso | — | Calcolare `filteredMeetings` una volta per `body`; `debouncedQuery` a 250 ms |
| E-06 ⚡ | P | `SpeakerAuditView`: `valid`/`triage` ricalcolano JSON + SHA-256 dell'intera riunione più volte per tasto (`:20-28`) | Campo nome reattivo su riunioni lunghe | A | S | Basso | — | `let valid`/`let triage` in testa a `body`, passati alle sotto-viste |
| E-07 ⚡⚠ | U | Uscita durante la registrazione senza conferma | Niente registrazioni interrotte per errore | A | S | Basso | — | `NSAlert` in `applicationShouldTerminate` quando `isRecording`; spiegare perché "Esci" è disabilitato quando occupato |
| E-08 ⚡⚠ | U | `fatalError` all'avvio | Errore leggibile invece di crash a ogni avvio | A | S | Basso | — | `NSAlert` con percorso, errore e "Mostra nel Finder" / "Esci" |
| E-02 ⚡ | M | Cache CMake stantia dopo lo spostamento del repository | Build nativa che si ripara da sola | M | S | Basso | — | In `build_echo.py` e `build.py` confrontare `CMAKE_HOME_DIRECTORY` con il sorgente e usare `cmake --fresh` se diverso |
| E-03 ⚡ | M | `analysis-comu/` (392 MB, APK di terzi) non ignorata; `mobile/` e 14 `docs/QA-*.md` non tracciati ma linkati dal README | Niente commit accidentale; clone completo | M | S | Basso | — | Aggiungere `analysis-comu/` a `.gitignore`; tracciare `mobile/` e `docs/QA-*.md`; valutare la rimozione dei ref `refs/codex/…` che contengono l'APK |
| E-09 ⚡⚠ | M | Trap su timeout negativo nel report | Nessun crash a ridosso della scadenza | B | S | Basso | — | `UInt64(max(0, timeout) * 1e9)` e check con `ReportTiming` che supera la scadenza alla seconda lettura |
| E-10 ⚡⚠ | M | Trap su ID duplicati nei sidecar | File danneggiato → messaggio, non crash | M | S | Basso | — | Validare l'unicità in `SpeakerAudit.load` e simili e lanciare "ripeti l'analisi" |
| E-11 ⚡ | M | Validazione dei path incoerente (`MeetingWorkProcessor.swift:44`, `EchoCancellation.swift:76`, `SessionStore.swift:39,50`); root non riportata a 0700; `NULL` passato a `%s` in `CParakeet/Bridge.c:40,71` | Difesa in profondità | M | S | Basso | — | Un `safeRelative(_:)` condiviso; `setAttributes(0o700)` in `SessionStore.init`; guardia sui `NULL` |
| E-13 ⚡ | M | Harness: totale parziale fuorviante (`SessionStoreTests.swift:346`), skip silenziosi, soglie di 0,18 s | Esito leggibile, meno falsi rossi | M | S | Basso | — | Totale finale e conteggio SKIP; allargare le soglie temporali |
| E-15 ⚡ | M | Pin in 5 punti; `build.py:119` riscrive un file tracciato; `-j 6` fisso | Aggiornamenti in un punto solo | M | S | Basso | — | Gli script leggono i lock JSON; niente riscrittura; `-j` da `--jobs` |
| E-20 ⚡ | U | Terminologia incoerente (Termina/Stop, Sospendi/Annulla, segmento/passaggio…) e poche scorciatoie | Interfaccia coerente | M | S | Basso | — | Glossario unico; ⌘N nuova riunione, ⌘F ricerca |
| E-30 ⚡ | X | Firma Developer ID con hardened runtime ma senza entitlements (`build.py:123`) | Build notarizzabile con microfono funzionante | M | S | Medio (NON VERIFICATO a runtime) | — | File `.entitlements` con `device.audio-input`, passato a `codesign` |
| E-36 ⚡ | M | CVE ggml da verificare sul pin | Rischio noto e documentato | M | S | Medio | — | Confrontare il pin con gli advisory; se serve aggiornare `parakeet.cpp` e rieseguire i check ASR |
| E-14 | M | Nessuna CI | Regressioni intercettate a ogni push | A | S–M | Basso | E-01 | Workflow GitHub Actions su runner macOS arm64: submodule, `sh scripts/test.sh`, build release |
| E-12 | M/U | Riunioni con `meeting.json` illeggibile spariscono in silenzio (`SessionStore.swift:18-20`, `AppModel.swift:990`) | Nessuna perdita apparente di dati | A | M | Basso | — | `listIssues()` nel core e avviso in Archivio con "Mostra nel Finder" |
| E-21 | P | `receive()` salva tutto `meeting.json` a ogni blocco di 5 s sul main, O(n²) (`AppModel.swift:563-568`); `store.list()` sincrono ad avvio e a inizio registrazione (`:438,536,990`) | Niente scatti durante riunioni lunghe; avvio indipendente dall'archivio | A | M | Medio | — | Il journal rende già durevoli i blocchi: limitare il salvataggio con `RecordingExportCadence`, passare da `workDisk`; aggiornare una sola riunione invece di rileggere l'archivio |
| E-22 | P | `processPending` decodifica audio e scrive sul main in modalità "durante la registrazione" (`AppModel.swift:580-649`) | UI fluida durante la call | A | M | Medio | E-21 | Spostare lettura/scrittura audio in `Task.detached`, precalcolare l'ultimo inizio per sorgente |
| E-23 | P | Core: 1 decode + 3 encode per blocco (`MeetingWorkProcessor.swift:13-17`), fingerprint nei cicli (`SpeakerLearning.swift:113-136`), scansione O(parole × segmenti) (`TranscriptRefinement.swift:84`), modelli da 940 MB ri-hashati a ogni job (`Models.swift:27`) | Elaborazione più rapida su riunioni di 2–3 h | A | M | Medio | — | Confronto a byte nel `commit`; fingerprint una volta; ricerca binaria; cache del digest per inode/mtime. Prima un benchmark sintetico in `PerformanceChecks` |
| E-16 ⚠ | U | Contrasto sotto AA; stato "scaduta" e selezione comunicati solo dal colore | Conformità WCAG 1.4.3 / 1.4.1 / 1.4.11 | A | M | Basso | — | `Palette.warning`/`danger` più scuri in chiaro, accento più chiaro in scuro; prefisso "Scaduta ·"; `.isSelected` sulle voci di navigazione |
| E-19 | U | Un solo alert generico; errori sovrascritti o stantii nei fogli; rimozione marcatore senza conferma | Errori azionabili | M | M | Basso | — | Alert con azioni ("Apri Impostazioni di Sistema"), errori per contesto, annulla sulla rimozione del marcatore |
| E-17 | U | Bersagli da 13–16 pt, controlli disabilitati senza motivo visibile, finestra minima 1000×680 con colonna non scorrevole | Uso più agevole su schermi piccoli | M | M | Basso | — | Frame minimo 24 pt + `contentShape`; motivo in chiaro sotto i controlli bloccati; colonna sessione scorrevole |
| E-18 | U | Download modelli (941 MB) con solo spinner | Attesa comprensibile e annullabile | M | M | Basso | — | Delegate `URLSession` in `ModelManager` con percentuale, dimensione e annulla |
| E-29 | M | Core quasi senza log; `try?` che nascondono cause; logica su stringhe italiane (`Review.swift:48`); duplicazioni | Diagnosi più rapida | M | M | Basso | — | `Logger` nei punti elencati; costanti condivise per gli stati; helper unici per hash e lookup audio |
| E-26 | M | ~900 righe di check nel binario di release (`VerbaleApp.swift:79-640`, `AppModel.swift:1001-1248`) | Binario più piccolo, meno superficie | M | M | Medio | E-27 | Target separato per i check UI, oppure flag di compilazione per il build di anteprima |
| E-28 | M | Nessun linter/formatter; righe da 300–500 caratteri | Diff e revisioni leggibili | M | M | Medio (diff enorme) | E-14 | Configurazione `swift-format`, riformattazione in un commit dedicato, controllo in CI. Disponibilità nella toolchain: NON VERIFICATO |
| E-32 | X | Audio esportato in `.caf`; `meeting.json` con path assoluto macOS | Export apribile su Windows e spostabile | M | M | Medio (formato) | — | Opzione WAV/M4A; `destination` relativa nel file esportato |
| E-24 | P | `list()` decodifica ogni riunione per intero; coda lavori mai sfoltita | Archivi grandi scalabili | M | L | Medio | E-21 | Indice/sommario per riunione; sfoltimento dei job conclusi |
| E-27 | M | Test come eseguibile con shim fatti a mano, senza discovery né copertura | Test standard, copertura misurabile | M | L | Medio | E-01 | Migrazione graduale a XCTest o Swift Testing; `--enable-code-coverage` |
| E-31 | X | Solo arm64 | Supporto Mac Intel | B–M | M | Medio | — | Build universale di Swift e delle due dylib (`CMAKE_OSX_ARCHITECTURES`), Metal opzionale |
| E-37 | M | `IMPLEMENTAZIONE.md` fermo alla 0.1; README "19 controlli"; nessun documento di architettura | Onboarding | B | S | Basso | E-03 | Aggiornare o rimuovere; breve `ARCHITECTURE.md` |
| E-25 | M | `AppModel` di 1.248 righe con ~60 `@Published` | Modifiche locali, meno invalidazioni | A | L–XL | Alto | E-21, E-27 | Estrarre coordinatori per registrazione, archivio, report, Teams, impostazioni; un passo per commit dietro i check esistenti |
| E-35 | Mobile | Probe Android non tracciato; crash probabile se `startForeground` non viene chiamato (`CaptureService.java:71-81`); UI bloccata su "Richiesta di avvio…"; rotazione che perde i dialoghi | Probe affidabile; base per l'app mobile | M | S (probe) / XL (app) | Medio | E-03 | Tracciare il progetto; `startForeground` nel catch prima di `stopSelf()`; reset dello snapshot; `configChanges`. L'app mobile completa è un progetto a sé |
| E-34 | X | Preparazione al port del core: nessun `#if canImport`, `URLSession` senza `FoundationNetworking`, CryptoKit, nomi `.dylib` fissi, CMake solo Apple | Core compilabile su Linux, CI Linux | M | L | Medio (swift-crypto è una dipendenza nuova) | E-33 | ~20 file su 43 sono Foundation-only (stima, NON VERIFICATO): isolare audio/keychain dietro protocolli, `if(APPLE)` in CMake, job Linux sul solo core |
| E-33 ⚠ | X | **Supporto Windows** | Soddisfa il vincolo dichiarato | A | XL | Alto | — | Tre strade: (a) dichiarare macOS-only; (b) core Swift portabile + UI e cattura audio native Windows (WASAPI loopback); (c) riscrittura su stack cross-platform. Serve la tua scelta prima di qualsiasi lavoro |

**Quick win consigliati per primi:** E-01, E-04, E-05, E-06, E-07, E-08, E-02, E-03.

## 6. Matrice di compatibilità

| Ambiente | Stato | Evidenza |
|---|---|---|
| macOS 14.2+ Apple Silicon, uso | OK | Check 137/137, UI 146/146 su macOS 26.6.2. Registrazione live e macOS 14/15: NON VERIFICATO |
| macOS, build con CLT 27.0 (SDK predefinito) | KO | Plugin `SwiftUIMacros` assente; OK con `SDKROOT=MacOSX26.5.sdk` |
| macOS Intel (x86_64) | KO | `lipo -archs` = `arm64` per app e dylib; DMG `-arm64` |
| macOS, distribuzione notarizzata | Non verificato | Solo firma ad-hoc esercitata; entitlements assenti (E-30) |
| Windows, uso | KO | `Package.swift:6`; SwiftUI/AppKit/Core Audio; `dlfcn.h`/`pthread.h` negli shim C |
| Windows, checkout del repository | OK dopo X-02 | Prima CRLF su `test.sh`; simulato con `core.autocrlf=true`, non su Windows reale |
| Linux (CI), app | KO | Stessi motivi; `native/echo/CMakeLists.txt:6` linka CoreFoundation; `build.py` usa `sips`, `iconutil`, `codesign`, `hdiutil` |
| Linux (CI), solo core | Non verificato | Stima ~20 file portabili; nessuna toolchain Linux eseguita |
| CI macOS | Assente | Nessun `.github/workflows`; clone pulito ora funziona (M-02) |
| Android | Parziale / non verificato | Solo APK diagnostico `mobile/android-probe` (minSdk 29, target 36), non tracciato; lint a 0 errori ma prodotto in un altro percorso; nessun dispositivo o emulatore usato in questo audit |

## 7. Assunzioni

| ID | Assunzione | Come verificarla |
|---|---|---|
| A1 | Perimetro dei fix = file tracciati. `mobile/` e `analysis-comu/` solo letti | Tua conferma; vedi E-03 |
| A2 | Windows/Linux/Android valutati solo staticamente | Runner Windows e Linux, dispositivo Android |
| A3 | Nessuna registrazione live, nessuna chiamata al gateway LLM, nessun download di modelli; `scripts/test_gateway.py` non eseguito (richiede `~/dev/llm-api` e Node) | Sessione di prova reale e gateway locale |
| A4 | "Lint" = warning del compilatore, in assenza di un linter | E-28 |
| A5 | La build del 9 novembre era riuscita con la stessa toolchain; la causa del cambiamento non è stata individuata | Storico degli aggiornamenti dei Command Line Tools |
| A6 | Costi di performance derivati dal codice, non profilati | Benchmark sintetico di 2–3 h e Instruments |
| A7 | Rapporti di contrasto calcolati dai valori di `Design.swift` e dai colori di sistema a memoria | Misura a schermo in chiaro e scuro |
| A8 | Self-check UI eseguito sul profilo isolato `Verbale Preview`; l'app `dist/Verbale.app` in esecuzione non è stata toccata | — |

Log dell'audit: `.build/audit/` (ignorata da git).

## 8. Evolutive implementate (approvate il 2026-11-14)

Stato dopo questa fase: check 137/137, self-check UI 147/147 (un check nuovo), build e test verdi **senza** impostare `SDKROOT` a mano.

| ID | Cosa è cambiato | Commit | Verifica |
|---|---|---|---|
| E-01 | `scripts/buildenv.py`: `build.py` e `test.sh` provano l'SDK predefinito e, se non compila SwiftUI e `SDKROOT` non è impostato, usano l'SDK installato più recente che funziona | `b3f5ba8` | `sh scripts/test.sh` e `build.py` senza `SDKROOT`: OK, con nota "uso MacOSX26.5.sdk" |
| E-02 | Le cartelle di build CMake configurate per un altro percorso vengono ricreate. `--fresh` non bastava: i file generati (shader Metal) tenevano il path vecchio | `d4f1068` | Cache `echo` e `parakeet` riportate al vecchio percorso: ricostruzione completa riuscita |
| E-03 | `analysis-comu/` in `.gitignore`; tracciati 14 `docs/QA-*.md` e `mobile/android-probe` (solo sorgenti, 24 file). I ref `refs/codex/…` con l'APK da 175 MB **non** sono stati toccati | `bb23cab` | `git status` pulito; nessun segreto nei file aggiunti (grep) |
| E-04 | `status` e `teamsStatus` pubblicano solo se il testo cambia. `elapsed` cambia davvero ogni secondo e resta com'è | `bc45164` | Nuovo self-check UI: 100 riassegnazioni uguali → 0 notifiche |
| E-05 | Ricerca archivio calcolata una volta per render, su query con debounce di 250 ms | `a6aee67` | Build + self-check UI. Guadagno non misurato |
| E-06 | `valid` e `triage` di `SpeakerAuditView` memorizzati per un passaggio di render | `6a5e093` | Build + self-check UI. Guadagno non misurato |
| E-07 | Conferma prima di uscire durante una registrazione | `c8af8b0` | Solo compilazione e lettura: **non provato a runtime** (nessuna registrazione live nell'audit) |
| E-08 | Avviso di sistema con errore, cartella e "Mostra nel Finder" al posto di `fatalError` | `50133ca` | Simulato con `Sessions` come file: il processo resta in attesa dell'avviso invece di andare in crash |

Note:
- E-08 usa `CFUserNotificationDisplayAlert` e non `NSAlert`: il modello nasce durante la costruzione della scena SwiftUI e un run loop modale lì dentro abortisce il processo (verificato: SIGABRT al primo tentativo).
- Con E-01 la riga "Build release, SDK predefinito 27.0" della sezione 2 passa da KO a OK tramite fallback; installare Xcode resta la soluzione pulita.
- Resta da provare a mano: E-07 con una registrazione reale, E-05/E-06 su un archivio grande.

## 9. Seconda tornata di evolutive (2026-11-14)

Stato finale: check 138/138, self-check UI 147/147, build release OK, probe Android compilato con lint a 0 errori.

**Implementate**

| ID | Cosa è cambiato | Verifica |
|---|---|---|
| E-09 | Timeout del report limitato a ≥ 0 prima della conversione | Solo compilazione; il caso non è riproducibile con l'orologio reale |
| E-10 | 8 indici per ID tollerano duplicati (vince il primo) invece di andare in trap | Check esistenti verdi; nessun check nuovo sul file danneggiato |
| E-11 | Cartella sessioni riportata a 0700; righe di journal con path assoluto o `..` ignorate; niente `NULL` a `%s` nello shim C | Check esistenti verdi |
| E-12 | Riunioni con manifest illeggibile segnalate all'avvio, con percorso | Nuovo check nel core |
| E-13 | Riga di esito finale dell'harness | Output `verbale-checks: all suites passed` |
| E-14 | Workflow GitHub Actions su runner macOS | **Mai eseguito su GitHub** |
| E-15 | I pin si leggono dai file lock; `build.py` non riscrive più un file tracciato | Build nativa e check verdi |
| E-16 | Colori di testo adattivi per avvisi, errori e accento; "Scaduta ·" in parole | Rapporti calcolati (≥ 5:1), non misurati a schermo |
| E-17 | Bersagli da 24 pt per 5 pulsanti icona; voce di navigazione selezionata esposta | Build + self-check UI |
| E-19 | Pulsante "Apri Impostazioni di Sistema" negli errori di permesso microfono | Solo compilazione |
| E-20 | ⌘N nuova riunione, ⌘F archivio; un'etichetta "Stop" corretta | Solo compilazione |
| E-23 | Cache del verdetto SHA-256 dei modelli; confronto a byte del manifest nel commit | Check verdi; guadagno non misurato |
| E-30 | Entitlement microfono passato a `codesign` per le firme Developer ID | **Non verificato**: nessuna identità Developer ID |
| E-35 | Probe Android: rotazione gestita senza ricreare l'activity; richiesta di stop su servizio inattivo | Build e lint offline; nessun dispositivo |
| E-37 | `IMPLEMENTAZIONE.md` marcato come storico; conteggio check rimosso dal README | — |

**Implementate solo in parte**

| ID | Fatto | Resta |
|---|---|---|
| E-17 | Bersagli e tratto selezionato | Motivo visibile sui controlli disabilitati; colonna sessione scorrevole |
| E-19 | Caso microfono | Errori per contesto, annulla sulla rimozione del marcatore |
| E-20 | Scorciatoie | Glossario unico dei termini |
| E-23 | Hash modelli, confronto manifest | Fingerprint nei cicli, scansione parole × segmenti |
| E-35 | Rotazione, stop | `startForeground` mancante su avvio fallito (serve un dispositivo) |

**Non implementate, con il motivo**

| ID | Motivo |
|---|---|
| E-21, E-22 | Toccano il salvataggio durante la registrazione. Senza una prova con registrazione reale il rischio di perdere audio non è accettabile |
| E-18 | Richiede un delegate di download nuovo e una UI di avanzamento: non verificabile senza scaricare 941 MB |
| E-24, E-25, E-27 | Lavori L/XL (indice archivio, scomposizione di `AppModel`, migrazione dei test): fuori dal budget di questa sessione |
| E-26 | Spostare i check fuori dal binario cambia il modo in cui gira il self-check UI: va deciso insieme a E-27 |
| E-28 | La riformattazione riscrive quasi ogni riga e va fatta da sola, su un branch pulito |
| E-29 | Logging e costanti: nessun difetto bloccante, rimandato |
| E-31 | Build universale: serve provare le dylib x86_64 su un Mac Intel |
| E-32 | Cambia il formato di export: serve la tua scelta sul formato audio |
| E-33, E-34 | Supporto Windows/Linux: serve la tua scelta tra le tre strade |
| E-36 | Verifica CVE del pin ggml: ricerca non svolta |
