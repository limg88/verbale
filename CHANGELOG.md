# In sviluppo — Progetti e registro attività

- Progetti locali e associazione delle riunioni; nuova pagina Da seguire con filtri per progetto, stato, scadenze confermate e responsabili mancanti.
- Proposte strutturate dal report operativo, sottoposte a revisione del PM prima di creare o aggiornare un’attività. Suggerimenti di corrispondenza nello stesso progetto e controllo dei duplicati.
- Registro persistente indipendente dai report, cronologia delle modifiche, fonti con ID stabili e copie del testo citato. Le date relative richiedono conferma e la rigenerazione non sovrascrive il lavoro del PM.
- Compatibilità con le riunioni precedenti; protezione da fonti obsolete, registri corrotti e salvataggi falliti.

# Verbale 0.16.2

- Digitazione delle note isolata dallo stato generale dell’app; salvataggio accorpato dopo 500 ms e completato prima dei lavori sul verbale e dell’uscita. Le bozze restano disponibili dopo navigazione o errore di scrittura, con comando di riprova.
- Correzioni e nomi degli interlocutori aggiornati subito, con persistenza ed export in background. Nessuna rilettura dell’intero archivio dopo una modifica, una rinomina, una rimozione o il completamento di un lavoro.
- Export delle revisioni senza riscrivere i documenti invariati né rileggere il contenuto degli allegati già esportati. Allegati nuovi o mancanti seguono l’export completo con verifica.
- Indice dei riconoscimenti vocali e delle correzioni riutilizzato fra aggiornamenti della stessa trascrizione.

# Verbale 0.16.1

- Navigazione nell’archivio e consultazione di altre riunioni anche durante la registrazione, inclusa la modalità con trascrizione live.
- Documento di registrazione separato dalla selezione: callback audio, salvataggi, timer, livelli, marcatori, screenshot, automazione Teams e stop restano associati alla sessione attiva.
- Barra persistente con titolo, durata e stop mentre si consulta un altro verbale; ritorno alla registrazione dalla barra laterale o dal comando dedicato. Widget e impostazioni mostrano il contesto audio corretto.
- Finalizzazione da qualsiasi schermata senza sostituire o accodare il verbale consultato. Ritorno alla registrazione tramite snapshot aggiornato, evitando di ripristinare dati precedenti ai callback.
- Rendering dei report invariati riutilizzato durante gli aggiornamenti del timer.

# Verbale 0.16.0

- Trascrizioni e report in background, con due code persistenti e navigazione libera tra le altre riunioni. Ogni lavoro usa l’ID della propria sessione; nessuna scrittura nella riunione selezionata per errore.
- Attività con avanzamento, sospensione, attesa Teams, errori e ripresa dopo riavvio. I report legati a una trascrizione in corso aspettano il risultato. Configurazione fissata alla richiesta, token esclusi dal file della coda.
- Conferme vocali immediate nell’interfaccia, salvataggio asincrono e raggruppamento delle esportazioni. Ricerche indicizzate nei passaggi al posto di scansioni ripetute, con protezione delle correzioni manuali conservata.
- Cestino visibile anche nel dettaglio. Le sessioni in lavorazione restano protette fino all’arresto effettivo del worker.
- Checkpoint della trascrizione, conservazione del report precedente, verifica delle fonti prima della pubblicazione e copia della coda in caso di manifest danneggiato.

# Verbale 0.15.3

- Corretto il comando Riprendi apparentemente inattivo durante una call Teams: banner nella trascrizione e indicazione nel menu spiegano l’attesa.
- Ripresa automatica quando Teams risulta inattivo e la riunione è selezionata. Intenzione salvata nel manifest e riattivata riaprendo la riunione, anche dopo un riavvio. Annullamento senza eliminare audio o testo.
- Nessuna inferenza se il segnale Teams non è verificabile; gestite cancellazione e risposte tardive del controllo. Rimossi gli avvisi di pausa obsoleti al completamento.
- Verificato sulla riunione Costacurta che tutti i 1657 blocchi audio sono presenti. Non eseguite inferenze reali durante la chiamata in corso.

