# Esplorazione della qualità della trascrizione

5 novembre 2026, codice Verbale 0.12.4. Analisi in sola lettura; nessuna modifica all’app o alle registrazioni e nessun invio di audio a servizi remoti. Non è ancora un benchmark comparativo dei modelli.

## Implementazione attuale

- Parakeet TDT 0.6B v3 in GGUF Q8_0, Silero VAD, audio canonico mono a 16 kHz per sorgente.
- File di cattura di circa 5 secondi. La trascrizione considera blocco precedente, corrente e successivo: circa 15 secondi di contesto. L’AEC può ricevere ulteriore contesto precedente, poi ritagliato prima dell’ASR.
- Silero identifica regioni vocali; l’app aggiunge 150 ms per lato e spezza a un massimo di 20 secondi. Pause brevi possono quindi ridurre molto il contesto effettivamente riconosciuto.
- Il bridge usa il decoder predefinito con una sola ipotesi. Il runtime incluso dispone anche di API N-best TDT, non esposte dall’app. Integrare le alternative richiederebbe conservare o ricostruire l’allineamento temporale.
- Il testo di ogni blocco viene ricostruito dalle parole il cui punto medio temporale appartiene a quel blocco. Manca una riconciliazione fra ipotesi ASR adiacenti della stessa sorgente.

## Evidenze locali

Nelle registrazioni 66B6910F, C1BE978F e 2D4D3CAA si trovano rispettivamente 15, 9 e 46 coppie candidate di parole uguali, appartenenti a segmenti diversi della stessa sorgente, con inizio distante meno di 120 ms. Questo criterio individua candidati, non certifica 70 errori: vanno distinti da ripetizioni reali e suddivisioni successive.

Esempio particolarmente indicativo in 66B6910F: «allenarmi» è presente con intervalli 39,666–40,226 e 39,726–40,286 secondi. Il confine di cattura è 40,006 secondi. Il punto medio della prima ipotesi cade prima del confine, quello della seconda sul confine: entrambe possono superare il filtro di proprietà del rispettivo blocco. È coerente con una duplicazione causata dalle due decodifiche sovrapposte. L’audio va controllato prima di considerare certa la diagnosi del singolo caso.

Una parte consistente delle frasi brevi e delle voci nella cronologia proviene dalla separazione degli interlocutori. Le correzioni salvate non costituiscono automaticamente un riferimento umano parola per parola.

Le confidenze per parola sono disponibili, ma numerosi valori sono prossimi a 1. Vanno calibrate contro audio verificato; non rappresentano una probabilità affidabile che la parola sia corretta.

## Interventi candidati, in ordine

1. **Riconciliazione dei confini.** Confrontare parole e tempi nelle finestre adiacenti, sulla stessa sorgente. Risolvere solo sovrapposizioni sufficientemente forti; preservare ripetizioni effettive, pause, interventi diversi e correzioni manuali. Verificare separatamente l’eventuale sovrapposizione introdotta dal padding VAD.
2. **Segmentazione orientata alle frasi.** Provare unione di regioni separate da pause brevi, più contesto e finestre di 20–30 secondi, misurando memoria e latenza. Evitare di trascrivere lunghi silenzi o unire senza controllo cambi di interlocutore.
3. **Secondo passaggio dopo la registrazione.** Conservare l’anteprima rapida e offrire una revisione dall’audio con finestre più ampie. Conservare versione originale, modifiche manuali e possibilità di confrontare le revisioni. La nuova versione deve mantenere o aggiornare esplicitamente timestamp, collegamenti, interlocutori e stato del report.
4. **Glossario della riunione.** Nomi, acronimi, progetti e termini inglesi. Parakeet v3 non espone in questo bridge un prompt lessicale; valutare N-best con riordinamento o un motore con contesto lessicale. Il glossario orienta le ipotesi, non deve sostituire automaticamente termini solo perché simili.
5. **Confronto locale dei motori.** Parakeet attuale contro Whisper large-v3/turbo via MLX e Qwen3-ASR 1.7B. Whisper ha un’implementazione MLX documentata; per Qwen va verificata l’integrazione sul Mac, inclusi timestamp e consumi. Nessun vincitore assunto prima dei test in italiano e nei passaggi misti italiano/inglese. Un confronto Q8/F16 del modello attuale è un ulteriore esperimento, non un miglioramento già dimostrato.
6. **Ritrascrizione mirata.** Segnalare passaggi con confidenza bassa, sovrapposizioni, disaccordo fra finestre o motori e consentire la ritrascrizione selettiva. Evitare di trattare il solo punteggio del modello come giudizio certo.

Un LLM di revisione testuale può migliorare la leggibilità, ma può anche cambiare numeri, negazioni e nomi. Un eventuale intervento va presentato come proposta separata dal trascritto fedele all’audio.

## Esperimento proposto

Preparare 15–20 minuti complessivi di estratti da più riunioni: italiano pulito, termini inglesi/acronimi, nomi propri, parlato sovrapposto, microfono con altoparlanti, passaggi ai confini dei blocchi. Verificare ascoltando una trascrizione di riferimento; tenere una parte separata per la verifica finale.

Confrontare a parità di audio: pipeline attuale; soli confini corretti; nuova segmentazione; secondo passaggio con lo stesso modello; modelli alternativi. Usare WER normalizzato con regole dichiarate, errori su nomi/acronimi/numeri/negazioni, omissioni, duplicazioni, punteggiatura e timestamp. Misurare anche tempo di elaborazione e picco di memoria. I miglioramenti tecnici già verificati nelle release precedenti non costituiscono una misura dell’accuratezza delle parole.

## Fonti primarie consultate

- Modello attuale e lingue supportate: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Alternative di decodifica del runtime: https://github.com/mudler/parakeet.cpp/blob/master/docs/tdt-nbest.md
- Whisper in MLX: https://github.com/ml-explore/mlx-examples/tree/main/whisper
- Prompt, lingua e timestamp di MLX Whisper: https://github.com/ml-explore/mlx-examples/blob/main/whisper/mlx_whisper/transcribe.py
- Qwen3-ASR: https://huggingface.co/Qwen/Qwen3-ASR-1.7B
