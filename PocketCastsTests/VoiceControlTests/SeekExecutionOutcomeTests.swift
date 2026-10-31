import XCTest
import AVFoundation
@testable import podcasts

/// Controls for the ADDITIVE typed seek-completion surface (task67 seek slice). Legacy
/// completions and EOF side effects are exercised alongside the typed deliveries. No await,
/// journal classification or manifest surface is in scope here.
///
/// Scope notes: the EffectsPlayer EOF control presets `haveNotifiedPlayer` so the legacy
/// finished-playing branch takes its already-notified path — that control covers the EOF
/// BRANCH only; the PlaybackManager singleton side effect is not executed from tests. The
/// DefaultPlayer cancelled control drives the extracted completion adapter directly with
/// `finished == false` — that is callback-ADAPTER evidence for the native cancellation path,
/// not a live AVPlayer cancellation.
final class SeekExecutionOutcomeTests: XCTestCase {

    // MARK: - Nil engine / nil task (synchronous decisions)

    /// A DefaultPlayer with no AVPlayer decides synchronously at the initiating call:
    /// typed `.engineUnavailable`, correct player identity, legacy completion NOT invoked.
    func testDefaultPlayerWithoutEngineReportsEngineUnavailableSynchronously() {
        let engine = DefaultPlayer()
        var typed: [SeekExecutionOutcome] = []
        var legacyCalls = 0

        engine.seekTo(5.0, completion: { legacyCalls += 1 }, typedCompletion: { typed.append($0) })

        XCTAssertEqual(typed.count, 1)
        guard case .engineUnavailable(let identity) = typed[0] else {
            return XCTFail("expected .engineUnavailable, got \(typed[0])")
        }
        XCTAssertEqual(identity.playerID, ObjectIdentifier(engine))
        XCTAssertNil(identity.readTaskID)
        XCTAssertNil(identity.itemID)
        XCTAssertEqual(legacyCalls, 0, "legacy path stays a silent no-op without an engine")
    }

    /// An EffectsPlayer with no read task (no episode loaded) decides synchronously:
    /// typed `.engineUnavailable` with a nil read-task identity, legacy completion NOT invoked.
    func testEffectsPlayerWithoutReadTaskReportsEngineUnavailableSynchronously() {
        let engine = EffectsPlayer()
        var typed: [SeekExecutionOutcome] = []
        var legacyCalls = 0

        engine.seekTo(5.0, completion: { legacyCalls += 1 }, typedCompletion: { typed.append($0) })

        XCTAssertEqual(typed.count, 1)
        guard case .engineUnavailable(let identity) = typed[0] else {
            return XCTFail("expected .engineUnavailable, got \(typed[0])")
        }
        XCTAssertEqual(identity.playerID, ObjectIdentifier(engine))
        XCTAssertNil(identity.readTaskID)
        XCTAssertEqual(legacyCalls, 0, "the guard path never schedules and never calls legacy")
    }

    // MARK: - Locked capture (AudioReadTask, real audio file)

