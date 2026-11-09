# Third-party components and model attribution

Verbale uses parakeet.cpp by its authors (including Ettore Di Giacinto and Richard Palethorpe), MIT, at the revision recorded in `runtime-lock.json`.
Source: https://github.com/mudler/parakeet.cpp

The runtime incorporates ggml under MIT and dr_wav by David Reid under its included dual public-domain/MIT terms. License texts are included in the app's `Contents/Resources/Licenses` directory. Apple frameworks remain supplied by macOS.

Model weights are separate downloads, not part of the executable or DMG:

| Component | Original source | Stated license |
|---|---|---|
| Parakeet TDT 0.6B v3 | NVIDIA, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 | CC BY 4.0, https://creativecommons.org/licenses/by/4.0/ |
| Silero VAD | Silero Team, https://github.com/snakers4/silero-vad | MIT, https://github.com/snakers4/silero-vad/blob/master/LICENSE |
| WeSpeaker ResNet34 (VoxCeleb, 256 dimensions) | WeSpeaker authors, https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM | CC BY 4.0, https://creativecommons.org/licenses/by/4.0/ |
| Nemotron-3-Diarization | NVIDIA, https://huggingface.co/nvidia/Nemotron-3-Diarization | OpenMDW 1.1, https://openmdw.ai/license/1-1/ |

The files selected by Verbale are GGUF conversions published by the parakeet.cpp project at https://huggingface.co/mudler/parakeet-cpp-gguf . ASR and diarization are quantized Q8_0; VAD is F16. These are converted/quantized copies of the models, not models trained by Verbale. Exact filenames, revisions, sizes and SHA-256 values are in the bundled models.json. No model endorsement of Verbale is implied.

The SDK/runtime license does not replace the model licenses. Preserve original attributions and conversion notes when redistributing the weights.


Echo reduction uses a standalone extraction of WebRTC AEC3 by Enaium, revision `2cec2f52e26646f93bd2d5498bbabf59cba18da9`, from https://github.com/Enaium/webrtc-aec3 . WebRTC project authors, BSD 3-Clause. The extraction and its simplified platform/Abseil shims remain in the pinned upstream submodule; Verbale adds a separate C ABI adapter and links Apple's CoreFoundation. The OOURA FFT copyright/permission notice is included as `WebRTC-OOURA-NOTICE.txt`. The upstream license and WebRTC additional patent grant are bundled as `WebRTC-BSD-3-Clause.txt` and `WebRTC-PATENTS.txt`. Patent grant source: https://webrtc.googlesource.com/src/+/refs/heads/main/PATENTS . The AEC runtime revision and format are recorded in `echo-runtime-lock.json`. No endorsement by Google, WebRTC or the extraction author is implied.

Local voice profiles use voice-detect.cpp by Ettore Di Giacinto and its contributors, MIT, nested revision `bca46bcbc2fe68169c2d7c414e9b290a7cb89911` of https://github.com/localai-org/voice-detect.cpp . The runtime shares the pinned ggml backend. The MIT text is bundled as `voice-detect-MIT.txt`.

The separate WeSpeaker download is the GGUF conversion `wespeaker-resnet34-voxceleb.gguf` published by Ettore Di Giacinto (mudler) at https://huggingface.co/mudler/voice-detect-gguf , revision `a45a8e5ef6b267eb903bc5b95efa1c5257fa005b`. It is a converted WeSpeaker model, not trained by Verbale; its original model card and CC BY 4.0 attribution are linked above. The conversion and original authors do not endorse Verbale. Model identity, size and SHA-256 are pinned in the catalogue. Code and weights have separate licenses.
