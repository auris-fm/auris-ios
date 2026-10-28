#import "SafeVadCreation.h"

#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>

void * _Nullable
AurisSafeCreateVoiceActivityDetector(const void * _Nullable config, float bufferSizeInSeconds) {
    if (config == nullptr) {
        return nullptr;
    }
    @try {
        const auto *detector = SherpaOnnxCreateVoiceActivityDetector(
            static_cast<const SherpaOnnxVadModelConfig *>(config), bufferSizeInSeconds);
        return static_cast<void *>(const_cast<SherpaOnnxVoiceActivityDetector *>(detector));
    } @catch (...) {
        // A present-but-unloadable model throws C++ Ort::Exception from inside the C API.
        // Swallowing it here converts a launch crash into a reportable nil for Swift.
        return nullptr;
    }
}
