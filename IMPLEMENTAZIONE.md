# Stato della prima build — Verbale 0.1

> **Documento storico.** Descrive la versione 0.1 e non viene aggiornato. Per lo stato corrente vedi `README.md`, `CHANGELOG.md` e `AUDIT_REPORT.md`.

Build macOS arm64 pronta in `dist/Verbale.app` e `dist/Verbale-0.1.0-arm64.dmg`.

## Implementato

- Interfaccia SwiftUI: riunione, archivio, modelli e impostazioni.
- Scelta della destinazione con selettore nativo e bookmark persistente.
- Acquisizione microfono con AVAudioEngine e audio di sistema con Core Audio tap privato; selezione dei dispositivi.
- Buffer limitati, resampling a 16 kHz, salvataggio durevole dei blocchi e journal.
- Pipeline di trascrizione progressiva con contesto adiacente e assegnazione dei vocaboli al blocco proprietario.
- Recupero dei blocchi salvati dopo interruzione e ripresa dei lavori non completati.
- Markdown, JSON, note, audio opzionale e screenshot con timestamp nella cartella selezionata.
- Copia verificata degli allegati, marker di appartenenza della cartella e rifiuto delle collisioni.
- Pulizia audio dopo successo, salvo conservazione esplicita per rielaborazione; conservazione in caso di errore.
- Diarizzazione opzionale post-registrazione, fino a 30 minuti in questa versione, con rinomina manuale.
- Report su richiesta con endpoint configurabile, chiave nel Portachiavi e sintesi gerarchica dei testi lunghi.
- Menu bar e scorciatoie della finestra.
- Catalogo modelli indipendente, con revisioni, dimensioni e digest fissati.
- Runtime compilato da sorgente, incorporato e firmato con l'app, CPU/Accelerate e Metal.
- CLI per la trascrizione di file e build riproducibile.

## Verifiche eseguite

Sette controlli automatici, zero fallimenti:

1. Recupero idempotente con journal troncato.
2. Esportazione di manifest, trascrizione e note.
3. Destinazione non disponibile senza perdita del recupero.
4. Allegato mancante senza falsa conferma di esportazione.
5. Round trip audio Float32.
6. Cartella esistente estranea senza sovrascrittura.
7. Conversione 48 kHz stereo → 16 kHz mono con durata attesa.

Prove end-to-end sulla build Release:

| Prova | Risultato |
|---|---|
| Inglese, fixture upstream, 7,435 secondi | Trascrizione coerente con il riferimento, file Markdown/JSON creati, backend GPU MTL0, uscita regolare |
| Italiano, voce sintetica Alice, 9,750 secondi | Testo atteso riconosciuto, incluso “venerdì alle 10”, file Markdown/JSON creati, backend CPU, uscita regolare |
| Lifecycle Metal | Risolto un assert alla chiusura tramite shutdown esplicito del backend dopo rilascio dell'ultimo modello |
| Interfaccia | App avviata e schermate Riunione/Modelli ispezionate; corretta la larghezza della sidebar |
| Pacchetto | Firma locale verificata con codesign; DMG generato |

I tempi di inferenza registrati in `test-results/validation.json` escludono caricamento modelli e primo caricamento shader. Sono smoke test su brevi file, non una certificazione di prestazioni o accuratezza su riunioni reali.

## Collaudo ancora necessario

Non sono stati registrati microfono o chiamate durante lo sviluppo. Da provare sul Mac dell'utente: nuovi permessi TCC, acquisizione simultanea, Bluetooth, cambio dispositivo, sleep/wake e sessioni lunghe. Diarizzazione e integrazione LLM sono implementate ma non validate end-to-end su una riunione reale o su un servizio esterno configurato.

La build è firmata ad-hoc per uso locale e non notarizzata con Developer ID. Il supporto minimo macOS 14.2 è dichiarato ma non certificato su una macchina con quella versione. Mancano download riprendibili, hotkey globali, importazione degli archivi originali e valutazione estesa WER/DER.

Queste attività restano aperte nel piano; la build consegnata è la prima versione eseguibile per il collaudo, non una release già validata per distribuzione pubblica.

Per istruzioni e build: [README](README.md).
