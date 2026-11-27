import XCTest

@testable import podcasts

/// ADMISSION IS A FACT ABOUT THE SERVER, NOT ABOUT THE SOCKET.
///
/// `cloud-assistant.md` → conversation mode: "A handle is resumable only after the server has
/// admitted a turn in it, which the client observes as `connected`, or as `duplicate_request` on a
/// retry of that same request (the original was admitted even though its `connected` was lost)."
/// Acceptance case: "A `create` whose `connected` was lost is retried and answered
/// `duplicate_request`; the next follow-up resumes that same conversation, not a fresh one."
///
/// Only `connected` acknowledged a handle, so a create whose answer went to a dead socket left the
/// conversation unacknowledged and the next follow-up opened a fresh one — the user's thread
/// restarted although the server had already admitted the request.
///
/// Every case here runs the REAL sink over a scripted transport and asserts the `conversation_mode`
/// a follow-up actually puts on the wire, never manager state the test wrote itself. The retry is
/// the production one: an inherited early connection whose first send transmits and then throws, so
/// `CloudRouteClient` re-dials once with the SAME frame and the same `request_id`.
@MainActor
final class DuplicateRequestAdmissionControl: XCTestCase {

    private let origin = 1

    /// Unused: this control exercises conversation identity, never playback.
    private struct UnusedPlaybackSink: VoicePlaybackSink {
        var isPlaying: Bool { false }
        func pause() -> VoiceResponse { .silent }
        func resume() -> VoiceResponse { .silent }
        func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
        func nextEpisode() -> VoiceResponse { .silent }
    }

