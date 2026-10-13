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
        let link = signal.$isActive.sink { active in
            if active { manager.registerLiveOrigin(signal.currentGeneration()) }
        }
        defer { link.cancel() }

        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()

        XCTAssertNotNil(
            manager.prepare(selection: .wakeWord, origin: generation),
            "an active window must admit a turn carrying that window's generation"
        )
    }

    /// The link's negative direction, and the one that matters for safety: a generation from a
    /// PREVIOUS window must not be admitted. Without the registration link the manager's origin
    /// stays at its initial value, so this also fails if the link silently stops running.
    func testASupersededGenerationIsRefused() {
        let signal = GracePeriodSignal()
        let manager = CloudConversationManager()
        let link = signal.$isActive.sink { active in
            if active { manager.registerLiveOrigin(signal.currentGeneration()) }
        }
        defer { link.cancel() }

        signal.onWakeWordDetected()
        let firstGeneration = signal.currentGeneration()

        // The window closes and a NEW one opens, moving the live generation on.
        signal.onAudioRouteChanged()
        signal.onWakeWordDetected()
        let secondGeneration = signal.currentGeneration()
        XCTAssertNotEqual(firstGeneration, secondGeneration, "the harness must actually move the generation")

        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: firstGeneration),
            "a generation from a superseded window must not be admitted"
        )
        XCTAssertNotNil(
            manager.prepare(selection: .wakeWord, origin: secondGeneration),
            "the current window's own generation must still be admitted"
        )
    }

    /// An unstamped dispatch belongs to no window and must never create a conversation.
    func testAnUnstampedDispatchIsRefused() {
        let signal = GracePeriodSignal()
        let manager = CloudConversationManager()
        let link = signal.$isActive.sink { active in
            if active { manager.registerLiveOrigin(signal.currentGeneration()) }
        }
        defer { link.cancel() }

        signal.onWakeWordDetected()

        XCTAssertNil(
            manager.prepare(selection: .wakeWord, origin: nil),
            "a dispatch with no origin belongs to no window"
        )
    }
}