# Verbale 0.15.2

- Messaggi della trascrizione vuota centrati orizzontalmente e verticalmente nel pannello: registrazione audio, ascolto, elaborazione e attesa. La lista scorrevole viene creata solo quando sono presenti passaggi.
- Centraggio uniforme anche per report non ancora generato/in elaborazione, archivio vuoto/ricerca senza risultati e profili vocali vuoti; adeguato lo spazio dello stato senza altri casi prioritari nella verifica voci.
- Verifica visiva con dati dimostrativi a 1000×680 e 1180×800; nessun cambiamento alla registrazione o all’elaborazione audio.

# Verbale 0.15.1

- Registrazione con trascrizione al termine come modalità iniziale: nessun modello ASR/VAD caricato e nessuna inferenza o cancellazione eco durante la cattura. Elaborazione in diretta ancora selezionabile nelle impostazioni; preferenza fissata nella singola riunione.
- Esportazioni raggruppate ogni 30 secondi durante la registrazione, mantenendo salvataggio interno e journal di ogni blocco audio; esportazione finale immediata.
- Thread CPU del runtime ASR limitati a due anziché otto. Nessuna modifica al dispositivo scelto, al volume o all’audio inviato da Teams.
- Chiamata Teams attiva durante l’elaborazione differita: lavoro messo in pausa, audio conservato e trascrizione riprendibile dall’archivio. Controllo anche con avvio automatico disattivato.
- Corretto il possibile avvio prematuro dell’elaborazione da un callback tardivo dopo Stop: la finalizzazione recupera prima il journal e carica i modelli prima di trascrivere.
- Verificato il recupero di tutti gli audio quando i modelli non sono disponibili al termine. Interfaccia esplicita sul testo differito e sul salvataggio locale.

# Verbale 0.15.0

- Formato Operativo predefinito, con Esteso selezionabile: estrazione dei contenuti PM, tabelle e sezioni composte localmente e una sola sintesi esecutiva per i report lunghi.
- Campi distinti per responsabile, scadenza, stato, dipendenze e impegno concordato/proposto/incerto. Nessuna deduzione del responsabile dal parlante.
- Blocchi più grandi quando dichiarati dal gateway; suddivisione adattiva in caso di troncamento, input eccessivo o timeout, conservata per la ripresa. I checkpoint estesi precedenti restano disponibili.
- Profilo di ragionamento leggero solo per il report operativo e solo se dichiarato dal gateway; modello selezionato invariato. Diagnostica con modello risolto e conteggio numerico dei token di ragionamento, se forniti.
- Nessuna elaborazione cloud durante la registrazione.

# Verbale 0.14.3

- Riprodotto il blocco sulla riunione reale: troncamenti ripetuti esaurivano il tetto preventivo dell’app prima della fine delle estrazioni. Il budget dei blocchi successivi ora si adatta all’uso effettivo, separatamente per dimensione dell’input; tetto complessivo adeguato a 384000 token richiesti, con limiti di durata e numero richieste invariati.
- Note personali determinate dalla fonte N, senza classificare osservazioni del parlato come appunti dell’utente o promuovere appunti a decisioni.
- Titoli di sezione non duplicati e citazioni ravvicinate raggruppate in intervalli navigabili. Formattazione riapplicabile dai checkpoint senza nuove inferenze.
- Errori con fase/indice, HTTP, codice e X-Request-Id quando disponibili; nessun dettaglio libero o segreto del provider nei messaggi.
- Prova reale completata con lo stesso Haiku e gateway dell’app, report salvato nell’archivio e nell’output, checkpoint v5 riutilizzati. Verificati audio, trascrizione e dati originali invariati.

# Verbale 0.14.2

