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
