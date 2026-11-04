import SwiftUI

struct VoiceControlSettingsView: View {
    @ObservedObject var service: VoiceControlService

    /// The sharing section, rendered from the SAME single settings model the surface has always
    /// used. Optional because the sharing lifetime is absent when no Auris origin is configured —
    /// in that case the row is omitted rather than shown as a dead control.
    private var sharing: VoiceSharingAccountView? {
        guard VoiceSharingSettingsModel.surfaceEnabled,
              let model = service.voiceSharingLifetime?.settingsModel,
              let tokenProvider = CloudTokenProviderRouter.voiceSharingProvider() else { return nil }
        let account = VoiceSharingAccountModel(
            client: VoiceSharingAccountClient(tokenProvider: tokenProvider),
            disclosureVersion: VoiceSharingDisclosure.productionVersion,
            purgeLocal: { model.deletePendingRecordingsOnThisDevice() })
        return VoiceSharingAccountView(accountModel: account, localModel: model,
                                       surfaceEnabled: { VoiceSharingSettingsModel.surfaceEnabled })
    }

    var body: some View {
        List {
            // Layout mirrors Android's Voice Control screen (spec 233c0d02, @android f86c6a67):
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
            // microphone is required" is deliberately NOT reproduced here — it would state
            // something false about this build.
            Section {
                statusRow(label: "Status", value: primaryStatusText(service.gatePosture))
            }

            if let sharing {
                sharing
            }
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
        case .onCall: return "onCall"
        case .modelsNotReady: return "modelsNotReady"
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