- Eliminato il consolidamento LLM che chiedeva contemporaneamente di preservare tutte le attività e ridurre le schede sotto metà del limite di input, causando il blocco «schede troppo lunghe». Integrata nel pacchetto la pipeline a record preparata nella chat di ottimizzazione.
- Estratti JSON validati, unione locale dei duplicati esatti con fonti combinate, conservazione di divergenze e correzioni. Accettato anche un singolo blocco JSON delimitato da Markdown.
- Report lunghi composti per sezioni e parti con input limitato: tutti i record vengono assegnati alle sezioni dettagliate, senza imporre che l’intera riunione entri in una richiesta finale. Un solo report Markdown con fonti navigabili.
- Checkpoint per estrazioni e parti del report; ripresa dopo interruzione senza rifare quelle completate. Nuovo schema v5: le vecchie schede v4 restano conservate, ma la prima generazione esegue nuovamente l’estrazione.
- Budget iniziali per fase, un solo aumento per troncamento e limiti complessivi espliciti; avanzamento per fase/sezione e diagnostica locale di soli metadati, inclusi HTTP e X-Request-Id.
- Prove sintetiche con 128/256 record distinti e limiti di input da 6000/14000 byte: conservazione di tutti i record nel flusso dettagliato, interruzione e ripresa a metà report. Nessuna inferenza reale eseguita per questi test.

# Verbale 0.14.1

- Corretto il tetto di 4000 token che interrompeva i report PM lunghi anche con Sonnet. Solo in caso di troncamento confermato, aumento automatico del budget fino a 16000, con massimo quattro tentativi complessivi per richiesta.
- Gestiti sia HTTP 422 `output_limit_exceeded` sia risposte con `finish_reason: length`; mai pubblicato il testo incompleto. Messaggio di errore aggiornato per distinguere la lunghezza della risposta dalla quota.
- Conservati prompt, chiavi dei checkpoint e budget iniziali di 0.14.0: estrazioni e consolidamenti completati vengono riutilizzati, e viene ritentata la composizione fallita.
- Test del collegamento con il gateway reale e upstream locale simulato: risposta troncata a 4000, completata a 8000, tetto di sicurezza, cancellazione e ripresa. Nessun contenuto reale inviato a provider durante le prove.

# Verbale 0.14.0

- Isolati i livelli audio dall’osservazione dell’intera applicazione; aggiornamenti visivi limitati a 10 Hz per sorgente, senza eliminare campioni.
- Evitate le letture SHA-256 ripetute degli audio già esportati e invariati. Cache limitata, invalidata anche da sostituzioni e modifiche con mtime ripristinato.
- Rilascio di ASR/VAD e AEC dopo stop manuale, ripresa o avvio fallito; caricamento dei modelli transazionale per evitare residui su errore parziale.
- Report PM con fatti e avanzamenti, decisioni, tabella attività/responsabili/scadenze/stati/dipendenze/fonti, rischi e problemi, opportunità, domande aperte. Distinzione esplicita di proposte, impegni e note personali.
- Composizione finale anche per call brevi, direttamente dalle fonti con una sola richiesta. Per call lunghe estrazione/consolidamento preservano gli incarichi; checkpoint separati dalla versione precedente.
- Benchmark offline su due ore sintetiche: CPU delle esportazioni ripetute da 2,68 a 0,82 s (-69%); non è una misura del risparmio totale in call.

# Verbale 0.13.1

- Scelta automatica, indipendente per microfono e uscita, del dispositivo audio esposto da Teams all’avvio della registrazione. Ripiego esplicito sui predefiniti del Mac se la scelta non è disponibile o univoca.
- Selezione manuale sempre prioritaria, memorizzata tramite UID stabile. Migrazione delle preferenze precedenti e segnalazione dei dispositivi manuali assenti senza sostituzioni silenziose.
- Impostazioni configurabili per la registrazione successiva anche durante una call; dispositivo attuale fissato e conservato nel manifest. Nessun cambio delle sorgenti da registrare o della modalità eco.
- Inventario dei dispositivi e processi audio letto fuori dal thread UI con attesa limitata. Il rilevamento non avvia registrazioni né modifica i dispositivi di Teams o macOS.

