import Foundation

/// One cloud request's latency, measured on the client's own clock.
///
/// `cloud-assistant.md`, KPIs: "Clients separately measure first validated action, first audible
/// audio, and terminal event on their own clock"; the
/// server's own figure (request in → first audio frame sent) cannot include the client's decode and
/// playback, and Android reports the same pair. Three instants, one record:
///
/// - `endOfSpeech` — the VAD decided the utterance had ended, i.e. the user stopped talking. This is
///   the instant the user's wait begins, so it is the start of the number that matters.
/// - `requestSent` — the authenticated request went out on the socket.
/// - `firstAudible` — the output node began rendering this turn's first sound, read from its own
///   render state (see `CloudAudioPlayer`). Deliberately not the instant the first buffer was
///   scheduled. A server lead-in clip arrives on the same stream unmarked, so this includes it:
///   the number is when sound started, not when the answer started.
///
/// A turn that escalates from a local `no_match` to the cloud logs ONE record, for the cloud
/// request that actually carries it: the local attempt produced no audio, so there is nothing
/// separate to report and a second record would double-count the turn.
final class CloudTurnLatencyRecord: Equatable {
    static func == (lhs: CloudTurnLatencyRecord, rhs: CloudTurnLatencyRecord) -> Bool { lhs === rhs }

    /// The clock every instant in this file is read from. One basis for all of them, so the
    /// differences are the user's wait rather than a difference of clocks.
    static let now: () -> Double = { CACurrentMediaTime() }

    let requestId: String
    /// The instant the utterance's speech ended, or nil when this request did not come from a
    /// spoken utterance (a typed request, an acceptance run): the record then still reports the
    /// request-to-audible part rather than inventing a start.
    let endOfSpeech: Double?
    /// The instant the endpoint decision fired, which follows the acoustic end of speech by the
    /// configured hangover. Reported as its own stage: that gap is real wait the user pays before
    /// recognition even starts.
    let endpointDecision: Double?
    /// True for a barge-in follow-up that was held while the turn it interrupted settled. Its end
    /// of speech is the user's real one, but its request went out only after that hold, so its
    /// end-of-speech-to-request time is not the phone's normal send path. Tagged on the line so
    /// medians can separate or exclude these turns.
    let followUpHeld: Bool

    init(requestId: String, endOfSpeech: Double?, endpointDecision: Double? = nil, followUpHeld: Bool = false) {
        self.requestId = requestId
        self.endOfSpeech = endOfSpeech
        self.endpointDecision = endpointDecision
        self.followUpHeld = followUpHeld
    }

    /// Milliseconds of capture-side hangover between the last speech sample and the endpoint
    /// decision, when both instants are known.
    var endpointMs: Double? {
        guard let endOfSpeech, let endpointDecision, endpointDecision >= endOfSpeech else { return nil }
        return (endpointDecision - endOfSpeech) * 1000
    }

    /// Milliseconds from the end of speech to the request going out, when both are known.
    func endOfSpeechToRequestMs(requestSent: Double) -> Double? {
        guard let endOfSpeech, requestSent >= endOfSpeech else { return nil }
        return (requestSent - endOfSpeech) * 1000
    }

    /// Milliseconds from the end of speech to the first audible audio, when both are known. This is
    /// the client-side figure the latency work compares across platforms.
    func endOfSpeechToFirstAudibleMs(firstAudible: Double) -> Double? {
        guard let endOfSpeech, firstAudible >= endOfSpeech else { return nil }
        return (firstAudible - endOfSpeech) * 1000
    }

    /// Milliseconds from the request going out to the first audible audio. Present even for a
    /// request with no spoken start.
    func requestToFirstAudibleMs(requestSent: Double, firstAudible: Double) -> Double? {
        guard firstAudible >= requestSent else { return nil }
        return (firstAudible - requestSent) * 1000
    }

    /// The single line this turn contributes, named after what each number is. Written whether or
    /// not audio was ever heard: a turn that produced no audio is the interesting case, and a
    /// missing line would be indistinguishable from a turn that never ran.
    func logLine(
        requestSent: Double?,
        firstAudible: Double?,
        outcome: String,
        audioFrames: Int? = nil,
        bufferClears: Int? = nil
    ) -> String {
        let endpointMs = self.endpointMs
        let ms: (Double?) -> String = { $0.map { String(format: "%.0fms", $0) } ?? "none" }
        let toRequest = requestSent.flatMap { endOfSpeechToRequestMs(requestSent: $0) }
        let requestToAudible = requestSent.flatMap { sent in
            firstAudible.flatMap { requestToFirstAudibleMs(requestSent: sent, firstAudible: $0) }
        }
        let toAudible = firstAudible.flatMap { endOfSpeechToFirstAudibleMs(firstAudible: $0) }
        var parts = [
            "request_id=\(requestId)",
            "outcome=\(outcome)",
            // The client's own share, split so a slow turn can be attributed: `endpoint` is the
            // capture-side hangover between the last speech sample and the endpoint decision,
            // `to_request` everything from there to the send (recognition plus routing).
            "endpoint_ms=\(ms(endpointMs))",
            "endpoint_to_request=\(ms(toRequest.flatMap { total in endpointMs.map { max(0, total - $0) } }))",
            "end_of_speech_to_request=\(ms(toRequest))",
            "request_to_first_audible=\(ms(requestToAudible))",
            "end_of_speech_to_first_audible=\(ms(toAudible))",
        ]
        if firstAudible == nil { parts.append("first_audible=absent") }
        // PLAYER-WIDE deltas over this turn's window, not this turn's own frames: a successor that
        // overlaps the window (a barge-in while this turn's loop still runs) lands its frames and
        // clears in these counts, so `buffer_cleared=1` may mean another turn's audio was shed.
        // Check the neighbouring turn before reading it as this turn's.
        // What the player was handed during this turn, so an absent first-audible is attributable:
        // zero frames means the audio never arrived; frames with clears means it arrived and was
        // shed; frames without clears means it arrived and was never scheduled.
        if let audioFrames { parts.append("audio_frames=\(audioFrames)") }
        if let bufferClears { parts.append("buffer_cleared=\(bufferClears)") }
        if followUpHeld { parts.append("follow_up=held") }
        return parts.joined(separator: " ")
    }
}
