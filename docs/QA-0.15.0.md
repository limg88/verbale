# QA Verbale 0.15.0 — 6 novembre 2026

## Implementazione

Formato Operativo predefinito e formato Esteso v5 opzionale. Estrazioni JSON, campi delle attività distinti, impaginazione locale di tutte le sezioni dettagliate e una sola sintesi esecutiva per i report lunghi. Budget specifico di input dichiarato dal gateway; richieste sequenziali. Suddivisioni memorizzate dei blocchi che eccedono i limiti. Il profilo low viene richiesto solo se pubblicizzato dal gateway ed entra nell’identità dei checkpoint. Nessuna elaborazione cloud durante la call.

Gateway separato aggiornato in modo additivo, verificato e riavviato quando active_requests e warm_clients erano entrambi zero. Alias, configurazione e credenziali invariati. Il launcher ufficiale ha richiesto più dei primi dieci secondi di attesa: la disponibilità e le nuove capabilities sono state poi verificate prima di procedere.

## Verifiche automatiche

- 112 gruppi di controlli core, compresi nove gruppi per report operativi.
- 114 PASS nella suite con gateway reale e backend locale/Groq simulati, zero FAIL. Coperti anche cache e contratto JSON operativo.
- 62 test Node del gateway, zero fallimenti; CLI simulato verifica inoltro selettivo di --effort e conteggi numerici.
- 92 controlli UI nell’app Preview separata, tutti veri. Ispezionata desktop-compact-report.png: formato e comandi visibili a 1000×680.
- Build release, firma locale verificata e DMG verificato da hdiutil.

## Prova reale

Riunione ESAOTE 4A6CFCF3-B630-44CC-A24C-A13460270E4E, 3683,89 secondi, 1836 segmenti. Stesso endpoint e alias claude/haiku; modello risolto dal provider claude-haiku-5-5. Tre esecuzioni senza checkpoint operativi riutilizzati:

| Esecuzione | Durata | Inferenze | Troncamenti |
| --- | ---: | ---: | ---: |
| Operativo iniziale, profilo standard | 397,11 s | 9 | 2 |
| Operativo, profilo low | 145,27 s | 5 | 0 |
| Operativo finale, istruzioni attività affinate, low | 119,29 s | 5 | 0 |

Sono misure sulla stessa riunione, non una media né un A/B isolato: tra le ultime due prove sono cambiate anche istruzioni su separazione delle attività, responsabili e dipendenze. Non è stato eseguito un nuovo report Esteso completo da zero; i 342 secondi della verifica precedente riutilizzavano nove estrazioni e non costituiscono una baseline confrontabile.

Esecuzione finale: 4 estrazioni e 1 sintesi, 72 record (33 attività), 30860 byte, sette sezioni PM, 168 link validi, nessuna fonte non verificata. Ripetizione dagli stessi checkpoint: 0 inferenze, circa 0,04 secondi. Le metriche includono 16545 token di ragionamento dichiarati dal provider; il profilo low non equivale ad assenza di ragionamento.

Controllo manuale a campione: revisione della bozza, rilettura del materiale, parere richiesto, appuntamento con il cliente, invito subordinato alla revisione, simulazione economica, inoltro delle note. Verificati i passaggi di fonte corrispondenti. Il primo risultato accorpava incarichi e attribuiva una moderazione al proponente: le istruzioni sono state rafforzate prima della prova finale. Non esiste una trascrizione di riferimento annotata e non è provata una copertura semantica completa. Rimangono possibili accorpamenti, qualificatori e dipendenze interpretati male, particolarmente nel parlato frammentato: serve revisione umana. Il formato Esteso rimane disponibile.

## Conservazione e distribuzione

Il meeting.json originale è identico allo snapshot precedente alla prova. Verificati gli hash di 1464 file originali esportati, audio inclusi: nessuna modifica. Il report pubblicato precedente è stato conservato; il nuovo risultato è consultabile nel workspace privato .build/report-operational-final-esaote-20261106/report.md, con metriche, verifica e prova di cache. I checkpoint sperimentali non sono stati copiati nell’archivio dell’utente.

Pacchetto dist/Verbale-0.15.0-arm64.dmg, build 30. Non sostituita né chiusa la copia installata: durante la preparazione risultava una registrazione attiva, con meeting.json aggiornato. Installazione da eseguire dopo la call. Preferenze e modello selezionato conservati.