# Verbale 0.13.0

- Riascolto locale con più contesto a fine registrazione: unione di pause brevi, finestre più ampie e proposte separate dal testo attuale.
- Confronto prima/dopo, ascolto dell’audio, selezione delle modifiche e ripristino della revisione precedente. Analisi su passaggi incerti, sull’intera trascrizione o su un singolo intervento.
- Escluse le correzioni testuali manuali e filtrati cambi di sola punteggiatura e tagli di frase dovuti ai confini. Conservati nomi, timestamp dei segmenti, cronologia e collegamenti ai report.
- Accettare una correzione testuale mantiene distinta la provenienza dell’identità vocale: resta possibile confermare o rifiutare separatamente il riconoscimento della persona.
- Revisioni persistenti ed esportabili; protezione da proposte obsolete, cancellazione del riascolto e conservazione dei dati originali. Note e report personali non vengono duplicati nella copia di ripristino.
- Confronto sperimentale offline fra Parakeet, Whisper e Qwen con e senza glossario, su estratti reali e campioni sintetici. I motori alternativi non sono inclusi nel pacchetto dell’app.

# Verbale 0.12.5

- Riconciliazione conservativa delle parole duplicate fra finestre ASR della stessa sorgente: confronto del testo e forte sovrapposizione dei tempi, senza modificare il testo già pubblicato.
- Gestione anche di regioni VAD sovrapposte, proteggendo ripetizioni reali, persone diverse, parole senza allineamento e correzioni manuali. Originali e decisioni salvati in `transcript-boundaries.json` e nel manifest.
- Riepilogo delle parole riconciliate negli avvisi della registrazione. Nessuna modifica automatica delle trascrizioni esistenti.
- Diagnostica su estratti audio per confrontare vecchio e nuovo flusso, verificare la conservazione delle parole rimanenti ed esportare entrambe le versioni senza alterare le sorgenti.

# Verbale 0.12.4

- Elenco Interlocutori raggruppato per nome assegnato: una sola riga anche quando la persona ha più gruppi manuali, automatici o sorgenti audio. I gruppi anonimi e le identità solo proposte restano separati.
- La rinomina dalla riga della persona aggiorna tutti i suoi gruppi attivi nella riunione, preservando identificativi, tempi e cronologia. La correzione del singolo passaggio resta disponibile nell’editor del trascritto.
- Navigazione alla prima occorrenza estesa a tutti i gruppi raccolti nella riga. Verifiche su gruppi misti, navigazione fra sorgenti, export e riunione reale letta senza modificarla.

# Verbale 0.12.3

- Isolati i numeri dei gruppi prodotti da una nuova separazione: un gruppo anonimo non eredita più il nome già confermato su un numero riutilizzato dal modello.
- Una nuova analisi rivaluta anche i nomi assegnati dall’apprendimento progressivo, senza trattarli come conferme manuali e senza annullare rinomine successive.
- Proposte di altre voci obsolete escluse dalla riapertura e rimosse dall’interfaccia dopo modifiche dei nomi o nuova analisi. Le conferme puntuali continuano ad aggiornare la revisione corrente.
- La modifica del nome resta coerente tra finestra e archivio anche se la destinazione di esportazione non è disponibile; l’export può essere ritentato.
- Diagnostica locale `check-meeting-voices` su copie isolate: separazione, riconoscimento, conferma puntuale, ri-analisi, salvataggio, export e, con `--audit`, rivalutazione progressiva e cache. Nessuna modifica agli originali o ai profili.

# Verbale 0.12.2

