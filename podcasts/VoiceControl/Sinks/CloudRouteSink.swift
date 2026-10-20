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
    /// The ownership INSTANCE currently owning an utterance's record, for controls that must
    /// prove a stale token no longer owns it (reviewer b2c09394).
    func recordInstanceForTesting(utteranceId: String) -> UUID? {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return recordsByUtteranceId[utteranceId]?.instance
    }
    /// True when a live record exists for the utterance.
    func hasLiveRecordForTesting(utteranceId: String) -> Bool {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return recordsByUtteranceId[utteranceId] != nil
    }
    /// Await a joiner's resolution against an admission token, for controls (reviewer 8501bd91).
    func joinForTesting(token: CloudDispatchOwnership.DispatchToken) async -> CloudRouteResult? {
        await resolveJoin(token: token)
    }
    /// The terminal result held on the record a token was admitted against, if any — so a control
    /// can observe the ORIGINAL owner's settlement rather than a generic refusal (reviewer
    /// be89233d). Nil when the token carries no record.
    func terminalResultForTesting(token: CloudDispatchOwnership.DispatchToken) -> CloudRouteResult? {
        token.record?.terminalResult
    }
    /// The record instance a token is bound to, for controls.
    func tokenRecordInstanceForTesting(token: CloudDispatchOwnership.DispatchToken) -> UUID? {
        token.record?.instance
    }
    /// Whether the STALE owner started a wire turn: counted through the client factory.
    @MainActor var wireDispatchCountForTesting: Int { clientCreationCountForTesting }
    @MainActor var clientCreationCountForTesting: Int = 0

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
    /// Injectable episode-AVAILABILITY source (test seam); nil falls back to the manager.
    private let episodeAvailable: (() -> Bool)?

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
    /// THIS sink's live playback hold. Acquired at the turn's admitted dispatch; ownership
    /// TRANSFERS atomically (begin-successor BEFORE end-predecessor) when a new turn is admitted,
    /// so a successor never runs hold-free between turns. Released at every terminal: error,
    /// superseded/earlyClose, done-without-pending, and the real drain/stop.
    private var heldPlaybackToken: GracePeriodSignal.PlaybackHoldToken?
    /// A rolled-back admission's hold, kept live until the retire stop it is waiting on
    /// CONFIRMS (review 8eb9fb44): the hold is the last live one over the predecessor's
    /// still-outstanding output, so its release responsibility transfers to the stop
    /// confirmation instead of firing at rollback time.
    private var pendingHoldRelease: (hold: GracePeriodSignal.PlaybackHoldToken, epoch: Int)?
    var pendingHoldReleaseEpochForTesting: Int? { pendingHoldRelease?.epoch }
    private let onGracePlaybackHoldBegin: ((Int?) -> GracePeriodSignal.PlaybackHoldToken?)?
    private let onGracePlaybackHoldEnd: ((GracePeriodSignal.PlaybackHoldToken?) -> Void)?
    /// The in-flight turn. A new turn supersedes it: the older turn stops
    /// consuming its stream and stops touching playback/analytics state, so two
    /// overlapping turns (double wake, barge-in) cannot interleave actions or
    /// double-restore the pause.
    private var activeTurn: CloudTurnToken?
    /// PLAYBACK ownership, distinct from consumer-Task lifetime (review 14f66b72): a turn that
    /// finished its NETWORK work can still own pending player audio (a deferring drain), so a
    /// successor must retire THAT even though `activeTurn` is already gone. Set at each
    /// admission transfer; never cleared on completion — retirement is by the next transfer.
    private var playbackOwner: CloudTurnToken?
    /// The stop identity each predecessor's retirement requested, captured AT THE TRANSFER and
    /// associated with the predecessor's token (review 14f66b72): the superseded turn's cleanup
    /// awaits ITS OWN captured identity — never the shared latest counter, which later stops
    /// move.





    /// Cancellation handle for one logical turn.
    final class CloudTurnToken: Hashable {
        private let lock = NSLock()
        private var cancelled = false
        /// The retire identity captured for THIS turn at the successor's admission transfer
    /// (review 14f66b72): stored ON the token so it lives exactly as long as the suspended
    /// turn that must await it — no shared table to reap, and no reap can discard it early.
    private let tokenLock = NSLock()
    private var capturedRetireEpochStorage: Int?
    var capturedRetireEpoch: Int? {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return capturedRetireEpochStorage }
        set { tokenLock.lock(); capturedRetireEpochStorage = newValue; tokenLock.unlock() }
    }
    /// Identity for the captured-retire table: object identity (a token is never reused).
        nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
        nonisolated static func == (lhs: CloudTurnToken, rhs: CloudTurnToken) -> Bool {
            lhs === rhs
        }

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
        episodeAvailable: (() -> Bool)? = nil,
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
        conversationSelectionProvider: @escaping () -> CloudConversationSelection = { .wakeWord },
        // Grace contract (token ownership holds): from the ADMITTED DISPATCH through done and the
        // actual drain/stop, the turn's window expiry is SUSPENDED and resumes EXACTLY ONCE when
        // the last hold releases. Identity is bound at acquisition (live generation only); release
        // is per-token, so a stale terminal never clears another owner's hold. Optional so
        // direct-constructed sinks in tests opt in.
        onGracePlaybackHoldBegin: ((Int?) -> GracePeriodSignal.PlaybackHoldToken?)? = nil,
        onGracePlaybackHoldEnd: ((GracePeriodSignal.PlaybackHoldToken?) -> Void)? = nil
    ) {
        self.onGracePlaybackHoldBegin = onGracePlaybackHoldBegin
        self.onGracePlaybackHoldEnd = onGracePlaybackHoldEnd
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.conversationManager = conversationManager
        self.conversationSelectionProvider = conversationSelectionProvider

        self.playbackManager = playbackManager
        self.playbackSink = playbackSink
        self.fingerprintMapper = fingerprintMapper
        self.playbackPositionMs = playbackPositionMs
        self.episodeAvailable = episodeAvailable
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

    // REQUEST OWNERSHIP (owner delta 3484cbc/5eca874, reviewer 39beabc7/a2723c92): one logical
    // dispatch per utterance. A duplicate invocation for the SAME utterance joins the owner (in
    // flight) or observes its settled result — never a second wire request. INDEPENDENT
    // utterances dispatch independently.
    //
    // RETENTION. Per-utterance OWNERSHIP RECORDS live for the WINDOW's lifetime with no cap and
    // no eviction. A window change does NOT destroy in-flight records: a held duplicate joiner
    // must still be settled by its owner, so in-flight records survive retirement and are
    // settled with that owner's result; only SETTLED records and effect claims retire. Each
    // record carries an ownership INSTANCE, so a late owner completing after its window retired
    // cannot publish into the successor's map — it settles its own waiters and stops.
    private let ownershipLock = NSLock()

    /// One OWNERSHIP RECORD per utterance dispatch. It carries the ownership INSTANCE that
    /// admission tokens bind to, ONE terminal state, and an explicit reference count of the
    /// admitted callers that still need its result — so a detached record is released as soon as
    /// no admitted caller needs it, with no immortal second map (reviewer be89233d).
    final class UtteranceRecord {
        let origin: Int?
        let instance = UUID()
        /// The record's ONE terminal state: nil until it settles, then the result it settled with.
        /// A retired record keeps its terminal result for its admitted joiners.
        var terminalResult: CloudRouteResult?
        /// Admitted callers (owner + joiners) that have NOT yet resolved. The record leaves the
        /// live map on retirement, and is RELEASED (dropped from its owner's retention) once this
        /// reaches zero AND the record is terminal.
        var outstandingCallers: Int = 0
        /// Admitted callers parked awaiting this record's terminal result.
        var waiters: [CheckedContinuation<CloudRouteResult, Never>] = []
        /// True once the OWNER has begun `routeToCloudOwned`; before that the record exists only
        /// because the owner claimed it, and the claiming caller is still the owner.
        var dispatchStarted = false
        /// True when retirement detached this record from the live map. A detached record answers
        /// only its admitted callers and never stands in for a successor's map entry.
        var detached = false
        init(origin: Int?) { self.origin = origin }
        var isTerminal: Bool { terminalResult != nil }
    }
    private var recordsByUtteranceId: [String: UtteranceRecord] = [:]
    /// Retirement detaches records from the live map; each record is held ONLY by the ownership
    /// tokens that were admitted against it (owner + joiners), and is released by the last of
    /// them to resolve. There is no separate long-lived map to leak.
    /// The window identity the retained SETTLED results belong to.
    private var retainedOrigin: Int?

    /// Retires the retained dispatch state when the grace window changes (or ends). SETTLED
    /// results and effect claims retire with the window — a new window starts clean. IN-FLIGHT
    /// records are RETAINED so their held joiners are still settled by their owner; they accept
    /// no new joiners and cannot publish into the new window.
    func retireRetainedDispatchesIfWindowChanged(to origin: Int?) {
        ownershipLock.lock()
        if origin != retainedOrigin {
            // Every record belongs to the OLD window. Detach them ALL from the live map: a
            // detached record accepts no new joiners and, crucially, must not block a same-id
            // utterance in the NEW window. Each detached record is still reachable through the
            // ownership TOKENS admitted against it, so its admitted callers resolve against it and
            // it is RELEASED by the last of them (reviewer be89233d) — no immortal second map.
            for record in recordsByUtteranceId.values { record.detached = true }
            recordsByUtteranceId.removeAll()
        }
        retainedOrigin = origin
        ownershipLock.unlock()
    }

    /// Admits a dispatch for the utterance and returns its ownership token ATOMICALLY, fenced by
    /// the LIVE origin, which is validated BEFORE any record is inspected so a stale caller can
    /// never observe or join a successor's record (reviewer 8501bd91).
    ///
    /// The returned token CARRIES the record it was admitted against, so a caller that pauses and
    /// resumes after a window change still resolves against ITS OWN record — a reused utterance id
    /// is never mistaken for the same owner (reviewer 8501bd91/be89233d).
    func beginDispatch(utteranceId: String?, origin: Int?) -> CloudDispatchOwnership {
        guard let utteranceId else {
            // No identity: legacy per-call effects, no join semantics, no retained record.
            return .owner(.init(utteranceId: "", instance: UUID(), record: nil))
        }
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        guard let origin, origin == conversationManager.liveOriginForTesting else { return .refused }
        if let record = recordsByUtteranceId[utteranceId] {
            if let terminal = record.terminalResult { return .settled(terminal) }
            // A JOINER: it is an admitted caller of THIS record, so it takes a reference and must
            // resolve before the record can be released.
            record.outstandingCallers += 1
            return .join(.init(utteranceId: utteranceId, instance: record.instance, record: record))
        }
        let record = UtteranceRecord(origin: origin)
        record.outstandingCallers = 1
        recordsByUtteranceId[utteranceId] = record
        return .owner(.init(utteranceId: utteranceId, instance: record.instance, record: record))
    }

    /// Public dispatch entry, fenced by the ownership TOKEN from `beginDispatch`. Only the token
    /// owner runs the wire turn; `.join` awaits the owner's record; `.settled` observes the
    /// retained result; `.refused` dispatches WITHOUT utterance identity (the bound refuses it
    /// downstream) rather than borrowing another caller's ownership.
    func routeToCloud(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?,
        utteranceId: String? = nil,
        preparedObserver: PreparedObserver? = nil,
        sourceTranscript: String? = nil,
        sourceLanguage: String? = nil,
        ownership: CloudDispatchOwnership? = nil
    ) async -> CloudRouteResult {
        guard let utteranceId else {
            return await routeToCloudOwned(
                request: request, tier: tier, context: context, origin: origin,
                selection: selection, utteranceId: nil, preparedObserver: preparedObserver,
                sourceTranscript: sourceTranscript, sourceLanguage: sourceLanguage
            )
        }
        let disposition: CloudDispatchOwnership = ownership ?? beginDispatch(utteranceId: utteranceId, origin: origin)
        switch disposition {
        case let .settled(result):
            return result
        case let .join(token):
            return await resolveJoin(token: token)
        case .refused:
            return await routeToCloudOwned(
                request: request, tier: tier, context: context, origin: origin,
                selection: selection, utteranceId: nil, preparedObserver: preparedObserver,
                sourceTranscript: sourceTranscript, sourceLanguage: sourceLanguage
            )
        case let .owner(token):
            guard token.utteranceId == utteranceId else {
                return await resolveJoin(token: token)
            }
            return await ownDispatch(
                token: token, request: request, tier: tier, context: context, origin: origin,
                selection: selection, utteranceId: utteranceId, preparedObserver: preparedObserver,
                sourceTranscript: sourceTranscript, sourceLanguage: sourceLanguage
            )
        }
    }

    /// Settles ONE admitted caller against the record its TOKEN was issued for. A record that is
    /// terminal answers immediately; otherwise the caller parks on that record. Either way the
    /// caller RELEASES its reference, so a detached terminal record is dropped once no admitted
    /// caller needs it (reviewer be89233d).
    private func resolveJoin(token: CloudDispatchOwnership.DispatchToken) async -> CloudRouteResult {
        guard let record = token.record else {
            return CloudRouteResult(response: .earcon(.error), outcome: .refused)
        }
        let result: CloudRouteResult = await withCheckedContinuation { (continuation: CheckedContinuation<CloudRouteResult, Never>) in
            ownershipLock.lock()
            if let terminal = record.terminalResult {
                ownershipLock.unlock()
                continuation.resume(returning: terminal)
            } else {
                record.waiters.append(continuation)
                ownershipLock.unlock()
            }
        }
        releaseCaller(record)
        return result
    }

    /// Releases ONE admitted caller's reference. When the record is terminal and no admitted
    /// caller remains, the record is dropped — it is no longer reachable from the live map (it was
    /// detached on retirement) nor from any token (every token has resolved).
    private func releaseCaller(_ record: UtteranceRecord) {
        ownershipLock.lock()
        record.outstandingCallers -= 1
        ownershipLock.unlock()
    }

    /// Runs the WIRE TURN for the token owner. Liveness is decided against the LIVE MAP, not the
    /// token, because retirement may have intervened between admission and this entry.
    private func ownDispatch(
        token: CloudDispatchOwnership.DispatchToken,
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?,
        utteranceId: String,
        preparedObserver: PreparedObserver?,
        sourceTranscript: String?,
        sourceLanguage: String?
    ) async -> CloudRouteResult {
        guard let record = token.record else {
            return CloudRouteResult(response: .earcon(.error), outcome: .refused)
        }
        // Is this token's record STILL the live record for the utterance? A detached record (its
        // window closed) or a replaced one means this caller no longer owns a live turn.
        let isLive: Bool = {
            ownershipLock.lock(); defer { ownershipLock.unlock() }
            guard recordsByUtteranceId[utteranceId] === record else { return false }
            record.dispatchStarted = true
            return true
        }()
        guard isLive else {
            // The window closed (or the record was replaced) between admission and dispatch: this
            // caller owns no live turn. Settle EVERY admitted caller (itself included) with the
            // record's terminal result and release, so nothing is abandoned (reviewer be89233d).
            let settlement = CloudRouteResult(response: .earcon(.error), outcome: .refused)
            settle(record, with: settlement)
            return settlement
        }

        let result = await routeToCloudOwned(
            request: request, tier: tier, context: context, origin: origin,
            selection: selection, utteranceId: utteranceId, preparedObserver: preparedObserver,
            sourceTranscript: sourceTranscript, sourceLanguage: sourceLanguage
        )
        settle(record, with: result)
        // The owner's own reference is released now that it has resolved.
        releaseCaller(record)
        return result
    }

    /// Terminal settlement of a record: the result is stored ONCE on the record's own instance,
    /// every parked waiter is resumed with it, and the record leaves the live map if it was
    /// detached (a stale owner must never stand in for a successor's map entry). The record itself
    /// survives until its last admitted caller releases it (reviewer be89233d).
    private func settle(_ record: UtteranceRecord, with result: CloudRouteResult) {
        ownershipLock.lock()
        if record.terminalResult == nil { record.terminalResult = result }
        let settlement = record.terminalResult!
        let waiters = record.waiters
        record.waiters = []
        // A record that is NO LONGER the live one for its utterance (a successor holds the id) must
        // not stand in for the successor: drop the map entry so the successor is unaffected.
        for (id, live) in recordsByUtteranceId where live === record && record.detached {
            recordsByUtteranceId.removeValue(forKey: id)
        }
        ownershipLock.unlock()
        waiters.forEach { $0.resume(returning: settlement) }
    }

    private func routeToCloudOwned(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?,
        utteranceId: String?,
        preparedObserver: PreparedObserver?,
        sourceTranscript: String?,
        sourceLanguage: String?
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
                origin: origin,
                // REQUEST OWNERSHIP: a repeated callback for the SAME utterance reuses the
                // already-prepared wire identity instead of minting another request.
                utteranceId: utteranceId
            ) else {
                return CloudRouteResult(response: .silent, outcome: .refused)
            }
            conversation = prepared
            preparedObserver?(prepared)
        }

        MainActor.assumeIsolated { clientCreationCountForTesting += 1 }
        let client = clientFactory()
        let routeContext = CloudRouteContext(from: context)

        // GRACE CONTRACT, acquisition at the ADMITTED DISPATCH: the window's expiry is held from
        // here — before any cloud/streamed audio — through done and the actual drain/stop.
        // Atomic transfer of ownership: the successor's hold is begun BEFORE the predecessor's is
        // released, so there is never a hold-free instant between turns in which the clock could
        // re-arm mid-flight.
        let admittedHoldOrigin = origin
        let admittedHold = onGracePlaybackHoldBegin?(admittedHoldOrigin)
        if let admittedHold {
            let predecessor = heldPlaybackToken
            heldPlaybackToken = admittedHold
            onGracePlaybackHoldEnd?(predecessor)
        }

        // Supersede any in-flight turn (double wake / barge-in) before touching
        // shared per-turn state. Only a turn that will actually run supersedes.
        let turnToken = CloudTurnToken()
        let playbackPredecessor = playbackOwner
        activeTurn?.cancel()
        // Transfer happens AT ADMISSION, before the quiescence wait: a turn that supersedes US
        // while we wait must observe itself as the owner (review 14f66b72).
        activeTurn = turnToken
        playbackOwner = turnToken
        // ATOMIC RETIRE + QUIESCENCE AT ADMISSION (reviews 9fc2603e / 14f66b72): the successor
        // retires the PLAYBACK predecessor's output HERE — before this turn can admit any audio
        // of its own — and WAITS for the confirmed stop before admitting, because `cancel` only
        // QUEUES a runner stop: frames admitted before the runner processes it would be shed by
        // the queued stop. The identity is captured at the transfer and associated with the
        // predecessor's token; the superseded turn's own cleanup awaits that captured identity.
        // Sequential turns (no playback predecessor, or nothing pending) retire nothing: an
        // extra stop request would only shift confirmed-stop identities under existing deferral
        // records.
        if let playbackPredecessor, audioPlayer.hasOutstandingOutput {
            // CLEANUP BEFORE THE FIRST AWAIT (review 05d27ddb): this turn already acquired its
            // token, playback ownership, and the admitted hold. A return from INSIDE this block
            // (timeout or superseded-while-waiting) bypasses the turn-wide defer below, so the
            // scoped defer here retires exactly what this turn acquired — never a strand.
            let retireEpoch = audioPlayer.cancel()
            // Identity lives ON the predecessor's token (review 4fc59e2c): a suspended turn
            // always finds its own identity, however many transfers happen meanwhile.
            playbackPredecessor.capturedRetireEpoch = retireEpoch
            var returnedEarly = true
            defer {
                // SUCCESS fall-through: B keeps what it acquired.
                if returnedEarly {
                    if activeTurn === turnToken { activeTurn = nil }
                    // Playback ownership reverts to the predecessor: this turn admitted
                    // nothing, so the next successor must gate on the SAME outstanding output
                    // this turn saw.
                    if playbackOwner === turnToken { playbackOwner = playbackPredecessor }
                    // HOLD RESPONSIBILITY (review 8eb9fb44): the predecessor's own hold was
                    // already ended at the atomic transfer, so THIS hold is the last live one.
                    // Ending it while the predecessor's stop is unconfirmed would leave the
                    // output with NO hold and re-arm the allowance mid-flight. If the stop is
                    // already confirmed, end it now; otherwise the release responsibility
                    // rides the stop confirmation (audioPlayerDidStop) — never a timer, never
                    // an allowance renewal.
                    if let acquired = heldPlaybackToken, acquired === admittedHold {
                        if audioPlayer.confirmedStopEpoch() >= retireEpoch {
                            heldPlaybackToken = nil
                            onGracePlaybackHoldEnd?(acquired)
                        } else {
                            pendingHoldRelease = (hold: acquired, epoch: retireEpoch)
                        }
                    }
                }
            }
            var quiesced = false
            for _ in 0..<8 {
                if await audioPlayer.awaitActualStop(after: retireEpoch, timeout: 0.25) {
                    quiesced = true
                    break
                }
                // Revalidate between bounds: a newer turn may have superseded US while we
                // waited; then THIS turn must not admit either.
                guard activeTurn === turnToken else { break }
            }
            guard activeTurn === turnToken, quiesced else {
                // Ownership-safe disposition: never admit over a predecessor that is not
                // confirmed quiescent, and never run as a superseded-while-waiting turn.
                return CloudRouteResult(response: .silent, outcome: .earlyClose)
            }
            // Success: the scoped rollback above must NOT fire on fall-through — B keeps the
            // active ownership, playback ownership, and admitted hold through its stream
            // (review 4fc59e2c).
            returnedEarly = false
        }
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

        let routed = client.routeWithResultSocket(
            request: request,
            context: routeContext,
            turn: turn,
            sourceTranscript: sourceTranscript,
            sourceLanguage: sourceLanguage
        )
        // The turn's own result socket: sends bind to THIS registration, so a superseded turn's
        // late results can never ride a successor's socket.
        activeResultSocket = routed.resultSocket
        resultSendClient = client

        // The consumer takes ownership of the turn socket here: the bounded never-consumed
        // cleanup no longer applies, however long this turn's awaited effect/result takes.
        routed.resultSocket.claimConsumerOwnership()
        // Cancellation cleanup is bound to the task that owns consumer execution, not to
        // AsyncStream termination (which never fires on task cancellation). A cancellation
        // handler installed on the OWNING task fires `onCancel` synchronously at cancel time —
        // the only legal observation of another task's cancellation — marks the flag, and retires
        // the ORIGINAL registration immediately. The journal is deliberately untouched: a
        // claimed-but-unfinished operation stays `.in_progress` on disk, so a restart
        // reconstructs `unknown` — never a fabricated `cancelled`.
        let ownerCancelledFlag = OwnerCancelFlag()
        // Nonisolated local copy for the cancellation handler: the handler runs on the owning
        // task and cannot touch main-actor state. The socket object itself is Sendable and its
        // close is idempotent and identity-bound, so this copy retires exactly THIS turn's
        // registration and nothing else.
        let turnSocket = routed.resultSocket
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
            // A turn that ENDS (any exit) leaves no predecessor behind: the retire-at-admission
            // must fire only when a successor actually SUPERSEDES a still-running turn, never
            // for a sequential turn that starts after the previous one fully returned.
            if activeTurn === turnToken {
                activeTurn = nil
            }
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
                        // The hold was acquired at this turn's admitted dispatch; it RETAINS
                        // through done into the actual drain and releases at the real stop.
                    } else {
                        restoreTransientAudioState()
                    }
                    turnResult = .completed
                    turnResponse = .silent
                    break turnLoop
                case let .error(_, code, message):
                    // A cancelled owner (cloud-token supersession OR the caller's own
                    // Task.cancel) classifies as an incomplete turn via the owner-cancel path
                    // below — never as a connection failure it did not observe.
                    guard !turnToken.isCancelled && !Task.isCancelled else { break turnLoop }
                    // GRACE STOP ORDER: release waits for the ACTUAL stop this cancel requested
                    // (identity-bound). On a timeout the confirmed stop notification itself
                    // releases via the deferral record — never an unconfirmed resume.
                    let stopEpoch = audioPlayer.cancel()
                    if await audioPlayer.awaitActualStop(after: stopEpoch) {
                        // REVALIDATE after the suspension: a successor may have started while
                        // this turn was suspended on the stop wait. Release only if the captured
                        // turn is still this turn's own.
                        guard activeTurn == nil || activeTurn === turnToken else { break turnLoop }
                        restoreTransientAudioState()
                    } else {
                        // Defer to the confirmed stop — but ownership holds in BOTH branches: a
                        // successor B that started (or already finished) while A was suspended owns
                        // the window, so A defers only if it still owns the release and no
                        // successor's deferral would be overwritten.
                        let stillOwner = activeTurn == nil || activeTurn === turnToken
                        if stillOwner && restoreHeldForPlayerDrain == nil {
                            restoreHeldForPlayerDrain = (owner: turnToken, drainEpoch: stopEpoch)
                        }
                    }
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
            turnSocket.finishTurn()
        }
        if let turnResult {
            return CloudRouteResult(response: turnResponse, outcome: turnResult)
        }
        if turnToken.isCancelled || ownerCancelledFlag.isSet {
            // OWNER CANCELLATION (review dee03708/fa03b7f9): the cancelled turn's OWNED output
            // still has to STOP, and the actual stop must complete before the window's host
            // playback resumes over it. The successor owns the WINDOW (pause/restore/analytics),
            // so this turn releases only if it still owns the captured release — but its own
            // audio dies here, identity-bound, not whenever the successor's drain happens to
            // shed it. Superseded is not a completion either.
            //
            // AUDIO OWNERSHIP (review 9fc2603e): this turn NEVER cancels the shared player on
            // the superseded path — the successor retired this turn's output AT ADMISSION
            // (before admitting its own), so a cancel here could only destroy successor-owned
            // audio. If no successor ran (plain Task cancellation), this turn is still the
            // owner and requests the stop itself. TIMEOUT DISPOSITION: a timeout is NOT a
            // confirmed stop — the turn returns earlyClose WITHOUT restoring the host playback
            // and records a deferral so the confirmed stop notification releases the window;
            // never an unconfirmed release.
            if activeTurn === turnToken {
                let stopEpoch = audioPlayer.cancel()
                if await audioPlayer.awaitActualStop(after: stopEpoch) {
                    guard activeTurn == nil || activeTurn === turnToken else {
                        return CloudRouteResult(response: .silent, outcome: .earlyClose)
                    }
                    restoreTransientAudioState()
                } else {
                    // Timeout: the stop notification owns the release via the deferral — same
                    // ownership rules as the error path (only if still owner, never overwrite a
                    // successor's deferral).
                    let stillOwner = activeTurn == nil || activeTurn === turnToken
                    if stillOwner && restoreHeldForPlayerDrain == nil {
                        restoreHeldForPlayerDrain = (owner: turnToken, drainEpoch: stopEpoch)
                    }
                }
            } else {
                // Superseded: await the identity captured for THIS token at the transfer
                // (review 14f66b72) — never the shared latest counter, which later stops move.
                if let capturedEpoch = turnToken.capturedRetireEpoch {
                    turnToken.capturedRetireEpoch = nil // consumed: nothing leaks
                    // Bounded: the confirmed stop lands via the normal path; if every bound
                    // expires the disposition is explicit — this turn releases NOTHING (the
                    // successor owns the window) and reports an incomplete turn, never claiming
                    // a quiescence that was not confirmed.
                    var quiesced = false
                    for _ in 0..<8 {
                        if await audioPlayer.awaitActualStop(after: capturedEpoch, timeout: 0.25) {
                            quiesced = true
                            break
                        }
                    }
                    _ = quiesced // disposition is: no release either way; earlyClose below
                }
                // No captured entry: nothing was retired for this turn (it owned no pending
                // playback at supersession) — nothing to await.
            }
            return CloudRouteResult(response: .silent, outcome: .earlyClose)
        }
        // DEFECT 3 (reviewer 7fc40b74) + review 24f236de: stop THIS turn's OWNED output and
        // AWAIT the identity-bound stop completion BEFORE releasing the host playback and the
        // hold. A truncated stream can leave enqueued cloud audio in the player; resuming the
        // episode under it would overlap two outputs. On a timeout the confirmed stop
        // notification releases via the deferral record. Successor-safe: the cancel touches only
        // audio this turn enqueued.
        let stopEpoch = audioPlayer.cancel()
        if await audioPlayer.awaitActualStop(after: stopEpoch) {
            // REVALIDATE after the suspension (review 5295572f): a successor B can start while
            // this turn was suspended on the stop wait; release ONLY the own token. A successor
            // still gets its own truncation release (the earlyClose return below stands).
            if activeTurn == nil || activeTurn === turnToken {
                restoreTransientAudioState()
            }
        } else {
            let stillOwner = activeTurn == nil || activeTurn === turnToken
            if stillOwner && restoreHeldForPlayerDrain == nil {
                restoreHeldForPlayerDrain = (owner: turnToken, drainEpoch: stopEpoch)
            }
        }
        // The stream ended without `done`: the turn was truncated, which is not a
        // completion and must not restore the allowance as though the model answered.
        return CloudRouteResult(response: .silent, outcome: .earlyClose)
    }

    private func restoreTransientAudioState() {
        // Whatever playback hold this sink owns ends with the release of the audio state:
        // error/supersede/no-pending/drain-stop all resume the window's interval exactly once.
        // Per-token release: a stale terminal never clears another owner's hold.
        if let held = heldPlaybackToken {
            heldPlaybackToken = nil
            onGracePlaybackHoldEnd?(held)
        }
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
            // REPLAY CONTRACT: answer from the DURABLE RECORD — the outcome AND the state settled
            // with it. The live playback state is not read: an unrelated operation may have moved
            // it since, and a settled answer must not be rewritten by later events.
            await reportRecorded(recorded, operationId: operationId, capabilityVersion: capabilityVersion)
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
            // Runtime gate: an identified operation whose action this build does not implement
            // is REFUSED (unsupported_operation) and the refusal SETTLED durably — never a
            // fabricated success, and a redelivery replays the recorded refusal. Identity-less
            // playback frames NEVER reach here: the gate above refuses them before any claim
            // (there is no legacy fallback that authorizes a mutation without
            // operation_id + capability_version).
            let knownActions: Set<String> = ["seek_to", "play_quote", "stop_quote", "seek_relative", "pause", "resume"]
            if !knownActions.contains(action) {
                let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.unsupportedOperation)
                let settled = operationJournal?.complete(operationId, result: refused) ?? true
                if settled {
                    await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion)
                } else {
                    let unsettled = OperationResult.nonSuccess(.unknown, reason: OperationReason.persistenceUnavailable)
                    await reportResult(unsettled, operationId: operationId, capabilityVersion: capabilityVersion)
                }
                return
            }
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
            // Settle with the state CAPTURED AT SETTLEMENT: replay must answer with what was
            // true when THIS operation finished, never a later reading.
            let settledResult = OperationResult.succeeded(state: currentPlaybackState())
            let settled = operationJournal?.complete(operationId, result: settledResult) ?? true
            if settled {
                // The FIRST send is the SAME CAPTURED envelope that was settled — not a second
                // live snapshot (review 5295572f): between settlement and send the state could
                // move, and then the wire answer and the durable record would disagree.
                await reportFrame(
                    AppOperationResultFrame(
                        operationId: operationId, outcome: .succeeded, state: settledResult.state
                    ),
                    capabilityVersion: capabilityVersion
                )
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
                // REAL PRECONDITION: no current episode (zero duration) makes the system seek
                // wrapper a silent no-op — that is NOT a success. Refuse durably instead.
                if let precondition = currentEpisodePrecondition { return precondition }
                seekToSinkSeconds(seconds)
                return nil
            case (nil, let reference?):
                // The reference form was BYPASSED by the episode check (review fa03b7f9) —
                // the mapping wrapper would early-return on no episode and report unavailable
                // for the WRONG reason; the honest precondition runs first.
                if let precondition = currentEpisodePrecondition { return precondition }
                capturePreActionPosition(referenceMs: reference)
                return seekToReference(reference)
            default:
                return .nonSuccess(.refused, reason: OperationReason.malformedSeekTarget)
            }
        // Serve the quote. This does not take or release the hold: the quote
        // plays over playback the server has already ducked, and the turn's end
        // is the release (Task 12). Resuming here would end the duck early.
        case "play_quote":
            // A quote without its reference target is a malformed request, not a success: the
            // honest outcome is refused, durably settled, and replayed on redelivery.
            guard let referenceMs = params["reference_position_ms"]?.int64Value else {
                return .nonSuccess(.refused, reason: OperationReason.malformedSeekTarget)
            }
            if let precondition = currentEpisodePrecondition { return precondition }
            capturePreActionPosition(referenceMs: referenceMs)
            return seekToReference(referenceMs)
        case "stop_quote":
            // Restoring requires a position this client actually saved (a prior play_quote). No
            // saved position: a precondition of current state failed — refused, never a success.
            guard let restoreMs = preQuotePositionMs else {
                return .nonSuccess(.refused, reason: OperationReason.stalePrecondition)
            }
            if let precondition = currentEpisodePrecondition { return precondition }
            let seconds = Int((Double(restoreMs) / 1000.0).rounded())
            _ = playbackSink.seekTo(positionSeconds: seconds)
            return nil
        case "seek_relative":
            // Per the recovery contract (PR 59, cloud-seek-relative):
            // Capture previous position so "go back to where I was" works
            // after a relative seek.
            if let precondition = currentEpisodePrecondition { return precondition }
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
            // PlaybackManager.play EARLY-RETURNS on no current episode — the silent wrapper is
            // a no-op, not a success. The availability precondition applies here too.
            if let precondition = currentEpisodePrecondition { return precondition }
            _ = playbackSink.resume()
            didAutoPause = false
            return nil
        default:
            // Unreachable for identified mutations (the runtime gate refuses unknown actions
            // before the claim); kept as an honest refusal, never a fabricated success.
            return .nonSuccess(.refused, reason: OperationReason.unsupportedOperation)
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
        await reportFrame(
            AppOperationResultFrame(
                operationId: operationId, outcome: .succeeded,
                state: currentPlaybackState()
            ),
            capabilityVersion: capabilityVersion
        )
    }

    /// The live typed playback state, captured at settlement (fresh executions only — replay
    /// answers from the journal's stored state).
    private func currentPlaybackState() -> [String: CloudRouteJSONValue] {
        [
            "position_seconds": .int(playbackPositionMs() / 1000),
            "playing": .bool(playbackSink.isPlaying),
        ]
    }

    /// Sends a RECORDED result: the journal's settled outcome and state, byte-for-byte the fact
    /// this client settled — not a reconstruction.
    private func reportRecorded(
        _ recorded: OperationResult,
        operationId: String,
        capabilityVersion: String?
    ) async {
        guard let socket = activeResultSocket,
              let frame = AppOperationResultFrame(
                operationId: operationId,
                outcome: recorded.outcome,
                reason: recorded.reason,
                state: recorded.state
              ) else { return }
        await reportFrame(frame, capabilityVersion: capabilityVersion)
    }

    private func reportFrame(_ frame: AppOperationResultFrame?, capabilityVersion: String?) async {
        _ = capabilityVersion // validated at the gate; rides the action frame, not the result
        guard let frame else { return }
        guard let client = resultSendClient else { return }
        guard let socket = activeResultSocket else { return }
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
    /// Retired on owner cancellation by the owning task's own cancellation handler, so no
    /// suspension point needs to be reached.
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

    /// REAL PRECONDITION (review 5295572f): the system seek wrapper early-returns when no
    /// episode is current, and its silent response would dress "nothing happened" as success.
    /// A position-changing operation REQUIRES a current episode with a duration; without one the
    /// honest durable outcome is refused (stale precondition of current state), not a success.
    private var currentEpisodePrecondition: OperationResult? {
        // EXPLICIT AVAILABILITY (review fa03b7f9), not duration: PlaybackManager.play/seek
        // early-return on no current episode, and their silent wrappers would dress "nothing
        // happened" as success. The injected closure is the test seam; production consults the
        // manager's own current-episode state. Applies to EVERY position-changing form INCLUDING
        // the reference-target seek and RESUME (play early-returns the same way).
        // PRODUCTION source (review 0846e993): the manager's REAL current-episode state — an
        // EXISTING episode with unknown/zero duration is present, not absent. Duration is not
        // availability.
        let availabilitySource = episodeAvailable.map { $0() }
            ?? playbackManager.map { $0.currentEpisode != nil }
        // No source at all (injection-only configuration): no evidence the precondition FAILED.
        if let available = availabilitySource, !available {
            return OperationResult.nonSuccess(.refused, reason: OperationReason.stalePrecondition)
        }
        return nil
    }

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
        // A rolled-back admission's hold releases exactly here: the stop it was waiting on
        // has confirmed (epoch identity, monotonic), so the output it covered is quiescent
        // and the window's allowance may be re-armed by THIS end — never earlier.
        if let pending = pendingHoldRelease, drainEpoch >= pending.epoch {
            pendingHoldRelease = nil
            if heldPlaybackToken === pending.hold {
                heldPlaybackToken = nil
                // End THIS hold explicitly (restoreTransientAudioState only ends what is still
                // in heldPlaybackToken), then run the FULL transient restore (review 9a093876):
                // the rolled-back turn inherited the host's auto-pause responsibility at the
                // transfer, so the confirmation must resume the inherited pause — exactly once,
                // guarded by the same flags as every other restore.
                onGracePlaybackHoldEnd?(pending.hold)
                restoreTransientAudioState()
            }
        }
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
        // MONOTONIC QUIESCENCE PROOF for the DEFERRAL RELEASE (review 9a093876): the claimed
        // drain epoch (the turn's finish()) and the epoch the runner actually stopped (a later
        // retire-cancel can shed the drain) differ, but any CONFIRMED stop at or after the
        // claimed epoch proves the output quiesced — the exact-identity rule governs
        // CONFIRMATION records, not this restore.
        guard drainEpoch >= deferred.drainEpoch else {
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
