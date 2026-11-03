# Third-party components and model attribution

Verbale uses parakeet.cpp by its authors (including Ettore Di Giacinto and Richard Palethorpe), MIT, at the revision recorded in `runtime-lock.json`.
Source: https://github.com/mudler/parakeet.cpp

The runtime incorporates ggml under MIT and dr_wav by David Reid under its included dual public-domain/MIT terms. License texts are included in the app's `Contents/Resources/Licenses` directory. Apple frameworks remain supplied by macOS.

Model weights are separate downloads, not part of the executable or DMG:

| Component | Original source | Stated license |
|---|---|---|
| Parakeet TDT 0.6B v3 | NVIDIA, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 | CC BY 4.0, https://creativecommons.org/licenses/by/4.0/ |
| Silero VAD | Silero Team, https://github.com/snakers4/silero-vad | MIT, https://github.com/snakers4/silero-vad/blob/master/LICENSE |
| Nemotron-3-Diarization | NVIDIA, https://huggingface.co/nvidia/Nemotron-3-Diarization | OpenMDW 1.1, https://openmdw.ai/license/1-1/ |

The files selected by Verbale are GGUF conversions published by the parakeet.cpp project at https://huggingface.co/mudler/parakeet-cpp-gguf . ASR and diarization are quantized Q8_0; VAD is F16. These are converted/quantized copies of the models, not models trained by Verbale. Exact filenames, revisions, sizes and SHA-256 values are in the bundled models.json. No model endorsement of Verbale is implied.

The SDK/runtime license does not replace the model licenses. Preserve original attributions and conversion notes when redistributing the weights.
