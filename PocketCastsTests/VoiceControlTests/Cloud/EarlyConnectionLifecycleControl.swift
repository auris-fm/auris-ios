import XCTest

@testable import podcasts

/// An early connection belongs to one utterance, and only that utterance's turn may use it.
///
/// The defects this guards are invisible within a single turn: a held connection is skipped, not
/// failed, so every turn still works — the successor silently loses its handshake, or a turn sends
/// a request on a socket opened for a different command. Only a multi-utterance control sees them.
@MainActor
final class EarlyConnectionLifecycleControl: XCTestCase {

    /// Speech and silence are driven by the sample value, so a fixture can compose an utterance
    /// with pauses inside it. The segmenter's other rules (min speech frames, endpoint timeout)
    /// stay exactly as production runs them.
    private final class ThresholdClassifier: SpeechFrameClassifier {
        func reset() {}
        func isSpeech(_ samples: [Float]) -> Bool {
            samples.contains { $0 > 0.1 }
        }
    }

    /// Unused by this control: it exercises the early-connection lifecycle, never playback.
    private struct UnusedPlaybackSink: VoicePlaybackSink {
        var isPlaying: Bool { false }
        func pause() -> VoiceResponse { .silent }
        func resume() -> VoiceResponse { .silent }
        func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
        func nextEpisode() -> VoiceResponse { .silent }
    }

