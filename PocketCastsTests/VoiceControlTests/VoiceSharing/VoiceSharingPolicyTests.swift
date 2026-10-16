import XCTest
@testable import podcasts

/// A fixed clock so lease arithmetic is exact rather than scheduling-dependent.
private final class StubMonotonicClock: MonotonicClock {
    private(set) var nowValue: MonotonicTime
    init(time: MonotonicTime) { nowValue = time }
    func advance(_ seconds: TimeInterval) { nowValue += seconds }
    func now() -> MonotonicTime { nowValue }
}

final class VoiceSharingPolicyTests: XCTestCase {

    // The fail-closed asymmetry: an absent/invalid remote value can only DISABLE.
    func test_absentRemoteSwitch_disablesFeature_localDefaultNeverEnables() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .unavailable },
            isAccountEnrolled: { true }
        )
        XCTAssertNil(policy.refreshAfterActivation())
        XCTAssertFalse(policy.permitsCollection, "an unavailable remote value must never enable collection")
    }

    func test_enrolledButRemoteDisabled_staysDisabled() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(false) },
            isAccountEnrolled: { true }
        )
        _ = policy.refreshAfterActivation()
        XCTAssertFalse(policy.permitsCollection)
    }

    func test_remoteEnabledButNotEnrolled_staysDisabled_enrollmentIsAccountStateNotConfig() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { false }
        )
        _ = policy.refreshAfterActivation()
        XCTAssertFalse(policy.permitsCollection, "Firebase supplies configuration, never authorization")
    }

    func test_allConditionsMet_permitsUntilLeaseExpiry_thenDisablesWithoutMutation() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        _ = policy.refreshAfterActivation()
        XCTAssertTrue(policy.permitsCollection)
        clock.advance(59)
        XCTAssertTrue(policy.permitsCollection)
        clock.advance(2) // t = 1061 > 1060 expiry
        XCTAssertFalse(policy.permitsCollection, "expired lease behaves as disabled")
        // Expired-but-true remote value cannot resurrect it without a fresh activation read.
        clock.advance(1)
        XCTAssertFalse(policy.permitsCollection)
    }

    func test_invalidPublicationClearsPreviousGoodSnapshot_insteadOfStickyLastGood() {
        let clock = StubMonotonicClock(time: 1_000)
        var remote: VoiceSharingPolicy.RemoteSwitchValue = .valid(true)
        let policy = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60,
            readRemoteSwitch: { remote },
            isAccountEnrolled: { true }
        )
        _ = policy.refreshAfterActivation()
        XCTAssertTrue(policy.permitsCollection)
        remote = .unavailable
        XCTAssertNil(policy.refreshAfterActivation(), "a bad publication must clear the snapshot")
        XCTAssertFalse(policy.permitsCollection)
    }

    /// Restart rule (reviewer finding 4): nothing persisted restores validity.
    /// This test models restart by constructing a NEW policy instance — exactly
    /// what the process does on relaunch — and asserting the first read is OFF
    /// until a real fetch→activate completes. There is deliberately no API that
    /// accepts a restored timestamp or cached value as lease evidence.
    func test_restart_neverRestoresLeaseFromPersistedTime_freshActivateRequired() {
        let clock = StubMonotonicClock(time: 50_000)
        let relaunched = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60 * 60,
            readRemoteSwitch: { .valid(true) },   // remote still says enabled
            isAccountEnrolled: { true }           // account still enrolled
        )
        XCTAssertFalse(relaunched.permitsCollection, "before activate completes after restart, collection is off regardless of remote/account state")
        _ = relaunched.refreshAfterActivation()
        XCTAssertTrue(relaunched.permitsCollection, "only a fresh post-activation install enables it")
    }

    /// Compile-time proof there is no restore-from-persistence surface at all:
    /// the type has no initializer parameter or method taking a stored snapshot.
    func test_policyHasNoPersistenceRestoreSurface() {
        let mirror = Mirror(reflecting: VoiceSharingPolicy(clock: SystemMonotonicClock(), readRemoteSwitch: { .unavailable }, isAccountEnrolled: { false }))
        let storedNames = Set(mirror.children.map { $0.label ?? "" })
        XCTAssertFalse(storedNames.contains("restored"), "no hidden restore slot may exist")
        XCTAssertNotNil(storedNames)
    }

    // MARK: - Target-membership boundary (the real defect this file must not re-break)

    /// The actual failure we hit was NOT in the app target: `FirebaseManager.swift` is an
    /// explicitly-listed source of THREE targets — podcasts, Pocket Casts App Clip and
    /// Pocket Casts TV App — while `podcasts/VoiceControl/**` reaches a target only through
    /// that target's `fileSystemSynchronizedGroups`. App Clip/TV do not sync VoiceControl at
    /// all, so an unguarded reference from FirebaseManager into VoiceSharing failed to compile
    /// for them even though the app target built fine. This control pins that asymmetry against
    /// the live project file; if membership ever changes, this fails and the guard can be revisited.
    /// FirebaseManager.swift is an explicitly-listed source of THREE targets (podcasts, App Clip,
    /// TV App), but `podcasts/VoiceControl/**` reaches a target only through that target's
    /// `fileSystemSynchronizedGroups` — and only the app target lists VoiceControl. That asymmetry
    /// is what actually broke the build: the app target compiled fine while App Clip failed with
    /// "cannot find 'VoiceSharingCoordinator' in scope". This control pins the asymmetry against the
    /// live project file so the #if !APPCLIP guard cannot silently become unnecessary (or wrong).
    func test_voiceControlIsSynchronizedIntoAppTargetOnly_notIntoAppClipOrTV() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoiceSharing/
            .deletingLastPathComponent()   // VoiceControlTests/
            .deletingLastPathComponent()   // PocketCastsTests/
            .deletingLastPathComponent()   // source root (worktree, or build-fixed when mirrored)
            .appendingPathComponent("podcasts.xcodeproj/project.pbxproj")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            XCTFail("could not find project file at \(projectURL.path) — the pin cannot be verified")
            return
        }
        let src = try String(contentsOf: projectURL, encoding: .utf8)
        let voiceControlID = "A1F8767439C1AD83A362A39B" /* VoiceControl synchronized root group */

        /// Slice FIRST, then use only that slice's own indices: mixing a String.Index produced
        /// against `src` with results from `body.range(of:)` does not compile.
        func syncGroupIDs(ofTarget id: String, named name: String) -> [String] {
            guard let anchor = src.range(of: "\t\t\(id) /* \(name) */ = {\n") else {
                XCTFail("target \(name) (\(id)) not found in project file"); return []
            }
            guard let bodyEnd = src.range(of: "\n\t\t};", range: anchor.upperBound..<src.endIndex) else {
                XCTFail("unterminated target block for \(name)"); return []
            }
            let body = String(src[anchor.upperBound..<bodyEnd.lowerBound])
            guard let fsg = body.range(of: "fileSystemSynchronizedGroups = (\n") else { return [] }
            guard let listEnd = body.range(of: "\n\t\t\t);", range: fsg.upperBound..<body.endIndex) else { return [] }
            let entries = String(body[fsg.upperBound..<listEnd.lowerBound]).components(separatedBy: "\n")
            // Anchor at line start (a comment field also holds 24 hex chars, so an unanchored scan
            // yields bogus ids), and escape the `/` in `/*`: writing it as `\*` makes `*` a
            // quantifier over `/`, which matches nothing and silently produces an empty list.
            let idPattern = try! NSRegularExpression(pattern: "^\\s*([0-9A-F]{24}) /\\*")
            return entries.compactMap { line in
                let r = NSRange(line.startIndex..., in: line)
                guard let m = idPattern.firstMatch(in: line, range: r), let g = Range(m.range(at: 1), in: line) else { return nil }
                return String(line[g])
            }
        }

        let app = syncGroupIDs(ofTarget: "BDBD53EB17019B2A0048C8C5", named: "podcasts")
        let clip = syncGroupIDs(ofTarget: "F5D5F7782CEBE769001F492D", named: "Pocket Casts App Clip")
        let tv = syncGroupIDs(ofTarget: "FF4B83AD2F981D8E001B8C56", named: "Pocket Casts TV App")

        // Without this, a parse that returned nothing would make BOTH negatives pass vacuously.
        XCTAssertGreaterThan(app.count, 10, "failed to parse the app target's sync groups — the negatives below would be meaningless")
        XCTAssertEqual(clip.count, 5, "unexpected App Clip sync-group parse")
        XCTAssertEqual(tv.count, 3, "unexpected TV App sync-group parse")
        XCTAssertTrue(app.contains(voiceControlID), "app target must sync VoiceControl (else the feature has no sources anywhere)")
        XCTAssertFalse(clip.contains(voiceControlID), "App Clip gained VoiceControl membership — the #if !APPCLIP guard premise changed; review before keeping it")
        XCTAssertFalse(tv.contains(voiceControlID), "TV App gained VoiceControl membership — same premise change")
    }
}
