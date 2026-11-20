# Port Windows — stato e piano

Decisione del 2026-11-14: mantenere il core Swift e renderlo portabile; interfaccia e cattura audio native per Windows. Questo documento descrive cosa è già stato preparato e cosa resta. **Oggi Verbale gira solo su macOS 14.2+ Apple Silicon**: nulla di quanto segue è stato compilato o eseguito su Windows o Linux.

## Già fatto (verificato solo su macOS)

- `URLSession`: i sei file del core che lo usano importano `FoundationNetworking` quando esiste.
- Nomi delle librerie native per piattaforma in `Sources/VerbaleCore/NativeLibrary.swift` (`.dylib`, `.so`, `.dll`).
- `native/echo/CMakeLists.txt` collega CoreFoundation solo su Apple.
- `CoreLog` usa OSLog dove disponibile, altrimenti stderr.
- `.gitattributes` mantiene LF; il nome della cartella di export è ASCII e indipendente dal locale; `meeting.json` esportato non contiene più il percorso assoluto del Mac.

## Mappa del core (`Sources/VerbaleCore`, 45 file)

| Gruppo | File | Lavoro per il port |
|---|---|---|
| Solo Foundation | 28 | Dovrebbero compilare così come sono; da verificare con una toolchain Swift per Linux |
| CryptoKit (SHA-256) | 5 — `Models`, `ProjectReport`, `SpeakerAudit`, `SpeakerLearning`, `TranscriptRefinement` | Serve `swift-crypto` (dipendenza nuova) oppure un SHA-256 proprio dietro un'unica funzione `Hashing.sha256` |
| Shim C | 2 — `EchoCancellation`, `SpeakerWindowAnalysis` | Gli shim usano `dlfcn.h` e `pthread.h`: su Windows servono `LoadLibrary` e `SRWLOCK` |
| Legati ad Apple | 10 — `Capture`, `AudioRouting`, `StreamingAudioConverter`, `Transcription`, `VoiceAnalysis`, `TeamsAutomation`, `Reports` (Portachiavi), `ReportPipeline` (OSLog), `ProjectTracking` (`rename`), `ArtifactVerification` (`fstatat`) | Vedi i passi sotto |

Attenzione agli accoppiamenti: file "solo Foundation" come `MeetingWorkProcessor` e `SessionStore` usano tipi dei file legati ad Apple (`AudioFiles`, `TranscriptionEngine`, `ArtifactVerification`). Finché questi non stanno dietro protocolli, il modulo non compila fuori da macOS.

## Passi, in ordine

1. **CI Linux sul core** — spezzare `VerbaleCore` in `VerbaleDomain` (modelli, store, report, coda: nessun framework Apple) e `VerbaleApple` (audio, portachiavi, Teams). Job Linux che compila e testa solo il primo. È il passo che rende misurabile tutto il resto. Stima: M.
2. **Astrazioni di piattaforma** — protocolli per lettura/scrittura audio (`AudioFiles`), archivio segreti (`Keychain`), rilevamento chiamata (`TeamsCallProbe`), cestino (`trashItem`), hashing. Stima: M.
3. **Runtime nativi su Windows** — compilare `parakeet.cpp` (CPU o Vulkan al posto di Metal) e `webrtc-aec3` con MSVC o clang-cl; riscrivere i due shim per `LoadLibrary`. Lo script di patch di ggml richiede bash: su Windows va eseguito con Git Bash o portato in Python. Stima: L.
4. **Cattura audio Windows** — microfono e loopback di sistema con WASAPI; equivalente del process tap di Core Audio. Rilevamento chiamata Teams senza le asserzioni energetiche di macOS (da progettare: sessioni audio attive del processo Teams). Stima: L.
5. **Interfaccia Windows** — nessuna riga di SwiftUI/AppKit è riusabile (29 file, ~4.500 righe). Opzioni: WinUI 3 in C# sopra il core esposto come libreria C, oppure una UI cross-platform. Scelta da fare prima di iniziare. Stima: XL.
6. **Distribuzione** — installer firmato, archivio credenziali di Windows, percorsi dati in `%APPDATA%`. Stima: M.

## Formato audio dell'export

L'audio viene salvato in blocchi da 5 secondi (`audio/<sorgente>_<uuid>.caf`), e la cartella esportata è anche la sorgente da cui l'app rilegge l'audio quando la copia interna è stata eliminata: i blocchi restano quindi in formato `.caf`. A registrazione conclusa l'export aggiunge un file riproducibile ovunque per ogni sorgente, `audio/microfono.wav` e `audio/sistema.wav` (PCM 16 bit, 16 kHz, mono), con i buchi resi come silenzio. Lo spazio occupato dall'audio esportato cresce di circa 115 MB per ora e per sorgente.
