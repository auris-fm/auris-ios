#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to the 3-stage wake word pipeline (mel → embed → classify).
typedef struct WakeWordPipeline WakeWordPipeline;

/// Initialize the 3-stage ONNX Runtime pipeline.
/// @param melModelPath  Path to melspectrogram.onnx
/// @param embedModelPath Path to embedding_model.onnx
/// @param clsModelPath  Path to the "Auris" classifier ONNX model
/// @param threshold     Confidence threshold for detection [0, 1]
/// @return Opaque handle, or NULL on failure.
WakeWordPipeline* wakeword_init(const char* melModelPath,
                                 const char* embedModelPath,
                                 const char* clsModelPath,
                                 float threshold);

/// Run detection on a 2-second window of 16kHz mono float32 PCM.
/// @return Confidence score in [0, 1].
float wakeword_detect(WakeWordPipeline* handle,
                       const float* samples,
                       int sampleCount,
                       int sampleRate);

/// Runs detection on a complete VAD segment per the recognition-pipeline
/// detection-window policy: prepends 2 seconds of virtual zero waveform
/// context, extracts mel frames and embeddings once over the combined input,
/// and scores 16-embedding classifier windows at stride 1 (~80 ms) whose
/// endpoints fall no later than 2 seconds after VAD onset. Returns the maximum
/// score in [0, 1], or 0 with `wakeword_last_error()` set on failure.
float wakeword_detect_segment(WakeWordPipeline* handle,
                              const float* samples,
                              int sampleCount,
                              int sampleRate,
                              int* out_completion_sample);

/// Release all ONNX Runtime resources.
void wakeword_release(WakeWordPipeline* handle);

/// Returns the last error message from the pipeline, or NULL if no error.
/// The returned pointer is valid until the next call to any wakeword_* function.
const char* wakeword_last_error(void);

#ifdef __cplusplus
}
#endif