- Comandi visibili nell’archivio per modificare il titolo e rimuovere una riunione. La copia interna viene spostata nel Cestino, con conferma; i file esportati restano disponibili.
- Titolo modificabile anche dall’intestazione, con salvataggio fuori dal thread UI e aggiornamento dei file di testo senza spostare cartelle o audio.
- Nomi riconosciuti associati automaticamente; proposte incerte evidenziate con un punto interrogativo cliccabile per confermare il singolo passaggio o correggerlo. Le proposte non confermate non diventano nomi certi nei file esportati.
- Riconoscimento automatico attivo come impostazione iniziale; viene rispettata una preferenza già salvata.

# Verbale 0.12.1

- Modifica del nome in una bozza locale, salvata una volta con Invio o Salva. Salvataggio ed export del nome fuori dal thread dell’interfaccia; eliminata la rilettura/hash di un allegato quando sorgente e destinazione sono già lo stesso file.
- I nomi nella trascrizione e nell’elenco Interlocutori sono cliccabili: portano alla prima occorrenza della persona, anche quando lo stesso nome usa identificativi interni diversi.
- L’assenza di audio di sistema prima dell’avvio del meeting è uno stato di attesa e non arresta più la registrazione dopo 12 secondi. Resta il controllo del microfono mancante.
- Avvio e arresto hardware isolati dal thread UI, con attesa massima e ripristino serializzato delle operazioni ritardate. Un driver bloccato non richiede di bloccare la finestra né permette di avviare una seconda cattura sopra la prima.

# Verbale 0.12.0

- Ogni assegnazione confermata nella revisione salva il nome e avvia la rivalutazione locale degli altri passaggi. Anche le correzioni puntuali del parlante possono diventare riferimenti.
- Conferme manuali e predizioni automatiche hanno provenienza distinta. Le predizioni non diventano esempi; le correzioni manuali prevalgono e rivalutano gli automatismi precedenti.
- Classificazione per estratti: non viene attribuito il nome a tutto un vecchio gruppo soltanto perché un campione corrisponde. Gli interventi lunghi richiedono concordanza delle finestre; i tratti troppo brevi o ambigui restano incerti.
- Cache privata dei vettori per riutilizzare l’audio già analizzato. Modello e sorgenti audio vincolano la cache; vettori esclusi da trascrizione, proposte esportabili e gateway.
- Stato di avanzamento, annullamento, riepilogo di assegnazioni e incertezze; le conferme rimangono salvate se la rivalutazione fallisce o viene annullata.

# Verbale 0.11.1

- Revisione rapida per persona: massimo cinque controlli distinti alla volta, fino a tre estratti per controllo, inclusi confronti con un riferimento dove disponibile.
- Priorità a incongruenze nei nomi, passaggi senza nome e varianti consistenti dello stesso nome; i frammenti brevi o privi di campioni restano nell’analisi completa.
- È possibile mettere da parte un controllo senza cambiare la trascrizione. La scelta è ricordata e lo stesso nome non viene riproposto in ogni lotto.
- La correzione dettagliata si apre solo su richiesta. Tutti i gruppi originali restano disponibili nell’analisi completa, senza approvazioni o fusioni automatiche.

# Verbale 0.11.0

- Ricerca sperimentale di altre voci su finestre di 90 secondi con 15 secondi di contesto: i numeri locali vengono collegati tramite embedding, con gruppi globali oltre il limite di otto.
- Analisi privata separata dalla riunione: non modifica testo, nomi, report o correzioni durante la ricerca. Nessun embedding viene scritto nelle proposte.
- Revisione con campioni audio, nomi precedenti e selezione esplicita dei passaggi. Solo le conferme cambiano i nomi; le assegnazioni precedenti restano nella cronologia e il report viene segnato da rigenerare.
- Risultati ambigui conservati in gruppi separati, avvisi per interventi brevi e finestre sature; nessuna promessa che il numero dei gruppi equivalga al numero di persone.
- Verifica degli input prima dell’applicazione: modifiche esterne alla trascrizione o ai nomi richiedono una nuova analisi. Supporto CLI per produrre proposte senza scrivere la sessione originale.

