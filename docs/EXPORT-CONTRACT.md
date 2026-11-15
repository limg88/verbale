# Contratto di esportazione di Verbale

Octo e gli altri lettori possono usare questo contratto per le cartelle prodotte da `SessionStore.export`. La versione corrente del contratto è **1**.

## Contenuto della cartella

| File obbligatorio | Contenuto |
| --- | --- |
| `meeting.json` | Manifest della riunione e segnale di completamento dell’esportazione. |
| `.verbale-id` | UUID della riunione in UTF-8, identico a `meeting.json.id`, senza apici o ritorno a capo. |
| `transcript.md` | Trascrizione in Markdown, con ancore per segmenti e momenti segnati. |
| `transcript.json` | Array dei segmenti, ordinati per inizio e, a parità di inizio, per sorgente. |
| `notes.md` | Note in UTF-8, anche vuote. |
| `markers.json` | Array dei momenti segnati. |
| `corrections.json` | Array della cronologia delle correzioni. |

Gli array sono presenti anche se vuoti. I documenti Markdown sono in UTF-8. I percorsi degli allegati sono relativi alla cartella esportata.

| File facoltativo | Quando viene esportato |
| --- | --- |
| `report.md` | Quando è disponibile un report. |
| `echo-duplicates.json` | Quando sono presenti duplicati attribuiti all’eco. |
| `transcript-boundaries.json` | Quando sono presenti correzioni ai confini delle finestre di trascrizione. |
| `transcription-refinement.json` | Quando il file della revisione esiste nell’archivio interno. |
| Screenshot (normalmente `screenshots/*.png`) | Per ciascuno screenshot, al percorso indicato da `screenshots[].filename` nel manifest e collegato da `transcript.md`. |
| Blocchi audio originali e ripuliti (normalmente `audio/*.caf`) | Con il salvataggio audio attivo. I percorsi sono in `chunks[].filename` e, se valorizzato, `chunks[].cleanedFilename`. |
| `audio/microfono.wav`, `audio/sistema.wav` | Copie riproducibili facoltative con il salvataggio audio attivo, fuori dallo stato `recording` e per le sorgenti dichiarate con blocchi disponibili. Un errore nella generazione del WAV consente comunque di completare l’export. |

Una riesportazione può lasciare nella cartella file facoltativi delle revisioni precedenti.

## Campi garantiti di `meeting.json`

| Campo | Tipo e significato |
| --- | --- |
| `schemaVersion` | Intero, attualmente `1`. |
| `id` | Stringa UUID, stabile per la stessa riunione. |
| `title` | Stringa con il titolo corrente. |
| `started` | Stringa ISO 8601 in UTC con suffisso `Z` e precisione al secondo, per esempio `2024-01-01T12:34:56Z`. È la codifica `.iso8601` di `JSONCoding`. |
| `timezone` | Stringa con l’identificatore del fuso orario della riunione, per esempio `Europe/Rome`. `started` resta espresso in UTC. |
| `duration` | Numero di secondi, anche frazionario. |
| `state` | Stringa tra `recording`, `interrupted`, `processing`, `complete` e `failed`. |
| `sources` | Array di stringhe con le sorgenti, `microphone` e/o `system`. |
| `exported` | Booleano `true` nel manifest esportato. Indica il completamento della scrittura dell’export anche se la riunione è ancora in corso. |

I lettori possono ignorare i campi aggiuntivi. Ogni modifica alle garanzie documentate richiede di incrementare `schemaVersion` e aggiornare il contratto e i relativi test. I lettori devono verificare di supportare la versione prima di interpretare i file.

## Ancore in `transcript.md`

Ogni segmento è preceduto da `<a id="segment-<uuid>"></a>` e ogni momento segnato da `<a id="marker-<uuid>"></a>`. Si usa l’UUID dell’elemento (campo `id` in `transcript.json` o `markers.json`) in minuscolo e con trattini. I link relativi hanno forma `transcript.md#segment-<uuid>` o `transcript.md#marker-<uuid>`. Finché l’elemento conserva il suo ID, l’ancora resta uguale anche dopo una modifica al testo o al titolo.

## Completamento e riesportazione

Nella cartella di destinazione, Verbale scrive `meeting.json` per ultimo e lo sostituisce atomicamente quando lo riscrive. Alla prima esportazione, un manifest leggibile con `exported: true` segnala che le scritture richieste sono terminate. Se una scrittura richiesta fallisce prima del manifest, il primo export resta senza manifest e una riesportazione può lasciare visibile il manifest precedente insieme a file già aggiornati. Il manifest segnala l’ultima pubblicazione riuscita e la cartella può essere in aggiornamento.

A parità di destinazione, Verbale riutilizza la stessa cartella anche quando cambia il titolo. Una cartella già esistente viene accettata solo se `.verbale-id` corrisponde esattamente all’ID della riunione. Se esiste anche un manifest leggibile con un altro ID, l’export viene rifiutato.

Con `documentsOnly: true`, Verbale riscrive solo i documenti mancanti o con byte diversi, incluso il manifest. Riusa gli allegati già pubblicati se corrispondono a quelli attesi e sono tutti presenti. Altrimenti passa alla copia e verifica degli allegati. Nell’export completo i documenti vengono riscritti anche a contenuto identico. In entrambe le modalità `.verbale-id` viene riscritto. Gli allegati già presenti sono riutilizzati sull’export completo e verificati quando è disponibile la sorgente. Un WAV già lungo quanto previsto viene riutilizzato.
