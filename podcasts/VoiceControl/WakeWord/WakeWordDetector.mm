#include "WakeWordDetector.h"
#include <onnxruntime_cxx_api.h>
#include <cstring>
#include <algorithm>
#include <cstdio>
#import <Foundation/Foundation.h>

// --- Pipeline constants (matching Android WakeWordJni.cpp) ---
static constexpr int kSampleRateHz       = 16000;
static constexpr int kMelBins            = 32;
static constexpr int kEmbeddingDim       = 96;
static constexpr int kMaxEmbeddings      = 16;    // classifier context window
static constexpr int kEmbedStride        = 8;     // mel frame stride for embedding windows
static constexpr int kMelWindowFrames    = 76;    // mel frames per embedding window
static constexpr int kVirtualContextSamples = 32000; // 2s before VAD onset
static constexpr int kOnsetCutoffSamples = 32000;    // last eligible endpoint after onset
static constexpr int kMelFrameStrideSamples = 160;
static constexpr int kEmbeddingStrideSamples =
    kEmbedStride * kMelFrameStrideSamples;
static constexpr int kEmbeddingEndpointOffsetSamples =
    kMelWindowFrames * kMelFrameStrideSamples;
static constexpr float kMelGain          = 10.0f; // mel = data / gain + 2 (Android transform)
static constexpr float kMelBias          = 2.0f;

struct WakeWordPipeline {
    Ort::Env env;
    Ort::SessionOptions sessionOpts;
    std::unique_ptr<Ort::Session> melSession;
    std::unique_ptr<Ort::Session> embedSession;
    std::unique_ptr<Ort::Session> clsSession;
    Ort::AllocatorWithDefaultOptions allocator;
    float threshold;

    // Cached input/output names
    std::string melInputName;
    std::string melOutputName;
    std::string embedInputName;
    std::string embedOutputName;
    std::string clsInputName;
    std::string clsOutputName;
};

// Thread-safe last-error storage
static std::string g_lastError;

const char* wakeword_last_error(void) {
    return g_lastError.empty() ? nullptr : g_lastError.c_str();
}

extern "C" {

WakeWordPipeline* wakeword_init(const char* melModelPath,
                                 const char* embedModelPath,
                                 const char* clsModelPath,
                                 float threshold) {
    auto* p = new (std::nothrow) WakeWordPipeline();
    if (!p) return nullptr;

    try {
        p->sessionOpts.SetIntraOpNumThreads(1);
        p->sessionOpts.SetInterOpNumThreads(1);
        p->sessionOpts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);

        p->melSession.reset(new Ort::Session(p->env, melModelPath, p->sessionOpts));
        p->embedSession.reset(new Ort::Session(p->env, embedModelPath, p->sessionOpts));
        p->clsSession.reset(new Ort::Session(p->env, clsModelPath, p->sessionOpts));

        // Cache input/output names.
        Ort::AllocatorWithDefaultOptions alloc;
        {
            auto name = p->melSession->GetInputNameAllocated(0, alloc);
            p->melInputName = name.get();
        }
        {
            auto name = p->melSession->GetOutputNameAllocated(0, alloc);
            p->melOutputName = name.get();
        }
        {
            auto name = p->embedSession->GetInputNameAllocated(0, alloc);
            p->embedInputName = name.get();
        }
        {
            auto name = p->embedSession->GetOutputNameAllocated(0, alloc);
            p->embedOutputName = name.get();
        }
        {
            auto name = p->clsSession->GetInputNameAllocated(0, alloc);
            p->clsInputName = name.get();
        }
        {
            auto name = p->clsSession->GetOutputNameAllocated(0, alloc);
            p->clsOutputName = name.get();
        }

        p->threshold = threshold;
        NSLog(@"[WakeWord] Pipeline initialized (threshold=%.2f)", threshold);
        return p;
    } catch (const std::exception& e) {
        g_lastError = std::string("init: ") + e.what();
        NSLog(@"[WakeWord] ONNX init FAILED: %s", e.what());
        delete p;
        return nullptr;
    }
}

void wakeword_release(WakeWordPipeline* handle) {
    delete handle;
}