# Verbale 0.10.3

- Indicatore per ogni campione basato su volume, pause, durata e saturazione: distingue i segnali consigliati da quelli da verificare e segnala l’audio non utilizzabile prima del salvataggio. Non certifica identità, assenza di rumore o sovrapposizioni.
- La variabilità degli embedding non blocca più il salvataggio esplicito di campioni confermati dalla persona che li ascolta, né l’aggiunta a un profilo esistente.
- Profili con campioni variabili segnalati nelle impostazioni: possono produrre proposte da confermare, senza assegnazione automatica del nome. Invariati verifica del modello, controlli sui file, campioni distinti e vettori validi.
- Errori di campionamento identificano il timestamp del passaggio interessato; un centro vettoriale nullo non interrompe il confronto degli altri profili.

# Verbale 0.10.2

- La selezione dei campioni vocali si ferma a sei: le caselle già selezionate restano modificabili, con contatore e spiegazione del requisito mancante per salvare. I passaggi già ascoltati indicano Riascolta.
- Salvare un profilo assegna anche il nome ai passaggi dell’interlocutore corrente e aggiorna la trascrizione esportata; se il passaggio non ha ancora un interlocutore distinto, viene nominato solo quello selezionato.
- Nuovo comando Assegna nome da profilo nel menu dei passaggi: permette di applicare un profilo già esistente senza salvare di nuovo campioni o rianalizzare l’audio.

# Verbale 0.10.1

- Corretto l’aumento dell’altezza minima della finestra aprendo Interlocutori in una registrazione esistente. L’elenco ha ora un’altezza limitata e scorre internamente, anche con molti parlanti.
- Limitata anche l’altezza dell’elenco delle corrispondenze vocali per conservare lo spazio della trascrizione e la possibilità di ridimensionare la finestra.

# Verbale 0.10.0

- Profili vocali locali, creati esplicitamente ascoltando da due a sei campioni distinti; aggiunta di campioni a un profilo esistente, rinomina, disattivazione ed eliminazione.
- Riconoscimento facoltativo al termine delle registrazioni o su richiesta: più campioni concordi per i nomi automatici, proposte da confermare nei casi dubbi, nessuna assegnazione forzata delle voci sconosciute.
- Correzioni manuali, conferme e rifiuti conservati durante le analisi successive; report invalidati quando cambiano i nomi.
- Modello WeSpeaker da 26,5 MB, separato e verificato tramite SHA-256. Gli embedding sono legati al modello esatto e non vengono esportati né inviati al gateway.
- Diarizzazione a blocchi su entrambe le sorgenti, senza il limite di 30 minuti o il caricamento dell’intera chiamata in memoria. Il microfono usa la traccia con eco ridotto quando prevista; i tratti sovrapposti restano anonimi.
- Vista Impostazioni → Voci, creazione dal menu dei passaggi e verifica delle associazioni nella trascrizione. Analisi annullabile, con trascrizione conservata.

# Verbale 0.9.0

- Desktop semplificato intorno a Riunione e Archivio, con recenti e un solo accesso al widget. Modelli e opzioni meno frequenti sono nelle impostazioni.
- Preparazione compatta, azione Avvia/Termina sempre nell’intestazione, scelta esplicita di sorgenti e salvataggio audio. Le riunioni concluse non ripropongono i controlli di acquisizione.
- Schede Trascrizione, Note e Report a tutta altezza; generazione, scelta del modello e copia del report direttamente nella riunione. Link alle fonti instradati alla scheda corrispondente.
- Report leggibili con titoli, elenchi e tabelle native; avviso di rigenerazione senza duplicazioni.
- Archivio con ricerca in titoli, testo e note, righe compatte e rimozione nel menu contestuale.
- Impostazioni divise in Registrazione, Report e Avanzate; connessione e credenziali del gateway espandibili.
- Finestra minima ridotta a 1000×680, caratteri più leggibili e nessuno scorrimento esterno della riunione. Verifiche con dati dimostrativi e stato di registrazione simulato, senza acquisizione audio.

