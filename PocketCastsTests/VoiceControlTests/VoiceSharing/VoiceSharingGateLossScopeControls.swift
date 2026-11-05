//
//  VoiceSharingGateLossScopeControls.swift
//  PocketCastsTests
//
//  THE FOREGROUND DRAIN WAS BEING CANCELLED BY ITS OWN REFRESH (2026-11-05, live build measurement).
//
//  Measured on the installed app: a foreground transition logged all three gates open and, 1 ms
//  later, `gate lost (temporary) — durable queue RETAINED`, which calls `uploadTrigger?.stop()`.
//  The membership-store observer fired that fan-out on EVERY notification, so the ordinary
//  projection refresh the foreground itself triggers cancelled the drain it had just started. 32
//  retained recordings could never drain.
//
//  These controls pin the corrected rule (spec d28fb334): the fan-out is for a CONSENT LOSS or an
//  ACCOUNT REPLACEMENT. A benign same-account projection must not stop anything.
//

import XCTest
import PocketCastsServer

@testable import podcasts

final class VoiceSharingGateLossScopeControls: XCTestCase {
    private var root: URL!
    private var store: VoiceSharingEnrollmentStore!
    private var previousUserId: String?
    private var previousEmail: String?

    override func setUp() {
        super.setUp()
        // SAVE THE GLOBALS (spec f81580be): this control drives the real store against a live
        // session, so it must put the user's account back exactly as it found it, not nil it.
        previousUserId = ServerSettings.userId
        previousEmail = ServerSettings.syncingEmail()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateLossScope-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ServerSettings.userId = "acct-1"
        store = VoiceSharingEnrollmentStore(
            defaults: UserDefaults(suiteName: "GateLossScope-\(UUID().uuidString)")!,
            accountScopeProvider: { ServerSettings.userId ?? "signed-out" },
            sessionIdentityProvider: { ServerSettings.userId })
    }

    override func tearDown() {
        ServerSettings.userId = previousUserId
        ServerSettings.setSyncingEmail(email: previousEmail)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Drives the coordinator's PRODUCTION observer path by mutating the store, which is what the
    /// live app does when a projection lands. The control never calls the fan-out directly, so a
    /// regression in the observer's predicate is visible here.
    func test_aBenignSameAccountProjectionDoesNotStopTheDrain() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        // Premise: consent is held, so any fan-out here is BY DEFINITION spurious.
        XCTAssertTrue(store.consentAllowsCollection, "premise: consent is held before the refresh")

        // THE BENIGN EVENT: a same-account projection refresh that changes nothing about consent —
        // exactly what a foreground refresh applies.
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        XCTAssertEqual(fanOuts, 0,
                       "a benign same-account projection must NOT fan out — that fan-out stops the "
                           + "drain the same foreground event started")
        XCTAssertTrue(store.consentAllowsCollection, "consent is still held after the refresh")
    }

