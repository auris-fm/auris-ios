import SwiftUI

struct VoiceControlSettingsView: View {
    @ObservedObject var service: VoiceControlService

    var body: some View {
        List {
            // Layout mirrors Android's Voice Control screen:
            // enable switch, model readiness, one plain status line, then the sharing section.
            Section {
                Toggle(isOn: Binding(
                    get: { service.gatePosture.setup.enabledByUser.isAllowed },
                    set: { service.setUserEnabled($0) }
                )) {
                    Text("Enable Voice Control")
                }
            } footer: {
                Text("Listen for voice commands during playback")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                statusRow(label: "Wake Word Model", value: readinessText(service.gatePosture.setup.modelsReady))
                // iOS exposes one combined readiness condition for the speech stack; there is no
                // separate published backend flag, so this reports the condition the app actually
                // gates on rather than inventing a second source.
                statusRow(label: "Speech Recognition Model", value: readinessText(service.gatePosture.setup.modelsReady))
            }

            // A plain status line, not a diagnostics block. iOS-specific wording: there is no
            // microphone-isolation requirement on this platform, so Android's "a headset or earbud
            // microphone is required" is deliberately not reproduced here — it would state
            // something false about this build.
            Section {
                statusRow(label: "Status", value: primaryStatusText(service.gatePosture))
            }

            // The sharing rows embed as PLAIN sections in this single List (reviewer on
            // b61af2897: no nested List). The host owns ONE account model for the screen
            // lifetime via @StateObject, so a service refresh cannot replace in-flight
            // operation/status state with a freshly constructed model.
            VoiceSharingSectionHost(localModel: service.voiceSharingLifetime?.settingsModel)
        }
        .navigationTitle("Voice Control")
    }

    private func readinessText(_ condition: GateCondition) -> String {
        condition.isAllowed ? "Ready" : "Not ready"
    }

    @ViewBuilder
    private var statusBadge: some View {
        let posture = service.gatePosture
        Text(primaryStatusText(posture))
            .foregroundColor(posture.allowed ? .green : .red)
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
        }
    }

    private func conditionRow(label: String, condition: GateCondition) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            conditionBadge(condition)
        }
    }

    @ViewBuilder
    private func conditionBadge(_ condition: GateCondition) -> some View {
        switch condition {
        case .allowed:
            Text("OK")
                .font(.caption)
                .foregroundColor(.green)
        case .blocked(let reason):
            Text(reason)
                .font(.caption)
                .foregroundColor(.red)
        case .unknown(let reason):
            Text(reason)
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private func primaryStatusText(_ posture: GatePosture) -> String {
        // Per the spec's settings status mapping:
        // Check specific blocked conditions with per-field detail
        if posture.offReason == .setupNotReady {
            if case .blocked = posture.setup.modelsReady {
                return "Blocked: model download in progress"
            }
            if case .blocked = posture.setup.enabledByUser {
                return "Disabled in settings"
            }
            return "Blocked: setup"
        }
        if posture.offReason == .conflictBlocking {
            if case .blocked = posture.conflicts.notOnCall {
                return "Blocked: phone call in progress"
            }
            if case .blocked = posture.conflicts.otherAppPlaying {
                return "Blocked: another app is playing audio"
            }
            if case .blocked = posture.conflicts.batteryOk {
                return "Blocked: Low Power Mode"
            }
            if case .blocked = posture.conflicts.notCasting {
                return "Blocked: AirPlay active"
            }
            return "Blocked"
        }
        if posture.offReason == .noContext {
            return "Inactive: no playback or foreground context"
        }
        if posture.offReason == .noMicrophone {
            return "No microphone on this route"
        }
        if posture.offReason == .exposedMicrophone {
            return "Built-in microphone; a headset or earbud microphone is required"
        }
        // "Active" requires actual capture: the posture stays `listening` whenever the route is
        // eligible, including when a start failed, so eligibility alone must not read as listening.
        if service.isListening, posture.listeningMode == .continuous {
            return "Active (grace period)"
        }
        if service.isListening, posture.listeningMode == .wakeWord {
            return "Active (wake word required)"
        }
        return "Off"
    }

    private func offReasonText(_ posture: GatePosture) -> String {
        guard let reason = posture.offReason else { return "none" }
        switch reason {
        case .setupNotReady: return "setupNotReady"
        case .conflictBlocking: return "conflictBlocking"
        case .noContext: return "noContext"
        case .noMicrophone: return "noMicrophone"
        case .exposedMicrophone: return "exposedMicrophone"
        }
    }

    private func listeningModeText(_ posture: GatePosture) -> String {
        guard let mode = posture.listeningMode else { return "n/a" }
        switch mode {
        case .continuous: return "continuous"
        case .wakeWord: return "wakeWord"
        }
    }
}


/// Owns the sharing account model for the lifetime of the Voice Control screen and renders the
/// sharing rows as plain sections (no List of its own) inside the screen's single List.
/// Omitted entirely when sharing is compiled off or the local settings lifetime is absent —
/// ordinary Voice Control settings still open and work signed out.
@MainActor
struct VoiceSharingSectionHost: View {
    @StateObject private var account: VoiceSharingAccountModel
    private let localModel: VoiceSharingSettingsModel?

    init(localModel: VoiceSharingSettingsModel?) {
        self.localModel = localModel
        // No configured origin ⇒ a never-yielding credential: the client exists so the screen
        // composes, but every server action fails closed (token -> nil) exactly as signed out.
        // purgeLocal is nil unless a local settings model exists — the closure must return a
        // NON-optional DeleteResult.
        let tokenProvider = CloudTokenProviderRouter.voiceSharingProvider() ?? NeverTokenProvider()
        _account = StateObject(wrappedValue: VoiceSharingAccountModel(
            client: VoiceSharingAccountClient(tokenProvider: tokenProvider),
            disclosureVersion: VoiceSharingDisclosure.productionVersion,
            purgeLocal: localModel.map { model in
                { await model.deletePendingRecordingsOnThisDevice() }
            }))
    }


    var body: some View {
        if VoiceSharingSettingsModel.surfaceEnabled {
            // @ObservedObject expects the object to already exist; the view struct here holds
            // @StateObject upstream, so wrap in a minimal observed passthrough is unnecessary:
            // construct the section view against the state-owned model.
            VoiceSharingAccountSections(
                accountModel: account,
                localModel: localModel,
                surfaceEnabled: { VoiceSharingSettingsModel.surfaceEnabled },
                originatingSession: account.accountActionSession)
        }
    }


}



/// Credential source that never yields a token: composes the sharing client when no Auris origin
/// is configured so the screen still renders, while every server action fails closed.
private struct NeverTokenProvider: CloudTokenProviding {
    func token() async -> String? { nil }
    func handleUnauthorized(rejectedToken: String?) async {}
}