# Verbale 0.8.0

- Report unificati esclusivamente tramite llm-api: rimosse le modalità dirette Groq/API compatibile e Claude abbonamento, insieme al relativo client Claude interno.
- Claude, Codex, Groq e modelli locali si selezionano nello stesso elenco di alias. URL, token e verifica del gateway restano invariati.
- Suddivisione del testo basata sul budget pubblicato dal gateway, compreso il limite ridotto per Groq. Quota temporanea distinta da quota giornaliera e credenziale provider distinta dal token locale.
- Groq viene gestito nel gateway separato, con GPT-OSS 20B/120B, reasoning low, budget output, attese da header e supporto Portachiavi macOS per la credenziale già configurata.

# Verbale 0.7.0

- Nuovo servizio report **Gateway locale · llm-api**: URL e cartella dedicati, import del token privato, voce Portachiavi distinta da Groq, verifica connessione e selezione degli alias pubblicati dal gateway.
- Avvio manuale del gateway nel Terminale tramite `start-verbale.command`; il servizio resta indipendente e condivisibile con altre app, con arresto tramite Ctrl-C.
- Contratto allineato al gateway: nessuna temperature per i backend CLI, timeout client 330 secondi, URL solo loopback, redirect bloccati, verifica di stato e modello prima di trasmettere la riunione.
- Errori dedicati a token, login backend, quota e concorrenza; tentativo limitato con budget maggiore per output rifiutato come incompleto. Checkpoint separati dai servizi diretti.
- Test con il gateway reale e modello locale fittizio: report/citazioni, ripresa, autenticazione, quota, troncamenti, redirect e cancellazione. Nessun account o registrazione utilizzato.

# Verbale 0.6.0

- Nuovo servizio report **Claude — abbonamento**, tramite il client ufficiale Claude Code (`claude -p`). Scelta Sonnet, Haiku o Opus, rilevamento del comando e verifica del login dalle Impostazioni.
- Autenticazione verificata prima di inviare la trascrizione: la modalità abbonamento rifiuta login API o backend alternativi e non utilizza la chiave API configurata per Groq.
- Prompt via standard input, strumenti e MCP disabilitati, directory temporanea privata e sessioni del client non persistenti. Sospensione interrompe anche il processo locale.
- Report Claude integrati con citazioni verificabili, avanzamento, checkpoint e ripresa; errori di quota e autenticazione con indicazioni operative.

# Verbale 0.5.2

- Report lunghi: parti limitate per byte UTF-8, sintesi gerarchica con dimensioni controllate e reasoning ridotto per i modelli Groq GPT-OSS.
- Limiti del servizio: classificazione degli errori, attese da Retry-After e header quota, tentativi limitati per errori temporanei. Quote giornaliere e richieste troppo grandi interrompono subito il lavoro con indicazioni utili.
- Parti del report salvate localmente: ripresa dopo errore, sospensione o riavvio, con invalidazione quando cambiano fonti, modello o endpoint. Chiavi API escluse dai checkpoint.
- Stato di avanzamento e pulsante Sospendi; risposte troncate dal modello non vengono pubblicate come report completi.

# Verbale 0.5.1

- 37 controlli automatici e regressioni superati, comprese copie della registrazione reale; collaudo Preview senza acquisizioni audio.

