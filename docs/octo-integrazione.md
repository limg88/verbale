# Integrazione di Verbale con Octo

Octo può continuare a importare gli export dallo schema `1`. Verbale pubblica il manifest completo per ultimo. La struttura dei file e i tipi dei campi sono descritti nel [contratto di esportazione](EXPORT-CONTRACT.md).

## Evento e link Teams

`TeamsCallProbe` controlla attraverso IOKit se un processo Teams mantiene l’asserzione di alimentazione della chiamata. Restituisce lo stato della chiamata. L’avvio automatico riceve un UUID locale usato per tenere traccia della chiamata rilevata. Verbale non riceve da Teams il link, l’identità dell’evento o l’elenco degli invitati. `calendarEventUID` e `onlineMeetingURL` restano quindi assenti.

Per acquisire i dati da un calendario sincronizzato sul Mac servirebbero EventKit, una motivazione di accesso in `Info.plist` e il consenso dell’utente all’accesso completo agli eventi. L’evento deve poter essere associato alla chiamata in modo univoco e fornire il link Teams. Per l’UID, occorre verificare che l’identificativo esposto dall’account calendario corrisponda all’UID degli inviti letti da Octo. Per una serie ricorrente servono anche l’orario e la data dell’occorrenza. In alternativa servirebbe una fonte autorizzata dei metadati Microsoft che identifichi la chiamata effettiva e il relativo evento. Gli eventuali invitati descrivono l’invito. La loro presenza effettiva richiede una fonte distinta.

## Letture da aggiungere in Octo

1. Per proporre la cartella di export, leggere `destination` in `~/Library/Application Support/Verbale/export.json` e accettare `schemaVersion: 1`. Il ripiego attuale sulle sessioni interne resta disponibile per le vecchie installazioni.
2. Per il collegamento al calendario, leggere `calendarEventUID` e `onlineMeetingURL` nel `summary.json` della riunione o in `meeting.json`. In assenza di questi campi continua a valere il confronto con orari e inviti.
3. Per compilare `_meta.md`, leggere `participants` dal riepilogo o dal manifest, con `email` facoltativa. Se il campo è assente, usare i nomi in `speakers` dal manifest come oggi.
4. Per elencare le riunioni, leggere `summary.json` quando `meeting.json` è presente e ripiegare sul manifest completo per gli export precedenti. Continuare a importare solo `schemaVersion: 1` e `state: "complete"`.
5. Per rilevare aggiornamenti, leggere `exportRevision` ed `exportedAt`. Se `meeting.json` scompare tra il controllo e la lettura, riprovare alla prossima scansione. Per verificare la coerenza durante la copia dei documenti, confermare che il manifest sia ancora disponibile e abbia la stessa revisione al termine della lettura.
