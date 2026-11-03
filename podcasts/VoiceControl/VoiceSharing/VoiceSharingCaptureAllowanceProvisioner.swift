import Foundation
import PocketCastsUtils

/// The minimal CONNECTED capture entry (scope correction 2026-11-03): one real
/// allowance request whose validated response becomes the collector's admission
/// authority. Memory-only — absent a valid installed response there is no
/// authority and capture fails closed through the existing admission path.
///
/// Fail-closed doctrine: an unavailable or refused outcome installs nothing and
/// surfaces its typed cause through FileLog; an installed batch issued under a
/// different enrollment epoch never admits (the authority is rebuilt with the
/// CURRENT stamp and epoch on every read, so an epoch move or account switch
/// invalidates the installed batch without any purge choreography).
final class VoiceSharingCaptureAllowanceProvisioner {
    private let client: VoiceSharingCaptureAllowanceClient
    private let accountProvider: () -> String?
    private let enrollmentEpochProvider: () -> String?
    private let stampProvider: () -> VoiceSharingCaptureStamp?
    private let log: (String) -> Void

    private let lock = NSLock()
    private var installedResponse: VoiceSharingCaptureAllowanceResponse?
    /// The account the installed response belongs to; an account switch invalidates.
    private var installedAccount: String?

    init(client: VoiceSharingCaptureAllowanceClient,
         accountProvider: @escaping () -> String?,
         enrollmentEpochProvider: @escaping () -> String?,
         stampProvider: @escaping () -> VoiceSharingCaptureStamp?,
         log: @escaping (String) -> Void = { FileLog.shared.addMessage("[VoiceSharing] \($0)") }) {
        self.client = client
        self.accountProvider = accountProvider
        self.enrollmentEpochProvider = enrollmentEpochProvider
        self.stampProvider = stampProvider
        self.log = log
    }

    /// Sync read for the collector's admission path (`currentAuthorization`).
    /// Rebuilt from the installed response against the CURRENT account, epoch
    /// and consent stamp — nothing stale can slip through a lifecycle move.
    func currentAuthorization() -> VoiceSharingCaptureAuthorization? {
        lock.lock()
        let response = installedResponse
        let account = installedAccount
        lock.unlock()
        guard let response, let account, accountProvider() == account,
              response.enrollmentEpoch == enrollmentEpochProvider(),
              let stamp = stampProvider() else { return nil }
        return VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
            account: account, response: response, consent: stamp)
    }

    /// One real request. `issued` installs; `replayed` also admits (its ledger
    /// reopens only if intact — reviewer 80ef8b5f.5). Every other outcome is
    /// surfaced and installs nothing.
    func provision() async {
        if currentAuthorization() != nil { return } // installed — no second request
        guard let account = accountProvider(), !account.isEmpty else {
            log("capture allowance provision skipped: no account identity")
            return
        }
        guard let epoch = enrollmentEpochProvider(), !epoch.isEmpty else {
            log("capture allowance provision skipped: no enrollment epoch")
            return
        }
        guard let request = VoiceSharingCaptureAllowanceRequest(requestID: UUID().uuidString,
                                                                enrollmentEpoch: epoch) else {
            log("capture allowance provision skipped: invalid request inputs")
            return
        }
        let outcome = await client.perform(request)
        switch outcome {
        case .accepted(let response):
            guard VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
                account: account, response: response,
                consent: stampProvider() ?? VoiceSharingCaptureStamp(session: nil, epoch: epoch,
                                                                     policyGeneration: 0)) != nil else {
                log("capture allowance response invalid for admission; nothing installed")
                return
            }
            lock.lock()
            installedResponse = response
            installedAccount = account
            lock.unlock()
            log("capture allowance installed: batch \(response.batchID) (epoch \(response.enrollmentEpoch))")
        case .refused(let refusal):
            log("capture allowance REFUSED: \(refusal)")
        case .unavailable:
            log("capture allowance unavailable; nothing installed")
        }
    }
}