float wakeword_detect(WakeWordPipeline* handle,
                       const float* samples,
                       int sampleCount,
                       int sampleRate) {
    if (!handle) return 0.0f;
    if (!samples || sampleCount <= 0) return 0.0f;

    try {
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        // ---- Stage 1: Mel spectrogram on full audio ----
        // Input: [1, sampleCount]  →  Output: [1, 1, time_frames, 32]
        std::vector<int64_t> melInputShape = {1, sampleCount};
        Ort::Value melInput = Ort::Value::CreateTensor<float>(
            memInfo, const_cast<float*>(samples), sampleCount,
            melInputShape.data(), melInputShape.size());

        const char* melInputNames[] = {handle->melInputName.c_str()};
        const char* melOutputNames[] = {handle->melOutputName.c_str()};
        auto melOutputs = handle->melSession->Run(
            Ort::RunOptions{nullptr},
            melInputNames, &melInput, 1,
            melOutputNames, 1);

        if (melOutputs.empty()) {
            NSLog(@"[WakeWord] detect: mel spectrogram produced no output");
            return 0.0f;
        }

        auto& melTensor = melOutputs.front();
        auto melShape = melTensor.GetTensorTypeAndShapeInfo().GetShape();
        if (melShape.size() < 4) {
            NSLog(@"[WakeWord] detect: unexpected mel output rank %zu", melShape.size());
            return 0.0f;
        }

        int64_t nMelFrames = melShape[2];   // time frames (varies with input length)
        int64_t melWidth   = melShape[3];   // 32
        size_t melCount = melTensor.GetTensorTypeAndShapeInfo().GetElementCount();
        const float* melData = melTensor.GetTensorMutableData<float>();

        if (nMelFrames == 0) return 0.0f;

        // Apply mel transform: mel = mel / 10 + 2 (matching Android)
        std::vector<float> melFrames(melData, melData + melCount);
        for (float& v : melFrames) { v = v / kMelGain + kMelBias; }

        // ---- Stage 2: Extract 76-frame embedding windows (stride 8) ----
        int nEmbeddings = (int)((nMelFrames - kMelWindowFrames) / kEmbedStride + 1);
        if (nEmbeddings < 0) nEmbeddings = 0;
        if (nEmbeddings == 0) return 0.0f;

        std::vector<float> embeddings;  // (nEmbeddings, kEmbeddingDim) flattened
        embeddings.reserve(nEmbeddings * kEmbeddingDim);

        for (int i = 0; i < nEmbeddings; i++) {
            int melStart = i * kEmbedStride;

            // Build [1, 76, 32, 1] input from the mel frame window.
            // melFrames layout: [1, 1, nMelFrames, 32]  →  flat index = f * 32 + bin
            std::vector<float> melWindowInput;
            melWindowInput.reserve(kMelWindowFrames * kMelBins);
            for (int f = 0; f < kMelWindowFrames; f++) {
                int frameOffset = (melStart + f) * (int)kMelBins;
                melWindowInput.insert(melWindowInput.end(),
                                      melFrames.begin() + frameOffset,
                                      melFrames.begin() + frameOffset + kMelBins);
            }

            std::vector<int64_t> embedInShape = {1, kMelWindowFrames, kMelBins, 1};
            Ort::Value embedInput = Ort::Value::CreateTensor<float>(
                memInfo, melWindowInput.data(), melWindowInput.size(),
                embedInShape.data(), embedInShape.size());

            const char* embedInputNames[] = {handle->embedInputName.c_str()};
            const char* embedOutputNames[] = {handle->embedOutputName.c_str()};
            auto embedOutputs = handle->embedSession->Run(
                Ort::RunOptions{nullptr},
                embedInputNames, &embedInput, 1,
                embedOutputNames, 1);

            if (embedOutputs.empty()) {
                NSLog(@"[WakeWord] detect: embedding produced no output at window %d", i);
                return 0.0f;
            }

            const float* embData = embedOutputs.front().GetTensorMutableData<float>();
            size_t embElemCount = embedOutputs.front().GetTensorTypeAndShapeInfo().GetElementCount();
            embeddings.insert(embeddings.end(), embData, embData + embElemCount);
        }

        // ---- Stage 3: Classifier — slide 16-embedding window, take max score ----
        int numWindows = nEmbeddings - kMaxEmbeddings + 1;
        if (numWindows < 1) numWindows = 1;

        int64_t clsInShape[] = {1, kMaxEmbeddings, kEmbeddingDim};
        float maxScore = 0.0f;

        for (int w = 0; w < numWindows; w++) {
            // Build classifier input: [1, 16, 96] with left-zero-padding for short segments
            std::vector<float> clsInput(kMaxEmbeddings * kEmbeddingDim, 0.0f);

            int embStart = (nEmbeddings < kMaxEmbeddings) ? 0 : w;
            int embCount = (nEmbeddings < kMaxEmbeddings) ? nEmbeddings : kMaxEmbeddings;
            int dstStart = (kMaxEmbeddings - embCount) * kEmbeddingDim;  // left-pad
            int srcStart = embStart * kEmbeddingDim;

            std::memcpy(clsInput.data() + dstStart,
                       embeddings.data() + srcStart,
                       embCount * kEmbeddingDim * sizeof(float));

            Ort::Value clsTensor = Ort::Value::CreateTensor<float>(
                memInfo, clsInput.data(), clsInput.size(),
                clsInShape, 3);

            const char* clsInputNames[] = {handle->clsInputName.c_str()};
            const char* clsOutputNames[] = {handle->clsOutputName.c_str()};
            auto clsOutputs = handle->clsSession->Run(
                Ort::RunOptions{nullptr},
                clsInputNames, &clsTensor, 1,
                clsOutputNames, 1);

            if (clsOutputs.empty()) continue;

            float score = clsOutputs.front().GetTensorMutableData<float>()[0];
            if (score < 0.0f) score = 0.0f;
            if (score > 1.0f) score = 1.0f;
            if (score > maxScore) maxScore = score;
        }

        static int detectCount = 0;
        if (++detectCount % 10 == 1 || maxScore > 0.3f) {
            NSLog(@"[WakeWord] detect #%d score=%.4f nMel=%lld nEmb=%d nWin=%d samples=%d",
                  detectCount, maxScore, nMelFrames, nEmbeddings, numWindows, sampleCount);
        }

        return maxScore;

    } catch (const std::exception& e) {
        g_lastError = std::string("detect: ") + e.what();
        NSLog(@"[WakeWord] detect FAILED: %s", e.what());
        return 0.0f;
    }
}

