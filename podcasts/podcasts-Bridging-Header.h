//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//
//  Auris-only: the vendored ObjC/C helpers (SJCommonUtils, SJMediaMetadataHelper,
//  MNAVChapterReader, VoiceBoostN) are now SwiftPM modules, imported directly in
//  Swift with `import SJUtils` / `import MNAVChapters` / `import VoiceBoostN`.
//  Only the voice-control / on-device ASR headers are bridged here.

#include "VoiceControl/WakeWord/WakeWordDetector.h"
#import "VoiceControl/IntentRouter/Native/LlmBridge.h"
@import SherpaOnnxC;  // sherpa-onnx C API (SenseVoice + Canary Flash backends)
