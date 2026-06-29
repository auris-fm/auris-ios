import SwiftUI

struct VoiceControlSettingsView: View {
    @ObservedObject var service: VoiceControlService
    @State private var voiceControlEnabled = false

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

            Section("Wake Word") {
                HStack {
                    Text("Wake Word")
                    Spacer()
                    Text("Auris")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Voice Control", isOn: $voiceControlEnabled)
            }
        }
        .navigationTitle("Voice Control")
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch service.gateState {
        case .off(let reason):
            Text(reasonLabel(reason))
                .foregroundColor(.red)
        case .listening:
            Text("Listening")
                .foregroundColor(.green)
        }
    }

    private func reasonLabel(_ reason: GateState.GateOffReason) -> String {
        switch reason {
        case .setupNotReady: return "Setup"
        case .conflictBlocking: return "Blocked"
        case .noContext: return "Inactive"
        case .noMicrophone: return "No Mic"
        case .onCall: return "On Call"
        case .modelsNotReady: return "Downloading"
        }
    }
}
