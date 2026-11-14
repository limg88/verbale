# QA 0.15.2 — centraggio e disposizione, 6 novembre 2026

Il messaggio «Audio in registrazione» era figlio della LazyVStack della trascrizione, dentro una ScrollView verticale. La vista vuota riceveva la dimensione del proprio contenuto e l’allineamento leading della lista: non disponeva dell’intero pannello come area di centraggio.

Lo stato vuoto è ora un ramo alternativo alla lista, con frame che riempie il pannello e contenuto centrato. La lista e i suoi handler di navigazione alle fonti/seguimento restano nel ramo con segmenti, con la stessa implementazione. La selezione dell’ultimo segmento continua a essere gestita quando la lista compare.

Uniformati anche i frame degli stati senza report, senza riunioni/risultati e senza casi prioritari nella verifica voci. I profili vocali vuoti sono centrati nella larghezza del contenitore e hanno spaziatura verticale, senza richiedere altezza infinita all’interno dello scroll delle impostazioni.

Build Preview isolata e 96 controlli UI esistenti superati. Aggiunte solo fixture visive: otto stati (registrazione differita, ascolto live, elaborazione, interruzione, report vuoto, report in generazione, archivio vuoto, profili vuoti), renderizzati a 1000×680 e 1180×800. Nessun accesso a hardware, acquisizione o backend di report durante queste fixture. Immagini .build/preview-profile/empty-*.png. Ispezionati entrambi i formati della registrazione e gli stati compatti di ascolto, elaborazione, report, archivio e profili. Controllati inoltre note, nuova riunione e verifica altre voci: nessun ulteriore disallineamento evidente nei render esaminati.

La nuova versione è 0.15.2 build 32. Build release, firma locale verificata con codesign --verify --deep --strict e checksum DMG verificato con hdiutil verify. Nessuna sessione utente modificata o arrestata e nessun riavvio dell’app attuale. Le fixture non costituiscono una prova di tutte le combinazioni di dimensione, lingua o testo dell’interfaccia.
