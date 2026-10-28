//
// SafeVadCreation — exception-safe creation of the sherpa-onnx VAD detector.
//
// WHY. `SherpaOnnxCreateVoiceActivityDetector` does not reliably return NULL on a bad model:
// ONNX Runtime throws a C++ exception ("Protobuf parsing failed") that crosses into Swift,
// where it is uncatchable and terminates the app at launch. Measured: a truncated-but-present
// `silero_vad.onnx` threw `Ort::Exception: Load model ... failed: Protobuf parsing failed`.
//
// This shim wraps creation in an Objective-C++ `@try/@catch` (which catches C++ exceptions
// too) and returns NULL instead, so Swift can surface classifier unavailability rather than
// crash. Swift cannot do this itself: it has no mechanism to catch C++ exceptions.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates a sherpa-onnx voice-activity detector, returning NULL when the runtime fails or
/// throws — including the C++ exceptions a present-but-unloadable model triggers.
/// The caller owns the returned detector and must destroy it with
/// `SherpaOnnxDestroyVoiceActivityDetector`.
FOUNDATION_EXPORT void * _Nullable
AurisSafeCreateVoiceActivityDetector(const void * _Nullable config, float bufferSizeInSeconds);

NS_ASSUME_NONNULL_END
