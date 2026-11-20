# Qualità ASR — prima fase, Verbale 0.12.5

5 novembre 2026. Implementata la riconciliazione dei raccordi fra blocchi e delle regioni vocali sovrapposte. Questa release mantiene modello, quantizzazione, VAD e durata del contesto ASR attuali.

## Comportamento

Il riconoscimento su finestre sovrapposte può restituire la stessa parola con tempi leggermente diversi. Il punto medio della prima ipotesi può appartenere al blocco precedente e quello della seconda al successivo: il precedente filtro di proprietà conservava entrambe.

La nuova riconciliazione confronta le ipotesi nuove con il testo della stessa sorgente vicino al confine, e con altre regioni nuove sovrapposte. Richiede testo equivalente, inizio distante al massimo 120 ms, durata di almeno 120 ms, copertura di almeno l’85% della parola più corta e intersezione/unione di almeno il 72%. Non riscrive il testo già pubblicato, non confronta sorgenti diverse o interlocutori esplicitamente diversi e non modifica le ipotesi protette da correzioni manuali. Non elimina ripetizioni interne alla stessa ipotesi né parole senza allineamento.

Le ipotesi rimosse, gli indici delle parole e i tempi delle copie conservate sono salvati in `transcriptBoundaryEdits` nel manifest e in `transcript-boundaries.json` nella cartella esportata. Negli avvisi della registrazione compare il numero di parole riconciliate. Le trascrizioni già complete non vengono modificate automaticamente.

## Confronto nativo su audio reale

Sono stati ritrascritti localmente 15 minuti complessivi di audio di sistema. Ogni finestra è stata riconosciuta una sola volta: baseline e nuova pipeline ricevono esattamente le stesse ipotesi ASR. Questo isola l’effetto della riconciliazione.

| Registrazione | Intervallo assoluto | Blocchi | Parole prima → dopo | Duplicazioni riconciliate | Tempo totale del test |
|---|---|---:|---:|---:|---:|
| 66B6910F | 00:00–05:00 | 60 | 660 → 658 | 2 | 25,9 s |
| C1BE978F | 02:30–07:30 | 60 | 555 → 555 | 0 | 22,0 s |
| 2D4D3CAA | 10:00–15:00 | 60 | 687 → 686 | 1 | 26,0 s |

Le tre rimozioni riguardano «allenarmi», «incontro» e «release», con tempi fortemente sovrapposti alle parole conservate. Le altre parole, il loro ordine all’interno dei passaggi e i timestamp sono identici alle ipotesi baseline; la differenza nel conteggio corrisponde esattamente alle rimozioni registrate. Anche i passaggi parzialmente ritagliati conservano l’identificativo per i collegamenti.

Verificati riapertura delle due versioni esportate e hash di manifest/audio sorgenti: 188 file controllati, nessuna modifica rilevata. Le copie diagnostiche non aggiornano i profili vocali o le riunioni originali. I test utilizzano i modelli già presenti sul Mac e non contattano servizi remoti.

## Regressioni

70 controlli di regressione superati, inclusi otto casi specifici per confini, timestamp oscillanti, ripetizioni reali, parole diverse, persone/sorgenti diverse, interventi manuali, regioni VAD e conservazione degli originali nell’export.

76 controlli dell’interfaccia superati nell’anteprima isolata. Verificati anche proprietà dei blocchi usata dall’app, riapertura degli originali conservati, collegamenti ai segmenti e correzione manuale successiva. Nessun dispositivo di cattura è stato avviato dai test.

## Limiti e fase successiva

Il risultato dimostra una correzione mirata di duplicazioni temporali, non un miglioramento misurato del WER generale. Non esiste ancora una trascrizione umana verificata dei 15 minuti: il controllo di sottosequenza certifica quali parole sono rimaste, ma non che tutte le parole riconosciute corrispondano al parlato.

Per procedere con maggiore contesto, nuovo VAD, glossario o modello alternativo serve un riferimento verificato ascoltando l’audio e un confronto separato. Le soglie conservative lasciano intenzionalmente irrisolti i casi troppo brevi o con sovrapposizione debole.

## Evidenze locali

- `.build/asr-boundary-tests/20261105-143458/summary.json`: esiti dei tre estratti, conteggi e controlli degli originali.
- Nelle sottocartelle: versioni `baseline` e `reconciled`, relativi trascritti, manifest e registro delle rimozioni.
- `.build/checks-0.12.5.log`: regressioni.
- `.build/preview-profile/background-ui-checks.json`: controlli dell’interfaccia.

Ripetibilità: `verbale-cli check-asr-boundaries <meeting.json> <asr.gguf> <vad.gguf> <inizio-secondi> <fine-secondi> <nuova-cartella-test>`.
