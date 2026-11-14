# QA 0.16.1 — navigazione durante la registrazione

## Causa e correzione

navigationLocked includeva isRecording e working, impedendo l’apertura delle altre sessioni. Il codice di acquisizione usava inoltre current per callback, ASR live e stop: togliere il solo blocco avrebbe spostato o perso dati al cambio di selezione.

Aggiunto un documento activeRecording separato da current. Tutti i percorsi di acquisizione, livelli, timer, marcatori globali, screenshot, stop e automazione Teams identificano il proprietario della registrazione. Gli aggiornamenti si riflettono nella selezione soltanto se gli ID coincidono. La sessione live resta disponibile anche dopo Stop fino alla conclusione dell’export e del passaggio alla coda, quindi viene liberata.

Il blocco di navigazione non include più la registrazione o il suo lavoro ASR live; preparazione/finalizzazione ed editor modali conservano i propri blocchi temporanei. Il dettaglio storico mostra i propri timestamp e contenuti, con una barra distinta per titolo/durata/stop della sessione in registrazione. Cestino della sessione live protetto anche se il documento selezionato è diverso. Al termine viene accodata la registrazione effettiva; la selezione non viene reindirizzata. Widget, controlli globali e percorso audio nelle impostazioni usano lo stesso proprietario.

Tornando alla registrazione si usa lo snapshot live più recente; per le altre sessioni il valore aggiornato della lista prevale su un riferimento precedente. Esportazioni storiche e cadenza di esportazione della registrazione restano separate. ReportDocumentView equatable evita di riparsare lo stesso Markdown al solo aggiornamento del timer, mantenendo i rimandi gestiti dal contesto selezionato.

## Verifiche

Fixture Preview senza avviare dispositivi, registrazioni, screenshot interattivi o modelli ASR reali. Due documenti distinti: A in registrazione e B storico con durata, note, testo e report propri. Verificati apertura B, rimandi report→trascrizione, callback sintetico persistito in A, marker globale in A, modifica note B che non altera A, protezione della cancellazione A e ritorno a uno snapshot A aggiornato. Verificato inoltre un risultato ASR live simulato mentre è aperto il report B: testo in A, nessuna modifica al testo di B.

Stop dalla schermata B: CaptureService è inattivo nella fixture, quindi non vengono chiamate operazioni hardware. Sono esercitati recupero journal, salvataggio/export, liberazione del documento live e passaggio della sola A alla coda (hook che registra l’ID senza inferenza). B resta selezionata con le proprie note e report. Il vecchio test dei callback tardivi è stato adeguato al proprietario esplicito usato in produzione.

Ispezionata desktop-recording-browsing.png a 1000×680: report storico con durata di dieci minuti, barra della registrazione distinta a 42 secondi, comando Vai alla registrazione, stop e cestino del verbale storico. Nessuna riunione utente modificata o chiusa. La prova riguarda isolamento dei documenti e controlli UI; il percorso hardware Core Audio non è stato modificato e non è stata effettuata una registrazione reale aggiuntiva.

121 gruppi core e 120 controlli UI superati, zero fallimenti. Firma codesign --verify --deep --strict e checksum DMG hdiutil verify superati.

Versione 0.16.1 build 35. Esiti finali in .build/recording-navigation-*. App dell’utente non riavviata o sostituita.
