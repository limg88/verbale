# Verifica locale di Verbale 0.12.3

5 novembre 2026. Test su copie isolate di cinque registrazioni reali. Nessun invio a servizi remoti, nessuna registrazione hardware avviata e nessun aggiornamento dei profili vocali originali.

## Registrazioni e risultati

| Caso | Durata | Situazione iniziale | Verifiche |
|---|---:|---|---|
| 522EBAB8 | 5m 20s | Nessun nome assegnato, microfono e sistema | Separazione, riconoscimento, conferma puntuale simulata, ri-analisi, export, riapertura, ricerca approfondita, apprendimento e cache |
| 65598D37 | 11s | Nessun nome assegnato, sistema | Gestione di poco parlato, ri-analisi e persistenza; nessuna identità forzata |
| 4B9B0365 | 3m 40s | Nomi parziali, microfono e sistema | Conservazione delle assegnazioni, proposte incerte, conferma puntuale, ri-analisi ed export |
| D861843D | 14m 37s | Nomi parziali e conferme esistenti | Conservazione delle correzioni, ricerca approfondita, apprendimento, cache e confronto con passaggi etichettati |
| E5F7F73C | 7m 09s | Nessun nome, audio non conservato | Errore esplicito, trascrizione e archivio invariati |

63 controlli sulle copie reali, tutti superati. La ricerca approfondita ha prodotto 5 gruppi nel primo caso e 17 nel quarto: sono proposte tecniche, non un conteggio verificato delle persone.

Nel controllo aggiuntivo della quarta registrazione sono stati nascosti i nomi di 14 passaggi, relativi a 5 persone, escludendo i passaggi sovrapposti ai campioni usati per creare i profili. I gruppi dell’etichettatura sono stati conservati. Risultato: 2 attribuzioni automatiche e 12 proposte corrispondenti ai nomi assegnati dall’utente, nessun nome discordante. Questo verifica il confronto dei profili su questi esempi; non misura l’accuratezza complessiva della separazione delle voci in una nuova riunione.

Le conferme aggiunte dal test sono simulazioni sulle copie. Non sono nuove verifiche umane dell’identità dei partecipanti e non vengono trasferite agli originali.

## Bug corretti

1. **Collisione dei numeri degli interlocutori.** Il modello può riutilizzare lo stesso numero in una nuova separazione. Un passaggio nuovo poteva così ereditare un nome manuale assegnato in precedenza. Il caso è stato riprodotto con un test fallente e corretto separando i nuovi identificativi da quelli già nominati.
2. **Proposte obsolete ancora visibili.** La riapertura caricava l’analisi verificando solo l’identificativo della riunione. Ora verifica anche i contenuti; rinomina e ri-analisi eliminano dalla vista le proposte non più applicabili. Le conferme puntuali che aggiornano correttamente l’analisi restano utilizzabili.
3. **Nome diverso fra archivio e finestra quando l’export fallisce.** Il nome veniva salvato internamente, ma un errore nell’export impediva di aggiornare lo stato mostrato. Ora il nome salvato resta visibile e coerente; la destinazione non disponibile viene segnalata separatamente e l’export è ritentabile.
4. **Predizioni progressive conservate come conferme durante la ri-analisi.** La preparazione ora ritira anche le attribuzioni automatiche della revisione precedente. Usa la provenienza soltanto per ritirare predizioni corrispondenti; non riattiva proposte obsolete e conserva rinomine e conferme manuali successive.

## Regressioni e risorse

- 63 controlli di regressione superati, inclusi i modelli nativi su audio pubblico, annullamento e apprendimento progressivo. Sul fixture pubblico la coda passa da 4 a 2 a 0 verifiche dopo le conferme; una rivalutazione a cache calda non ricalcola gli embedding.
- 68 controlli dell’interfaccia superati nell’app di anteprima isolata, compresi proposte obsolete e destinazione di export non disponibile.
- Hash SHA-256 confrontati su 724 file originali, fra archivi, esportazioni, audio e profili: nessuna modifica rilevata.
- Picco di memoria del processo diagnostico: circa 296–659 MiB nei quattro casi con audio. Il test completo del caso da 14m 37s richiede circa 35 secondi su questo Mac; comprende più analisi e rivalutazioni. Queste misure riguardano il processo CLI, non l’intera app durante una registrazione.

## Evidenze e ripetibilità

Gli esiti selezionati sono elencati in `.build/meeting-voice-tests/20261105-133804/summary.json`. I singoli `checks.json`, i log e le copie sono nella stessa cartella. Per il caso D861843D l’esito finale è `D861-holdout-verified/checks.json`; i tentativi precedenti restano come cronologia diagnostica.

Suite nativa: `.build/checks-0.12.3-native.log`.

Interfaccia: `.build/preview-profile/background-ui-checks.json` e `.build/ui-0.12.3.log`.

Verifica finali degli originali: `.build/meeting-voice-tests/20261105-133804/final-originals-verification.json`.

La CLI offre `check-meeting-voices <meeting.json> <diarizzazione.gguf> <voce.gguf> <profiles.json> <nuova-cartella-test> [--audit]`. Gli artefatti diagnostici contengono dati delle riunioni e restano locali.