- Preparazione di entrambe le sorgenti prima dell’epoca comune e avvio del sistema prima del microfono, eliminando la preparazione del tap mentre il microfono è già in registrazione.
- Convertitore PCM continuo: frame richiesti rispettati, output completamente scaricato, coda finalizzata allo stop e rifiuto dei cambi formato non gestibili.
- Timeline dei blocchi basata sui campioni effettivamente salvati, senza riancoraggio al tempo della callback dopo ogni flush. Marcatore `captureTimelineVersion: 2` nei nuovi manifest.
- Riparazione conservativa dei riferimenti legacy anche all’apertura dell’archivio, con esportazione dell’audit aggiornato e conservazione degli ID precedenti.
- Diarizzazione con ID del primo gruppo conservato e rimappatura uno-a-molti dei riferimenti dell’audit eco; riparazione legacy verificabile con vecchi ID conservati e stato esplicito dei collegamenti ricostruiti/non risolti.
- Test del parlato sovrapposto con voce locale debole; filtro lineare conservativo confermato per evitare soppressione della voce.
- Regressioni su flussi 48 kHz, 44,1 kHz, stereo interleaved, pacchetti irregolari, forma d’onda, durata, code finali e riferimenti dopo separazioni ripetute.
- Confronto su copie dei dati reali: ricostruire la continuità migliora la riduzione del rientro senza cambiare aggressività del filtro. Nessun audio originale sovrascritto; nuova acquisizione hardware da collaudare sul Mac.

# Verbale 0.5.0

- Modalità Altoparlanti con riduzione dell’eco da audio di sistema, mantenendo entrambe le sorgenti attive; modalità Cuffie/acquisizione diretta e preferenza persistente fissata nella sessione.
- WebRTC AEC3 fissato alla revisione `2cec2f52e26646f93bd2d5498bbabf59cba18da9`, filtro adattivo lineare per preservare la voce locale nelle sovrapposizioni.
- Elaborazione delle finestre audio prima dell’ASR, fuori dal thread UI, senza cambiare instradamento o riproduzione Teams; compensazione del ritardo del filtro e durata invariata.
- Originali conservati; con Salva audio sono esportati anche i blocchi ripuliti con riferimenti nel manifest. Compatibilità con manifest e journal precedenti.
- Riferimento mancante: passthrough del microfono e segnalazione nella sessione; dati corrotti: errore recuperabile, senza fingere una pulizia riuscita.
- Riconciliazione conservativa dei duplicati testuali fra sorgenti con almeno 5 parole coincidenti e tempi compatibili; copie originali e riferimenti di provenienza in `echo-duplicates.json`.
- Comando CLI `clean-echo` per due file sincronizzati, senza sovrascrivere l’output.
- 29 controlli superati includendo la fixture di parlato sintetico con ASR reale: 17 parole di rientro escluse, tutte le 31 parole locali riconosciute conservate; tre parole residue brevi mantenute per prudenza.
- Controlli sintetici di attenuazione dell’eco, due sorgenti simultanee, preservazione della voce locale, durata/timestamp, riferimenti assenti, input non validi e conservazione/esportazione delle tracce. Prova acustica reale ancora necessaria.

# Verbale 0.4.0

- Marcatori Punto importante, Decisione e Azione durante la registrazione, disponibili nella riunione, nel widget con contatore e nella barra dei menu; rimozione e salvataggio nei file esportati.
- Report basati su trascrizione, note personali e marcatori, con tipi di fonte distinti e rimandi ai segmenti originali. Input lunghi suddivisi mantenendo l’identità delle fonti; riferimenti sconosciuti segnalati.
- Correzione manuale del testo e assegnazione dei parlanti per segmento, con cronologia delle modifiche e conservazione dei dati precedenti. Le sessioni archiviate senza questi nuovi campi restano leggibili.
- Report precedenti contrassegnati come da rigenerare dopo modifiche; blocco della diarizzazione dopo correzioni per evitare sovrascritture.
- Export `markers.json`, `corrections.json` e ancore stabili nella trascrizione Markdown.
- 19 controlli automatici, compresa generazione report con trasporto simulato senza contattare servizi esterni.

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
