import XCTest
@testable import podcasts

/// The CALLER-level provenance control: a wake during ACTIVE GRACE must reach the sink as
/// `.wakeWord`, driven through the service rather than the manager.
///
/// This is the control the manager-level case explicitly cannot be: the manager is given an
/// explicit selection, so it never exercises where the service derives one. Here the service is
/// given an input whose provenance is a wake while the window is already open, which is the
/// arrangement in which a live `isActive` read would wrongly say `.followUp`.
final class ServiceSelectionProvenanceTests: XCTestCase {
    /// SKIPPED, with the exact blocker rather than an artificial seam.
    ///
    /// `handleRoutingInput` guards on `isListening`, and the only ways in are `startIfAllowed()`
    /// or the private `start(in:)` — both of which start REAL audio capture and play a listening
    /// earcon. Driving that from a unit test would mean either a synthetic setter (which would
    /// make the case assert against a state the app never reaches) or a live capture session.
    ///
    /// Left skipped so the gap is visible in the suite rather than silently absent. The step that
    /// unblocks it is a testable entry point that does not start capture — a service-level
    /// decision, not a test-side workaround.
    @MainActor
    func testAWakeInputDuringActiveGraceReachesTheSinkAsWake() async throws {
        try XCTSkipIf(
            true,
            "blocked: handleRoutingInput requires isListening, reachable only by starting real "
                + "capture; needs a non-capturing test entry point before this can assert"
        )
        let assembly = VoiceControlAssembly()
        guard let service = assembly.buildVoiceControlService() else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        _ = service   // the assembly must have wired a sink to assert against

        // A window is already open — grace active — BEFORE the wake arrives. Without this the
        // case cannot distinguish "classified by provenance" from "classified by a closed window".
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "the window is not open, so a live read and the input agree and this proves nothing"
        )

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let wakeInput = IntentRoutingInput.english(
            transcript: "Auris play the next episode",
            selection: .wakeWord
        )

        await service.handleRoutingInput(wakeInput)

        let reached = await MainActor.run { sink.lastSelectionForTesting }
        XCTAssertEqual(
            reached, .wakeWord,
            "a wake during active grace reached the sink as a follow-up — the selection was "
                + "derived from live window state rather than the input's provenance"
        )
    }
}