float wakeword_detect_segment(WakeWordPipeline* handle,
                              const float* samples,
                              int sampleCount,
                              int sampleRate,
                              int* out_completion_sample) {
    if (out_completion_sample) *out_completion_sample = -1;
    if (!handle) return 0.0f;
    if (!samples || sampleCount <= 0) return 0.0f;

    try {
        // Virtual leading context: 2 seconds of zeros prepended to every VAD
        // segment so the classifier always has its 16-embedding window even for
        // wake-only segments. Classifier-level padding is forbidden by the
        // recognition-pipeline detection-window policy; the virtual samples
        // exist only inside the detector (never captured, logged, or passed on).
        std::vector<float> padded;
        padded.reserve(kVirtualContextSamples + sampleCount);
        padded.insert(padded.end(), kVirtualContextSamples, 0.0f);
        padded.insert(padded.end(), samples, samples + sampleCount);

        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        // ---- Stage 1: Mel spectrogram once over the combined input ----
        std::vector<int64_t> melInputShape = {1, (int64_t)padded.size()};
        Ort::Value melInput = Ort::Value::CreateTensor<float>(
            memInfo, padded.data(), padded.size(),
            melInputShape.data(), melInputShape.size());

        const char* melInputNames[] = {handle->melInputName.c_str()};
        const char* melOutputNames[] = {handle->melOutputName.c_str()};
        auto melOutputs = handle->melSession->Run(
            Ort::RunOptions{nullptr},
            melInputNames, &melInput, 1,
            melOutputNames, 1);

        if (melOutputs.empty()) {
            NSLog(@"[WakeWord] detect_segment: mel spectrogram produced no output");
            return 0.0f;
        }

        auto& melTensor = melOutputs.front();
        auto melShape = melTensor.GetTensorTypeAndShapeInfo().GetShape();
        if (melShape.size() < 4) {
            NSLog(@"[WakeWord] detect_segment: unexpected mel output rank %zu", melShape.size());
            return 0.0f;
        }

        int64_t nMelFrames = melShape[2];
        int64_t melWidth = melShape[3];
        size_t melCount = melTensor.GetTensorTypeAndShapeInfo().GetElementCount();
        const float* melData = melTensor.GetTensorMutableData<float>();

        if (nMelFrames == 0) return 0.0f;

        std::vector<float> melFrames(melData, melData + melCount);
        for (float& v : melFrames) { v = v / kMelGain + kMelBias; }

        // ---- Stage 2: Embeddings once, stride 8 mel frames ----
        int nEmbeddings = (int)((nMelFrames - kMelWindowFrames) / kEmbedStride + 1);
        if (nEmbeddings < 0) nEmbeddings = 0;
        if (nEmbeddings == 0) {
            g_lastError = "detect_segment: no embeddings extracted";
            NSLog(@"[WakeWord] detect_segment: no embeddings extracted");
            return 0.0f;
        }

        std::vector<float> embeddings;
        embeddings.reserve(nEmbeddings * kEmbeddingDim);

        for (int i = 0; i < nEmbeddings; i++) {
            int melStart = i * kEmbedStride;
            std::vector<float> melWindowInput;
            melWindowInput.reserve(kMelWindowFrames * kMelBins);
            for (int f = 0; f < kMelWindowFrames; f++) {
                int frameOffset = (melStart + f) * (int)kMelBins;
                melWindowInput.insert(melWindowInput.end(),
                                      melFrames.begin() + frameOffset,
                                      melFrames.begin() + frameOffset + kMelBins);
            }

            std::vector<int64_t> embedInShape = {1, kMelWindowFrames, kMelBins, 1};
            Ort::Value embedInput = Ort::Value::CreateTensor<float>(
                memInfo, melWindowInput.data(), melWindowInput.size(),
                embedInShape.data(), embedInShape.size());

            const char* embedInputNames[] = {handle->embedInputName.c_str()};
            const char* embedOutputNames[] = {handle->embedOutputName.c_str()};
            auto embedOutputs = handle->embedSession->Run(
                Ort::RunOptions{nullptr},
                embedInputNames, &embedInput, 1,
                embedOutputNames, 1);

            if (embedOutputs.empty()) {
                g_lastError = "detect_segment: embedding produced no output";
                NSLog(@"[WakeWord] detect_segment: embedding produced no output at window %d", i);
                return 0.0f;
            }

            const float* embData = embedOutputs.front().GetTensorMutableData<float>();
            size_t embElemCount = embedOutputs.front().GetTensorTypeAndShapeInfo().GetElementCount();
            embeddings.insert(embeddings.end(), embData, embData + embElemCount);
        }

        // ---- Stage 3: dense windows whose endpoints remain inside the onset gate ----
        // For classifier window start w, the final embedding index is w+15 and
        // its waveform endpoint relative to speech onset is:
        //   76*160 + 8*160*(w+15) - virtualContext.
        // With the frozen 2s context/cutoff this admits starts 0...25 (26 windows).
        int totalWindows = nEmbeddings - kMaxEmbeddings + 1;
        if (totalWindows < 1) {
            // The virtual 2s context must yield >= 16 embeddings; anything less
            // is a pipeline failure, never a padded "detection".
            g_lastError = "detect_segment: fewer than 16 embeddings after virtual context";
            NSLog(@"[WakeWord] detect_segment: %d embeddings, need %d", nEmbeddings, kMaxEmbeddings);
            return 0.0f;
        }
        int maxLastEmbeddingIndex =
            (kVirtualContextSamples + kOnsetCutoffSamples -
             kEmbeddingEndpointOffsetSamples) /
            kEmbeddingStrideSamples;
        int maxEligibleWindowStart = maxLastEmbeddingIndex - (kMaxEmbeddings - 1);
        int numWindows = std::min(totalWindows, maxEligibleWindowStart + 1);
        if (numWindows < 1) return 0.0f;

        int64_t clsInShape[] = {1, kMaxEmbeddings, kEmbeddingDim};
        float maxScore = 0.0f;
        int bestWindow = -1;

        for (int w = 0; w < numWindows; w++) {
            std::vector<float> clsInput(kMaxEmbeddings * kEmbeddingDim);
            std::memcpy(clsInput.data(),
                        embeddings.data() + w * kEmbeddingDim,
                        kMaxEmbeddings * kEmbeddingDim * sizeof(float));

            Ort::Value clsTensor = Ort::Value::CreateTensor<float>(
                memInfo, clsInput.data(), clsInput.size(),
                clsInShape, 3);

            const char* clsInputNames[] = {handle->clsInputName.c_str()};
            const char* clsOutputNames[] = {handle->clsOutputName.c_str()};
            auto clsOutputs = handle->clsSession->Run(
                Ort::RunOptions{nullptr},
                clsInputNames, &clsTensor, 1,
                clsOutputNames, 1);

            if (clsOutputs.empty()) continue;

            float score = clsOutputs.front().GetTensorMutableData<float>()[0];
            if (score < 0.0f) score = 0.0f;
            if (score > 1.0f) score = 1.0f;
            if (score > maxScore) {
                maxScore = score;
                bestWindow = w;
            }
        }

        if (out_completion_sample && bestWindow >= 0) {
            int lastEmb = bestWindow + kMaxEmbeddings - 1;
            int endpointRelOnset =
                kEmbeddingEndpointOffsetSamples +
                lastEmb * kEmbeddingStrideSamples -
                kVirtualContextSamples;
            if (endpointRelOnset < 0) endpointRelOnset = 0;
            *out_completion_sample = endpointRelOnset;
        }

        NSLog(@"[WakeWord] detect_segment score=%.4f nMel=%lld nEmb=%d nWin=%d/%d samples=%d",
              maxScore, nMelFrames, nEmbeddings, numWindows, totalWindows, sampleCount);

        return maxScore;

    } catch (const std::exception& e) {
        g_lastError = std::string("detect_segment: ") + e.what();
        NSLog(@"[WakeWord] detect_segment FAILED: %s", e.what());
        return 0.0f;
    }
}

} // extern "C"
