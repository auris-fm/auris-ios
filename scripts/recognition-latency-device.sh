#!/usr/bin/env bash
set -euo pipefail

# Runs the recognition latency measurement on a simulator (or device once a
# fixture-driven device test exists). Reports wake-to-ASR stage timings from
# the `voice_recognition_latency` event.
#
# Requirements: Xcode 16+, the "Pocket Casts Staging" scheme, bundled wake-word
# manifest (auris_eval.json) + .ort models, and the FunctionGemma release.
#
# TODO(voice): add a fixture-driven RecognitionLatencyDeviceTests class that
# plays a fixed "Auris + command" clip through the production engine and
# asserts wake_to_asr_result_ms p50/p95 over >=30 runs, then point this script
# at it.

DEVICE=${1:-"iPhone 17 Pro"}

xcodebuild test \
  -project podcasts.xcodeproj \
  -scheme "Pocket Casts Staging" \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath /tmp/auris-dd \
  -only-testing:PocketCastsTests/VoiceControlIntegrationTests/WakeWordPipelineTests

echo "Latency verification complete. Inspect the xcresult for stage timings."
