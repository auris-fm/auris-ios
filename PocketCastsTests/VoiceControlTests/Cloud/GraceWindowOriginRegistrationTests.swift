import XCTest
@testable import podcasts

/// The production wiring links the grace window to the conversation manager's live origin:
///
///     VoiceControlAssembly.swift:24
///       gracePeriodSignal.$isActive.sink { active in
///           if active { conversationManager.registerLiveOrigin(gracePeriodSignal.currentGeneration()) }
///       }
///
/// Every existing case calls `registerLiveOrigin` DIRECTLY, so the link itself — the thing that
/// decides whether a turn's captured origin is still live in the real app — had no coverage.
/// These cases drive the LINK through its observable consequence: `prepare(origin:)` returns nil
/// exactly when the origin is not the registered one.
final class GraceWindowOriginRegistrationTests: XCTestCase {

    /// The link's positive direction: while the window is active, a turn carrying the window's
    /// generation is admitted. If the assembly ever stopped registering (or registered a
    /// different value), this fails.
    func testActiveWindowAdmitsATurnCarryingItsGeneration() {
        let signal = GracePeriodSignal()
        let manager = CloudConversationManager()
        let link = CloudConversationManager.bindLiveOrigin(to: signal, on: manager)
        defer { link.cancel() }

        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()

        XCTAssertNotNil(
            manager.prepare(selection: .wakeWord, origin: generation, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"),
            "an active window must admit a turn carrying that window's generation"
        )
    }

    /// The link's negative direction, and the one that matters for safety: a generation from a
    /// PREVIOUS window must not be admitted. Without the registration link the manager's origin
    /// stays at its initial value, so this also fails if the link silently stops running.
    func testASupersededGenerationIsRefused() {
        let signal = GracePeriodSignal()
        let manager = CloudConversationManager()
        let link = CloudConversationManager.bindLiveOrigin(to: signal, on: manager)
        defer { link.cancel() }

        signal.onWakeWordDetected()
        let firstGeneration = signal.currentGeneration()

        // The window closes and a NEW one opens, moving the live generation on.
        signal.onAudioRouteChanged()
        signal.onWakeWordDetected()
        let secondGeneration = signal.currentGeneration()
        XCTAssertNotEqual(firstGeneration, secondGeneration, "the harness must actually move the generation")

        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: firstGeneration, utteranceId: "0d6f1e2a-93c4-4b57-8a20-5e1f7c9b3d44"),
            "a generation from a superseded window must not be admitted"
        )
        XCTAssertNotNil(
            manager.prepare(selection: .wakeWord, origin: secondGeneration, utteranceId: "5b2c8d41-7ea9-4c06-b3f8-2a9d4e6c1f70"),
            "the current window's own generation must still be admitted"
        )
    }

    /// A CLOSED window admits nothing (PR #49 review comment 4305981418).
    ///
    /// The link registered the origin only on `active == true`, so after the 30 s timeout — or
    /// any close with no successor wake — `liveOrigin` still named the ended generation. A turn
    /// that captured that generation passed the `origin == liveOrigin` guard and was dialled
    /// after the window ended, creating or resuming a conversation the type's own contract says
    /// must be refused. This drives the REAL close path (`onAppBackgrounded`, the privacy close)
    /// through the link and asserts both modes are refused for the closed window's generation.
    func testClosedWindowAdmitsNothingForItsOwnGeneration() {
        let signal = GracePeriodSignal()
        let manager = CloudConversationManager()
        let link = CloudConversationManager.bindLiveOrigin(to: signal, on: manager)
        defer { link.cancel() }

        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        // Premise: while open, its own generation is admitted.
        XCTAssertNotNil(
            manager.prepare(selection: .wakeWord, origin: generation, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"),
            "harness: the open window must admit its own generation before the close"
        )

        // The window CLOSES (privacy fail-closed) with no successor wake.
        signal.onAppBackgrounded()

        XCTAssertNil(
            manager.prepare(selection: .wakeWord, origin: generation, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"),
            "a closed window must not CREATE a conversation under its ended generation"
        )
        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: generation, utteranceId: "c3a91d27-6f84-4e5b-92a0-8d1b3c7e54f6"),
            "a closed window must not RESUME a conversation under its ended generation"
        )
    }

    /// An unstamped dispatch belongs to no window and must never create a conversation.
    func testAnUnstampedDispatchIsRefused() {
        let signal = GracePeriodSignal()
        let manager = CloudConversationManager()
        let link = CloudConversationManager.bindLiveOrigin(to: signal, on: manager)
        defer { link.cancel() }

        signal.onWakeWordDetected()

        XCTAssertNil(
            manager.prepare(selection: .wakeWord, origin: nil, utteranceId: "e8d42b16-9c57-4a30-8f61-7b0e2d94c853"),
            "a dispatch with no origin belongs to no window"
        )
    }
}
