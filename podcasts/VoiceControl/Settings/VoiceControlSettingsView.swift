import SwiftUI

struct VoiceControlSettingsView: View {
    @ObservedObject var service: VoiceControlService

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    Text("Voice Control")
                    Spacer()
                    statusBadge
                }
                if case .listening(let mode) = service.gateState {
                    HStack {
                        Text("Listening Mode")
                        Spacer()
                        Text(mode == .continuous ? "Continuous" : "Wake Word")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Diagnostics") {
                let posture = service.gatePosture
                statusRow(label: "Gate", value: posture.allowed ? "Allowed" : "Blocked")
                statusRow(label: "Off Reason", value: offReasonText(posture))
                statusRow(label: "Listening Mode", value: listeningModeText(posture))
                statusRow(label: "Capture", value: captureStateText())
                statusRow(label: "Mic Exposure", value: "\(posture.micExposure)")
                statusRow(label: "Grace Period", value: posture.gracePeriodActive ? "Active" : "Inactive")
                statusRow(label: "Context", value: "\(posture.context)")

                // Per-condition breakdown
                Section("Setup") {
                    conditionRow(label: "User Enabled", condition: posture.setup.enabledByUser)
                    conditionRow(label: "Device Supported", condition: posture.setup.deviceSupported)
                    conditionRow(label: "Models Ready", condition: posture.setup.modelsReady)
                }

                Section("Conflicts") {
                    conditionRow(label: "Not On Call", condition: posture.conflicts.notOnCall)
                    conditionRow(label: "Not Casting", condition: posture.conflicts.notCasting)
                    conditionRow(label: "Battery OK", condition: posture.conflicts.batteryOk)
                    conditionRow(label: "Other App Playing", condition: posture.conflicts.otherAppPlaying)
                }
            }

            Section("Wake Word") {
                HStack {
                    Text("Wake Word")
                    Spacer()
                    Text("Auris")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Voice Control")
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
        // Activity comes from the actual capture state, not the listening mode: the posture stays
        // `listening` whenever the route is eligible, including when capture never started.
        if posture.micExposure == .isolated {
            switch service.captureState {
            case .startFailed:
                return "Blocked: microphone capture failed to start"
            case .starting:
                return "Starting…"
            case .idle:
                return "Off"
            case .active:
                break
            }
        }
        if posture.listeningMode == .continuous {
            return "Active (grace period)"
        }
        if posture.listeningMode == .wakeWord {
            return "Active (wake word required)"
        }
        return "Unknown"
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

    private func captureStateText() -> String {
        switch service.captureState {
        case .idle: return "idle"
        case .starting: return "starting"
        case .active: return "active"
        case .startFailed: return "startFailed"
        }
    }
}
