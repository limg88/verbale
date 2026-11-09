#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <memory>
#include <vector>
#include "api/echo_canceller3_config.h"
#include "api/echo_canceller3_factory.h"
#include "audio_processing/audio_buffer.h"

// Stateless bounded windows include context before the owned audio chunk.
// Inputs/outputs: mono Float32 [-1,1], 16 kHz, identical timestamps.
extern "C" int ve_clean(const float* microphone, const float* reference,
                         const uint8_t* covered, float* output, int count) noexcept {
    if (!microphone || !reference || !covered || !output || count <= 0 || count > 60 * 16000) return -1;
    try {
        webrtc::Environment environment;
        webrtc::EchoCanceller3Config config;
        // Use the adaptive linear output: residual suppression can erase a
        // quiet local speaker during double-talk, even with near-end protection.
        config.filter.export_linear_aec_output = true;
        webrtc::EchoCanceller3Factory factory(config);
        auto echo = factory.Create(environment, 16000, 1, 1);
        webrtc::AudioBuffer render(16000, 1, 16000, 1, 16000, 1);
        webrtc::AudioBuffer capture(16000, 1, 16000, 1, 16000, 1);
        webrtc::AudioBuffer linear(16000, 1, 16000, 1, 16000, 1);
        // The pinned AEC3 linear path has a 64-sample block-framing delay.
        // Flush one extra frame and remove it so timestamps and duration stay exact.
        std::vector<float> filtered(count + 160, 0.f);
        std::vector<uint8_t> valid_frames((count + 159) / 160, 1);
        for (int i = 0; i < count; ++i) if (!covered[i]) valid_frames[i / 160] = 0;
        for (int offset = 0; offset < count + 160; offset += 160) {
            const int n = std::min(160, count + 160 - offset);
            for (int i = 0; i < 160; ++i) {
                const float mic = offset+i < count ? microphone[offset+i] : 0;
                const float ref = offset+i < count ? reference[offset+i] : 0;
                if (!std::isfinite(mic) || !std::isfinite(ref)) return -2;
                render.channels()[0][i] = std::clamp(ref, -1.f, 1.f) * 32768.f;
                capture.channels()[0][i] = std::clamp(mic, -1.f, 1.f) * 32768.f;
            }
            echo->AnalyzeRender(&render);
            echo->AnalyzeCapture(&capture);
            echo->ProcessCapture(&capture, &linear, false);
            for (int i = 0; i < n; ++i) {
                const float result = linear.channels_const()[0][i] / 32768.f;
                if (!std::isfinite(result)) return -3;
                filtered[offset+i] = std::clamp(result, -1.f, 1.f);
            }
        }
        for (int i = 0; i < count; ++i) {
            // Missing reference: preserve local speech verbatim, never gate the mic.
            output[i] = valid_frames[i / 160] ? filtered[i + 64] : microphone[i];
        }
        return 0;
    } catch (...) { return -4; }
}
