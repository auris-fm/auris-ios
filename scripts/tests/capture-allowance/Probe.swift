import Foundation
import Darwin

@main
struct CaptureAllowanceProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 9, let records = UInt64(args[4]), let bytes = UInt64(args[5]) else { exit(64) }
        let limits = VoiceSharingCaptureLimits(dailyRecords: records, dailyBytes: bytes,
            compiledRecordsCeiling: 100, compiledBytesCeiling: 1_000_000,
            clipSamples: 16, metadataBytes: 128, compiledClipSamples: 16, compiledMetadataBytes: 128)
        guard let authority = VoiceSharingCaptureAuthorization(account: args[2], establishedWindow: args[3],
            limits: limits, consent: .init(session: "synthetic", epoch: "one", policyGeneration: 1)) else { exit(65) }
        let ledger = VoiceSharingCaptureLedger(root: URL(fileURLWithPath: args[1]), barrier: { phase in
            guard phase.rawValue == args[6] else { return }
            print("BARRIER:" + phase.rawValue)
            fflush(stdout)
            if args[7] == "crash" { _exit(77) }
            if args[7] == "hold" { _ = FileHandle.standardInput.readData(ofLength: 1) }
        })
        if args[8] == "provision" {
            print(ledger.provision(.init(verifiedFirstProvisioningAccount: args[2], establishedWindow: args[3])!) ? "PROVISIONED" : "REFUSED")
        } else {
            print(ledger.charge(authority) ? "CHARGED" : "REFUSED")
        }
    }
}
