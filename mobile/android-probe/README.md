# Verbale · Prova audio Android 0.1.0

APK diagnostico preparato per verificare le possibilità di acquisizione sul Samsung Galaxy S25 dell’utente. Non è ancora la versione mobile completa di Verbale e non dichiara compatibilità con la registrazione di telefonate, WhatsApp o Teams.

## Installazione e prima prova

Il file pronto è `dist/Verbale-ProvaAudio-0.1.0.apk` nella radice del repository. È un APK di prova firmato con la chiave Android debug locale, package `io.verbale.probe`, Android 10/API 29 o successivo; compilato e targettizzato con API 36.

1. Apri l’APK sul telefono e installalo tramite il flusso Android. Autorizza il microfono e le notifiche quando l’app li richiede.
2. Senza chiamate attive, scegli **Microfono · MIC**, registra una frase, premi **Termina e salva**, quindi **Ascolta / interrompi**. Questo è il controllo di base.
3. Scegli l’etichetta **Telefonata**, **WhatsApp** o **Teams** e il modo di ascolto effettivo: vivavoce, telefono all’orecchio o auricolari.
4. Avvia la prova, passa alla chiamata, pronuncia una frase e fai parlare l’altro partecipante. Torna nell’app e termina. La prova si ferma comunque dopo due minuti.
5. Riascolta e usa **Annota quali voci senti**: mia voce e voce dell’interlocutore hanno risposte separate Sì/No/Non verificato.
6. Ripeti con **Microfono · VOICE_RECOGNITION** e, se utile, **Audio interno · MediaProjection**, mantenendo le condizioni confrontabili. Android chiede una nuova autorizzazione di condivisione per ogni prova di audio interno: l’app non salva immagini o video.

Puoi provare anche l’avvio quando la chiamata è già in corso: l’esito può differire e Android può rifiutare l’avvio o silenziare il registratore. Il pulsante **Termina** nella notifica arresta la prova. Passare a un’altra app lascia la registrazione attiva; rimuovere Verbale dalle attività recenti richiede l’arresto della prova.

## Cosa misuriamo

Le tre modalità sono prove separate, non un mix delle due direzioni di chiamata. Le registrazioni sono PCM mono 16 bit a 16 kHz, in WAV. Per ogni prova `session.json` riporta:

- modello, produttore, versione Android/API e identificativo build quando disponibili;
- etichetta di scenario e modalità di ascolto scelte dall’utente;
- modalità di acquisizione, numero di campioni, durata audio e durata della prova;
- RMS, picco, campioni non nulli e clipping;
- transizioni osservate del modo audio Android;
- campionamenti di `AudioRecordingConfiguration.isClientSilenced()`, se la configurazione è disponibile;
- errori, inizializzazione e ragione dell’arresto;
- risultati dell’ascolto inseriti manualmente, quando compilati.

Il silenziamento viene campionato circa ogni secondo: intervalli più brevi possono non essere osservati. Zero verifiche significa **configurazione non osservata**, non assenza di silenziamento. L’energia audio non distingue voci, rumore, eco o rientro dal vivavoce. La presenza dell’interlocutore va verificata ascoltando. La modalità di ascolto è un’etichetta manuale, non una misura automatica della route.

Le intestazioni WAV vengono aggiornate periodicamente. In caso di chiusura forzata o arresto del processo il file può contenere una parte riproducibile, ma la parte finale e le statistiche non sono garantite; la lista segnala le sessioni rimaste in stato di preparazione/registrazione come interrotte quando nessuna acquisizione è attiva. Le misure del livello sono cumulative sulla prova.

## Limiti verificati nella documentazione