    private struct NoFingerprintMap: FingerprintMappingProviding {
        func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }
        func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { nil }
        func observedOffsetSeconds(beforeReferenceTime referenceTime: TimeInterval) -> Double? { nil }
        func isBracketedReference(_ referenceTime: TimeInterval) -> Bool { false }
    }

    private final class UnusedResultConsumer: CloudOperationResultConsuming {
        func consume(_ result: OperationResult, context: String) {}
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }

    /// The auth frames a task actually sent, decoded from the wire.
    private func authFrames(_ task: StubWebSocketTask) -> [[String: Any]] {
        task.sentTextFrames.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.filter { $0["type"] as? String == "authenticate" }
    }

    /// Builds a sink whose client dials `first` for the early connection and `second` for the
    /// re-dial, exactly as production does when an inherited socket dies after transmitting.
    private func makeSink(
        manager: CloudConversationManager,
        first: StubWebSocketTask,
        second: StubWebSocketTask
    ) -> CloudRouteSink {
        var dialled: [StubWebSocketTask] = []
        return CloudRouteSink(
            clientFactory: {
                CloudRouteClient(
                    baseURL: "https://cloud.test",
                    tokenProvider: StubTokenProvider(token: "test_token"),
                    webSocketTaskFactory: { _ in
                        let task = dialled.isEmpty ? first : second
                        dialled.append(task)
                        return task
                    }
                )
            },
            isConfigured: { true },
            playbackSink: UnusedPlaybackSink(),
            fingerprintMapper: NoFingerprintMap(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            operationResultConsumer: UnusedResultConsumer(),
            conversationManager: manager
        )
    }

    /// Runs the opening turn over an inherited connection that transmits and then fails, so the
    /// client re-dials and the server answers `duplicate_request` on the retry.
    ///
    /// Returns the conversation id the opening turn carried, read off its own auth frame.
    private func runRetriedCreate(
        sink: CloudRouteSink,
        first: StubWebSocketTask,
        second: StubWebSocketTask,
        utteranceId: String
    ) async -> (conversationId: String?, result: CloudRouteResult?) {
        let tag = sink.beginEarlyConnection(tag: CloudRouteSink.mintEarlyConnectionTag())
        guard let tag else { return (nil, nil) }
        sink.claimEarlyConnection(tag: tag, utteranceId: utteranceId)
        let result = await sink.routeToCloud(
            request: "find episodes", tier: .free, context: sampleContext(),
            origin: origin, selection: .wakeWord, utteranceId: utteranceId
        )
        return (authFrames(second).first?["conversation_id"] as? String, result)
    }

    /// The follow-up's wire mode and conversation id, after the opening turn above.
    private func followUpWire(
        sink: CloudRouteSink, task: StubWebSocketTask, utteranceId: String
    ) async -> (mode: String?, conversationId: String?) {
        _ = await sink.routeToCloud(
            request: "play the second one", tier: .free, context: sampleContext(),
            origin: origin, selection: .followUp, utteranceId: utteranceId
        )
        let frame = authFrames(task).last
        return (frame?["conversation_mode"] as? String, frame?["conversation_id"] as? String)
    }

    /// A `create` whose `connected` was lost, retried and answered `duplicate_request`: the server
    /// admitted it, so the next follow-up must RESUME that same conversation.
    ///
    /// The break this catches: only `connected` acknowledges, so the handle stays a draft and the
    /// follow-up sends `create` with a fresh id — the user's thread restarts.
    func testACreateAnsweredDuplicateOnItsRetryIsResumedByTheNextFollowUp() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(origin)

        let first = StubWebSocketTask(textFrames: [])
        first.transmitsThenThrows = true
        let second = StubWebSocketTask(textFrames: [
            #"{"type":"error","code":"duplicate_request","message":"already admitted"}"#
        ])
        let sink = makeSink(manager: manager, first: first, second: second)

        let openedId = await runRetriedCreate(
            sink: sink, first: first, second: second, utteranceId: "u-open-retry"
        ).conversationId

        // Premises: without these the assertion below is satisfied by a turn that never retried.
        XCTAssertEqual(first.sent.count, 1, "premise: the first frame must have transmitted")
        XCTAssertFalse(second.sentTextFrames.isEmpty, "premise: the retry must reach the server")
        XCTAssertEqual(
            first.sentAuthFrame?["request_id"] as? String,
            second.sentAuthFrame?["request_id"] as? String,
            "premise: both sends must carry the SAME request id, or this is not a retry"
        )
        XCTAssertEqual(
            second.sentAuthFrame?["conversation_mode"] as? String, "create",
            "premise: the retried turn must be a create"
        )
        let createdId = try XCTUnwrap(openedId, "premise: the opening turn must have named a conversation")

        // A fresh socket for the follow-up, so its auth frame is unambiguous.
        let next = StubWebSocketTask(textFrames: [
            #"{"type":"connected","codec":"pcm_s16le@24k"}"#,
            #"{"type":"done","usage":{"input_tokens":1,"output_tokens":1}}"#
        ])
        let followUpSink = makeSink(manager: manager, first: next, second: next)
        let wire = await followUpWire(sink: followUpSink, task: next, utteranceId: "u-next-retry")

        XCTAssertEqual(wire.mode, "resume", "an admitted conversation was not resumed, so the thread restarts")
        XCTAssertEqual(wire.conversationId, createdId, "the follow-up must continue the SAME conversation")
    }

    /// The same fact on the re-dial path, where the turn itself reports `connection_lost`.
    ///
    /// The two decisions are separate and both must hold: the ANSWER really did go to a dead
    /// socket, so the user hears the ordinary connection loss; the ADMISSION is a fact about the
    /// server, so the handle is still resumable. Relabelling the error would hide a real loss, and
    /// dropping the handle would restart the thread.
    func testTheRetryPathReportsConnectionLostAndStillLeavesTheHandleResumable() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(origin)

        let first = StubWebSocketTask(textFrames: [])
        first.transmitsThenThrows = true
        let second = StubWebSocketTask(textFrames: [
            #"{"type":"error","code":"duplicate_request","message":"already admitted"}"#
        ])
        let sink = makeSink(manager: manager, first: first, second: second)
        let opening = await runRetriedCreate(
            sink: sink, first: first, second: second, utteranceId: "u-open-loss"
        )
        let createdId = try XCTUnwrap(opening.conversationId)

        // The turn's own report is unchanged: a lost answer is a loss, not a refusal. Asserted on
        // the outcome the sink returned, which is what the caller renders and records.
        let result = try XCTUnwrap(opening.result)
        XCTAssertEqual(
            result.outcome, .failed(code: "connection_lost"),
            "a duplicate after a transmitted frame is a lost answer, not a refusal"
        )

        let next = StubWebSocketTask(textFrames: [
            #"{"type":"connected","codec":"pcm_s16le@24k"}"#,
            #"{"type":"done","usage":{"input_tokens":1,"output_tokens":1}}"#
        ])
        let followUpSink = makeSink(manager: manager, first: next, second: next)
        let wire = await followUpWire(sink: followUpSink, task: next, utteranceId: "u-next-loss")
        XCTAssertEqual(wire.mode, "resume")
        XCTAssertEqual(wire.conversationId, createdId)
    }

    /// A `duplicate_request` on a turn that NEVER re-sent anything is not this client's retry: some
    /// other socket carried that id. It says nothing about a request this client made, so the
    /// handle stays unacknowledged and the next follow-up opens a fresh conversation.
    ///
    /// Without this case the rule could be implemented as "any duplicate acknowledges", which would
    /// resume a conversation this client never established.
    func testADuplicateWithoutARetryLeavesTheHandleUnacknowledged() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(origin)

        // No inherited connection and no throw: ONE send, answered with a duplicate.
        let only = StubWebSocketTask(textFrames: [
            #"{"type":"error","code":"duplicate_request","message":"already admitted"}"#
        ])
        let sink = makeSink(manager: manager, first: only, second: only)
        _ = await sink.routeToCloud(
            request: "find episodes", tier: .free, context: sampleContext(),
            origin: origin, selection: .wakeWord, utteranceId: "u-open-noretry"
        )
        XCTAssertEqual(only.sent.count, 1, "premise: exactly one send, so nothing was retried")
        let openedId = authFrames(only).first?["conversation_id"] as? String

        let next = StubWebSocketTask(textFrames: [
            #"{"type":"connected","codec":"pcm_s16le@24k"}"#,
            #"{"type":"done","usage":{"input_tokens":1,"output_tokens":1}}"#
        ])
        let followUpSink = makeSink(manager: manager, first: next, second: next)
        let wire = await followUpWire(sink: followUpSink, task: next, utteranceId: "u-next-noretry")

        XCTAssertEqual(wire.mode, "create", "a duplicate that was not this client's retry proved no admission")
        XCTAssertNotEqual(wire.conversationId, openedId, "the follow-up must open a FRESH conversation")
    }
}