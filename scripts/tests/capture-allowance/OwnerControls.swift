import Foundation

private enum Injected: Error { case failure }

/// Preconstructed authorization only: no hashing, policy snapshots, or storage in the reader.
private final class CachedAuthority {
    private let lock = NSLock()
    private var value: VoiceSharingCaptureAuthorization?
    private(set) var reads = 0
    init(_ value: VoiceSharingCaptureAuthorization?) { self.value = value }
    func get() -> VoiceSharingCaptureAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return value
    }
    func set(_ value: VoiceSharingCaptureAuthorization?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@main
struct CaptureAllowanceOwnerControls {
    static let stamp = VoiceSharingCaptureStamp(session: "test", epoch: "epoch", policyGeneration: 1)
    static func authority(records: UInt64 = 2, bytes: UInt64 = 1000, account: String = "test", window: String = "one",
                          consent: VoiceSharingCaptureStamp = stamp) -> VoiceSharingCaptureAuthorization {
        let limits = VoiceSharingCaptureLimits(dailyRecords: records, dailyBytes: bytes,
            compiledRecordsCeiling: 10, compiledBytesCeiling: 10000,
            clipSamples: 16, metadataBytes: 128, compiledClipSamples: 16, compiledMetadataBytes: 128)!
        precondition(limits.reservationBytes == 204)
        return VoiceSharingCaptureAuthorization(account: account, establishedWindow: window, limits: limits, consent: consent)!
    }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Missing authority must not even create the accounting directory.
        let absentRoot = base.appendingPathComponent("absent")
        let absent = VoiceSharingCaptureAllowance(ledger: .init(root: absentRoot), currentAuthorization: { nil })
        absent.requestPreparation()
        absent.waitForPreparationForTesting()
        precondition(absent.take(for: stamp) == nil && !FileManager.default.fileExists(atPath: absentRoot.path))
        precondition(VoiceSharingCaptureAuthorization(account: "test", establishedWindow: nil, limits: authority().limits, consent: stamp) == nil)
        precondition(VoiceSharingCaptureLimits(dailyRecords: 1, dailyBytes: 1000, compiledRecordsCeiling: nil,
            compiledBytesCeiling: 1000, clipSamples: 16, metadataBytes: 128, compiledClipSamples: 16, compiledMetadataBytes: 128) == nil)
        // One prepaid token; repeated preparation cannot create a pool. Taking uses only cached memory.
        let cached = CachedAuthority(authority())
        let root = base.appendingPathComponent("tokens")
        var storageCalls = 0
        let ledger = VoiceSharingCaptureLedger(root: root, synchronize: { _, _ in storageCalls += 1 })
        precondition(ledger.provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
        let owner = VoiceSharingCaptureAllowance(ledger: ledger, currentAuthorization: cached.get)
        for _ in 0..<20 { owner.requestPreparation() }
        owner.waitForPreparationForTesting()
        let callsBeforeTake = storageCalls
        let readsBeforeTake = cached.reads
        precondition(owner.take(for: stamp)?.clipSamples == 16)
        precondition(storageCalls == callsBeforeTake && cached.reads == readsBeforeTake + 1)
        precondition(owner.take(for: stamp) == nil)
        owner.requestPreparation()
        owner.waitForPreparationForTesting()
        owner.invalidate() // Unused second reservation is still charged.
        owner.requestPreparation()
        owner.waitForPreparationForTesting()
        precondition(owner.take(for: stamp) == nil)
        precondition(!VoiceSharingCaptureLedger(root: root).charge(authority()))
        // Byte budget independently prevents a second record even with record capacity left.
        let byteRoot = base.appendingPathComponent("bytes")
        let byteLedger = VoiceSharingCaptureLedger(root: byteRoot)
        precondition(byteLedger.provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
        precondition(byteLedger.charge(authority(records: 10, bytes: 407)))
        precondition(!byteLedger.charge(authority(records: 10, bytes: 407)))
        // Each stale handoff consumes its old durable reservation, but cannot publish a usable token.
        let variants: [VoiceSharingCaptureAuthorization] = [
            authority(account: "other"), authority(window: "two"), authority(records: 3),
            authority(consent: .init(session: "changed", epoch: "epoch", policyGeneration: 1)),
            authority(consent: .init(session: "test", epoch: "changed", policyGeneration: 1)),
            authority(consent: .init(session: "test", epoch: "epoch", policyGeneration: 2))
        ]
        for (index, replacement) in variants.enumerated() {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let original = authority(records: 1)
            let cache = CachedAuthority(original)
            let staleRoot = base.appendingPathComponent("stale-\(index)")
            precondition(VoiceSharingCaptureLedger(root: staleRoot).provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
            let held = VoiceSharingCaptureLedger(root: staleRoot, barrier: { phase in
                if phase == .intentSettled {
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 3) == .success)
                }
            })
            let pending = VoiceSharingCaptureAllowance(ledger: held, currentAuthorization: cache.get)
            pending.requestPreparation()
            precondition(entered.wait(timeout: .now() + 3) == .success)
            // A different instance in this process refuses without waiting for the held storage worker.
            precondition(!VoiceSharingCaptureLedger(root: staleRoot).charge(original))
            precondition(pending.take(for: stamp) == nil)
            cache.set(replacement)
            release.signal()
            pending.waitForPreparationForTesting()
            // Restore the original cache only after joining: a wrongly published stale token would now be usable.
            cache.set(original)
            precondition(pending.take(for: original.consent) == nil)
            precondition(!VoiceSharingCaptureLedger(root: staleRoot).charge(original))
        }
        // Independently test the take-time live comparison after a token was already published.
        for (index, replacement) in variants.enumerated() {
            let cache = CachedAuthority(authority())
            let takeLedger = VoiceSharingCaptureLedger(root: base.appendingPathComponent("take-\(index)"))
            precondition(takeLedger.provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
            let ready = VoiceSharingCaptureAllowance(ledger: takeLedger, currentAuthorization: cache.get)
            ready.requestPreparation()
            ready.waitForPreparationForTesting()
            cache.set(replacement)
            precondition(ready.take(for: stamp) == nil)
            cache.set(authority())
            precondition(ready.take(for: stamp) == nil, "stale token must be consumed")
        }
        // Lifecycle invalidation independently rejects a completed refill with unchanged authority.
        do {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let original = authority(records: 1)
            let lifecycleRoot = base.appendingPathComponent("lifecycle")
            precondition(VoiceSharingCaptureLedger(root: lifecycleRoot).provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
            let pending = VoiceSharingCaptureAllowance(ledger: .init(root: lifecycleRoot, barrier: { phase in
                if phase == .intentSettled {
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 3) == .success)
                }
            }), currentAuthorization: { original })
            pending.requestPreparation()
            precondition(entered.wait(timeout: .now() + 3) == .success)
            pending.invalidate()
            release.signal()
            pending.waitForPreparationForTesting()
            precondition(pending.take(for: stamp) == nil)
            precondition(!VoiceSharingCaptureLedger(root: lifecycleRoot).charge(original))
        }
        // Enumerate all actual sync calls, then independently fail each file/directory barrier.
        var barriers: [(String, Bool)] = []
        let reference = base.appendingPathComponent("sync-reference")
        let referenceLedger = VoiceSharingCaptureLedger(root: reference, synchronize: { url, directory in
            barriers.append((url.lastPathComponent, directory))
        })
        precondition(referenceLedger.provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
        precondition(referenceLedger.charge(authority(records: 1)))
        let barrierNames = [
            "root-directory", "root-parent", "account-directory", "account-parent",
            "claim-file", "claim-directory", "claim-root",
            "genesis-initializing-temp", "genesis-initializing-file", "genesis-initializing-directory",
            "zero-usage-temp", "zero-usage-file", "zero-usage-directory",
            "genesis-established-temp", "genesis-established-file", "genesis-established-directory",
            "intent-temp", "intent-file", "intent-directory", "usage-target-temp", "usage-target-file",
            "usage-target-directory", "intent-removal-directory"
        ]
        precondition(barriers.count == barrierNames.count)
        for fault in barriers.indices {
            var count = 0
            let faultRoot = base.appendingPathComponent("sync-\(fault)")
            let failed = VoiceSharingCaptureLedger(root: faultRoot, synchronize: { _, _ in
                defer { count += 1 }
                if count == fault { throw Injected.failure }
            })
            let provisioned = failed.provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!)
            let charged = provisioned ? failed.charge(authority(records: 1)) : false
            precondition(!charged)
            let recovered = VoiceSharingCaptureLedger(root: faultRoot)
            // Only faults before claim creation, or after established-genesis rename, admit a fresh charge.
            let permitsFreshCharge = [14, 15].contains(fault)
            precondition(recovered.charge(authority(records: 1)) == permitsFreshCharge)
            precondition(!recovered.charge(authority(records: 1)))
            let usageURL = faultRoot.appendingPathComponent(authority().accountDigest).appendingPathComponent("usage.json")
            if permitsFreshCharge || [17, 18, 20, 21, 22].contains(fault) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: usageURL)) as! [String: Any]
                let payload = object["payload"] as! [String: Any]
                precondition((payload["records"] as! NSNumber).uint64Value == 1)
                precondition((payload["bytes"] as! NSNumber).uint64Value == 204)
            }
            print("sync fault \(fault) \(barrierNames[fault]) \(barriers[fault]) freshCharge=\(permitsFreshCharge)")
        }
        // Missing established state, corrupt counters, and unknown leftovers preserve uncertainty.
        for defect in ["missing-usage", "missing-genesis", "counter-corruption", "unknown-file"] {
            let damagedRoot = base.appendingPathComponent(defect)
            precondition(VoiceSharingCaptureLedger(root: damagedRoot).provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
            precondition(VoiceSharingCaptureLedger(root: damagedRoot).charge(authority()))
            let directory = damagedRoot.appendingPathComponent(authority().accountDigest)
            let usageURL = directory.appendingPathComponent("usage.json")
            switch defect {
            case "missing-usage": try FileManager.default.removeItem(at: usageURL)
            case "missing-genesis": try FileManager.default.removeItem(at: directory.appendingPathComponent("genesis.json"))
            case "counter-corruption":
                let bytes = try String(contentsOf: usageURL, encoding: .utf8)
                precondition(bytes.contains("\"records\":1"))
                try Data(bytes.replacingOccurrences(of: "\"records\":1", with: "\"records\":0").utf8).write(to: usageURL)
            default: try Data([1]).write(to: directory.appendingPathComponent("unknown.next"))
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let before = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            precondition(!VoiceSharingCaptureLedger(root: damagedRoot).charge(authority()))
            let afterFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let after = try Dictionary(uniqueKeysWithValues: afterFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            precondition(before == after)
        }
        let lostRoot = base.appendingPathComponent("complete-loss")
        let lost = VoiceSharingCaptureLedger(root: lostRoot)
        precondition(lost.provision(.init(verifiedFirstProvisioningAccount: "test", establishedWindow: "one")!))
        precondition(lost.charge(authority()))
        try FileManager.default.removeItem(at: lostRoot)
        precondition(!VoiceSharingCaptureLedger(root: lostRoot).charge(authority()))
        precondition(!FileManager.default.fileExists(atPath: lostRoot.path))
        print("PASS cached-memory admission, single-use/no-refund, independent byte budget, six stale handoffs, same-process exclusion, \(barriers.count) sync faults")
    }
}
