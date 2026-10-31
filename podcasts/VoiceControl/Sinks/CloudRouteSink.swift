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

    /// Whether an interruption report awaits a later EXPLICIT user request. A refusal retains the
    /// report but submits nothing, so the turn ends locally and there is no successor frame to
    /// observe it on (reviewer c38ff4ba item 2).
    @MainActor var hasPendingInterruptionReportForTesting: Bool { interruptionState.hasPendingReport }

    /// The client that owns this sink's socket registrations. Exposed so a control can retire one
    /// through the production retirement path and observe a genuinely `.undelivered` send.
    @MainActor var resultClientForTesting: CloudRouteClient? { resultSendClient }

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
        return recordForTesting(utteranceId: utteranceId)?.instance
    }
    /// True when a live record exists for the utterance.
    func hasLiveRecordForTesting(utteranceId: String) -> Bool {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return recordForTesting(utteranceId: utteranceId) != nil
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
    /// A WEAK handle on the record a token was admitted against, so a control can prove the record
    /// is actually DEALLOCATED once the live-map entry and every token are gone (reviewer
    /// f3492082). Selecting `Live` here is what keeps the control honest about ARC.
    func weakRecordForTesting(token: CloudDispatchOwnership.DispatchToken) -> () -> UtteranceRecord? {
        weak var weakRecord = token.record
        return { weakRecord }
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
    /// Consulted by the dispatch fence: does this exact turn still hold admitted work under
    /// `origin`? Nil means the sink was constructed without one and fences on the live origin
    /// alone (the pre-existing behaviour).
    /// TEST-ONLY: an interleaving barrier invoked inside the coherent admission block, before the
    /// decision reads. Nil in production.
    @MainActor var admissionInterleavingBarrierForTesting: (() -> Void)?

    private let admittedWorkAuthority: (() -> GracePeriodSignal.AdmittedWorkAuthority?)?

    /// The manager whose live origin must follow the grace window. Exposed so the SERVICE can own
    /// the subscription: a binding stored in the assembly's `cancellables` is cancelled as soon as
    /// What selected the current turn. Defaults to a wake word: a turn with no reported
    /// selection is a new user act, and create-then-resume is the safe direction — resuming
    /// a conversation nobody opened would attach an utterance to someone else's history.
    private let conversationSelectionProvider: () -> CloudConversationSelection
    /// Cross-turn interruption state: the retained follow-up and the pending report.
    private let interruptionState: CloudInterruptionState

    /// How long a successor waits for the interrupted turn's terminal before giving up on the
    /// acknowledgement: long enough for a normal settle, short enough that a dead turn cannot wedge
    /// the sink. On expiry the hold is dropped and the expiry is logged, never assumed away.
    static let interruptionAcknowledgementTimeout: TimeInterval = 10

    /// WHO and WHERE an operation was issued, captured when its turn was admitted.
///
/// Deliberately a value: the journal's replay identity is this triple plus the operation's
/// original bytes, and an identity read from "the latest turn" at effect time would relabel an
/// earlier turn's operation the moment a successor was admitted.
/// TURN-LOCAL memory of the admitted identity. `completingOwner` alone was a pure function: the
/// turn loop kept passing its original empty-owner value, so each action could re-derive a
/// DIFFERENT account from a socket that changed in between. The completed value must be stored
/// once, per turn, and reused — including the "completed with no principal" answer, which is a
/// settled fact and not something to keep re-asking.
final class AdmittedTurnIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: AdmittedTurnIdentity
    private var completed: Bool

    init(_ identity: AdmittedTurnIdentity, completed: Bool = false) {
        self.identity = identity
        self.completed = completed
    }

    /// Complete from the turn's own socket exactly once, then always return the stored value.
    /// Sticky even when the socket later names a different account: an identity already captured
    /// for this turn must not be relabelled by a switch that happens afterwards.
    func completing(from socket: AppOperationResultSocket?) -> AdmittedTurnIdentity {
        lock.lock()
        defer { lock.unlock() }
        // FIRST COMPLETION WINS, and the comparison is made under the SAME lock that performs
        // the write. The previous version released the lock to derive, then re-took it: two
        // callers could both observe `completed == false`, and the loser's freshly derived
        // identity could overwrite the winner's — so a turn could still be relabelled by an
        // account that arrived second.
        if completed { return identity }
        // NOT YET ACQUIRED IS NOT A COMPLETED ANSWER. With owner frozen at publication, an absent
        // freeze means this turn has not acquired yet: the question is still open, so the box must
        // stay INCOMPLETE. Marking it complete here would settle the identity as "no owner" before
        // the acquisition ever happened, and the late acquisition could never be observed.
        // A FROZEN nil IS completed, and `completingOwner` returns the unchanged (empty-owner)
        // identity for it — that is the genuine "this turn has no principal" answer.
        guard socket?.frozenAcquisition != nil else { return identity }
        // Deriving here rather than outside keeps read-derive-write atomic. `completingOwner`
        // only reads the socket's own lock-guarded freeze, and never calls back into this box, so
        // holding our lock across it cannot re-enter this lock.
        identity = identity.completingOwner(from: socket)
        completed = true
        return identity
    }

    var current: AdmittedTurnIdentity {
        lock.lock(); defer { lock.unlock() }; return identity
    }
}

struct AdmittedTurnIdentity: Equatable {
    let conversation: String
    let turn: String
    /// The authenticated account. EMPTY means "no trusted owner is available", which is a
    /// fail-closed condition at the operation gate — never journaled as a real identity.
    let owner: String
    /// The credential that account was authenticated with, captured at admission.
    ///
    /// The operation gate re-checks that this session is still the live one before it claims, so
    /// an account switch part-way through a turn cannot get its operation journaled under the
    /// account that opened the turn. Compared, never persisted and never logged.
    let sessionCredential: String

    init(conversation: String, turn: String, owner: String, sessionCredential: String = "") {
        self.conversation = conversation
        self.turn = turn
        self.owner = owner
        self.sessionCredential = sessionCredential
    }

    /// COMPLETE the owner from the turn's own socket, at the moment the answer exists.
    ///
    /// The client publishes its validated acquisition asynchronously, so at admission there may be
    /// nothing to read yet. Rather than block the consumer waiting for it, the owner is taken when
    /// the first action is handled — by which point the turn has authenticated, if it is going to.
    ///
    /// Idempotent and STICKY: once completed the values never change again, so a later account
    /// switch on the socket cannot relabel an identity already captured, and a successor turn can
    /// never reach it (this value is captured by value per turn).
    ///
    /// No session ⇒ both fields stay empty, which the operation gate refuses. That is the same
    /// fail-closed answer whether the turn had no principal or the acquisition never happened.
    func completingOwner(from socket: AppOperationResultSocket?) -> AdmittedTurnIdentity {
        guard owner.isEmpty else { return self }
        // THE OWNER BELONGS TO THE CREDENTIAL PAIR THIS TURN ACTUALLY ACQUIRED, not to whichever
        // mutable session happens to exist when the first action is handled. Reading
        // `authenticatedSession` here let a mid-turn rebinding relabel the owner: the box adopted
        // the NEW account, the live-session re-check then compared that account against itself,
        // and the operation settled under an account whose credential never opened this turn.
        //
        // The client freezes the acquisition result once, at publication. Reading that immutable
        // snapshot preserves delayed acquisition (the answer simply is not there until it
        // happens) and freezes the explicit no-principal answer too, without rereading the
        // provider and without capturing a premature nil before acquisition has occurred.
        guard let frozen = socket?.frozenAcquisition else { return self }
        // A frozen nil session is a COMPLETED "no principal" answer: both fields stay empty, which
        // the gate refuses. An empty account is not an owner either — treating it as one would
        // turn "unauthenticated" into a journaled identity.
        guard let session = frozen.session, !session.accountId.isEmpty else { return self }
        return AdmittedTurnIdentity(
            conversation: conversation,
            turn: turn,
            owner: session.accountId,
            sessionCredential: session.accessToken
        )
    }
}

/// The conversation of the most recently admitted turn. A refusal is recorded from the FAILING
    /// turn, which is the same conversation as the turn it interrupted (a barge-in continues the
    /// conversation), so this is the id the retained report must carry.
    @MainActor private var lastAdmittedConversationId: String?


    /// The turn socket currently open, so an ordering control can establish that a PRIOR turn is
    /// genuinely in flight before it starts a successor. Without this the interruption path never
    /// runs in a test and a control about interruption ordering passes vacuously.
    @MainActor
    var activeResultSocketForTesting: AppOperationResultSocket? { activeResultSocket }



    /// Drives the action-admission path with an EXPLICIT admitted identity and the socket that
    /// identity came from. TEST-ONLY: it exists so a control can deliver a delay-arriving action
    /// from a prior turn without pretending the current live socket is its own — the exact
    /// mistake a global `activeResultSocket` read invites. Production always reaches this path
    /// through the turn loop, which passes the turn's own `turnSocket`.
    @MainActor
    func executeActionForTesting(
        action: String,
        params: [String: CloudRouteJSONValue],
        operationId: String?,
        capabilityVersion: String?,
        actionBytes: Data?,
        precondition: [String: CloudRouteJSONValue],
        admittedTurnBox: AdmittedTurnIdentityBox,
        admittedTurnSocket: AppOperationResultSocket?,
        admittedTurnClient: CloudRouteClient
    ) async {
        await executeAction(
            tool: "playback", action: action, params: params,
            operationId: operationId, capabilityVersion: capabilityVersion,
            actionBytes: actionBytes, precondition: precondition,
            parameterViolation: nil,
            admittedTurnBox: admittedTurnBox,
            admittedTurnSocket: admittedTurnSocket,
            admittedTurnClient: admittedTurnClient
        )
    }

    /// Builds the turn-local identity a control drives through `executeActionForTesting`, so the
    /// control reuses ONE box across several actions exactly as a real turn does.
    static func admittedTurnBoxForTesting(
        conversation: String, turn: String
    ) -> AdmittedTurnIdentityBox {
        AdmittedTurnIdentityBox(
            AdmittedTurnIdentity(conversation: conversation, turn: turn, owner: ""))
    }

    /// The interruption state this sink carries, so a service-level control can observe the
    /// cross-turn state the production service actually uses rather than assuming its contents.
    @MainActor
    var interruptionStateForTesting: CloudInterruptionState { interruptionState }
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
    /// The episode the app is currently targeting. `nil` provider falls back to the real manager.
    private let currentEpisodeIdProvider: (() -> String?)?

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

        // MARK: - Interruption acknowledgement latch
        //
        // When a successor interrupts this turn, it must NOT proceed until this turn's terminal
        // has actually arrived (reviewer ff00457c item 1). Cancelling immediately ends the receive
        // loop through the owner-cancel path, so the `done`/`error` branches that carry the
        // interruption transitions are never reached and the acknowledgement is silently skipped.
        //
        // The latch CARRIES A BOUND RESOLUTION, not a bare boolean (reviewer eaa8c06a). A boolean
        // let both `.done` and `.error` wake the successor, which then unconditionally proceeded to
        // authenticate: a refusal therefore promoted an unacknowledged utterance into an ordinary
        // turn, and so did a timeout and an undelivered send. The resolution is now explicit and
        // only `.acknowledged` may lead to submission.
        //
        // Bounded by the waiter's own timeout, so a server that never answers cannot wedge the
        // sink. One-shot: the ticket has exactly one winner, so a terminal landing at the same
        // instant as the timer cannot double-resume.
        private var resolution: InterruptionResolution?

        /// How this turn resolved for an interruption waiter.
        enum InterruptionResolution: Equatable {
            /// A `done` arrived — even a `completed` one. This is the ONLY outcome that may submit
            /// the held follow-up.
            case acknowledged
            /// An `error` terminal: the server refused the interruption. Nothing may be submitted.
            case refused
            /// No resolution: the bound expired, or the send never reached the server. Nothing may
            /// be submitted, and the held input must NOT be promoted to an ordinary turn.
            case failed
        }

        private var acknowledgementTicket: AcknowledgementTicket?

        /// Park until this turn's interruption resolves, or the bound expires.
        ///
        /// The result must be acted on, not treated as success: `.refused` and `.failed` both
        /// forbid submission. Deliberately a single one-shot continuation rather than a task group
        /// racing a sleep — a group that resumed a parked waiter after the timeout branch had
        /// already won would resume a continuation whose task had been cancelled, which is
        /// undefined. The ticket pattern here has exactly one winner.
        func awaitAcknowledgement(timeout: TimeInterval) async -> InterruptionResolution {
            let ticket = AcknowledgementTicket()
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let resolution {
                    lock.unlock()
                    continuation.resume(returning: resolution)
                    return
                }
                ticket.continuation = continuation
                acknowledgementTicket = ticket
                lock.unlock()
                // Arm the bound OUTSIDE the lock; the timer resumes through the same one-shot
                // transition, so a terminal landing at the same instant cannot double-resume.
                ticket.timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    _ = self?.settleAcknowledgement(.failed)
                }
            }
        }

        /// One-shot settlement of the acknowledgement wait. Returns the value the waiter was
        /// resumed with, or nil when another path already settled it.
        @discardableResult
        private func settleAcknowledgement(_ outcome: InterruptionResolution) -> InterruptionResolution? {
            lock.lock()
            // FIRST settlement wins, and it is recorded even with nobody waiting, so a waiter that
            // parks later reads it immediately.
            guard resolution == nil else {
                lock.unlock()
                return nil
            }
            resolution = outcome
            let ticket = acknowledgementTicket
            acknowledgementTicket = nil
            lock.unlock()
            ticket?.timer?.cancel()
            ticket?.continuation?.resume(returning: outcome)
            ticket?.continuation = nil
            return outcome
        }

        /// The turn settled with a terminal. `.acknowledged` for `done` (even `completed`),
        /// `.refused` for an `error`. Idempotent: a late second terminal settles nothing.
        func markAcknowledgement(_ outcome: InterruptionResolution) {
            _ = settleAcknowledgement(outcome)
        }
    }


    private final class AcknowledgementTicket: @unchecked Sendable {
        var continuation: CheckedContinuation<CloudTurnToken.InterruptionResolution, Never>?
        var timer: Task<Void, Never>?
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
        // The episode the app is CURRENTLY targeting, for the wire's target-match precondition.
        // Production reads the manager's own current episode; the closure exists so a control can
        // state "the user moved to a different episode" without a real player.
        currentEpisodeIdProvider: (() -> String?)? = nil,
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
        // Interruption state (cloud-assistant.md → Interruption, spec c5fe3416): the retained
        // follow-up and the pending report, held ACROSS turn boundaries. A default instance keeps
        // direct-constructed test sinks working; production passes the service's one instance so
        // two turns of the same app session share it.
        interruptionState: CloudInterruptionState = CloudInterruptionState(),
        // Grace contract (token ownership holds): from the ADMITTED DISPATCH through done and the
        // actual drain/stop, the turn's window expiry is SUSPENDED and resumes EXACTLY ONCE when
        // the last hold releases. Identity is bound at acquisition (live generation only); release
        // is per-token, so a stale terminal never clears another owner's hold. Optional so
        // direct-constructed sinks in tests opt in.
        onGracePlaybackHoldBegin: ((Int?) -> GracePeriodSignal.PlaybackHoldToken?)? = nil,
        onGracePlaybackHoldEnd: ((GracePeriodSignal.PlaybackHoldToken?) -> Void)? = nil,
        // Carries ADMITTED-WORK authority to the dispatch fence. A turn admitted before the
        // deadline stays eligible through recognition (voice-control-core.md:270), so its claim
        // can be granted AFTER the window expires and the live origin has moved on. The fence
        // must therefore admit an origin that this turn still HOLDS, not only the origin that is
        // live now — otherwise the granted claim is refused one step later. Retirement
        // (privacy/route) still refuses, because a retired turn is not admitted work. Absent by
        // default, so a direct-constructed sink keeps the live-origin-only fence.
        admittedWorkAuthority: (() -> GracePeriodSignal.AdmittedWorkAuthority?)? = nil
    ) {
        self.onGracePlaybackHoldBegin = onGracePlaybackHoldBegin
        self.onGracePlaybackHoldEnd = onGracePlaybackHoldEnd
        self.admittedWorkAuthority = admittedWorkAuthority
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.conversationManager = conversationManager
        self.conversationSelectionProvider = conversationSelectionProvider
        self.interruptionState = interruptionState

        self.playbackManager = playbackManager
        self.playbackSink = playbackSink
        self.fingerprintMapper = fingerprintMapper
        self.playbackPositionMs = playbackPositionMs
        self.episodeAvailable = episodeAvailable
        self.currentEpisodeIdProvider = currentEpisodeIdProvider
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
    /// admission tokens bind to and ONE terminal state. LIFETIME IS ARC: the sink's live map holds
    /// the record until retirement detaches it, and each ADMITTED CALLER'S TOKEN holds it while
    /// that caller is still resolving (`DispatchToken.record`). A detached record is therefore
    /// deallocated exactly when its live-map entry and its last outstanding token are both gone —
    /// no counter, no second map (reviewer be89233d/f3492082).
    final class UtteranceRecord {
        let origin: Int?
        let instance = UUID()
        /// The record's ONE terminal state: nil until it settles, then the result it settled with.
        /// A retired record keeps its terminal result for its admitted joiners.
        var terminalResult: CloudRouteResult?
        /// Admitted callers parked awaiting this record's terminal result.
        var waiters: [CheckedContinuation<CloudRouteResult, Never>] = []
        /// True when retirement detached this record from the live map. A detached record answers
        /// only its admitted callers and never stands in for a successor's map entry.
        var detached = false
        init(origin: Int?) { self.origin = origin }
    }
    /// Records keyed by (utterance id, origin). This is the ONLY index: an id may be live in two
    /// windows at once (a delayed admitted turn and a successor reusing the id), and each must
    /// keep its own ownership until its own token releases it. There is no second id-keyed map:
    /// a single id slot either hides a delayed turn's record behind a successor's or vice versa.
    private var recordsByIdentity: [RecordKey: UtteranceRecord] = [:]

    /// Identifies one dispatch's ownership: an utterance id is only unique WITHIN a window, so the
    /// origin is part of the identity.
    struct RecordKey: Hashable {
        let utteranceId: String
        let origin: Int
    }
    /// Retirement detaches records from the live map; each record is held ONLY by the ownership
    /// tokens that were admitted against it (owner + joiners), and is released by the last of
    /// them to resolve. There is no separate long-lived map to leak.
    /// The window identity the retained SETTLED results belong to.
    private var retainedOrigin: Int?

    /// Retires the retained dispatch state when the grace window changes (or ends). SETTLED
    /// results and effect claims retire with the window — a new window starts clean. IN-FLIGHT
    /// records are RETAINED so their held joiners are still settled by their owner; they accept
    /// no new joiners and cannot publish into the new window.
    /// TEST SEAM: whether a record is nameable for this EXACT identity.
    func hasRecordForTesting(utteranceId: String, origin: Int) -> Bool {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return recordsByIdentity[RecordKey(utteranceId: utteranceId, origin: origin)] != nil
    }

    /// TEST SEAM resolution: the record of the LIVE origin for this id, or the only entry when
    /// just one exists. There is no id-keyed slot behind this.
    private func recordForTesting(utteranceId: String) -> UtteranceRecord? {
        let liveOrigin = conversationManager.liveOriginForTesting
        let entries = recordsByIdentity.filter { $0.key.utteranceId == utteranceId }
        if entries.count == 1 { return entries.first?.value }
        return entries.first { $0.key.origin == liveOrigin }?.value
    }

    /// Releases the index entry of a DELAYED admitted turn whose final owner has gone. The record
    /// object itself is NOT detached: already-issued tokens and parked waiters keep it alive and
    /// resolve exactly as before. Only its nameability ends, and only for the non-live origin — a
    /// live-window turn's settled dedup lifetime is unchanged.
    func releaseRetainedAdmittedDispatch(utteranceId: String, origin: Int) {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        guard origin != conversationManager.liveOriginForTesting else { return }
        recordsByIdentity.removeValue(forKey: RecordKey(utteranceId: utteranceId, origin: origin))
    }

    func retireRetainedDispatchesIfWindowChanged(to origin: Int?) {
        ownershipLock.lock()
        if origin != retainedOrigin {
            // Every record belongs to the OLD window. Detach them ALL from the live map: a
            // detached record accepts no new joiners and, crucially, must not block a same-id
            // utterance in the NEW window. Each detached record is still reachable through the
            // ownership TOKENS admitted against it, so its admitted callers resolve against it and
            // it is RELEASED by the last of them (reviewer be89233d) — no immortal second map.
            //
            // A RECORD OF ADMITTED WORK IS THE EXCEPTION, and it is not an immortal second map:
            // the same token lifetime that keeps it reachable through its token must also keep it
            // NAMEABLE by id, or a repeated callback for that delayed turn would find no record
            // and mint a FRESH one — fresh ownership for work that already owns a dispatch. Its
            // origin is no longer live and it can only be reached by the utterance that holds the
            // reservation, so it neither blocks a new window's same-id utterance nor grows
            // unboundedly: it is released exactly like every other record, by its token.
            let authority = admittedWorkAuthority?()
            var retained: [(RecordKey, UtteranceRecord)] = []
            for (key, record) in recordsByIdentity {
                let isAdmittedElsewhere = key.origin != origin
                    && authority?.isAdmittedWork(key.utteranceId, key.origin) == true
                if isAdmittedElsewhere {
                    // Still nameable by its own identity so a repeated callback JOINS it.
                    retained.append((key, record))
                } else {
                    record.detached = true
                    recordsByIdentity.removeValue(forKey: key)
                }
            }
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
        // COHERENT ADMISSION (review 4d474d80/086c0172): the decision reads main-bound state
        // (origin liveness, the turn's admitted-work answer), so it must run ON the main queue,
        // and its publication (recordsByIdentity) must be atomic with that decision or a
        // retirement between snapshot and publication could admit a stale origin. Both are
        // achieved by performing decision AND publication in ONE main-queue block, guarded by
        // `ownershipLock` taken ON main. Lock order stays safe in both directions: every other
        // `ownershipLock` holder never hops to main while holding the lock (verified: the waiter
        // continuation path, `settle`, and the test accessors are main-sync-free under the lock),
        // so an off-main holder cannot deadlock against this main-queue admission; and this block,
        // once running on main, performs no further cross-queue hops. Retirement that lands before
        // the block runs is simply observed by the decision; retirement after publication settles
        // through the normal ownership path.
        guard let origin else { return .refused }
        let decideAndPublish: () -> CloudDispatchOwnership = {
            // TEST HOOK (review 5fa6e007): an explicit interleaving barrier INSIDE the coherent
            // block — production nil. A control can pause the admission mid-decision, perform a
            // window retirement, and release, proving the decision observes the retirement because
            // it reads state INSIDE the block (never from a pre-block snapshot).
            self.admissionInterleavingBarrierForTesting?()
            let originIsLive = origin == self.conversationManager.liveOriginForTesting
            let turnHoldsAdmittedWork: Bool = {
                guard let authority = self.admittedWorkAuthority?() else { return false }
                return authority.isAdmittedWork(utteranceId, origin)
            }()
            self.ownershipLock.lock()
            defer { self.ownershipLock.unlock() }
            guard originIsLive || turnHoldsAdmittedWork else { return .refused }
            // ORIGIN-BOUND OWNERSHIP: a retained record is only the SAME ownership if it belongs to
            // THIS request's origin. A retained record of a different origin must not be joined or
            // observed — otherwise a new-window request that happens to reuse the id would inherit
            // (or be settled by) the earlier window's turn. It is a different turn entirely.
            // The authoritative lookup is (id, origin): an id may be live in two windows at once, and
            // each owns its own record until its own token releases it. Looking up by id alone would
            // let a successor's turn take over the earlier turn's record — making the earlier id
            // unnameable while its token is still live, so its repeated callback would acquire a
            // FRESH owner instead of joining the original.
            let key = RecordKey(utteranceId: utteranceId, origin: origin)
            if let existing = self.recordsByIdentity[key] {
                if let terminal = existing.terminalResult { return .settled(terminal) }
                return .join(.init(utteranceId: utteranceId, instance: existing.instance, record: existing))
            }
            let record = UtteranceRecord(origin: origin)
            self.recordsByIdentity[key] = record
            return .owner(.init(utteranceId: utteranceId, instance: record.instance, record: record))
        }
        if Thread.isMainThread { return decideAndPublish() }
        var disposition: CloudDispatchOwnership!
        DispatchQueue.main.sync { disposition = decideAndPublish() }
        return disposition
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
        return result
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
            guard recordsByIdentity.values.contains(where: { $0 === record }) else { return false }
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
        for (key, live) in recordsByIdentity where live === record && record.detached {
            recordsByIdentity.removeValue(forKey: key)
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
        // MISSING-ID REFUSAL (reviewer 9ab31c6d): a dispatch without an admitted utterance
        // identity has no honest `request_id` to present, so it is refused BEFORE prepare,
        // before any client creation, and before touching successor-owned state — the sink
        // never lets the turn reach the wire under a fabricated identity.
        guard let utteranceId else {
            return CloudRouteResult(response: .silent, outcome: .refused)
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

        // INTERRUPT THE OPEN PRIOR SOCKET (cloud-assistant.md → Interruption, spec c5fe3416).
        //
        // Barge-in means the user spoke over an answer. That is a DIFFERENT act from a local
        // supersede: it must tell the SERVER to stop generating and settle the turn as
        // `interrupted`, on the prior turn's still-open socket, BEFORE that turn's terminal. The
        // server ignores a post-terminal interrupt, so this is a one-shot send with no retry —
        // `claimInterruptEmission` makes "one shot" a property of the state rather than of caller
        // discipline, and a claim made after the terminal returns false.
        //
        // Ordering is load-bearing and deliberate: the claim + send happen BEFORE `cancel()` below.
        // Cancelling first would retire the socket registration the frame needs (and could race
        // the server's own terminal), turning every barge-in into a lost interrupt.
        // THE EAGER PATH MAY HAVE ALREADY RUN (spec e38a790a / reviewer bea7a291). The service
        // calls `emitBargeIn` at input admission, AHEAD of its serial chain, because a barge-in
        // must reach the wire while the predecessor socket is still open — and the serial chain
        // otherwise delays this turn until that socket has closed. Here we only ADOPT that
        // emission; emitting a second time is impossible anyway (`claimInterruptEmission` is one
        // shot), but asking the state rather than re-claiming keeps the reason explicit.
        // A FOLLOW-UP SUBMISSION IS NOT A NEW BARGE-IN. When this utterance is the retained
        // follow-up being submitted after its acknowledgement, the interruption already happened:
        // claiming another one would interrupt whatever is now live and hold this same utterance
        // AGAIN, which is how one utterance became two submissions (reviewer eaa8c06a, observed on
        // the wire as u-barge authenticating as its own turn and again as the follow-up).
        //
        // The binding tells us which turn this utterance interrupted. The submission is the
        // NORMAL dispatch of that utterance, so this turn proceeds as an ordinary turn carrying
        // no interruption of its own.
        let isRetainedFollowUpSubmission = interruptedRequestIdForUtterance(utteranceId) != nil
        var interruptedRequestIdForThisTurn: String? = nil
        if !isRetainedFollowUpSubmission,
           let priorRequestId = activeResultSocket?.requestId,
           (activeTurn.map { !$0.isCancelled }) ?? false,
           interruptionState.claimInterruptEmission(forRequestId: priorRequestId) {
            interruptedRequestIdForThisTurn = priorRequestId
            interruptionState.hold(
                request: request,
                utteranceId: utteranceId,
                origin: origin,
                forRequestId: priorRequestId
            )
            if await sendInterruptOnPriorSocket(forRequestId: priorRequestId) == .undelivered {
                interruptedRequestIdForThisTurn = nil
            }
        }

        if interruptedRequestIdForThisTurn != nil, let priorToken = activeTurn {
            // KEEP THE INTERRUPTED TURN'S RECEIVE ALIVE UNTIL ITS TERMINAL (reviewer ff00457c
            // item 1), now that the interrupt has been SENT. The interrupt needs that turn's
            // terminal to resolve the hold, and the `cancel()` below would otherwise end its
            // receive loop through the owner-cancel path — skipping the very branch that records
            // the acknowledgement, so the acknowledgement would silently never happen.
            //
            // Two things are kept SEPARATE on purpose: playback quiescence (the stop requested
            // below) and the prior TRANSPORT's lifetime (this wait). Waiting for the terminal does
            // not reintroduce the audio overlap the quiescence wait exists to prevent.
            //
            // A turn that cannot answer must not wedge the successor: the wait is BOUNDED, and its
            // expiry is acted on — the hold is dropped, since no terminal is coming to resolve it,
            // and this turn proceeds as an ordinary new turn rather than pretending it settled.
            // STOP LOCAL OUTPUT IMMEDIATELY, BEFORE THE WAIT (reviewer eaa8c06a item 3).
            //
            // The contract's barge-in rule is "the client IMMEDIATELY stops local output and clears
            // buffered answer audio while retaining captured user input" (cloud-assistant.md →
            // Interruption). The stop used to live in the supersede block BELOW this wait, so the
            // answer kept playing for the whole acknowledgement wait — up to the full bound — which
            // is the exact overlap the rule exists to prevent. Stopping only the OUTPUT keeps the
            // receiver alive for the terminal this wait is waiting for; those are different
            // concerns and are now ordered accordingly.
            let bargeInStopEpoch = interruptedRequestIdForThisTurn != nil
                ? audioPlayer.cancel()
                : nil

            if interruptedRequestIdForThisTurn != nil, let priorToken = activeTurn {
                let resolution = await priorToken.awaitAcknowledgement(
                    timeout: Self.interruptionAcknowledgementTimeout
                )
                switch resolution {
                case .acknowledged:
                    // The ONLY outcome that may submit. The follow-up was already released by the
                    // terminal branch; this turn proceeds.
                    break
                case .refused:
                    FileLog.shared.addMessage(
                        "[VoicePipeline] interruption REFUSED for turn "
                        + "\(interruptedRequestIdForThisTurn ?? "nil") — retained utterance "
                        + "DISCARDED and suppressed; it must never be submitted"
                    )
                    // SUPPRESS, not merely release: a refusal is a server answer, and the contract
                    // says never to treat it as settlement or submit the held utterance. This
                    // utterance's turn is already queued, so releasing alone let it reach the wire.
                    interruptionState.suppressHeldFollowUp(
                        forRequestId: interruptedRequestIdForThisTurn ?? ""
                    )
                    interruptedRequestIdForThisTurn = nil
                    // END LOCALLY (reviewer c38ff4ba item 2). Clearing the id and falling through
                    // made THIS turn continue into its own dispatch, authenticating the very
                    // utterance the refusal discarded. A refusal is a server answer about the
                    // interruption; it is not settlement and it authorizes nothing, so nothing may
                    // be submitted for it — including this turn's own successor frame.
                    if let bargeInStopEpoch {
                        _ = await audioPlayer.awaitActualStop(after: bargeInStopEpoch, timeout: 0.25)
                    }
                    return CloudRouteResult(response: .silent, outcome: .refused)
                case .failed:
                    // Timeout or an undelivered send: no acknowledgement can ever arrive, so this
                    // must END LOCALLY. It must NOT be promoted to an ordinary turn — the user's
                    // utterance was an interruption of a turn whose fate is now unknown, and
                    // submitting it would assert a settlement that never happened.
                    FileLog.shared.addMessage(
                        "[VoicePipeline] interruption NOT acknowledged for turn "
                        + "\(interruptedRequestIdForThisTurn ?? "nil") after "
                        + "\(Self.interruptionAcknowledgementTimeout)s — held follow-up dropped, "
                        + "nothing submitted, local generic failure"
                    )
                    interruptionState.suppressHeldFollowUp(
                        forRequestId: interruptedRequestIdForThisTurn ?? ""
                    )
                    interruptedRequestIdForThisTurn = nil
                    if let bargeInStopEpoch {
                        _ = await audioPlayer.awaitActualStop(after: bargeInStopEpoch, timeout: 0.25)
                    }
                    return CloudRouteResult(response: .silent, outcome: .refused)
                }
            }
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
        // THE INTERRUPTION POINT FOR SETTLED PLAYBACK (reviewer eaa8c06a item 4).
        //
        // If the predecessor settled with audio still outstanding, THIS successor stopping it is
        // the moment the user stopped hearing the answer — the fact the contract owes the server.
        // The predecessor could not know it at its own `done`, which is why the binding was
        // recorded there and the report is created here.
        if let playbackPredecessor, audioPlayer.hasOutstandingOutput,
           let interruptedPlayback = interruptionState.takeBufferedPlayback(
               ifOwnedBy: playbackPredecessor
           ) {
            interruptionState.recordPendingReport(
                CloudInterruptionState.PendingReport(
                    requestId: interruptedPlayback.requestId,
                    playbackPositionMs: interruptedPlayback.playbackPositionMs,
                    conversationId: interruptedPlayback.conversationId
                )
            )
            FileLog.shared.addMessage(
                "[VoicePipeline] buffered playback of turn \(interruptedPlayback.requestId) "
                + "interrupted by a successor — report queued for the next authentication frame"
            )
        }
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
        // This turn's wire identity, used by the interruption state to bind an acknowledgement or a
        // refusal to the follow-up it resolves.
        let turnRequestId = turn.requestId
        // The conversation this turn carries, used to stamp an interruption report so the report
        // can be discarded if the user abandons that conversation.
        let turnConversationId = conversation.conversationId
        lastAdmittedConversationId = turnConversationId
        // THE identity of THIS admitted turn, captured ONCE and by value. The action-delivery
        // closure below captures this constant rather than reading "the latest turn" later:
        // turns overlap, and a later turn's admission must not relabel an earlier turn's
        // operations.
        //
        // The IMMUTABLE half (conversation, turn) is bound here. The OWNER half cannot be: it is
        // only knowable from the authenticated acquisition on THIS turn's socket, which does not
        // exist until the client has routed the turn. Reading a global instead would let a
        // delayed action be attributed to whatever turn happens to be current, so the identity is
        // completed below from `routed.resultSocket` — the object this turn owns — and never from
        // `activeResultSocket`, which a successor may already have replaced.
        let admittedConversation = turnConversationId
        let admittedTurnId = turnRequestId
        // Every terminal exit finalizes this request's unresolved hold. Done/refusal already
        // resolve it; cancellation and truncated streams must discard it rather than strand B.
        defer {
            interruptionState.recordRefusal(
                forRequestId: turnRequestId,
                retainingReport: .init(
                    requestId: turnRequestId,
                    playbackPositionMs: nil,
                    conversationId: turnConversationId
                )
            )
            turnToken.markAcknowledgement(.failed)
        }

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

        // The pending interruption report rides THIS turn's authentication frame
        // (cloud-assistant.md → Interruption, spec c5fe3416): taken once, so a turn attaches it a
        // single time. Taken here — at the turn's own wire construction — rather than earlier, so a
        // report cannot be consumed by a turn that never reaches the socket.
        // ABANDONMENT CHECK FIRST (`cloud-assistant.md` → Interruption: abandoning the
        // conversation discards the report). A report describes ONE conversation's settled
        // history; attaching it to a turn that opened or switched to a DIFFERENT conversation
        // would ask the server to correct turns it never settled. Detected here, at the wire
        // construction for this turn, using the conversation id this turn will actually carry.
        if let carriedConversationId = interruptionState.pendingReportConversationId,
           carriedConversationId != conversation.conversationId {
            interruptionState.discardPendingReport()
            FileLog.shared.addMessage(
                "[VoicePipeline] pending interruption report discarded — conversation changed "
                + "from \(carriedConversationId) to \(conversation.conversationId)"
            )
        }
        let pendingInterruptReport = interruptionState.takePendingReport()
        let routed = client.routeWithResultSocket(
            request: request,
            context: routeContext,
            turn: turn,
            sourceTranscript: sourceTranscript,
            sourceLanguage: sourceLanguage,
            pendingInterruptReport: pendingInterruptReport,
            // Confirm the report only once it actually left: a failed connection or token fetch
            // must not destroy a correction the user still owes the server.
            onReportAttached: { [weak self] requestId in
                await MainActor.run { self?.interruptionState.confirmReportAttached(requestId: requestId) }
            }
        )
        // The turn's own result socket: sends bind to THIS registration, so a superseded turn's
        // late results can never ride a successor's socket.
        activeResultSocket = routed.resultSocket
        resultSendClient = client

        // The admitted turn's identity. The OWNER is left unset here on purpose and completed
        // when the first action is consumed — see `AdmittedTurnIdentity.completingOwner(from:)`
        // and its use in the action path.
        //
        // `routeWithResultSocket` returns as soon as it has STARTED the transport task, so the
        // client has not necessarily acquired a credential yet: nil at this instant means "not
        // yet asked", not "no principal". AWAITING it here was the first instinct and is wrong —
        // it blocks stream consumption on a second continuation system, and then every early
        // return that skips publication strands the consumer. Completing at first use defers the
        // question until the answer genuinely exists, with no wait and no extra termination
        // path. The conversation/turn pair is already bound, so the identity cannot drift.
        // The turn-local identity, completed ONCE and reused by every action of this turn.
        let admittedTurnBox = AdmittedTurnIdentityBox(
            AdmittedTurnIdentity(
                conversation: admittedConversation,
                turn: admittedTurnId,
                owner: "",
                sessionCredential: ""
            )
        )

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
        //
        // `turnSocket`, NOT `activeResultSocket`: this turn may already have been superseded, and
        // retiring whatever is live would close a SUCCESSOR's still-open turn.
        if ownerCancelledFlag.isSet || Task.isCancelled {
            turnSocket.finishTurn()
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
                case let .action(tool, action, params, operationId, capabilityVersion, actionBytes,
                                 precondition, parameterViolation):
                    // BUFFERED ADMISSION CHECK: an event drained from the buffer after the owner
                    // was cancelled must not admit any later effect or a completed result. The
                    // handler's mark (or Task.isCancelled) stops consumption here; the turn is
                    // classified earlyClose below, never `completed`.
                    if ownerCancelledFlag.isSet || Task.isCancelled { break turnLoop }
                    await executeAction(
                        tool: tool, action: action, params: params,
                        operationId: operationId, capabilityVersion: capabilityVersion,
                        actionBytes: actionBytes, precondition: precondition,
                        parameterViolation: parameterViolation,
                        admittedTurnBox: admittedTurnBox,
                        admittedTurnSocket: turnSocket,
                        admittedTurnClient: client
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
                    // THE TERMINAL LANDED — signal before any cancellation guard below. A
                    // successor that interrupted this turn is parked on this latch, and the whole
                    // point of the latch is that the terminal ARRIVED; whether this turn then
                    // reports completion is a separate question it answers for itself.
                    //
                    // `.acknowledged`, not `.refused`: a `done` is the acknowledgement even when it
                    // carries `outcome: completed`, which the contract is explicit about
                    // ("do not wait for a second terminal or reopen the closed socket").
                    turnToken.markAcknowledgement(.acknowledged)
                    if ownerCancelledFlag.isSet || Task.isCancelled { break turnLoop }
                    guard !turnToken.isCancelled else { break turnLoop }
                    // INTERRUPTION, ACKNOWLEDGEMENT-FIRST ORDERING (cloud-assistant.md →
                    // Interruption, spec c5fe3416): this `done` — even with `outcome: completed` —
                    // IS the acknowledgement the retained follow-up was waiting for. The contract
                    // forbids waiting for a second terminal or reopening the socket, so this is
                    // settled here: record the pending report for the NEXT turn, and release the
                    // held follow-up for submission on its own new socket. Both are idempotent;
                    // the release returns non-nil exactly once, so two terminals cannot submit it
                    // twice.
                    recordInterruptionAcknowledgement(
                        requestId: turnRequestId,
                        conversationId: turnConversationId
                    )
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
                    // The Swift queue can already be empty while the node still has scheduled audio.
                    let needsDeferral = audioPlayer.hasOutstandingOutput
                    // A coalesced request has no notification of its own. Bind the hold to the
                    // stop owner captured atomically with this request, not its superseded epoch.
                    let scheduledDrain = audioPlayer.finishWithStopBinding()
                    if needsDeferral {
                        restoreHeldForPlayerDrain = (owner: turnToken, drainEpoch: scheduledDrain.stopEpoch)
                        // The hold was acquired at this turn's admitted dispatch; it RETAINS
                        // through done into the actual drain and releases at the real stop.
                    } else {
                        restoreTransientAudioState()
                    }
                    // BUFFERED PLAYBACK AFTER `done` (`cloud-assistant.md` → Interruption:
                    // "Buffered audio may still play after `done` closes the socket. Report that
                    // interruption in the next turn's authentication frame instead"). The socket
                    // is closed but the user is still HEARING the answer, so the fact that only
                    // part of it was heard is still owed to the server — and there is no
                    // interruption left to report it, because the turn already settled.
                    //
                    // Recorded here, at the terminal, because this is the only point that knows
                    // both that the turn settled and that audio remains: `needsDeferral` is that
                    // measurement. A report that named a turn whose audio had already drained
                    // would tell the server the user heard less than they did.
                    if needsDeferral {
                        // BIND THE REPORT'S PRODUCER TO THIS TURN (reviewer eaa8c06a item 4).
                        //
                        // The report is owed when the user stops hearing THIS turn's audio short
                        // of its end. That cannot be known at `done`: `done` only says the server
                        // finished sending and audio remains, not whether the user ever
                        // interrupts the remainder. Recording the report HERE claimed an
                        // interruption that may never happen, and gating on
                        // `interruptedRequestIdForThisTurn` skipped the case entirely — an
                        // ordinary turn that settled with buffered audio had no id, so no report
                        // producer existed at all when a later turn DID interrupt its playback.
                        //
                        // So bind the OWNERSHIP now and create the report at the interruption,
                        // where the fact is actually established.
                        interruptionState.recordBufferedPlaybackOwner(
                            CloudInterruptionState.BufferedPlayback(
                                requestId: turnRequestId,
                                playbackPositionMs: nil,
                                conversationId: turnConversationId,
                                owner: turnToken
                            )
                        )
                        // The turn that interrupted it, if any, is still owed a report immediately:
                        // its interruption was already acknowledged at the socket.
                        if let interrupted = interruptedRequestIdForThisTurn {
                            interruptionState.recordPendingReport(
                                CloudInterruptionState.PendingReport(
                                    requestId: interrupted,
                                    playbackPositionMs: nil,
                                    conversationId: turnConversationId
                                )
                            )
                        }
                    }
                    turnResult = .completed
                    turnResponse = .silent
                    break turnLoop
                case let .error(_, code, _):
                    // A terminal — refused or failed — settles the latch too: a waiter must not be
                    // left parked because the answer was an error rather than a `done`. It settles
                    // as `.refused`, so a successor DISCARDS the held follow-up instead of
                    // submitting an utterance the server never acknowledged (reviewer eaa8c06a).
                    turnToken.markAcknowledgement(.refused)
                    // A cancelled owner (cloud-token supersession OR the caller's own
                    // Task.cancel) classifies as an incomplete turn via the owner-cancel path
                    // below — never as a connection failure it did not observe.
                    guard !turnToken.isCancelled && !Task.isCancelled else { break turnLoop }
                    // INTERRUPTION, REFUSAL-FIRST ORDERING (cloud-assistant.md → Interruption,
                    // spec c5fe3416): a refusal before any terminal acknowledgement DISCARDS the
                    // retained follow-up and retains the pending interruption report for a later
                    // explicit user request. Never treat refusal as settlement, and never submit
                    // the held utterance — so this is the one path that drops it.
                    recordInterruptionRefusal(
                        requestId: turnRequestId,
                        interruptedRequestId: interruptedRequestIdForThisTurn,
                        code: code
                    )
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
                    // THE REMOTE MESSAGE IS NEVER SPOKEN (cloud-assistant.md, spec 961fab07): the
                    // wire `message` is bounded OPERATOR DIAGNOSTICS — "never spoken or used to
                    // select client feedback". So `message` is deliberately NOT read here. What the
                    // user hears is resolved LOCALLY from the stable code: every code maps to its
                    // own `cloud_error_<code>` template in the user's own locale. A code with no
                    // template in that locale (a Required code whose translation is missing is an
                    // observable client GAP, not permission to substitute generic feedback) falls
                    // back to the error earcon — never to English prose, and never to the remote
                    // text. `limit_exceeded` (spec 27ced9b) is Required and names Auris and its
                    // daily allowance; it is one of these templates, not a special case.
                    let spoken = spokenTemplates.resolveForUserLocale("cloud_error_\(code)")
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
        capabilityVersion: String?,
        actionBytes: Data?,
        precondition: [String: CloudRouteJSONValue],
        parameterViolation: AppOperationRequest.ParameterViolation? = nil,
        admittedTurnBox: AdmittedTurnIdentityBox,
        admittedTurnSocket: AppOperationResultSocket?,
        admittedTurnClient: CloudRouteClient
    ) async {
        guard tool == "playback" else { return }
        // COMPLETE ONCE, HERE, and store it in the turn-local box. Deferring to this point is what
        // makes the read correct without waiting: by now the client has either published its
        // acquisition or the turn produced no credential. Storing it means a LATER action of the
        // same turn cannot recapture a different account.
        let admittedTurn = admittedTurnBox.completing(from: admittedTurnSocket)
        await executeCloudMutation(
            action: action, params: params, precondition: precondition,
            operationId: operationId, capabilityVersion: capabilityVersion,
            actionBytes: actionBytes, parameterViolation: parameterViolation,
            admittedTurn: admittedTurn,
            admittedTurnSocket: admittedTurnSocket,
            admittedTurnClient: admittedTurnClient
        )
    }

    /// The wire contract's runtime gate (rev da327e624 §1, amended @ bf5fb219): every cloud app
    /// operation carries `operation_id` AND `capability_version`, both non-empty; an operation
    /// missing either is MALFORMED — refused before any effect, never executed as a legacy
    /// playback frame. A missing half is the amendment's explicit "incomplete pair is
    /// malformed, not legacy playback".
    private func executeCloudMutation(
        action: String,
        params: [String: CloudRouteJSONValue],
        precondition: [String: CloudRouteJSONValue],
        operationId: String?,
        capabilityVersion: String?,
        actionBytes: Data?,
        parameterViolation: AppOperationRequest.ParameterViolation? = nil,
        admittedTurn: AdmittedTurnIdentity,
        admittedTurnSocket: AppOperationResultSocket?,
        admittedTurnClient: CloudRouteClient
    ) async {
        // THE ORIGINAL TURN'S ROUTE, resolved once and used by every result path below —
        // success, refusal, replay and unknown. Nil when the turn has no socket, which refuses to
        // send rather than borrowing a successor's.
        let admittedTurnRoute: (socket: AppOperationResultSocket, client: CloudRouteClient)? =
            admittedTurnSocket.map { (socket: $0, client: admittedTurnClient) }
        // THE CLASSIFICATION BOUNDARY, stated once because it is the difference between a
        // CONTRACT REFUSAL and an AUTHORIZATION:
        //
        //  • NO identity field at all — no `operation_id` AND no `capability_version`. This is a
        //    pre-v1 legacy playback frame. The amendment's rule is that an incomplete or invalid
        //    identity-bearing frame must not EXECUTE VIA THE LEGACY PATH; it does not forbid a
        //    frame that never claimed an identity. Such a frame keeps its original behaviour and
        //    runs the effect below with no journal, no owner and no result frame — it was never
        //    part of the app-operation protocol, so there is nothing to claim or settle.
        //
        //  • ANY identity field present — even one half, a blank string or a wrong type. This IS
        //    an app-operation attempt, and it may never fall back to the legacy path. It is
        //    answered on the wire with a pinned reason and produces zero effects: `.unsupported`
        //    when the pair is absent-or-empty in a way the parser could not classify, and
        //    `invalid_request` when an `operation_id` exists but cannot be accounted for.
        //
        // `classify` already made this decision upstream; re-deriving it here from the two
        // values that survived parsing keeps the sink's boundary identical to the parser's.
        //
        // THE TEST IS PRESENCE, NOT EMPTINESS. `(operationId ?? "").isEmpty` collapses two
        // different frames into one: a frame that never sent an identity field, and a frame that
        // sent an explicit blank. The parser already tells them apart — `classify` keys on
        // `json[...] != nil` and returns `.malformedIdentity` (no event) for the blank case — so
        // a blank-declaring frame never reaches here at all. At this boundary both optionals are
        // `nil` precisely when no identity field was present, and nil-vs-empty is expressible.
        if operationId == nil && capabilityVersion == nil {
            // No identity field of any kind: the established pre-v1 playback path. Deliberately
            // keeps its existing behaviour, including NOT applying v1 required preconditions —
            // the compatibility ruling covers these frames, and retrofitting v1 rules onto them
            // would break them.
            await runLegacyMutation(action: action, params: params)
            return
        }
        await continueIdentifiedOperation(
            action: action, params: params, precondition: precondition,
            operationId: operationId, capabilityVersion: capabilityVersion,
            actionBytes: actionBytes, parameterViolation: parameterViolation,
            admittedTurn: admittedTurn, admittedTurnSocket: admittedTurnSocket,
            admittedTurnClient: admittedTurnClient, admittedTurnRoute: admittedTurnRoute)
    }

    /// Continues an IDENTIFIED operation through the fail-closed gates to its effect.
    private func continueIdentifiedOperation(
        action: String,
        params: [String: CloudRouteJSONValue],
        precondition: [String: CloudRouteJSONValue],
        operationId: String?,
        capabilityVersion: String?,
        actionBytes: Data?,
        parameterViolation: AppOperationRequest.ParameterViolation?,
        admittedTurn: AdmittedTurnIdentity,
        admittedTurnSocket: AppOperationResultSocket?,
        admittedTurnClient: CloudRouteClient,
        admittedTurnRoute: (socket: AppOperationResultSocket, client: CloudRouteClient)?
    ) async {
        // Reached only from the declared-identity branch, which admits a frame carrying at least
        // one identity field. A missing `operation_id` here is an incomplete pair and refuses
        // `unsupported_operation` — never legacy playback.
        guard let operationId, !operationId.isEmpty else {
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.unsupportedOperation)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        }
        // FAIL-CLOSED PREREQUISITES, all checked BEFORE any effect. An identified operation is
        // only executable when the client can actually account for it: a malformed identity pair,
        // a missing journal, a missing owner, a missing conversation/turn, or missing original
        // bytes all refuse. Substituting empty values instead would silently produce a record
        // that cannot distinguish one operation from another.
        // SESSION RE-CHECK AT THE POINT OF USE. The owner was captured at admission; an account
        // switch since then must not get its operation journaled under the account that opened
        // the turn. No live paired session ⇒ treated as no trusted owner.
        // Read from the SAME socket object the identity was captured from. `sessionCredential`
        // being non-empty proves this turn HAD an established principal at admission; asking that
        // turn's socket now is what detects a later account switch on the live connection.
        //
        // Deliberately NOT `activeResultSocket`: a successor turn has already replaced it, so a
        // delayed action from a prior turn would be checked against the SUCCESSOR's session —
        // passing the "still the admitted one" test on the wrong turn and sending a result on a
        // socket that is not its own. Reading this turn's own socket is what keeps the check
        // attached to the identity it was performed for.
        let liveOwner: CloudAuthenticatedSession? = admittedTurn.sessionCredential.isEmpty
            ? nil
            : admittedTurnSocket?.authenticatedSession
        let sessionIsStillTheAdmittedOne = liveOwner?.accountId == admittedTurn.owner
            && !admittedTurn.owner.isEmpty

        let identityPrerequisites: OperationIdentity? = {
            guard !operationId.isEmpty else { return nil }
            guard let capabilityVersion, !capabilityVersion.isEmpty else { return nil }
            guard sessionIsStillTheAdmittedOne else { return nil }
            guard !admittedTurn.conversation.isEmpty, !admittedTurn.turn.isEmpty else { return nil }
            guard let actionBytes, !actionBytes.isEmpty else { return nil }
            return OperationIdentity(
                owner: admittedTurn.owner,
                conversation: admittedTurn.conversation,
                turn: admittedTurn.turn,
                actionBytes: actionBytes
            )
        }()
        guard let identity = identityPrerequisites, let capabilityVersion else {
            // `invalid_request` (wire-pinned): the request cannot be accounted for, so nothing was
            // attempted. The settlement names the malformation rather than claiming the operation
            // is unsupported — and no effect runs.
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.invalidRequest)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        }
        // Exactly-once: the durable claim happens BEFORE the effect, so an interruption leaves a
        // reconstructible record (`.interrupted` → `unknown`) rather than a silent re-run. NO
        // JOURNAL = NO EFFECT: a sink without durable storage cannot claim anything, and an
        // unclaimable operation must not execute.
        guard let operationJournal else {
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.persistenceUnavailable)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        }
        switch operationJournal.claim(operationId, identity: identity) {
        case .identityConflict:
            // Same id, different contents or a different owner/conversation/turn: this is a
            // DIFFERENT operation. It is refused, never executed under the old identity — that
            // would apply an effect no record accounts for.
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.invalidRequest)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        case .alreadyRun(let recorded):
            // REPLAY CONTRACT: answer from the DURABLE RECORD — the outcome AND the state settled
            // with it. The live playback state is not read: an unrelated operation may have moved
            // it since, and a settled answer must not be rewritten by later events.
            await reportRecorded(recorded, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        case .inProgress:
            return
        case .interrupted(let result):
            // The effect is not knowable: answer `unknown`, never re-execute.
            await reportResult(result, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        case .persistenceUnavailable:
            // Fail closed: the exactly-once record could not be durably persisted (or durable
            // history is unreadable). Refuse before any effect — never execute unrecorded.
            let refused = OperationResult.nonSuccess(.refused, reason: OperationReason.persistenceUnavailable)
            recordSeekRejection(refused)
            await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        case .claimed:
            // Runtime gate: an identified operation whose action this build does not implement
            // is REFUSED (unsupported_operation) and the refusal SETTLED durably — never a
            // fabricated success, and a redelivery replays the recorded refusal. Identity-less
            // playback frames NEVER reach here: the gate above refuses them before any claim
            // (there is no legacy fallback that authorizes a mutation without
            // operation_id + capability_version).
            let knownActions: Set<String> = ["seek_to", "play_quote", "stop_quote", "seek_relative", "pause", "resume"]
            // A REQUEST THAT CANNOT RUN IS STILL ANSWERED. Two distinct classes reach here, and
            // they get distinct wire reasons:
            //  - an action this build does not implement → `unsupported_operation`;
            //  - an implemented action whose parameters/targets do not satisfy its contract →
            //    `invalid_request` (or the more specific malformed/stale target reason).
            // Both are settled durably, so a redelivery replays the refusal instead of
            // re-deciding it, and neither runs an effect.
            // The CURRENT-TARGET half of admission needs live playback state, so it is decided
            // here rather than at the parser: the proposal may have been formed for an episode the
            // user has since left. A parser cannot see that; the sink can.
            // FAIL CLOSED AT THE EFFECT BOUNDARY. `.notEvaluated` is the PARSER's answer — a
            // caller that owns no playback state. Here, at the boundary where an effect would be
            // released, a sink that cannot observe the current target cannot prove the proposal
            // is still for the episode the user is on, and "I cannot check" must never authorise
            // a mutation. It is reported as an unavailable target (`.absent`), which refuses
            // `stale_precondition` with zero effects.
            let targetMatch: AppOperationRequest.TargetMatch
            if let currentEpisodeIdProvider {
                targetMatch = currentEpisodeIdProvider().map { .available($0) } ?? .absent
            } else if let playbackManager {
                targetMatch = playbackManager.currentEpisode.map { .available($0.uuid) } ?? .absent
            } else {
                targetMatch = .absent
            }
            var refusalReason: String? = {
                if !knownActions.contains(action) { return OperationReason.unsupportedOperation }
                if let parameterViolation { return Self.wireReason(for: parameterViolation) }
                return nil
            }()
            if refusalReason == nil,
               case let .failure(violation) = AppOperationRequest.validate(
                   action: action, params: params, precondition: precondition,
                   target: targetMatch) {
                refusalReason = Self.wireReason(for: violation)
            }
            if let refusalReason {
                let refused = OperationResult.nonSuccess(.refused, reason: refusalReason)
                let settled = operationJournal.complete(operationId, identity: identity, result: refused)
                if settled {
                    await reportResult(refused, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
                } else {
                    let unsettled = OperationResult.nonSuccess(.unknown, reason: OperationReason.persistenceUnavailable)
                    await reportResult(unsettled, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
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
            //
            // `admittedTurnSocket`, NOT `activeResultSocket`: a superseded turn's cancellation
            // must retire ITS registration. Reaching through the global would close the successor.
            admittedTurnSocket?.finishTurn()
            let unexecuted = OperationResult.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)
            await reportResult(unexecuted, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            return
        }
        let outcome = performIdentifiedMutation(action: action, params: params)
        if let refusal = outcome.refusal {
            // Observe refusal settlement too: a failed refusal-persist leaves the durable
            // record in progress, so the honest report is unknown, never a replayable refusal.
            let settled = operationJournal.complete(operationId, identity: identity, result: refusal)
            recordSeekRejection(refusal)
            if settled {
                await reportResult(refusal, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            } else {
                let unsettled = OperationResult.nonSuccess(.unknown, reason: OperationReason.persistenceUnavailable)
                await reportResult(unsettled, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            }
        } else {
            // Persist the settlement FIRST and observe it: a failed settlement write must not
            // be reported as success — the durable record is still in progress, so the honest
            // answer is unknown, never a replayable success.
            // Settle with the SINGLE OBSERVATION the classification used (voice-intents.md
            // @ 818c8f75): `performIdentifiedMutation` captured it once, so the gate that
            // decided success and the state on the wire cannot come from different readings —
            // for a pause, a gate on observed `false` can never settle `playing: true`.
            Swift.precondition(outcome.settledState != nil,
                               "a succeeded identified mutation must carry its captured state")
            let settledResult = OperationResult.succeeded(state: outcome.settledState!)
            let settled = operationJournal.complete(operationId, identity: identity, result: settledResult)
            if settled {
                // The FIRST send is the SAME CAPTURED envelope that was settled — not a second
                // live snapshot (review 5295572f): between settlement and send the state could
                // move, and then the wire answer and the durable record would disagree.
                await reportFrame(
                    AppOperationResultFrame(
                        operationId: operationId, outcome: .succeeded, state: settledResult.state
                    ),
                    capabilityVersion: capabilityVersion,
                    route: admittedTurnRoute
                )
            } else {
                let unsettled = OperationResult.nonSuccess(.unknown, reason: OperationReason.persistenceUnavailable)
                await reportResult(unsettled, operationId: operationId, capabilityVersion: capabilityVersion, route: admittedTurnRoute)
            }
        }
    }

    /// The wire reason for a parameter-admission violation.
    ///
    /// Each violation states a DIFFERENT fact, and the reason must not flatten them into one:
    /// an unstated target is the wire's generic `invalid_request`, a target that is no longer the
    /// current episode is the specific `stale_precondition` (the server can act on that — the
    /// proposal was formed for an episode the user has moved away from), and a malformed or
    /// ambiguous seek target is `malformed_seek_target`, which is a fact about the REQUEST rather
    /// than about state.
    static func wireReason(for violation: AppOperationRequest.ParameterViolation) -> String {
        switch violation {
        case .unsupportedAction:
            return OperationReason.unsupportedOperation
        case .stalePrecondition:
            return OperationReason.stalePrecondition
        case .ambiguousSeekTarget, .wrongType, .missingField:
            return OperationReason.malformedSeekTarget
        case .missingPrecondition:
            return OperationReason.invalidRequest
        }
    }

    /// Runs the mutation. Returns the refusal to record (nil = executed).
    /// The LEGACY playback path: a frame that never claimed an identity. It runs the same
    /// effect, and NOTHING else — no journal claim (there is no identity to claim under), no
    /// owner, no result frame (the pre-v1 protocol expects no answer), no refusal settlement.
    ///
    /// Deliberately NOT routed through `executeCloudMutation`'s post-effect tail: everything
    /// after the claim there is about durably settling an identified operation, and inventing an
    /// identity for a legacy frame to reuse it is exactly the fabrication the amendment forbids.
    private func runLegacyMutation(action: String, params: [String: CloudRouteJSONValue]) async {
        if let refusal = performMutation(action: action, params: params) {
            // A precondition failure on a legacy frame is observable to the user, not silent.
            recordSeekRejection(refusal)
        }
    }

    /// The IDENTIFIED-operation mutation path (voice-intents.md @ 818c8f75): for `playback.pause`
    /// it produces ONE fresh post-sink observation and returns it as the state the caller must
    /// settle and send, so classification and wire state cannot come from different readings.
    /// Every other action, and the whole legacy path, behave exactly as `performMutation` does.
    ///
    /// Returns `(refusal, settledState)`: a non-nil refusal is settled and reported as-is with
    /// NO state; a nil refusal means the mutation succeeded and `settledState` is the captured
    /// observation to settle and send.
    private func performIdentifiedMutation(
        action: String, params: [String: CloudRouteJSONValue]
    ) -> (refusal: OperationResult?, settledState: [String: CloudRouteJSONValue]?) {
        if action == "pause" {
            _ = playbackSink.pause()
            didAutoPause = false
            // A v1 `succeeded` result requires a fresh observed `{"playing": false}` after the
            // pause sink completes; an already-paused engine satisfies this idempotently. The
            // value is the engine's current reading — never the request, an earcon, a cached
            // pre-action read or an answer hold. Unavailable: `unknown`/
            // `playback_state_unavailable`. Still playing: a FAILED pause
            // (`pause_not_observed`), not a refusal — the mutation was attempted. Non-success
            // carries no state.
            switch playbackSink.observedPlaying {
            case nil:
                return (.nonSuccess(.unknown, reason: OperationReason.playbackStateUnavailable), nil)
            case .some(true):
                return (.nonSuccess(.failed, reason: OperationReason.pauseNotObserved), nil)
            case .some(false):
                return (nil, ["position_seconds": .int(playbackPositionMs() / 1000), "playing": .bool(false)])
            }
        }
        let refusal = performMutation(action: action, params: params)
        return (refusal, refusal == nil ? currentPlaybackState() : nil)
    }

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
            // LEGACY path: unchanged response behaviour (voice-intents.md @ 818c8f75). The
            // OBSERVED pause classification lives only in the identified-operation path —
            // `performIdentifiedMutation` below — so a legacy turn never reports an
            // app-operation result and never classifies a pause at all.
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
    // MARK: - Interruption state transitions
    //
    // These are the two orderings of `cloud-assistant.md` → Interruption, and each is a single
    // call so the sink cannot half-apply one. `CloudInterruptionState` owns the compare-and-set
    // that makes each transition happen exactly once even if two terminals race.

    /// The prior turn reached its terminal: release the held follow-up for submission on its own
    /// socket, and retain the pending interruption report for the next turn.
    ///
    /// `done` counts as acknowledgement even with `outcome: completed` — the contract forbids
    /// waiting for a second terminal — so this is called from the `done` branch only.
    private func recordInterruptionAcknowledgement(requestId: String, conversationId: String) {
        let released = interruptionState.recordTerminalAcknowledgement(forRequestId: requestId)
        if let released {
            // The report names the INTERRUPTED turn, which is the turn whose held follow-up this
            // acknowledgement resolves — not the turn that happened to complete. Recording the
            // completing turn's id here was a real bug the ordering controls caught: the report
            // then travelled to the following turn describing a turn nobody interrupted.
            interruptionState.recordPendingReport(
                CloudInterruptionState.PendingReport(
                    requestId: released.interruptedRequestId,
                    playbackPositionMs: nil,
                    // The conversation this turn runs in IS the interrupted turn's conversation:
                    // a barge-in continues the same conversation.
                    conversationId: conversationId
                )
            )
            pendingFollowUpSubmission = released
            FileLog.shared.addMessage(
                "[VoicePipeline] interruption acknowledged for turn \(requestId) — follow-up "
                + "\(released.utteranceId) released for submission"
            )
        }
    }

    /// The prior turn was REFUSED before any terminal: discard the held follow-up, keep the report.
    private func recordInterruptionRefusal(
        requestId: String,
        interruptedRequestId: String?,
        code: String
    ) {
        // The refusal discards the held follow-up and retains a report naming the INTERRUPTED turn.
        // The server applies the report to already-settled history, so it must name a turn the
        // server knows we interrupted — which is the interrupted turn, not the refused one.
        let reportConversationId = lastAdmittedConversationId
        let discarded = interruptionState.recordRefusal(
            forRequestId: interruptedRequestId ?? requestId,
            retainingReport: CloudInterruptionState.PendingReport(
                requestId: interruptedRequestId ?? requestId,
                playbackPositionMs: nil,
                // Refusals are recorded from the failing turn's own scope, which does not know the
                // interrupted turn's conversation; the report is conversation-scoped, so the
                // caller stamps it (a nil stamp simply cannot be discard-checked, which is the
                // conservative outcome: the report is carried, never silently dropped).
                conversationId: reportConversationId
            )
        )
        if discarded {
            FileLog.shared.addMessage(
                "[VoicePipeline] interruption refused for turn \(requestId) (code=\(code)) — "
                + "held follow-up discarded, pending report retained"
            )
        }
    }

    // MARK: - Eager barge-in (spec e38a790a, reviewer bea7a291)

    /// Whether this utterance's interruption was refused, so its turn must not be submitted.
    @MainActor
    func isSuppressedForTesting(_ utteranceId: String?) -> Bool {
        guard let utteranceId else { return false }
        return interruptionState.isSuppressed(utteranceId)
    }

    /// Which interrupted turn, if any, this utterance is the retained follow-up for.
    ///
    /// Synchronous so the eager path can decide without awaiting. Nil when this utterance is not
    /// holding a follow-up (the ordinary case).
    nonisolated func interruptedRequestIdForUtterance(_ utteranceId: String?) -> String? {
        guard let utteranceId else { return nil }
        return interruptionState.interruptedRequestId(forHeldUtterance: utteranceId)
    }

    /// Nil in production; orders a request’s failed-send cleanup against its receive terminal.
    var beforeUnsentHoldReleaseForTesting: ((String) async -> Void)?
    var afterUnsentHoldReleaseForTesting: ((String) -> Void)?

    /// Send the `interrupt` frame on the prior turn's still-open socket, if there is one.
    ///
    /// Extracted so the eager path and the dispatch path share ONE implementation. Returns the
    /// send report; `.undelivered` means no acknowledgement can ever arrive and the caller must
    /// drop the hold rather than wait.
    @discardableResult
    private func sendInterruptOnPriorSocket(
        forRequestId priorRequestId: String
    ) async -> CloudRouteClient.AppOperationResultSendReport? {
        guard let priorSocket = activeResultSocket, let client = resultSendClient else {
            // No transport to interrupt: no acknowledgement can come, so nothing may stay held.
            interruptionState.releaseUnsentHold(forRequestId: priorRequestId)
            return .undelivered
        }
        // AWAITED, because delivery IS the interruption: a fire-and-forget send could be scheduled
        // after this turn retires the registration, which is how an interrupt becomes a silent
        // no-op. Position is omitted until one is actually measured.
        let report = await client.sendInterrupt(
            requestId: priorRequestId,
            playbackPositionMs: nil,
            via: priorSocket
        )
        if report == .undelivered {
            await beforeUnsentHoldReleaseForTesting?(priorRequestId)
            // The frame never reached the server, so no terminal is coming to resolve the hold.
            interruptionState.releaseUnsentHold(forRequestId: priorRequestId)
            afterUnsentHoldReleaseForTesting?(priorRequestId)
        }
        return report
    }

    /// THE EAGER BARGE-IN STEP. Called by the service at INPUT ADMISSION, ahead of its serial
    /// routing chain.
    ///
    /// WHY IT MUST BE EAGER (spec e38a790a, reviewer bea7a291): the contract requires the interrupt
    /// while the prior socket remains open (`9e309cc1` → Interruption). Routing inputs run through
    /// a serial chain, so this turn's dispatch cannot run until the predecessor has finished — by
    /// which time its socket is closed and the interrupt is useless or refused. The interruption
    /// must therefore be triggered at admission, while the predecessor is still live. Only the
    /// INTERRUPTION steps move here: classification and execution stay serial, and the retained
    /// follow-up is still submitted only by the acknowledgement, through normal admission checks.
    ///
    /// Returns the turn this utterance interrupted, so the caller can pass it through; nil means
    /// "not a barge-in" (no live predecessor, or already claimed). Idempotent and safe to call from
    /// concurrent inputs: `claimInterruptEmission` admits exactly one claimant per predecessor, and
    /// `hold` refuses a second hold for a different turn.
    @discardableResult
    @MainActor
    func emitBargeIn(
        request: String,
        utteranceId: String?,
        origin: Int?,
        selection: CloudConversationSelection? = nil,
        sourceTranscript: String? = nil,
        sourceLanguage: String? = nil,
        translationKind: TranslationKind? = nil,
        validatingEpoch: UInt64? = nil,
        isEpochStillCurrent: (@Sendable (UInt64) -> Bool)? = nil
    ) async -> String? {
        guard let utteranceId else { return nil }
        // A PRE-EXISTING BINDING IS NOT RETENTION (regression caught by the
        // ServiceSelectionProvenance queued-input controls). `interruptedRequestIdForUtterance` is
        // keyed by utterance id, and two DISTINCT turns may legitimately reuse one. Returning the
        // old binding made the second turn believe it had been retained by an interruption that had
        // already resolved, so it handed its execution to a bridge that would never submit it and
        // the turn was silently lost. Retention for this call therefore means exactly one thing:
        // the claim below, made against a LIVE predecessor.
        //
        // A genuine second eager call for the SAME capture cannot reach here — the eager step runs
        // once per admission — so nothing is lost by not short-circuiting on the stored binding.
        // A TURN CANNOT INTERRUPT ITSELF. If the live predecessor carries the SAME identity as the
        // incoming capture, this is not a barge-in: it is the same admitted utterance (a repeated
        // dispatch, or a follow-up reconstructed from the same capture) meeting its own turn. The
        // ServiceSelectionProvenance queued-input controls drive exactly this shape, and treating it
        // as a barge-in made the successor hand its execution to a bridge that would never submit
        // it, silently losing the turn.
        guard activeResultSocket?.requestId != utteranceId else { return nil }
        guard let priorRequestId = activeResultSocket?.requestId,
              (activeTurn.map { !$0.isCancelled }) ?? false,
              interruptionState.claimInterruptEmission(forRequestId: priorRequestId) else {
            return nil
        }
        guard interruptionState.hold(
            request: request,
            utteranceId: utteranceId,
            origin: origin,
            selection: selection,
            sourceTranscript: sourceTranscript,
            sourceLanguage: sourceLanguage,
            translationKind: translationKind,
            forRequestId: priorRequestId
        ) else {
            // A different turn is already holding a follow-up: the contract allows exactly one
            // retained follow-up, so this utterance must not displace it.
            return nil
        }
        // THE INPUT'S OWN WINDOW IS REVALIDATED AT THE EFFECT BOUNDARY (reviewer c38ff4ba item 3).
        //
        // The caller checked `epoch` BEFORE the main-actor hop into this function, and awaits sit
        // between that check and the send. Testing the PRIOR socket/token here would answer a
        // different question — "is the turn being interrupted still live?" — and would let a stale
        // capture interrupt a perfectly valid turn: a service stop/restart in that window ends
        // THIS input's capture while the predecessor remains live. The only correct question at
        // the effect boundary is whether the window that admitted this input is still current,
        // asked of the service, immediately before the frame leaves.
        if let validatingEpoch, let isEpochStillCurrent, !isEpochStillCurrent(validatingEpoch) {
            interruptionState.releaseUnsentHold(forRequestId: priorRequestId)
            FileLog.shared.addMessage(
                "[VoicePipeline] capture window ended before the interrupt send for turn "
                + "\(priorRequestId) — utterance \(utteranceId) suppressed, nothing interrupted"
            )
            return nil
        }
        guard activeResultSocket?.requestId == priorRequestId else {
            interruptionState.releaseUnsentHold(forRequestId: priorRequestId)
            FileLog.shared.addMessage(
                "[VoicePipeline] interruption ownership lost before the send for turn "
                + "\(priorRequestId) — utterance \(utteranceId) suppressed, nothing interrupted"
            )
            return nil
        }
        // STOP LOCAL OUTPUT IMMEDIATELY — before the send, and long before any wait. The contract
        // says the client stops output and clears buffered answer audio immediately on barge-in.
        _ = audioPlayer.cancel()
        if await sendInterruptOnPriorSocket(forRequestId: priorRequestId) == .undelivered {
            // The interruption already claimed this input. A matching done may have handed it
            // to the bridge while the send was suspended; otherwise failed-send cleanup discards
            // it. Neither disposition returns execution ownership to the queued input link.
            FileLog.shared.addMessage(
                "[VoicePipeline] interrupt undelivered for turn \(priorRequestId) — "
                + "queued link \(utteranceId) retired; interruption settlement owns its disposition"
            )
            return priorRequestId
        }
        FileLog.shared.addMessage(
            "[VoicePipeline] barge-in emitted eagerly for turn \(priorRequestId) from "
            + "utterance \(utteranceId)"
        )
        return priorRequestId
    }

    /// Take the follow-up released by an interruption acknowledgement. Read-and-clear, so the
    /// submitter submits it exactly once.
    @MainActor
    func takeReleasedInterruptionFollowUp() -> CloudInterruptionState.ReleasedFollowUp? {
        let released = pendingFollowUpSubmission
        pendingFollowUpSubmission = nil
        return released
    }

    /// Take the pending interruption report for the next turn's authentication frame.
    @MainActor
    func takePendingInterruptionReport() -> CloudInterruptionState.PendingReport? {
        interruptionState.takePendingReport()
    }

    /// The consumer surface also fires (generic, transport-less contexts).
    private func reportResult(
        _ result: OperationResult,
        operationId: String?,
        capabilityVersion: String?,
        route: (socket: AppOperationResultSocket, client: CloudRouteClient)?
    ) async {
        // THE ORIGINAL TURN'S ROUTE, threaded in. Reading `activeResultSocket`/`resultSendClient`
        // here let a superseded turn's refusal ride whatever successor happened to be live — the
        // same defect the admission fix was supposed to close, left open on the send side.
        guard let operationId, let route else { return }
        let socket = route.socket
        guard let frame = AppOperationResultFrame(
            operationId: operationId,
            outcome: result.outcome,
            reason: result.reason
        ) else { return }
        _ = capabilityVersion // validated at the gate; rides the action frame, not the result
        // AWAITED inside the turn loop: a fire-and-forget Task can be scheduled after the turn's
        // socket closed, turning a deliverable result into a spurious undelivered (measured).
        _ = await route.client.sendOperationResult(frame, via: socket)
    }

    /// Diagnostic: this turn's bound result socket handle.


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
        capabilityVersion: String?,
        route: (socket: AppOperationResultSocket, client: CloudRouteClient)?
    ) async {
        // The route is REQUIRED and comes from the ORIGINAL turn: a replayed answer answers that
        // turn's operation, not whatever turn is live when the replay lands.
        guard let route,
              let frame = AppOperationResultFrame(
                operationId: operationId,
                outcome: recorded.outcome,
                reason: recorded.reason,
                state: recorded.state
              ) else { return }
        await reportFrame(frame, capabilityVersion: capabilityVersion, route: route)
    }

    private func reportFrame(
        _ frame: AppOperationResultFrame?,
        capabilityVersion: String?,
        route: (socket: AppOperationResultSocket, client: CloudRouteClient)?
    ) async {
        _ = capabilityVersion // validated at the gate; rides the action frame, not the result
        guard let frame, let route else { return }
        _ = await route.client.sendOperationResult(frame, via: route.socket)
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
    /// The follow-up released by an interruption acknowledgement, waiting to be submitted on its
    /// own socket. Read-and-clear by the submitter so it is submitted exactly once.
    @MainActor private(set) var pendingFollowUpSubmission: CloudInterruptionState.ReleasedFollowUp?

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
        // THE PRODUCTION DRAIN PATH (reviewer c38ff4ba item 4). Until now nothing in production
        // ever cleared the buffered-playback binding: a test called it directly, so the "audio
        // drained on its own owes nothing" claim had no production witness. The confirmed drain
        // IS that moment — the turn has finished and its output quiesced — so a later successor
        // must not find a stale binding and report an interruption of audio nobody stopped.
        interruptionState.clearBufferedPlaybackOwner(ifOwnedBy: deferred.owner)
        restoreTransientAudioState()
    }
}