    /// Builds a real audio file so performSeek's locked capture is exercised for real.
    private func makeAudioFile(durationSeconds: Double, sampleRate: Double = 44_100) throws -> (file: AVAudioFile, url: URL, totalFrames: Int64) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-capture-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        let totalFrames = file.length
        return (try AVAudioFile(forReading: url), url, totalFrames)
    }

    private func makeReadTask(file: AVAudioFile) -> AudioReadTask {
        AudioReadTask(trimSilence: .off,
                      audioFile: file,
                      outputFormat: file.processingFormat,
                      bufferManager: PlayBufferManager(),
                      playPositionHint: 0,
                      frameCount: file.length,
                      useVoiceBoostN: nil,
                      sampleRate: 0)
    }

    /// Overlapping seeks on one read task: BOTH typed captures deliver, each carrying the
    /// same read-task identity, and each capture holds the EXACT frame the locked
    /// `framePositionForTime` computes for its requested time (10 s of 44.1 kHz audio:
    /// 441 000 frames; 1.0 s → 44 100, 2.0 s → 88 200).
    func testOverlappingSeeksDeliverIndividualLockedCapturesWithExactFrames() throws {
        let (file, url, totalFrames) = try makeAudioFile(durationSeconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = makeReadTask(file: file)

        let lock = NSLock()
        var captures: [LockedSeekCapture] = []
        var legacy: [Bool] = []
        // ONE expectation per TYPED delivery: the test completes only when both typed
        // callbacks have run — not when a legacy callback happens to fire first.
        let bothTyped = XCTestExpectation(description: "both typed captures delivered")
        bothTyped.expectedFulfillmentCount = 2

        // Two seeks issued back-to-back WITHOUT waiting — genuine overlap on the global queue.
        task.seekTo(1.0, completion: { capture in
            lock.lock(); legacy.append(capture); lock.unlock()
        }, typedCapture: { capture in
            lock.lock(); captures.append(capture); lock.unlock()
            bothTyped.fulfill()
        })
        task.seekTo(2.0, completion: { capture in
            lock.lock(); legacy.append(capture); lock.unlock()
        }, typedCapture: { capture in
            lock.lock(); captures.append(capture); lock.unlock()
            bothTyped.fulfill()
        })

        wait(for: [bothTyped], timeout: 10)
        lock.lock(); let gotCaptures = captures; let gotLegacy = legacy; lock.unlock()

        XCTAssertEqual(gotLegacy, [false, false], "neither in-range seek is EOF")
        XCTAssertEqual(gotCaptures.count, 2, "each initiating seek delivers exactly one capture")
        let byTime = Dictionary(uniqueKeysWithValues: gotCaptures.map { ($0.requestedTime, $0) })
        XCTAssertEqual(Set(byTime.keys), [1.0, 2.0], "captures are per-seek, not merged")
        let expected1 = Int64(Double(totalFrames) * 1.0 / 10.0)
        let expected2 = Int64(Double(totalFrames) * 2.0 / 10.0)
        XCTAssertEqual(try XCTUnwrap(byTime[1.0]).landedFrame, expected1, "exact locked frame for 1.0 s")
        XCTAssertEqual(try XCTUnwrap(byTime[2.0]).landedFrame, expected2, "exact locked frame for 2.0 s")
        for capture in gotCaptures {
            XCTAssertFalse(capture.seekedToEnd)
            XCTAssertEqual(capture.engineTotalSeconds, Double(totalFrames) / 44_100.0, accuracy: 0.001)
        }
    }

    /// A seek past the engine's end: the locked capture is the EOF branch — seekedToEnd true,
    /// landedFrame nil (the engine assigns no frame there), requested time and engine total
    /// preserved, and the legacy Bool completion receives true as today.
    func testSeekPastEndOfEngineDeliversEndOfFileCaptureWithoutFrame() throws {
        let (file, url, totalFrames) = try makeAudioFile(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = makeReadTask(file: file)

        let lock = NSLock()
        var captures: [LockedSeekCapture] = []
        var legacy: [Bool] = []
        let typedDone = XCTestExpectation(description: "EOF capture delivered")
        task.seekTo(60.0, completion: { ended in
            lock.lock(); legacy.append(ended); lock.unlock()
        }, typedCapture: { capture in
            lock.lock(); captures.append(capture); lock.unlock()
            typedDone.fulfill()
        })

        wait(for: [typedDone], timeout: 10)
        lock.lock(); let gotCaptures = captures; let gotLegacy = legacy; lock.unlock()

        XCTAssertEqual(gotCaptures.count, 1)
        let capture = try XCTUnwrap(gotCaptures.first)
        XCTAssertTrue(capture.seekedToEnd, "past-end seek takes the EOF branch")
        XCTAssertNil(capture.landedFrame, "EOF assigns no frame; none is fabricated")
        XCTAssertEqual(capture.requestedTime, 60.0)
        XCTAssertEqual(capture.engineTotalSeconds, Double(totalFrames) / 44_100.0, accuracy: 0.001)
        XCTAssertEqual(gotLegacy, [true], "legacy Bool unchanged")
    }

    // MARK: - EffectsPlayer typed path (real engine, injected read task)

    /// EffectsPlayer delivers the typed EOF outcome with the full identity (player + read
    /// task), while the legacy completion stays silent on the EOF branch — the same branch
    /// the production code uses; `haveNotifiedPlayer` is preset so the legacy finished-playing
    /// side effect takes its already-notified path. This control covers the EOF BRANCH only;
    /// it does not execute the PlaybackManager singleton side effect.
    func testEffectsPlayerDeliversTypedEndOfFileWithIdentityAndLegacySilence() throws {
        let (file, url, _) = try makeAudioFile(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = makeReadTask(file: file)
        let playBufferManager = PlayBufferManager()
        playBufferManager.haveNotifiedPlayer.value = true

        let engine = EffectsPlayer()
        engine.audioReadTask = task
        engine.playBufferManager = playBufferManager

        var typed: [SeekExecutionOutcome] = []
        var legacyCalls = 0
        let typedDone = XCTestExpectation(description: "typed EOF delivered")
        let typedLock = NSLock()

        engine.seekTo(60.0, completion: { legacyCalls += 1 }, typedCompletion: { outcome in
            typedLock.lock(); typed.append(outcome); typedLock.unlock()
            typedDone.fulfill()
        })

        wait(for: [typedDone], timeout: 10)
        typedLock.lock(); let got = typed; typedLock.unlock()

        XCTAssertEqual(got.count, 1)
        guard case .endOfFile(let identity, let requested, let total) = got[0] else {
            return XCTFail("expected .endOfFile, got \(got[0])")
        }
        XCTAssertEqual(identity.playerID, ObjectIdentifier(engine))
        XCTAssertEqual(identity.readTaskID, ObjectIdentifier(task))
        XCTAssertEqual(requested, 60.0)
        XCTAssertGreaterThan(total, 0.5)
        XCTAssertEqual(legacyCalls, 0, "the EOF branch never calls the legacy completion")
    }

    /// THE SAME EffectsPlayer and read task, two seeks: identical player and read-task
    /// identifiers but DISTINCT invocation tokens — the token is what separates outcomes for
    /// two seeks against one engine/task pair.
    func testTwoSeeksOnSameEngineAndTaskCarryDistinctInvocationTokens() throws {
        let (file, url, _) = try makeAudioFile(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = makeReadTask(file: file)
        let playBufferManager = PlayBufferManager()
        playBufferManager.haveNotifiedPlayer.value = true

        let engine = EffectsPlayer()
        engine.audioReadTask = task
        engine.playBufferManager = playBufferManager

        let lock = NSLock()
        var identities: [SeekIdentity] = []
        let bothTyped = XCTestExpectation(description: "both typed EOF outcomes delivered")
        bothTyped.expectedFulfillmentCount = 2

        engine.seekTo(60.0, completion: nil, typedCompletion: { outcome in
            if case .endOfFile(let identity, _, _) = outcome {
                lock.lock(); identities.append(identity); lock.unlock()
            }
            bothTyped.fulfill()
        })
        engine.seekTo(60.0, completion: nil, typedCompletion: { outcome in
            if case .endOfFile(let identity, _, _) = outcome {
                lock.lock(); identities.append(identity); lock.unlock()
            }
            bothTyped.fulfill()
        })

        wait(for: [bothTyped], timeout: 10)
        lock.lock(); let got = identities; lock.unlock()

        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].playerID, got[1].playerID, "same engine instance")
        XCTAssertEqual(got[0].readTaskID, got[1].readTaskID, "same read task")
        XCTAssertNotEqual(got[0].invocationToken, got[1].invocationToken,
                          "the invocation token separates two seeks on the SAME engine/task pair")
    }

    // MARK: - DefaultPlayer success / cancelled adapter / item replacement (real AVPlayer)

    /// Generates a real local audio asset and returns a player pointed at it.
    private func makePlayer(assetDuration seconds: Double) throws -> (AVPlayer, URL) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-player-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        let item = AVPlayerItem(url: url)
        return (AVPlayer(playerItem: item), url)
    }

    /// Bounded readiness wait via a PREDICATE-BASED expectation (XCTNSPredicateExpectation,
    /// not KVO-backed) — never blocks the test thread, fulfills only when the item is actually
    /// ready, and THROWS on failure so the caller stops.
    private func waitForReady(_ player: AVPlayer) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            player.currentItem?.status == .readyToPlay
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        guard result == .completed, player.currentItem?.status == .readyToPlay else {
            throw ItemNotReadyError(waiterResult: result.rawValue)
        }
    }

    private struct ItemNotReadyError: Error, CustomStringConvertible {
        let waiterResult: Int
        var description: String { "item never became ready (waiter result \(waiterResult))" }
    }

    /// Actual DefaultPlayer success: a real AVPlayer completes a seek; the typed outcome
    /// carries the QUANTIZED effective request read back from the CMTime actually handed to
    /// AVPlayer — proven with a NON-grid request (0.509 s → 0.50, the only value that catches
    /// a report of the pre-quantization clamp) and a below-clamp input (0.0 → 0.1) — plus the
    /// initiating item identity and the item-clock observation taken at handler entry. The
    /// legacy completion also fires, as today.
    func testDefaultPlayerRealSeekReportsQuantizedRequestAndItemIdentity() throws {
        let (avPlayer, url) = try makePlayer(assetDuration: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = DefaultPlayer()
        engine.player = avPlayer
        try waitForReady(avPlayer)
        let item = try XCTUnwrap(avPlayer.currentItem)

        let lock = NSLock()
        var typed: [SeekExecutionOutcome] = []
        var legacyCalls = 0

        // NON-GRID request: 0.509 must be reported as 0.50 (hundredths quantization), not 0.509.
        let firstDone = XCTestExpectation(description: "0.509 seek delivered")
        engine.seekTo(0.509, completion: {
            lock.lock(); legacyCalls += 1; lock.unlock()
        }, typedCompletion: { outcome in
            lock.lock(); typed.append(outcome); lock.unlock()
            firstDone.fulfill()
        })
        wait(for: [firstDone], timeout: 10)

        // BELOW-CLAMP request: 0.0 must be reported as 0.1 (the fmax clamp feeds the CMTime).
        let secondDone = XCTestExpectation(description: "0.0 seek delivered")
        engine.seekTo(0.0, completion: {
            lock.lock(); legacyCalls += 1; lock.unlock()
        }, typedCompletion: { outcome in
            lock.lock(); typed.append(outcome); lock.unlock()
            secondDone.fulfill()
        })
        wait(for: [secondDone], timeout: 10)

        lock.lock(); let got = typed; let gotLegacy = legacyCalls; lock.unlock()

        guard got.count == 2 else { return XCTFail("expected 2 completed outcomes, got \(got.count)") }
        let completions = got.compactMap { outcome -> (identity: SeekIdentity, request: TimeInterval, clock: TimeInterval)? in
            guard case .completed(let identity, let request, let clock) = outcome else { return nil }
            return (identity, request, clock)
        }
        guard completions.count == 2 else { return XCTFail("expected both outcomes .completed, got \(got)") }
        XCTAssertEqual(gotLegacy, 2, "legacy completion fires per completed seek")
        XCTAssertEqual(completions[0].request, 0.50, accuracy: 1e-9, "0.509 quantizes DOWN to the handed CMTime 0.50")
        XCTAssertEqual(completions[1].request, 0.1, accuracy: 1e-9, "0.0 clamps to 0.1 before quantization")
        for completion in completions {
            XCTAssertEqual(completion.identity.playerID, ObjectIdentifier(engine))
            XCTAssertEqual(completion.identity.itemID, ObjectIdentifier(item))
            XCTAssertGreaterThanOrEqual(completion.clock, 0.0)
            XCTAssertLessThanOrEqual(completion.clock, 1.0)
        }
        XCTAssertNotEqual(completions[0].identity.invocationToken, completions[1].identity.invocationToken,
                          "the two seeks carry distinct invocation tokens")
    }

    /// CALLBACK-ADAPTER EVIDENCE (deterministic): the extracted completion adapter driven
    /// directly with `finished == false` reports `.cancelled` and leaves the legacy completion
    /// silent — the native-cancellation branch the old `if finished` guard discarded. This is
    /// adapter evidence, not a live AVPlayer cancellation; the real handler invokes this same
    /// adapter unchanged.
    func testCompletionAdapterReportsCancelledOnFinishedFalseAndSuppressesLegacy() {
        let engine = DefaultPlayer()
        let identity = SeekIdentity(invocationToken: UUID(), playerID: ObjectIdentifier(engine), readTaskID: nil, itemID: nil)
        var typed: [SeekExecutionOutcome] = []
        var legacyCalls = 0
        var resumedPlay = false

        DefaultPlayer.seekCompletionAdapter(finished: false,
                                            observedItemClock: 0.42,
                                            identity: identity,
                                            effectiveRequest: 0.5,
                                            playing: false,
                                            shouldKeepPlaying: true,
                                            resumePlay: { resumedPlay = true },
                                            legacyCompletion: { legacyCalls += 1 },
                                            typedCompletion: { typed.append($0) })

        XCTAssertEqual(typed.count, 1)
        guard case .cancelled(let gotIdentity) = typed[0] else {
            return XCTFail("expected .cancelled, got \(typed[0])")
        }
        XCTAssertEqual(gotIdentity, identity)
        XCTAssertEqual(legacyCalls, 0, "the cancelled branch never calls the legacy completion")
        XCTAssertFalse(resumedPlay, "the cancelled branch never resumes playback")
    }

    /// Initiating-item replacement identity: after `replaceCurrentItem`, a seek's outcome
    /// carries the NEW item's identity — the replacement-detection input. (Item B is an
    /// UNATTACHED AVPlayerItem; it never belongs to another player.)
    func testSeekAfterItemReplacementCarriesNewItemIdentity() throws {
        let (avPlayer, urlA) = try makePlayer(assetDuration: 10)
        defer { try? FileManager.default.removeItem(at: urlA) }
        let engine = DefaultPlayer()
        engine.player = avPlayer
        try waitForReady(avPlayer)
        let itemA = try XCTUnwrap(avPlayer.currentItem)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let urlB = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-itemB-\(UUID().uuidString).caf")
        let fileB = try AVAudioFile(forWriting: urlB, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let bufferB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 10)!
        bufferB.frameLength = 44_100 * 10
        try fileB.write(from: bufferB)
        defer { try? FileManager.default.removeItem(at: urlB) }
        let itemB = AVPlayerItem(url: urlB) // deliberately UNATTENDED/UNATTACHED

        var before: SeekIdentity?
        var after: SeekIdentity?
        let beforeDone = XCTestExpectation(description: "pre-replacement seek delivered")
        let afterDone = XCTestExpectation(description: "post-replacement seek delivered")

        engine.seekTo(9.0, completion: nil, typedCompletion: { outcome in
            if case .completed(let identity, _, _) = outcome {
                before = identity
            }
            beforeDone.fulfill()
        })
        wait(for: [beforeDone], timeout: 10)
        guard let beforeIdentity = before else { return XCTFail("first seek did not complete") }
        XCTAssertEqual(beforeIdentity.itemID, ObjectIdentifier(itemA))

        avPlayer.replaceCurrentItem(with: itemB)
        try waitForReady(avPlayer) // item B readiness BEFORE issuing the post-replacement seek

        engine.seekTo(1.0, completion: nil, typedCompletion: { outcome in
            if case .completed(let identity, _, _) = outcome {
                after = identity
            }
            afterDone.fulfill()
        })
        wait(for: [afterDone], timeout: 10)
        guard let afterIdentity = after else { return XCTFail("post-replacement seek did not complete") }

        XCTAssertEqual(afterIdentity.itemID, ObjectIdentifier(itemB), "the new seek carries the NEW item's identity")
        XCTAssertNotEqual(beforeIdentity.itemID, afterIdentity.itemID)
        XCTAssertNotEqual(beforeIdentity.invocationToken, afterIdentity.invocationToken)
        XCTAssertEqual(afterIdentity.playerID, ObjectIdentifier(engine), "same engine instance throughout")
    }
}
