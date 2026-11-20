# QA 0.15.3 — ripresa trascrizione durante una call Teams

## Caso reale

Riunione «06112025 - Riunione con Costacurta», ID 1A8165E5-2686-4A11-86EB-CF78E81DA08D, iniziata il 6 novembre 2026 alle 11:00:18 Europe/Rome, durata circa 69m49s. Manifest interrotto, modalità afterRecording, zero segmenti e zero blocchi elaborati. Tutti i 1657 file audio dichiarati risultano presenti (838 sistema, 819 microfono), interni o esportati. Il titolo con 2025 è stato rispettato.

L’utente ha chiarito che la call era ancora in corso e la registrazione già terminata; pmset mostrava l’asserzione Microsoft Teams Call in progress. Non si trattava di un errore del backend: resume() restituiva correttamente per dare priorità a Teams, ma aggiornava solo status, visibile nella UI solo durante recording/busy/working. Un busy brevissimo seguito dal return dava l’impressione di un comando senza effetto.

## Correzione

Attesa dedicata, visibile nella trascrizione e nel menu. Quando Stop o Riprendi incontrano Teams attivo (o non verificabile), la sessione resta recuperabile e viene salvata l’intenzione resumeAfterTeams. Un controllo senza inferenze riparte quando il segnale è inattivo, la stessa riunione è selezionata e non ci sono operazioni o editor aperti. Il controllo funziona anche con automazione Teams disattivata. Se viene selezionata un’altra riunione, non cambia il documento dell’utente: la richiesta rimane nel manifest e viene ripristinata riaprendo quella in attesa, anche dopo un riavvio.

Annulla attesa cancella il controllo e la richiesta persistente, senza rimuovere file. Il controllo verifica cancellazione e identità anche dopo il ritorno asincrono del probe; nessuna partenza da risultati tardivi. Scomparsa dell’archivio interrompe il controllo. Errori precedenti vengono azzerati iniziando un nuovo tentativo; l’avviso di pausa viene rimosso al completamento.

## Verifiche

114 gruppi core superati, inclusa compatibilità e persistenza del campo opzionale. Controlli Preview con segnali iniettati: resume con call attiva mostra/persiste l’attesa senza inferenza; segnale sconosciuto non avvia; fine call richiama una sola ripresa; annullamento cancella anche la richiesta sul disco; un probe già in corso non può avviare lavoro dopo annullamento; anche il comando manuale attende su segnale sconosciuto. L’azione costosa di ripresa automatica è sostituita da un contatore nelle prove, senza caricare modelli.

Immagini empty-waiting-1000.png e empty-waiting-1180.png nel profilo Preview: banner, pulsante e messaggio centrato verificati a finestra compatta e normale. Non sono stati eseguiti ASR, rielaborazioni reali o registrazioni durante la call dell’utente. Il manifest originale è rimasto identico allo snapshot privato .build/costacurta-resume-analysis/meeting-original.json; nessuna pubblicazione o modifica alla sua trascrizione.

La verifica prova il controllo della ripresa e la UI, non il completamento dei 1657 blocchi reali, rimandato alla fine della call per rispettare la protezione dei consumi. Build 33, versione 0.15.3. Pacchetto e riepilogo test verificati negli artefatti .build/resume-0.15.3-*.
