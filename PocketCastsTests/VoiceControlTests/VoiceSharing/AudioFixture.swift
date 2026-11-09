import Foundation
@testable import podcasts

/// One ready-to-upload recording, encoded through the production encoder and published through the
/// production queue. Tests that need a queued entry use this rather than hand-writing a record, so a
/// schema change cannot silently divergence a fixture from what the app writes.
enum AudioFixture {
    @discardableResult
    static func makeReadyEntry(in queue: VoiceSharingQueue) throws -> VoiceSharingQueue.Entry {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        guard let name = queue.publish(audio: encoded.wav, metadata: encoded.metadata),
              let entry = queue.entries().first(where: { $0.name == name })
        else { throw XCTSkipWrapper("the queue refused the fixture recording") }
        return entry
    }
}

struct XCTSkipWrapper: Error {
    let message: String
    init(_ message: String) { self.message = message }
}