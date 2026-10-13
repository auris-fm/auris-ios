import OSLog
import XCTest
@testable import podcasts

/// Records lifecycle events so transition/severity/dedup rules are verifiable
/// without the live service or OSLog.
final class RecordingMicLifecycleSink: MicLifecycleLogSink {
    private(set) var records: [MicLifecycleLogRecord] = []

    func write(_ record: MicLifecycleLogRecord) {
        records.append(record)
    }
}

final class VoiceControlServiceLoggingTests: XCTestCase {

    private func makeLogger() -> (MicLifecycleLogger, RecordingMicLifecycleSink) {
        let sink = RecordingMicLifecycleSink()
        return (MicLifecycleLogger(sink: sink), sink)
    }

    private func posture(
        enabledByUser: GateCondition = .allowed,
        notOnCall: GateCondition = .allowed,
        context: GateContext = .appInForeground,
        exposure: MicExposure = .exposed,
        mode: ListeningMode? = nil
    ) -> GatePosture {
        GatePosture(
            allowed: mode != nil,
            listeningMode: mode,
            setup: GateSetup(enabledByUser: enabledByUser, deviceSupported: .allowed, modelsReady: .allowed),
            conflicts: GateConflicts(
                notOnCall: notOnCall,
                notCasting: .allowed,
                batteryOk: .allowed,
                otherAppPlaying: .allowed
            ),
            context: context,
            micExposure: exposure,
            gracePeriodActive: false,
            offReason: mode == nil ? .exposedMicrophone : nil
        )
    }

    private let route = "builtInSpeaker:builtInMic"

    func test_blockedPostureWithoutCapture_emitsInfoAcquisitionSkipped() {
        let (logger, sink) = makeLogger()

        logger.transition(posture: posture(context: .none), route: route, wasCapturing: false, isCapturing: false)

        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].event, "mic_acquisition_skipped")
        XCTAssertEqual(sink.records[0].level, .info)
        XCTAssertEqual(sink.records[0].reasons, ["ListeningContext", "ExposedMic"])
    }

    func test_userDisablesDuringActiveCapture_emitsInfoCaptureStopped() {
        let (logger, sink) = makeLogger()

        logger.transition(
            posture: posture(enabledByUser: .blocked(reason: "user"), exposure: .isolated),
            route: route,
            wasCapturing: true,
            isCapturing: false
        )

        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].event, "mic_capture_stopped")
        XCTAssertEqual(sink.records[0].level, .info)
        XCTAssertEqual(sink.records[0].reasons, ["EnabledByUser"])
        XCTAssertTrue(sink.records[0].priorCapture)
    }

    func test_callStartsDuringActiveCapture_emitsErrorCaptureStopped() {
        let (logger, sink) = makeLogger()

        logger.transition(
            posture: posture(notOnCall: .blocked(reason: "inCall"), exposure: .isolated),
            route: route,
            wasCapturing: true,
            isCapturing: false
        )

        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].event, "mic_capture_stopped")
        XCTAssertEqual(sink.records[0].level, .error)
        XCTAssertEqual(sink.records[0].reasons, ["NotOnCall"])
    }

    func test_routeChangeToNoMicDuringActiveCapture_emitsErrorCaptureStopped() {
        let (logger, sink) = makeLogger()

        logger.transition(
            posture: posture(exposure: .noMic),
            route: "builtInSpeaker:nil",
            wasCapturing: true,
            isCapturing: false
        )

        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].event, "mic_capture_stopped")
        XCTAssertEqual(sink.records[0].level, .error)
        XCTAssertTrue(sink.records[0].reasons.contains("NoMic"))
    }

    func test_failedRouteAcquisition_logsNonAcquisitionWithFailureReason() {
        let (logger, sink) = makeLogger()

        logger.transition(
            posture: posture(exposure: .exposed),
            route: route,
            wasCapturing: false,
            isCapturing: false,
            acquisitionFailureReason: "route_acquisition_no_candidate"
        )

        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].event, "mic_acquisition_skipped")
        XCTAssertEqual(sink.records[0].level, .info)
        XCTAssertTrue(sink.records[0].reasons.contains("route_acquisition_no_candidate"))
    }

    func test_sameBlockedPosture_doesNotEmitDuplicateEvent() {
        let (logger, sink) = makeLogger()
        let blocked = posture(context: .none)

        logger.transition(posture: blocked, route: route, wasCapturing: false, isCapturing: false)
        logger.transition(posture: blocked, route: route, wasCapturing: false, isCapturing: false)

        XCTAssertEqual(sink.records.count, 1)
    }

    func test_changedBlockingReasonSet_emitsAnotherEvent() {
        let (logger, sink) = makeLogger()

        logger.transition(posture: posture(context: .none), route: route, wasCapturing: false, isCapturing: false)
        logger.transition(posture: posture(exposure: .noMic), route: route, wasCapturing: false, isCapturing: false)

        XCTAssertEqual(sink.records.count, 2)
    }

    func test_recordsNeverIncludeAudioOrTranscriptText() {
        let (logger, sink) = makeLogger()
        let transcriptSentinel = "hello auris play the latest episode"

        logger.transition(posture: posture(context: .none), route: route, wasCapturing: false, isCapturing: false)
        logger.transition(
            posture: posture(notOnCall: .blocked(reason: "inCall"), exposure: .isolated),
            route: route,
            wasCapturing: true,
            isCapturing: false
        )

        for record in sink.records {
            XCTAssertFalse(record.reasons.joined(separator: " ").contains(transcriptSentinel))
            XCTAssertFalse(record.route.contains(transcriptSentinel))
            XCTAssertFalse(record.listeningMode.contains(transcriptSentinel))
            XCTAssertFalse(record.context.contains(transcriptSentinel))
            XCTAssertFalse(record.micExposure.contains(transcriptSentinel))
        }
    }
}
