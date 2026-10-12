import SwiftUI

/// Auris-only developer menu entries (voice control / on-device ASR).
extension DeveloperMenuSection {
    static var voiceControl: DeveloperMenuSection {
        DeveloperMenuSection(title: "Voice Control", items: [
            .link("Voice Control") {
                if let service = VoiceControlService.shared {
                    VoiceControlSettingsView(service: service)
                } else {
                    Text("Feature flag disabled")
                }
            }
        ])
    }
}