- [Android: condivisione dell’ingresso audio](https://developer.android.com/media/platform/sharing-audio-input): una chiamata mantiene priorità sul microfono; l’accesso all’audio della chiamata richiede privilegi specifici. Questo APK non richiede tali privilegi, root o Accessibilità.
- [Android: AudioPlaybackCapture](https://developer.android.com/media/platform/av-capture): la cattura ordinaria dell’audio riprodotto si applica a `MEDIA`, `GAME` e `UNKNOWN`, con policy compatibile dell’app sorgente. Non costituisce un’API generale per catturare audio `VOICE_COMMUNICATION`.
- [Samsung: registrazione schermo](https://www.samsung.com/us/support/answer/ANS10001616/): Samsung esclude telefonate e chiamate VoIP/video dalla funzione descritta. Non si deve assumere che MediaProjection sia una soluzione alle chiamate.
- [Samsung: registrazione telefonica nativa](https://www.samsung.com/sa_en/support/mobile-devices/how-to-use-the-call-recording-feature-on-your-samsung-galaxy-smartphone/): disponibilità dipendente da regione, modello e One UI. L’APK non abilita o modifica tale funzione.
- [Teams: registrazioni delle riunioni](https://support.microsoft.com/en-gb/teams/meetings/start-stop-and-find-meeting-recordings-in-microsoft-teams): registrazione nativa distinta dall’acquisizione audio locale, con disponibilità regolata da account e policy.

La prova sul Galaxy S25 reale rimane necessaria. Una riuscita sull’emulatore non dimostra compatibilità con una chiamata reale, con auricolari o con il firmware Samsung.

## Dati e condivisione

L’app non dichiara il permesso Internet e non contiene client di rete. Non legge contatti, numero chiamante, registro chiamate o notifiche di altre app. Non rileva automaticamente l’app in chiamata: le etichette sono manuali.

Audio e JSON restano nella directory privata dell’app. Backup e trasferimento dei file sono esclusi nelle regole dichiarate. **Condividi audio e diagnostica…** apre il selettore Android per i soli file della prova selezionata; il provider concede lettura temporanea degli URI, senza scrittura e senza accesso a percorsi arbitrari. L’app destinataria scelta dall’utente può trasferire i file secondo il proprio comportamento.

L’elenco mostra le ultime 20 prove. L’archivio viene rimosso disinstallando l’app o cancellandone i dati nelle impostazioni Android; non viene cancellato automaticamente dopo l’ascolto.

## Build e verifica

Requisiti: JDK 17, SDK Android con piattaforma/build-tools 36.0.0, Gradle 9.8.2 (wrapper incluso), Android Gradle Plugin 9.5.0. Non servono dipendenze applicative dichiarate. Gradle può recuperare le proprie dipendenze di build da Google/Maven Central.

```sh
cd mobile/android-probe
./gradlew :app:assembleDebug :app:lintDebug
sh checks/run.sh
```

Configurare `ANDROID_HOME` o un `local.properties` non versionato con `sdk.dir`. L’APK viene scritto in `app/build/outputs/apk/debug/app-debug.apk`. Il progetto Android è indipendente dal progetto Swift macOS.

Verificati:

- build dell’app e APK dei test, lint senza errori;
- controlli Java su silenzio, RMS/clipping, estremi PCM, intestazioni e checkpoint WAV, prevenzione della sovrascrittura e rifiuto di percorsi/traversal/symlink esterni in condivisione;
- configurazione manifest senza Internet/contatti/registro chiamate e componenti privati;
- installazione e test strumentale su emulatore Android 15/API 35 dedicato, avviato con `-no-window -no-audio`: registrazione dal dispositivo audio virtuale, arresto/finalizzazione, coerenza fra dati WAV e statistiche, provider in sola lettura.

I test su emulatore non acquisiscono il microfono del Mac. L’output del test locale è in `build/emulator-checks.txt`. Il runner `checks/emulator.py` è vincolato al solo AVD `verbale-audio-probe` sul seriale `emulator-5584`; non va eseguito su un telefono reale. Il test strumentale rifiuta dispositivi che non corrispondono al profilo emulatore previsto.

Lint segnala che esiste un SDK successivo al 36: per questo APK diagnostico si mantiene la piattaforma già installata, coerente con il target iniziale S25. Non sono stati verificati Android 10–14 o Android 16 su hardware reale. Le API deprecate per risultati Activity e media projection sono ancora compilabili al target scelto; una versione definitiva potrà migrare al relativo stack di lifecycle.
