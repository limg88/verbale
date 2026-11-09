# Revisione desktop — Verbale 0.9.0

## Problemi osservati

La finestra precedente presentava intestazione promozionale, grande riquadro di avvio e preparazione audio prima della trascrizione. Il contenuto era diviso tra scorrimento della pagina e due pannelli interni di altezza fissa. Aprire una riunione conclusa lasciava in evidenza le preferenze della prossima registrazione. Il comando report portava nelle impostazioni, dove erano mescolati configurazione e risultato. Widget e azioni di avvio erano ripetuti; l’archivio dedicava spazio a statistiche ma non offriva ricerca. I testi descrittivi occupavano spazio anche dopo la prima configurazione.

## Scelte applicate

- Due destinazioni quotidiane nella barra laterale: Riunione e Archivio. Recenti per l’accesso rapido; Impostazioni e widget disponibili senza duplicazioni. Gestione modelli raggiungibile dalle impostazioni o dalla preparazione iniziale.
- Nuova riunione: titolo facoltativo, sorgenti, modalità di ascolto, destinazione e spunta audio. Avvio in alto a destra. Nessun livello audio fittizio prima della registrazione.
- Riunione aperta: intestazione con data, durata e sorgenti registrate. Durante la registrazione restano timer, stop, livelli delle sorgenti, marcatori e screenshot. Dopo la chiusura non vengono riproposte le preferenze della prossima acquisizione.
- Tre schede: Trascrizione, Note, Report. Il contenuto usa l’altezza disponibile; nessuno scorrimento esterno alla pagina della riunione. Trascrizione con caratteri più leggibili e opzione per seguire il parlato. Note autosalvate e marcatori raggiungibili senza un pannello laterale permanente.
- Report: modello e generazione nella scheda della riunione, lettura con titoli, elenchi e tabelle, copia del documento e rimandi interni. Un solo avviso visivo quando serve rigenerare. Il collegamento a una fonte seleziona la scheda corretta prima di posizionarsi sul passaggio.
- Archivio: ricerca in titolo, trascrizione e note; righe compatte con data/durata/stato. Rimozione nel menu contestuale, con la conferma e le protezioni già presenti nel coordinatore.
- Impostazioni: Registrazione, Report e Avanzate. Connessione/credenziali e spiegazioni meno frequenti sono espandibili. Modifiche sensibili alla sessione restano bloccate mentre è in corso un lavoro.

## Verifica

Anteprima separata dal profilo utente, con testi e report dimostrativi. Controllati layout a 1180×800 e 1000×680, trascrizione, note, report, archivio, impostazioni e nuova riunione. Verificati i rimandi del report, la persistenza delle correzioni e il reset della scheda quando si apre una nuova riunione. I controlli esistenti della modalità discreta e del widget restano attivi. Nessuna registrazione o chiamata a un modello viene avviata dall’anteprima.

Le immagini sono in `.build/preview-profile/desktop-*.png`; gli esiti in `background-ui-checks.json`. Non è stato eseguito un test di usabilità con utenti o una prova di registrazione live durante questa revisione; non si dichiarano miglioramenti di prestazione o accuratezza audio.
