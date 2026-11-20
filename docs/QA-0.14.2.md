# QA 0.14.2 — blocco nel consolidamento dopo il report PM

## Causa verificata

L'errore «Il modello produce schede troppo lunghe per consolidarle senza perdere attività» è un errore locale del flusso v4 di Verbale, distinto dagli errori HTTP del gateway. Il report PM aveva reso gli intermedi più ricchi, ma la compattazione continuava a imporre circa 6799 byte per scheda, richiedendo allo stesso tempo di preservare tutte le informazioni. La richiesta di compattazione ripeteva sostanzialmente le istruzioni di consolidamento, senza garantire una contrazione. I checkpoint della riunione segnalata contengono 19 risposte, con intermedi fino a 11683 byte e otto intestazioni in una delle schede più estese. Aumentare il budget di output non risolve quel limite di input; può persino produrre intermedi più estesi.

Nel workspace era già stata preparata nella chat di ottimizzazione una pipeline v5 a record JSON, ma non era stata confezionata nel DMG distribuito. La sua unione locale elimina il collo di bottiglia delle riscritture. Tuttavia conservava un limite sul report finale unico: tutti i record dovevano ancora rientrare in una richiesta. La versione 0.14.2 integra quel lavoro e completa la gestione dei report lunghi.

## Comportamento corretto

- Estrazioni JSON con fatti tipizzati e riferimenti; niente report PM completo in ogni estrazione. Accettato anche un unico delimitatore Markdown attorno a JSON valido.
- Unione locale dei record identici con riferimenti combinati. Date, titolari, negazioni e versioni divergenti non sono fusi per somiglianza e non vengono eliminati.
- Se l'evidenza completa entra nel limite del gateway, un'unica composizione finale. Altrimenti separazione per sezione PM e dimensione effettiva del JSON più istruzioni; ogni record appartiene a una sezione dettagliata. Il modello compone solo il corpo della parte richiesta. Titoli e parti sono assemblati localmente in un unico report, con citazioni risolte alla fine.
- La sola sintesi esecutiva usa una selezione di record interi, bilanciata fra categorie; non sostituisce le sezioni dettagliate e non può dedurre uno stato globale o l'assenza di informazioni dalla selezione. Non si promette una valutazione esaustiva delle priorità da una selezione automatica.
- Nessun requisito di dimezzare le schede e nessuna nuova chiamata LLM di compattazione. Il caso patologico di un singolo record più grande dell'input disponibile resta un errore esplicito; il contenuto non viene tagliato.
- Checkpoint per estrazione, sintesi e parte di sezione. Una richiesta fallita non pubblica un report parziale; alla ripresa le risposte completate vengono riutilizzate.
- Restano i limiti di lavoro della pipeline v5: 48 inferenze, 192000 token di budget richiesto cumulativo, 15 minuti per invocazione, massimo tre tentativi per passaggio e un solo aumento del budget dopo troncamento, fino a 16000 token. Una ripresa riutilizza il lavoro completato; non si promette lavoro illimitato per una singola invocazione.
- OSLog con metadati per fase, tentativo, budget, durata, HTTP, codice e X-Request-Id quando disponibili. Nessun prompt, trascrizione o risposta nei log diagnostici.

## Compatibilità

Versione 0.14.2, build 28, prompt v5-records. Il primo report richiede una nuova estrazione rispetto ai checkpoint v4 di 0.14.0/0.14.1; i vecchi file restano conservati. Non si convertono automaticamente riassunti narrativi non validabili in fatti strutturati. Audio, trascrizione, nomi e report precedenti non sono modificati dall'installazione. Il gateway in uso non è stato modificato né riavviato e il modello selezionato non cambia.

## Prove

- Suite core e integrazione finale: 100 righe PASS, nessun FAIL. Include 13 gruppi della pipeline report, più verifica del gateway locale reale.
- Nuova fixture: 256 record e input massimo 14000 byte; 128 record e input massimo 6000 byte. Fonti lunghe, duplicati fra estrazioni, otto categorie, note, incarichi e riferimenti. L'unione supera la capacità di una singola richiesta finale. Tutte le richieste rispettano il limite; ogni record distinto compare nella sezione dettagliata della fixture e nel report assemblato.
- Interruzione per quota a metà delle sezioni; ripresa senza ripetere estrazioni e parti completate. Un'unica intestazione per la sezione attività, link validi dopo assemblaggio. JSON sia semplice sia delimitato da Markdown.
- Altri test: report breve, troncamenti HTTP/finish_reason, quote, 502/503, deadline, cancellazione, invalidazione dei checkpoint, input Unicode e record individuale sovradimensionato senza tagli silenziosi.
- `python3 scripts/test_gateway.py`: gateway reale su porte temporanee con upstream simulato. Audit finale: 5 richieste locali, crescita budget [6000,16000], una chiamata Groq simulata, nessuna fuga sul redirect. Nessuna chiamata a provider reali o al seat Claude.
- Preview isolata: 92 controlli dell'interfaccia, tutti veri. Confezionamento arm64, versione verificata sul bundle e verifica di firma/DMG prima della consegna.

I test provano dimensionamento, instradamento dei record, persistenza e assemblaggio con un modello simulato. Non provano che Sonnet estragga o riscriva ogni dettaglio correttamente: non sono state effettuate inferenze reali né rigenerata automaticamente la riunione dell'utente.
