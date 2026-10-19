import Foundation
import PocketCastsUtils

/// Real cloud route sink: WebSocket client → audio player → action dispatch.
///
/// Cloud answers arrive as synthesised audio streamed over the WebSocket; the
/// client plays them directly through the shared audio output path. Text
/// accumulation (`.token`) is removed — cloud answers are played, not spoken.
/// How a cloud turn actually ended, reported separately from how it was rendered.
///
/// The rendered response cannot carry this: a spoken server error and a silent success
/// are both "no earcon", so a caller deciding what happened from the response shape gets
/// them backwards — which is how a failed turn was recorded as a completed cloud route
/// and reopened the grace window for a turn that never happened.
enum CloudRouteOutcome: Equatable {
    /// The server sent `done`: the turn completed.
    case completed
    /// The server reported an error, or the route could not be dialled.
    case failed(code: String?)
    /// The stream ended without `done`: a truncated turn, not a completion.
    case earlyClose
    /// Cloud is not configured, so no turn was attempted.
    case refused
}

/// A turn's terminal outcome together with the feedback it rendered.
struct CloudRouteResult: Equatable {
    let response: VoiceResponse
    let outcome: CloudRouteOutcome
}

/// Lock-guarded one-way flag: set synchronously from a cancellation handler, read from any task.
final class OwnerCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    func mark() { lock.lock(); flagged = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flagged }
}