    /// THE POSITIVE CONTROL: the same observation must be able to SEE a real loss. Without this,
    /// the zero above would pass even if the fan-out were gutted entirely.
    func test_bAWithdrawalStillFansOut() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        // The SAME path: an authoritative projection, this time carrying a withdrawal.
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: false,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .withdrawn),
            readUnder: try XCTUnwrap(store.projectionToken()))

        XCTAssertEqual(fanOuts, 1, "a withdrawal MUST fan out — the observation is able to fail")
        XCTAssertFalse(store.consentAllowsCollection, "premise: consent is gone")
    }

    /// ACCOUNT REPLACEMENT between two OPTED-IN accounts must still cancel (spec d28fb334): the
    /// consent predicate alone cannot see it, because both accounts hold consent. This is the
    /// control for the SCOPE half of the rule — without it, narrowing to consent truth alone would
    /// silently leak the old owner's in-flight work into the new account.
    ///
    /// The swap deliberately does NOT go through `transitionToAccount(signedIn: false)`: that
    /// re-initialises the snapshot and drops consent, so the CONSENT check would fire and the scope
    /// check would never be exercised. Here account 2 is already signed in and already opted in, and
    /// only the account scope moves — consent reads `true` on both sides of the event.
    func test_cAccountReplacementBetweenTwoOptedInAccountsStillFansOut() async throws {
        let defaults = UserDefaults(suiteName: "GateLossScope-\(UUID().uuidString)")!
        var scope = "acct-1"
        // Account 2's state must exist under its own scope BEFORE the swap, so the replacement does
        // not look like a consent change: it is purely a change of WHICH owner the snapshot is for.
        store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { scope },
            sessionIdentityProvider: { scope })
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))
        XCTAssertTrue(store.consentAllowsCollection, "premise: account 1 holds consent")

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        // ACCOUNT 2 was already opted in under its own scope, then the session moves to it.
        let accountTwo = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-2" },
            sessionIdentityProvider: { "acct-2" })
        accountTwo.transitionToAccount(signedIn: true)
        accountTwo.setLocalOptIn(true)
        accountTwo.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-2", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(accountTwo.projectionToken()))

        scope = "acct-2"
        store.transitionToAccount(signedIn: true)

        XCTAssertTrue(store.consentAllowsCollection,
                      "both accounts hold consent, which is exactly why scope must be checked")
        XCTAssertGreaterThan(fanOuts, 0,
                             "an account replacement must fan out even when both accounts opt in — "
                                 + "the consent predicate alone cannot see it")
    }

    /// THE ASSEMBLED-PATH CONTROL (spec f81580be): counting fan-outs proves the predicate, not the
    /// COMPOSITION. Here an actual drain is in flight and a benign same-account projection lands
    /// mid-flight; the drain must still reach the wire. Before the fix the fan-out called
    /// `uploadTrigger.stop()`, which is what killed the live foreground drain after 1 ms.
    func test_eAnInFlightDrainSurvivesABenignProjectionAndReachesTheWire() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let entry = try makeReadyEntry(queue)
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let wire = GateLossWire()
        let trigger = VoiceControlAssembly().makeVoiceSharingUploadTrigger(
            queue: queue,
            isAuthorized: { self.store.consentAllowsCollection },
            currentIdentity: {
                VoiceSharingUploadIdentity(
                    accountScope: ServerSettings.userId ?? "signed-out", enrollmentEpoch: "epoch-1")
            },
            baseURLProvider: { "https://unit.test" },
            tokenProvider: GateLossTokens(),
            session: wire.session)
        let subscription = coordinator.registerGateLostHandler {
            // THE PRODUCTION HANDLER'S EFFECT: this is the call that cancelled the live drain.
            trigger.stop()
        }
        defer { _ = subscription }
        await coordinator.settleObservedWork()

        wire.reset()
        trigger.triggerDrainIfPermitted()
        // THE BENIGN PROJECTION LANDS WHILE THE DRAIN IS IN FLIGHT.
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))
        await trigger.awaitDrainCompletionForTesting()

        XCTAssertEqual(wire.uploadRequests, 1,
                       "the in-flight drain must survive a benign projection and reach the wire")
        XCTAssertTrue(store.consentAllowsCollection, "premise: consent never left")
        _ = entry
    }

    /// A SIGNED-OUT transition is a real loss and must still fan out.
    func test_dSignOutStillFansOut() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        store.transitionToAccount(signedIn: false)

        XCTAssertGreaterThan(fanOuts, 0, "sign-out must fan out")
        XCTAssertFalse(store.consentAllowsCollection, "premise: consent is gone")
    }

    private func makeReadyEntry(_ queue: VoiceSharingUploadQueue) throws
        -> VoiceSharingUploadQueue.Entry
    {
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
        let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        try queue.finalize(entry)
        return entry
    }
}

/// Counts upload-route requests only, so "reached the wire" means the contribution POST and not
/// the token call that precedes it.
private final class GateLossWire: URLProtocol {
    static let lock = NSLock()
    static var uploads = 0

    var uploadRequests: Int { GateLossWire.lock.lock(); defer { GateLossWire.lock.unlock() }; return GateLossWire.uploads }
    func reset() { GateLossWire.lock.lock(); GateLossWire.uploads = 0; GateLossWire.lock.unlock() }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GateLossWire.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let bearer = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "")
        var status = 200
        var body: [String: Any] = [:]
        if path == CloudAuthTokenProvider.tokenPath {
            body = ["access_token": "tok-\(bearer ?? "none")", "refresh_token": "chain",
                    "expires_in": 900, "token_type": "Bearer"]
        } else if path == VoiceSharingUploadTransport.uploadPath {
            GateLossWire.lock.lock(); GateLossWire.uploads += 1; GateLossWire.lock.unlock()
            // A refusal, so acceptance is not this control's subject: only the wire is.
            status = 503
        } else if path == VoiceSharingAccountClient.projectionPath {
            body = ["schema_version": 1, "membership_revision": "rev-1", "plan": "free",
                    "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                    "accepted_disclosure_version": "voice-sharing-v1", "withdrawal_state": "active"]
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A token provider that hands back a fixed credential without a network round trip, so the control
/// measures the upload path rather than its auth preamble.
private final class GateLossTokens: CloudTokenProviding {
    func token() async -> String? { "tok-acct-1" }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {}
}