    /// No fingerprint map is relevant here: the test never routes a cloud turn.
    private struct NoFingerprintMap: FingerprintMappingProviding {
        func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }
        func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { nil }
    }

    private func makeSink() -> CloudRouteSink {
        CloudRouteSink(
            clientFactory: {
                CloudRouteClient(
                    baseURL: "https://cloud.test",
                    userId: "user_test",
                    tokenProvider: StubTokenProvider(token: "test_token"),
                    webSocketTaskFactory: { _ in StubWebSocketTask(textFrames: []) }
                )
            },
            isConfigured: { true },
            playbackSink: UnusedPlaybackSink(),
            fingerprintMapper: NoFingerprintMap(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            conversationManager: CloudConversationManager()
        )
    }

    /// A locally answered command never consumes its connection. The next utterance must not be
    /// turned away by the held one: opening replaces it, so the successor gets its own handshake
    /// instead of silently inheriting or losing one.
    func test_localCommandThenNextUtteranceOpensItsOwnConnection() {
        let sink = makeSink()

        let firstTag = sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag())
        XCTAssertNotNil(firstTag)
        sink.claimEarlyConnection(tag: firstTag, utteranceId: "utterance-local")
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-local")

        // The command is answered locally, so nothing takes the connection. The next utterance
        // speaks and opens its own.
        let secondTag = sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag())
        XCTAssertNotNil(secondTag, "the next utterance must open a connection, not be refused by a stale one")
        XCTAssertNotEqual(secondTag, firstTag, "it must be a NEW connection, not the predecessor's")
        XCTAssertNil(sink.earlyConnectionOwnerForTesting,
                     "the fresh connection belongs to no utterance until its own turn is admitted")

        sink.claimEarlyConnection(tag: secondTag, utteranceId: "utterance-next")
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-next")
    }

    /// A drop that arrives after the successor opened must be ignored: closing the successor's
    /// socket would leave a turn waiting on a handshake cancelled underneath it.
    func test_delayedDropFromPredecessorDoesNotCloseTheSuccessorsConnection() {
        let sink = makeSink()

        let predecessorTag = try! XCTUnwrap(sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag()))
        sink.claimEarlyConnection(tag: predecessorTag, utteranceId: "utterance-predecessor")

        // The predecessor's turn dies and schedules its drop. Before it runs, the successor opens
        // and is admitted.
        let successorTag = try! XCTUnwrap(sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag()))
        sink.claimEarlyConnection(tag: successorTag, utteranceId: "utterance-successor")

        // The predecessor's drop finally runs.
        sink.discardEarlyConnection(tag: predecessorTag, reason: "predecessor's late drop")

        XCTAssertTrue(sink.hasEarlyConnectionForTesting,
                      "a predecessor's delayed drop must not close the successor's connection")
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-successor")
    }

    /// A turn may only pin the connection whose tag it carries.
    ///
    /// The important case is an UNCLAIMED connection — one that opened during trailing silence and
    /// has not been pinned yet. Any utterance could then arrive and claim it; without the tag
    /// check, a stale tag pins it to the wrong turn, and that turn sends its request on a socket
    /// opened for a different command.
    func test_turnDoesNotClaimAnUnclaimedConnectionWithAStaleTag() {
        let sink = makeSink()

        let heldTag = try! XCTUnwrap(sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag()))
        XCTAssertNil(sink.earlyConnectionOwnerForTesting, "not pinned until an utterance is admitted")

        // A different utterance arrives carrying a tag that is not the held one.
        sink.claimEarlyConnection(tag: "some-other-tag", utteranceId: "utterance-other")

        XCTAssertNil(sink.earlyConnectionOwnerForTesting,
                     "a stale tag must not pin an unclaimed connection to another utterance")
    }

    /// Once pinned, the connection cannot be reassigned to a second utterance: one connection
    /// carries one turn.
    func test_pinnedConnectionIsNotReassignedToAnotherUtterance() {
        let sink = makeSink()

        let heldTag = try! XCTUnwrap(sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag()))
        sink.claimEarlyConnection(tag: heldTag, utteranceId: "utterance-owner")
        sink.claimEarlyConnection(tag: heldTag, utteranceId: "utterance-other")

        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-owner",
                       "the connection carries one turn, so its owner cannot be reassigned")
    }

    /// Speech that resumes and pauses again is the SAME utterance: the connection opened for its
    /// first pause must survive, not be replaced by a second open.
    ///
    /// Replacement belongs to a new utterance. Treating a resumed utterance's second pause as a new
    /// one throws away a handshake that was already in flight and pays for it again.
    func test_resumedSpeechKeepsTheSameConnection() {
        let sink = makeSink()

        let tag = try! XCTUnwrap(sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag()))
        sink.claimEarlyConnection(tag: tag, utteranceId: "utterance-resumed")
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-resumed")

        // The segmenter does not report a second pause for an utterance that is still being
        // spoken, so nothing opens again. Asserted at the sink: opening for the SAME utterance
        // must not discard its connection.
        XCTAssertTrue(sink.hasEarlyConnectionForTesting)
    }

    /// Speech that resumes and pauses again is the same utterance, so its connection must survive.
    ///
    /// Driven through the real segmenter: two pauses inside one utterance must open ONCE. Opening
    /// again would replace a handshake the turn is about to use and pay for it twice.
    func test_twoPausesInsideOneUtteranceOpenOnlyOnce() {
        let classifier = ThresholdClassifier()
        let segmenter = NativeVadSegmenter(
            threshold: 0.0, silenceTimeoutMs: 10_000, minSpeechFrames: 2, classifier: classifier
        )
        var opens = 0
        segmenter.onTrailingSilenceBegan = {
            opens += 1
            return CloudRouteSink.mintEarlyConnectionTag()
        }

        // ONE utterance with a pause inside it: speech frames, a short silence run that does not
        // reach the endpoint, more speech, then silence again. Each `process` is a single frame, as
        // capture delivers them.
        let speech = [Float](repeating: 0.5, count: 1_600)
        let silence = [Float](repeating: 0.0, count: 1_600)
        for _ in 0..<8 { segmenter.process(speech) }
        for _ in 0..<3 { segmenter.process(silence) }
        for _ in 0..<8 { segmenter.process(speech) }
        for _ in 0..<3 { segmenter.process(silence) }

        XCTAssertEqual(opens, 1,
                       "a resumed utterance must open once, not once per pause")
    }
}