@MainActor
final class CloudRouteSink: VoiceCloudRouteSink,
                            CloudAudioPlayer.Delegate {

    /// The active turn's cancellation state, readable so a test can observe whether a refused
    /// turn cancelled its predecessor. The cancellation is a FLAG the running turn checks at its
    /// next event, so a held turn has not yet acted on it — reading the flag is what distinguishes
    /// "cancelled but not yet observed" from "never cancelled".
    /// Main-actor isolated like the rest of the sink: `activeTurn` is actor state, so the read
    /// must be too. A test awaits it through `MainActor.run`.
    var activeTurnIsCancelledForTesting: Bool? { activeTurn?.isCancelled }

    /// The selection the last turn arrived with, so a caller-level case can assert that the
    /// service derived it from the turn's own provenance rather than from live window state.
    /// Necessary because the two are indistinguishable from inside the sink when grace is active.
    @MainActor private(set) var lastSelectionForTesting: CloudConversationSelection?
    /// The ORIGIN the last turn arrived with, recorded at the same PRE-GUARD point as the selection.
    /// A caller-level case can therefore assert that the turn carried the generation captured at its
    /// callback — the raw `CloudRouteIntent.origin` — rather than whatever window is live later.
    @MainActor private(set) var lastOriginForTesting: Int?

    /// REQUEST-SCOPED preparation observer: the dispatch supplies it, so the prepared identity is
    /// captured FOR THAT DISPATCH rather than read from a sink-wide "last" slot. A shared slot is a
    /// last-value property: with more than one turn on a sink it reports whichever ran most
    /// recently, which is the wrong subject for an identity comparison.
    typealias PreparedObserver = @MainActor (CloudPreparedConversation) -> Void

    /// The cloud player this sink drives, so a test can reach the real producer through
    /// the chain the app builds rather than constructing its own.
    var audioPlayerForTesting: CloudAudioPlayer? { audioPlayer }
    /// The PRODUCTION client factory, extracted so the assembly reuses it VERBATIM and the test seam
    /// substitutes it. Production is unchanged: the default is this same factory.
    nonisolated static func productionClientFactory() -> () -> CloudRouteClient {
        {
            CloudRouteClient(
                baseURL: CloudConfig.shared.baseUrl,
                userId: CloudIdentity.shared.userId,
                tokenProvider: CloudTokenProviderRouter.provider()
            )
        }
    }

    private let clientFactory: () -> CloudRouteClient
    private let isConfigured: () -> Bool
    /// Prepares the conversation identity for each turn.
    private let conversationManager: CloudConversationManager

    /// The manager whose live origin must follow the grace window. Exposed so the SERVICE can own
    /// the subscription: a binding stored in the assembly's `cancellables` is cancelled as soon as
    /// What selected the current turn. Defaults to a wake word: a turn with no reported
    /// selection is a new user act, and create-then-resume is the safe direction — resuming
    /// a conversation nobody opened would attach an utterance to someone else's history.
    private let conversationSelectionProvider: () -> CloudConversationSelection
    /// The origin the turn runs under, so a resume cannot cross an ended window.

    /// ONE pre-effect hold, used ONLY by controls to strike cancellation deterministically between
    /// the durable claim and the effect. Production never sets it (nil = no pause). The hold is
    /// AWAITED, so the OWNER really suspends here — "the consumer is held" is a fact about the
    /// owner, not about some detached task. Its implementation must be cancellation-INSENSITIVE
    /// (explicit release only), so owner cancellation cannot open it; the caller performs the
    /// ordinary post-suspension cancellation check once it returns.
    var effectGate: ((_ operationId: String) async -> Void)?
    /// The CURRENT turn's cancellation mark, installed by the owning task's handler. Held work
    /// reads it after any suspension; cleared when the turn ends.
    private var currentOwnerCancelFlag: OwnerCancelFlag?

    var ownerCancelledNowForCurrentTurn: Bool { currentOwnerCancelFlag?.isSet ?? false }
    private let playbackSink: VoicePlaybackSink
    private let fingerprintMapper: FingerprintMappingProviding
    private let playbackPositionMs: () -> Int64
    private let cloudPlaybackContextState: CloudPlaybackContextState
    private let analytics: VoiceAnalytics?
    /// Renders structured `search_results_v1` results. False until the discovery
    /// renderer lands (Item 5 slice 2) — the capability is only advertised when
    /// the client can actually render result/empty/unavailable.
    private let rendersStructuredResults: Bool
    /// Typed-only route hint for the current turn. Free-text turns pass nil and
    /// keep today's interpretation path.
    private let routeHintProvider: () -> CloudRouteHint?
    /// Bounded prior conversation for the turn (≤4 turns / ≤8 KiB enforced by
    /// `RecentConversation.bounded`).
    private let recentConversationProvider: () -> [RecentConversationTurn]
    /// Renders negotiated discovery results. Present only when the UI can show
    /// result/empty/unavailable states — the same condition that justifies
    /// advertising `search_results_v1`.
    private weak var resultsPresenter: DiscoveryResultsPresenting?
    /// Spoken templates for client-authored codes. Injectable so the locale rule
    /// (speak only in the user's own language; earcon otherwise) is testable.
    private let spokenTemplates: SpokenTemplateResolver

    /// Audio player for cloud-delivered speech.
    private let audioPlayer: CloudAudioPlayer
    private let playbackManager: PlaybackManager?

    /// Playback position captured before `seek_to` / `play_quote` for `stop_quote`.
    private var preQuotePositionMs: Int64?
    /// True when this turn paused playback so we can restore on done/error.
    private var didAutoPause = false
    /// Whether the host was playing when the turn took its hold. The user's own
    /// pause stays the user's; only a hold that stopped running playback is
    /// released by the turn's end (Task 12).
    private var wasPlayingBeforeHold = false

    /// Set when the turn has completed and the player is draining: the hold is
    /// released from `audioPlayerDidStop` rather than at `done`.
    ///
    /// It records WHICH turn deferred, not merely THAT one did. The player's stop notification
    /// carries no turn identity, and a turn's audio can still be draining after a later turn has
    /// taken over the hold, so acting on the flag alone let an older turn's notification restore
    /// playback that the newer turn was deliberately holding.
    /// The deferred restoration, carrying the identity captured WHEN ITS DRAIN WAS SCHEDULED:
    /// which turn deferred and which drain it waits on. Neither alone suffices — the current owner
    /// can be the same turn when a foreign notification arrives, and a drain identity alone cannot
    /// say whether this turn still owns the release.
    private var restoreHeldForPlayerDrain: (owner: CloudTurnToken, drainEpoch: Int)?
    /// The in-flight turn. A new turn supersedes it: the older turn stops
    /// consuming its stream and stops touching playback/analytics state, so two
    /// overlapping turns (double wake, barge-in) cannot interleave actions or
    /// double-restore the pause.
    private var activeTurn: CloudTurnToken?





    /// Cancellation handle for one logical turn.
    final class CloudTurnToken {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    // `nonisolated`: the sink conforms to `CloudAudioPlayer.Delegate`, which is
    // `@MainActor`, so `CloudRouteSink` is implicitly main-actor-isolated. The
    // assembly that builds it is not, and construction only stores dependencies
    // (no main-actor state is touched), so the initializer is safe to call from
    // any context.
    nonisolated init(
        clientFactory: @escaping () -> CloudRouteClient = CloudRouteSink.productionClientFactory(),
        isConfigured: @escaping () -> Bool = { !CloudConfig.shared.baseUrl.isEmpty },
        audioPlayer: CloudAudioPlayer? = nil,
        playbackManager: PlaybackManager? = nil,
        playbackSink: VoicePlaybackSink,
        fingerprintMapper: FingerprintMappingProviding,
        playbackPositionMs: @escaping () -> Int64,
        cloudPlaybackContextState: CloudPlaybackContextState,
        analytics: VoiceAnalytics? = nil,
        rendersStructuredResults: Bool = false,
        routeHintProvider: @escaping () -> CloudRouteHint? = { nil },
        recentConversationProvider: @escaping () -> [RecentConversationTurn] = { [] },
        resultsPresenter: DiscoveryResultsPresenting? = nil,
        spokenTemplates: SpokenTemplateResolver = SpokenTemplateResolver(),
        operationResultConsumer: CloudOperationResultConsuming? = nil,
        operationJournal: OperationJournal? = nil,
        // Last so a call site can always supply them after whatever other defaults it uses.
        conversationManager: CloudConversationManager = CloudConversationManager(),
        conversationSelectionProvider: @escaping () -> CloudConversationSelection = { .wakeWord }
    ) {
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.conversationManager = conversationManager
        self.conversationSelectionProvider = conversationSelectionProvider

        self.playbackManager = playbackManager
        self.playbackSink = playbackSink
        self.fingerprintMapper = fingerprintMapper
        self.playbackPositionMs = playbackPositionMs
        self.cloudPlaybackContextState = cloudPlaybackContextState
        self.analytics = analytics
        self.rendersStructuredResults = rendersStructuredResults
        self.routeHintProvider = routeHintProvider
        self.recentConversationProvider = recentConversationProvider
        self.resultsPresenter = resultsPresenter
        self.operationResultConsumer = operationResultConsumer
        self.operationJournal = operationJournal
        self.spokenTemplates = spokenTemplates
        // Assigned last, and its delegate is set after every stored property is
        // initialized: `audioPlayer.delegate = self` reads `self` to make the
        // delegate reference, which Swift forbids before the initializer fully
        // initializes `self`.
        let resolvedAudioPlayer = audioPlayer ?? CloudAudioPlayer()
        self.audioPlayer = resolvedAudioPlayer
        resolvedAudioPlayer.delegate = self
    }

    /// Renders a negotiated discovery result (result / no-match). Rendering
    /// never initiates playback — selection goes through
    /// `DiscoverySelectionHandler`.
    func presentDiscoveryResults(_ model: DiscoveryResultsViewModel) {
        resultsPresenter?.present(model)
    }

    func routeToCloud(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?,
        preparedObserver: PreparedObserver? = nil
    ) async -> CloudRouteResult {
        // Recorded BEFORE any guard: what selected this turn is a property of the TURN, not of
        // whether the sink happens to be configured. Recording after the configured check made
        // the seam blind to exactly the refused turns a caller-level case most needs to observe.
        MainActor.assumeIsolated {
            lastSelectionForTesting = selection ?? (try? conversationSelectionProvider())
            lastOriginForTesting = origin
        }
        guard isConfigured() else {
            // Same rule as the error path: a client-authored message is spoken
            // only in the user's own locale (spec ruling 2026-09-24).
            let comingSoon = spokenTemplates.resolveForUserLocale("general.cloud_coming_soon")
            return CloudRouteResult(
                response: comingSoon.isEmpty ? .earcon(.error) : .spoken(comingSoon),
                outcome: .refused
            )
        }

        // The conversation identity is prepared FIRST, before anything this turn can disturb.
        // A nil result means the origin is NOT LIVE: this turn has no claim on any conversation,
        // so it is refused — and it must be refused before touching successor-owned state. The
        // supersede block below cancels the in-flight turn and claims `activeTurn`; running that
        // for a turn that is then refused would let a stale dispatch CANCEL a live successor and
        // leave the sink pointing at a token nobody will ever complete.
        let effectiveSelection = selection ?? conversationSelectionProvider()
        let conversation: CloudPreparedConversation
        do {
            guard let prepared = conversationManager.prepare(
                // The captured selection when the caller supplied one; the provider is the
                // fallback for callers that did not, which is the late-reading behaviour this
                // replaces.
                selection: effectiveSelection,
                origin: origin
            ) else {
                return CloudRouteResult(response: .silent, outcome: .refused)
            }
            conversation = prepared
            preparedObserver?(prepared)
        }

        let client = clientFactory()
        let routeContext = CloudRouteContext(from: context)

        // Supersede any in-flight turn (double wake / barge-in) before touching
        // shared per-turn state. Only a turn that will actually run supersedes.
        let turnToken = CloudTurnToken()
        activeTurn?.cancel()
        activeTurn = turnToken

        let turn = CloudTurnEnvelope.make(
            capabilities: CloudClientCapabilities.advertised(rendersStructuredResults: rendersStructuredResults),
            routeHint: routeHintProvider(),
            recentConversation: recentConversationProvider(),
            conversation: conversation
        )
        // NOTHING IS RETAINED FOR REPLAY. An earlier version kept the prepared request so a retry
        // could re-drive it, and that retention IS what made replay possible: a completed or
        // possibly-submitted request left on the books is exactly what a replay path would find.
        // With no producer able to establish that a frame was never submitted, the honest state is
        // to retain nothing, and there is no retry entry point left to consume one.
        //
        // The sink therefore has ONE path: prepare a turn, dispatch it, handle its events, report
        // its outcome. Nothing here implies a second attempt is possible.

        // Per-turn quote state is turn-scoped: without this reset a `stop_quote`
        // in a turn that issued no `play_quote` would seek to a previous turn's
        // captured position (task #12 PR review).
        preQuotePositionMs = nil

        // Hold the place for the turn: the server decides when the assistant
        // speaks, so the client does not pause on its own for a turn that may
        // not produce audio. The hold is only ours to release if it stopped
        // playback that was already running.
        //
        // A superseded turn leaves its hold in place (it returns without
        // restoring, deliberately: the winning turn does that). `isPlaying` is
        // therefore already false, and reading it here would lose the hold —
        // the user would be left paused for good. Inherit the outstanding hold
        // instead, so this turn releases it exactly once at its own end.
        if didAutoPause && wasPlayingBeforeHold {
            // Turn B started while A's hold was still in effect: B owns the
            // release now (A must not also resume — see the supersede tests).
            didAutoPause = true
        } else {
            wasPlayingBeforeHold = playbackSink.isPlaying
            if wasPlayingBeforeHold {
                _ = playbackSink.pause()
                didAutoPause = true
            }
        }

        let routed = client.routeWithResultSocket(request: request, context: routeContext, turn: turn)
        // The turn's own result socket: sends bind to THIS registration, so a superseded turn's
        // late results can never ride a successor's socket.
        activeResultSocket = routed.resultSocket
        resultSendClient = client

        // The consumer takes ownership of the turn socket here: the bounded never-consumed
        // cleanup no longer applies, however long this turn's awaited effect/result takes.
        routed.resultSocket.claimConsumerOwnership()
        // Cancellation cleanup is bound to THIS turn's token — the cancellation state of the
        // task that owns consumer execution — not to AsyncStream termination (which never fires
        // on task cancellation). If the turn is cancelled while suspended in action or result
        // handling, the watcher retires the registration within one poll tick, idempotently and
        // tied to the original registration identity. The journal is deliberately untouched: a
        // claimed-but-unfinished operation stays `.in_progress` on disk, so a restart
        // reconstructs `unknown` — never a fabricated `cancelled`.
        let resultSocket = routed.resultSocket
        // The watcher runs on its OWN task, so it must observe the OWNER's cancellation directly
        // (control-armed box) alongside the turn token: a consumer suspended inside action
        // handling never reaches a throwing suspension point, and without this the registration
        // would outlive the cancelled owner.
        // Observation uses the SAME lock-guarded mechanism as production close paths: an
        // unstructured poller cannot observe the owner task's cancellation (no legal API), so it
        // mirrors `withTaskCancellationHandler` — the handler runs synchronously at cancel time.
        // The flag is checked under the lifetime's closeLock by `closeIfOwnerCancelled`, so a
        // consumer suspended inside held work still retires the ORIGINAL registration promptly.
        // Observation uses the SAME mechanism production close paths use: withTaskCancellationHandler's
        // onCancel runs synchronously at cancel time on the owning task. The flag is guarded so the
        // watcher (and any later check) sees cancellation immediately, even while the consumer is
        // suspended inside held work with no throwing suspension point to reach.
        // The consumer is wrapped in a cancellation handler installed on the OWNING task, so its
        // `onCancel` fires synchronously at cancel time — the only legal observation of another
        // task's cancellation. Held work therefore sees the flag immediately after any release,
        // and the turn-wide cleanup plus this post-loop check retire the ORIGINAL registration
        // before the loop can return normally on a cancelled turn.
        let ownerCancelledFlag = OwnerCancelFlag()
        currentOwnerCancelFlag = ownerCancelledFlag

        // ONE turn-wide cleanup covering EVERY exit — normal end, break, early return, error,
        // token cancellation: retire the registration idempotently. Never per-action: a second
        // action, audio, and done must all keep riding the same live socket. Prompt retirement on
        // OWNER cancellation is NOT delivered by a poller here — it is performed synchronously by
        // the owning task's cancellation handler below (the only legal observation of another
        // task's cancellation), so no unstructured polling task exists to mask it.
        defer {
            routed.resultSocket.finishTurn()
            currentOwnerCancelFlag = nil
        }
        // Loop-exit immediate check: `onCancel` fires synchronously at cancel time and marks the
        // flag; when the suspended loop returns here after cancellation, retire the ORIGINAL
        // registration NOW — before any release-dependent held work can reach its effect check.
        if ownerCancelledFlag.isSet || Task.isCancelled {
            activeResultSocket?.finishTurn()
        }
        var turnResult: CloudRouteOutcome?
        var turnResponse: VoiceResponse = .silent
        await withTaskCancellationHandler {
            turnLoop: for await event in routed.stream {
                // Superseded mid-stream: stop consuming so this turn cannot execute
                // late actions or overwrite the new turn's state. The stream's own
                // termination closes the transport. (`break turnLoop` — a bare
                // `break` inside the switch would only leave the switch.)
                // OWNER-CANCELLATION GATE before ANY admission: connected/audioFrame/action/done/
                // error and their result sends ALL refuse buffered work once the owning Task is
                // cancelled — not only action/done. Post-loop classification returns earlyClose.
                if ownerCancelledFlag.isSet || Task.isCancelled || turnToken.isCancelled { break turnLoop }
                switch event {
                case let .connected(codec):
                    // The server names the codec for this turn's binary frames;
                    // the player decodes at that rate rather than the hardware's.
                    audioPlayer.setNegotiatedCodec(codec)
                case let .audioFrame(frame):
                    // Owner cancellation gates buffered audio admission too: a frame drained
                    // after cancel must not reach the player.
                    if ownerCancelledFlag.isSet || Task.isCancelled { break turnLoop }
                    audioPlayer.enqueue(frame)
                case let .action(tool, action, params, operationId, capabilityVersion):
                    // BUFFERED ADMISSION CHECK: an event drained from the buffer after the owner
                    // was cancelled must not admit any later effect or a completed result. The
                    // handler's mark (or Task.isCancelled) stops consumption here; the turn is
                    // classified earlyClose below, never `completed`.
                    if ownerCancelledFlag.isSet || Task.isCancelled { break turnLoop }
                    await executeAction(
                        tool: tool, action: action, params: params,
                        operationId: operationId, capabilityVersion: capabilityVersion
                    )
                // .token is no longer accumulated — cloud answers are played as
                // audio, not text (spec: "cloud answers are played, not spoken").
                case .token:
                    break
                case let .result(result):
                    // Structured results are rendered as they arrive; the turn still
                    // completes on `done` with the same restore/analytics behavior.
                    presentDiscoveryResults(DiscoveryResultsViewModel(result: result))
                case let .done(usage):
                    // Buffered-`done` admission check: a cancelled owner must not report a
                    // completed result for an event drained after cancellation (mirrors the
                    // action guard above; earlyClose classification follows below).
                    if ownerCancelledFlag.isSet || Task.isCancelled { break turnLoop }
                    guard !turnToken.isCancelled else { break turnLoop }
                    analytics?.recordCloudAssistantTurn(
                        outcome: "done",
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens
                    )
                    // Restore playback only once the answer has stopped coming out
                    // of the speaker: `done` means the server has finished sending,
                    // not that the client has finished playing, so restoring here
                    // would resume the episode under the answer's tail. With nothing
                    // left to play the drain is a no-op and the restore is immediate.
                    // The turn's own drain is scheduled by `finish()`, and that is when the drain's
                    // identity is pinned — so the deferral must be recorded AFTER it, with the epoch
                    // that `finish()` just assigned. Recording before would capture the PREVIOUS
                    // cycle's identity and reject this turn's own notification.
                    let needsDeferral = audioPlayer.hasPendingAudio
                    // Record the identity `finish()` ALLOCATED for this turn's drain. Re-reading the
                    // current value could pick up a later schedule, leaving this turn waiting on an
                    // identity that is not its own.
                    let scheduledEpoch = audioPlayer.finish()
                    if needsDeferral {
                        restoreHeldForPlayerDrain = (owner: turnToken, drainEpoch: scheduledEpoch)
                    } else {
                        restoreTransientAudioState()
                    }
                    turnResult = .completed
                    turnResponse = .silent
                    break turnLoop
                case let .error(_, code, message):
                    guard !turnToken.isCancelled else { break turnLoop }
                    audioPlayer.cancel()
                    restoreTransientAudioState()
                    analytics?.recordCloudAssistantTurn(outcome: "error", inputTokens: nil, outputTokens: nil)
                    // A server-supplied message passes through (localising it is the
                    // server's job). When the client generated the diagnostic it
                    // carries a code and an empty message instead of English prose:
                    // resolve a localized template for that code if one exists, and
                    // fall back to the error earcon when it doesn't (PR #19 review).
                    // Whitespace-only counts as absent: a server message of spaces
                    // would otherwise be "spoken" as silence, occupying the turn's
                    // only feedback channel (PR #19 review).
                    let serverMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    let spoken = serverMessage.isEmpty
                        ? spokenTemplates.resolveForUserLocale("cloud_error_\(code)")
                        : serverMessage
                    turnResult = .failed(code: code)
                    turnResponse = spoken.isEmpty ? .earcon(.error) : .spoken(spoken)
                    break turnLoop
                }
            }
        } onCancel: {
            // Fires SYNCHRONOUSLY at owning-Task cancellation — the only legal observation of
            // another task's cancel. Cancellation itself performs the cleanup: mark the flag AND
            // retire the ORIGINAL registration immediately, even while the consumer stays
            // suspended in held work (retirement must not wait for eventual loop exit). The
            // lifetime close is idempotent and identity-checked, so the turn-wide defer and any
            // later path re-running it is harmless; a successor turn's socket is never touched.
            ownerCancelledFlag.mark()
            resultSocket.finishTurn()
        }
        if let turnResult {
            return CloudRouteResult(response: turnResponse, outcome: turnResult)
        }
        if turnToken.isCancelled {
            // The superseding turn owns pause/restore and analytics. Superseded is not a
            // completion: the winner's turn decides the window, and reporting this one as
            // completed would let a turn that was cancelled mid-stream reopen it.
            return CloudRouteResult(response: .silent, outcome: .earlyClose)
        }
        restoreTransientAudioState()
        // The stream ended without `done`: the turn was truncated, which is not a
        // completion and must not restore the allowance as though the model answered.
        return CloudRouteResult(response: .silent, outcome: .earlyClose)
    }

    private func restoreTransientAudioState() {
        // Release only a hold we took, and only if it stopped playback the user
        // was already hearing. A hold that cannot be told apart from the user's
        // own pause must not be released — resuming here would start audio the
        // user asked to stop.
        if didAutoPause && wasPlayingBeforeHold {
            _ = playbackSink.resume()
        }
        didAutoPause = false
        wasPlayingBeforeHold = false
        // Seek positions are intentionally not rolled back.
    }

    private func executeAction(
        tool: String,
        action: String,
        params: [String: CloudRouteJSONValue],
        operationId: String?,
        capabilityVersion: String?
    ) async {
        guard tool == "playback" else { return }
        await executeCloudMutation(
            action: action, params: params,
            operationId: operationId, capabilityVersion: capabilityVersion
        )
    }

    /// The wire contract's runtime gate (rev da327e624 §1): every cloud app operation carries
    /// `operation_id` and `capability_version`; an identity-less app operation does NOT execute
    /// as a legacy fallback — it is refused (no mutation) and the refusal is reported.
    private func executeCloudMutation(
        action: String,
        params: [String: CloudRouteJSONValue],
        operationId: String?,
        capabilityVersion: String?
    ) async {
        guard let operationId, !operationId.isEmpty, capabilityVersion != nil else {
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.unsupportedOperation)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion)
            return
        }
        // Exactly-once: the durable claim happens BEFORE the effect, so an interruption leaves a
        // reconstructible record (`.interrupted` → `unknown`) rather than a silent re-run.
        switch operationJournal?.claim(operationId) ?? .claimed {
        case .alreadyRun(let recorded):
            await reportResult(recorded, operationId: operationId, capabilityVersion: capabilityVersion)
            return
        case .inProgress:
            return
        case .interrupted(let result):
            // The effect is not knowable: answer `unknown`, never re-execute.
            await reportResult(result, operationId: operationId, capabilityVersion: capabilityVersion)
            return
        case .persistenceUnavailable:
            // Fail closed: the exactly-once record could not be durably persisted (or durable
            // history is unreadable). Refuse before any effect — never execute unrecorded.
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.persistenceUnavailable)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion)
            return
        case .claimed:
            break
        }
        // Test-only deterministic hold between the durable claim and the effect (nil in
        // production assembly). Production cancellation policy around it: after ANY suspension,
        // check the owning Task's cancellation BEFORE starting the effect. A cancelled owner
        // must never execute merely because the final result is journalable. On pre-effect
        // cancellation the ORIGINAL registration is retired immediately (prompt retirement while
        // still held in action handling) and the claimed-but-unexecuted operation stays durably
        // IN PROGRESS — no settlement here: this process reports `unknown`, and a restart
        // reconstructs the same honest unknown. Never a replay, never a fabricated outcome.
        // DETERMINISTIC CLAIM BOUNDARY (control-only): the durable claim above has COMMITTED.
        // The OWNER awaits the hold here, so the suspension is the owner's own and "held" is a
        // fact about the owner rather than about a detached task. Cancellation is observed by the
        // ordinary post-suspension check below, once this returns.
        if let effectGate {
            await effectGate(operationId)
        }
        if Task.isCancelled || ownerCancelledNowForCurrentTurn {
            // Immediate, synchronous retirement of the ORIGINAL registration (idempotent; the
            // turn-wide defer re-runs it harmlessly): the held work cannot proceed to the effect
            // on a live socket and late results report undelivered against the retired identity.
            activeResultSocket?.finishTurn()
            let unexecuted = OperationResult.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)
            await reportResult(unexecuted, operationId: operationId, capabilityVersion: capabilityVersion)
            return
        }
        let refusal = performMutation(action: action, params: params)
        if let refusal {
            // Observe refusal settlement too: a failed refusal-persist leaves the durable
            // record in progress, so the honest report is unknown, never a replayable refusal.
            let settled = operationJournal?.complete(operationId, result: refusal) ?? true
            recordSeekRejection(refusal)
            if settled {
                await reportResult(refusal, operationId: operationId, capabilityVersion: capabilityVersion)
            } else {
                let unsettled = OperationResult.nonSuccess(.unknown, reason: OperationReason.persistenceUnavailable)
                await reportResult(unsettled, operationId: operationId, capabilityVersion: capabilityVersion)
            }
        } else {
            // Persist the settlement FIRST and observe it: a failed settlement write must not
            // be reported as success — the durable record is still in progress, so the honest
            // answer is unknown, never a replayable success.
            let settled = operationJournal?.complete(operationId, result: .succeeded) ?? true
            if settled {
                await reportSuccess(operationId: operationId, capabilityVersion: capabilityVersion)
            } else {
                let unsettled = OperationResult.nonSuccess(.unknown, reason: OperationReason.persistenceUnavailable)
                await reportResult(unsettled, operationId: operationId, capabilityVersion: capabilityVersion)
            }
        }
    }

    /// Runs the mutation. Returns the refusal to record (nil = executed).
    private func performMutation(action: String, params: [String: CloudRouteJSONValue]) -> OperationResult? {
        switch action {
        case "seek_to":
            // Two forms, per the wire contract's schema (app_operation_schema_map 11993ca):
            // "ordinary" carries position_seconds in SINK time and seeks directly;
            // "reference_target" carries reference_position_ms and requires the validated
            // mapping. Both or neither is a malformed request, not a default to guess.
            let sinkSeconds = params["position_seconds"]?.int64Value
            let referenceMs = params["reference_position_ms"]?.int64Value
            switch (sinkSeconds, referenceMs) {
            case (let seconds?, nil):
                seekToSinkSeconds(seconds)
                return nil
            case (nil, let reference?):
                capturePreActionPosition(referenceMs: reference)
                return seekToReference(reference)
            default:
                return .nonSuccess(.refused, reason: OperationReason.malformedSeekTarget)
            }
        // Serve the quote. This does not take or release the hold: the quote
        // plays over playback the server has already ducked, and the turn's end
        // is the release (Task 12). Resuming here would end the duck early.
        case "play_quote":
            guard let referenceMs = params["reference_position_ms"]?.int64Value else { return nil }
            capturePreActionPosition(referenceMs: referenceMs)
            return seekToReference(referenceMs)
        case "stop_quote":
            guard let restoreMs = preQuotePositionMs else { return nil }
            let seconds = Int((Double(restoreMs) / 1000.0).rounded())
            _ = playbackSink.seekTo(positionSeconds: seconds)
            return nil
        case "seek_relative":
            // Per the recovery contract (PR 59, cloud-seek-relative):
            // Capture previous position so "go back to where I was" works
            // after a relative seek.
            capturePreActionPositionForRelativeSeek()
            // Zero delta is treated as "no stated amount" — the sink
            // applies its interval in the request's direction.
            let delta = params["delta_seconds"]?.int64Value
                .flatMap { Int($0) == 0 ? nil : Int($0) }
            // The parameter is a `CloudRouteJSONValue`; take its string. Typing
            // this as `String?` rather than `Any?` makes the compiler reject the
            // next call site that passes the wrapper where a string is wanted.
            let direction = seekDirectionOf(delta: delta, declared: params["direction"]?.stringValue)
            _ = playbackSink.seekRelative(deltaSeconds: delta, direction: direction)
            return nil
        case "pause":
            _ = playbackSink.pause()
            didAutoPause = false
            return nil
        case "resume":
            _ = playbackSink.resume()
            didAutoPause = false
            return nil
        default:
            return nil // unknown action ignored (forward compatibility)
        }
    }

    /// Reports an outcome through the turn's bound transport, keyed to the server-issued identity.
    /// The consumer surface also fires (generic, transport-less contexts).
    private func reportResult(
        _ result: OperationResult,
        operationId: String?,
        capabilityVersion: String?
    ) async {
        guard let operationId, let socket = activeResultSocket else { return }
        guard let frame = AppOperationResultFrame(
            operationId: operationId,
            outcome: result.outcome,
            reason: result.reason
        ) else { return }
        _ = capabilityVersion // validated at the gate; rides the action frame, not the result
        // AWAITED inside the turn loop: a fire-and-forget Task can be scheduled after the turn's
        // socket closed, turning a deliverable result into a spurious undelivered (measured).
        guard let client = resultSendClient else {
            return
        }
        let report = await client.sendOperationResult(frame, via: socket)
    }

    /// Diagnostic: this turn's bound result socket handle.


    /// Success carries the ACTUAL resulting state, typed per the owning family (wire contract §3):
    /// playback seeks state position and playing; identity-less successes cannot occur (the gate).
    private func reportSuccess(operationId: String, capabilityVersion: String?) async {
        guard let socket = activeResultSocket,
              let frame = AppOperationResultFrame(
                operationId: operationId, outcome: .succeeded,
                state: [
                    "position_seconds": .int(playbackPositionMs() / 1000),
                    "playing": .bool(playbackSink.isPlaying),
                ]
              ) else { return }
        _ = capabilityVersion
        guard let client = resultSendClient else { return }
        _ = await client.sendOperationResult(frame, via: socket)
    }

    private func capturePreActionPosition(referenceMs: Int64) {
        let previous = playbackPositionMs()
        preQuotePositionMs = previous
        cloudPlaybackContextState.record(
            referencePositionMs: referenceMs,
            previousReferencePositionMs: previous
        )
    }

    /// Records that a reference-time seek could not be mapped to playback time.
    ///
    /// The unavailable mapping is the operation's outcome: no position was changed, and the
    /// reason the server is told is that this client cannot convert the target — not that it
    /// sought somewhere arbitrary.
    private func recordReferenceSeekUnavailable(referenceMs: Int64) {
        unavailableReferenceSeek = OperationResult.nonSuccess(
            .refused,
            reason: OperationReason.referenceMappingUnavailable
        )
    }

    /// The most recent unavailable-reference-seek outcome, consumed by the executor.
    private(set) var unavailableReferenceSeek: OperationResult?

    /// Production surface for every recorded non-success outcome (see
    /// `CloudOperationResultConsuming`). Optional: a sink without a transport still records.
    private var operationResultConsumer: CloudOperationResultConsuming?

    /// This turn's bound result socket (nil between turns). Sends via it are bound to the
    /// original registration — late results from a superseded turn never ride a successor.
    /// Set at turn start from the caller-supplied owning Task; refreshed by the pre-effect
    /// cancellation check sites. The watcher polls it so retirement does not depend on the
    /// consumer reaching a suspension point.
    /// Read-only test seam: the socket whose lifetime the current turn owns (nil between turns).
    var currentTurnResultSocketForTesting: AppOperationResultSocket? { activeResultSocket }

    private var activeResultSocket: AppOperationResultSocket?

    /// Exactly-once records for server-identified operations (wire contract rev da327e624).
    /// Nil = this sink has no journal (assembly wires the durable store).
    private var operationJournal: OperationJournal?

    /// The client this turn routed on — result sends ride the SAME client/socket.
    private var resultSendClient: CloudRouteClient?

    /// Capture the current playback position before a relative seek so that a
    /// subsequent "go back to where I was" restores the correct place. The
    /// recovery contract (PR 59, cloud-seek-relative) requires this for all
    /// relative seeks — not just `seek_to` / `play_quote`.
    private func capturePreActionPositionForRelativeSeek() {
        let previous = playbackPositionMs()
        preQuotePositionMs = previous
    }

    /// Resolve seek direction when a relative seek arrives.
    ///
    /// Per the recovery contract: the delta's sign is authoritative when a
    /// delta is present; `direction` decides only when it is absent. A request
    /// that stated neither takes the app's default forward interval.
    private func seekDirectionOf(delta: Int?, declared: String?) -> SeekDirection {
        if let delta {
            return delta < 0 ? .backward : .forward
        }
        if declared == "backward" { return .backward }
        if declared == "forward" { return .forward }
        return .forward // default: app's configurable interval
    }

    /// Seeks to an absolute position in SINK time — the ordinary form, no mapping involved.
    ///
    /// Signed values are allowed: the duration-aware sink overload resolves a negative
    /// position as an offset back from the episode end, matching how the local path behaves.
    private func seekToSinkSeconds(_ seconds: Int64) {
        let durationSeconds = Int(playbackManager?.duration().rounded() ?? 0)
        _ = playbackSink.seekTo(positionSeconds: Int(seconds), episodeDurationSeconds: durationSeconds)
    }

    private func recordSeekRejection(_ result: OperationResult) {
        lastSeekRejection = result
        operationResultConsumer?.consume(result, context: "seek/parameters")
    }

    /// The most recent malformed-seek rejection, consumed by the executor.
    @MainActor private(set) var lastSeekRejection: OperationResult?

    private func seekToReference(_ referenceMs: Int64) -> OperationResult? {
        let referenceSeconds = Double(referenceMs) / 1000.0
        // Reference time is not playback time. The two happen to coincide on an unmapped
        // episode, but taking the fallback when the mapping is *missing* silently seeks to a
        // position the server never asked for — on a mapped episode that is the wrong place,
        // and nothing downstream can tell it apart from a correct seek. So an unavailable
        // mapping is reported as unavailable rather than converted by assumption.
        guard let playbackSeconds = fingerprintMapper.playbackTime(forReferenceTime: referenceSeconds) else {
            recordReferenceSeekUnavailable(referenceMs: referenceMs)
            return unavailableReferenceSeek
        }
        let seconds = Int(playbackSeconds.rounded())
        // Negative positionSeconds is an offset back from the episode end.
        // Use the duration-aware overload so the sink resolves and bounds it.
        let durationSeconds = Int(playbackManager?.duration().rounded() ?? 0)
        _ = playbackSink.seekTo(positionSeconds: seconds, episodeDurationSeconds: durationSeconds)
        return nil
    }
}

