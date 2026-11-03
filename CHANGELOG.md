# Verbale 0.3.0

## Teams desktop

- Opzione persistente per registrare automaticamente tutte le chiamate Teams desktop, disattivata di default.
- Rilevamento locale dell’asserzione energetica di chiamata, verificata tramite bundle ID Teams; nessun accesso a log, conversazioni, Graph o Accessibilità.
- Conferma iniziale di 2 secondi, arresto dopo 20 secondi senza segnale e tolleranza alle riconnessioni.
- Nessun riavvio automatico nella stessa chiamata dopo arresto manuale o avvio fallito; nessun arresto delle registrazioni manuali alla fine di Teams.
- Attesa della finalizzazione precedente prima di un nuovo avvio; annullamento se la chiamata finisce durante la preparazione.
- Rilascio dei modelli dalla memoria dopo la finalizzazione automatica.
- Diagnostica in sola lettura tramite `verbale-cli teams-status`.

## Modalità nella barra dei menu

- Icona neutra a livelli, piena durante la registrazione; menu con stato, durata, errori e arresto.
- Avvio senza dashboard o widget quando l’automazione è abilitata; nessuna icona nel Dock in modalità discreta.
- Riapertura delle finestre solo su richiesta esplicita dal menu; gli eventi di riattivazione non interrompono la modalità discreta.
- Sorgenti e dispositivi audio ricordati tra gli avvii.
- Nessuna garanzia di invisibilità durante la condivisione dell’intero schermo: barra dei menu e indicatori macOS possono essere catturati.

## Collaudo e limiti

- 14 controlli automatici: persistenza/audio e stati Teams (conferma, riconnessione, chiamate consecutive, segnale indisponibile, duplicati, identità del processo).
- Controlli UI integrati nel solo bundle Preview: dashboard, widget, assenza di finestre e Dock, riapertura esplicita e nessuna acquisizione audio.
- Il segnale osservato con Teams aperto senza chiamate è inattivo. La rilevazione positiva, le chiamate reali in muto e la condivisione Teams devono ancora essere convalidate sul client installato.
- L’asserzione Teams non è un’API Microsoft stabile: la funzione è sperimentale. Verbale deve essere già aperto; nessuna registrazione automatica al login.

# Verbale 0.2.0

## Audio

- Salvataggio dell'audio nella cartella di destinazione attivo di default, anche sulle installazioni precedenti senza una preferenza esplicita.
- Spunta disponibile in Riunione, Impostazioni e widget; la scelta viene conservata tra gli avvii.
- La politica è fissata all'avvio della sessione: i controlli sono bloccati durante registrazione/finalizzazione.
- Etichetta “Microfono” per la sorgente locale, senza attribuzione automatica alla persona “Tu”.

## Interfaccia

- Dashboard con nuova gerarchia visiva, sfumature, pannelli e stati.
- Controlli separati per microfono e audio di sistema con livelli effettivi.
- Archivio con durata, stato e indicazione dell'audio conservato.
- Pagine Modelli e Impostazioni ridisegnate.

## Widget

- Pannello flottante compatto e spostabile, accessibile dalla dashboard, dalla barra dei menu e con ⇧⌘M.
- Avvio/arresto della stessa sessione della finestra principale, timer, livelli, opzione audio e screenshot.
- Puntina per il primo piano; chiusura indipendente dalla registrazione.
- Riapertura della finestra principale anche dopo averla chiusa.

## Verifiche

- Nove controlli automatici superati, inclusi conservazione dell'audio esportato dopo la pulizia e opt-out audio.
- Controllo visivo della dashboard, delle impostazioni e del widget.
- Verificati default audio attivo, spunta disattivabile, persistenza dopo riavvio e sincronizzazione finestra/widget.
- Verificati puntina e riapertura della finestra principale dal widget.
- Collaudo UI con bundle ID e directory dati separati da quelli dell'app utente; nessuna registrazione reale avviata.

Il pacchetto usa una firma locale ad-hoc, senza notarizzazione Apple.
