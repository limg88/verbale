# Dispositivo automatico della call — Verbale 0.13.1

5 novembre 2026. La selezione riguarda il dispositivo, non l’abilitazione delle sorgenti Microfono/Audio di sistema.

## Comportamento

All’avvio di ciascuna registrazione Verbale legge i dispositivi Core Audio e quelli esposti dai processi Microsoft Teams, inclusi gli helper. Microfono e uscita vengono risolti separatamente. In modalità automatica i dispositivi dei processi con audio attivo hanno priorità; una scelta Teams univoca viene usata anche quando differisce dai predefiniti del Mac. Se Teams non espone una scelta univoca, viene usato il predefinito macOS e il motivo è visibile nelle impostazioni.

La scelta manuale è sempre prioritaria. Viene memorizzata con l’UID del dispositivo, così un diverso ID numerico dopo la riconnessione non cambia la preferenza. Un dispositivo manuale mancante o non utilizzabile nella direzione scelta viene segnalato: non viene sostituito silenziosamente. Le preferenze precedenti basate su ID numerico vengono migrate quando il dispositivo è disponibile; altrimenti restano indicate come selezioni manuali da aggiornare.

In Impostazioni → Avanzate → Dispositivi audio si può scegliere Automatico, Predefinito del Mac o un dispositivo specifico. Le preferenze possono essere configurate durante una registrazione, ma valgono per quella successiva. La registrazione in corso conserva il dispositivo iniziale: questa release non implementa il passaggio a un altro dispositivo durante la call.

Il rilevamento non cambia i dispositivi predefiniti di macOS o le impostazioni di Teams, non avvia registrazioni e non modifica le sorgenti o la modalità di riduzione eco scelte dall’utente. Le letture vengono eseguite fuori dal thread UI, con un’attesa limitata a tre secondi. Quando entrambe le scelte sono manuali o predefinite Mac, non è necessario interrogare i processi Teams.

Il manifest della registrazione conserva nomi e origine della scelta dei dispositivi effettivamente risolti. Non contiene gli UID hardware.

## Verifica

- Controlli di policy: priorità Teams, priorità dei processi attivi, assenza/ambiguità, override manuale e predefinito Mac, UID stabile dopo cambio dell’ID numerico, dispositivo manuale mancante, capacità input/output, migrazione, identificazione degli helper Teams e metadati esportabili.
- Prova Core Audio sul Mac dell’utente: rilevate le **Bose Q35ii** sia come ingresso sia come uscita di Teams. La prova legge solo metadati e non acquisisce campioni audio.
- Controlli UI: etichette del dispositivo rilevato, persistenza della scelta manuale, sorgenti di registrazione invariate, configurazione per la prossima registrazione senza modificare il dispositivo corrente, selezione manuale assente e pulizia di errori precedenti dopo un rilevamento riuscito.
- Il codice di acquisizione, i clock e i processi di avvio/arresto hardware non sono modificati: i dispositivi risolti vengono passati al percorso di selezione esplicita già esistente.

Non è stata avviata una registrazione reale come parte di queste verifiche. Il test hardware copre il rilevamento, mentre l’interfaccia viene verificata con fixture isolate.

## Evidenze

- `.build/checks-0.13.1.log`: regressioni e prova metadata Core Audio.
- `.build/preview-profile/background-ui-checks.json`: esiti UI.
- `.build/preview-profile/audio-routing-settings.png`: impostazioni durante una registrazione simulata, con preferenze modificabili per la successiva.
- CLI di diagnosi in sola lettura: `verbale-cli audio-route-status`.