// MARK: - CloudAudioPlayer.Delegate

extension CloudRouteSink {
    func audioPlayerDidStartPlaying() {
        // Audio started — the sink doesn't need to react; the player
        // already managed the AVAudioEngine and playbackSink ducking
        // is handled by the sink's own pause/resume on action events.
    }

    func audioPlayerDidPause() {
        // Audio paused due to buffer underrun — the sink doesn't need
        // to react; the player will resume automatically when new
        // frames arrive.
    }

    func audioPlayerDidStop(drainEpoch: Int) {
        // The player has drained its buffer and stopped output. This is when a
        // hold taken for the turn may be released, so the answer is not played
        // over the resumed episode, and the turn's held state stays consistent
        // even though the sink has already returned to its caller.
        //
        // OWNERSHIP: act only for the turn that DEFERRED. A successor that inherited the hold has
        // already taken it over (it keeps `didAutoPause`), so once ownership moves on, a
        // notification belonging to the earlier turn must not release the newer turn's hold. The
        // inherited transfer itself is unchanged — a turn that owns the hold still restores it,
        // whether it took the hold or inherited it.
        guard let deferred = restoreHeldForPlayerDrain else { return }
        // The notification must belong to the drain this turn is waiting on. A foreign drain's
        // notification is rejected on its own identity, and the record is LEFT INTACT so the turn
        // that does own it is not robbed of its restoration.
        guard deferred.drainEpoch == drainEpoch else {
            return
        }
        // ...and the deferring turn must still own the release.
        guard activeTurn == nil || activeTurn === deferred.owner else {
            return
        }
        restoreHeldForPlayerDrain = nil
        restoreTransientAudioState()
    }
}
