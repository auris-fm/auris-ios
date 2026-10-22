import SwiftUI

/// Voice Sharing settings — BUILT DISABLED.
///
/// Renders nothing unless `VoiceSharingSettingsModel.surfaceEnabled` is true (compiled `false`).
/// No control here can enable collection: toggles that exist are local preferences, deletion routes
/// through the queue's owner-wide purge, and every state value is a READ-ONLY projection.
///
/// SCOPE (reviewer f92ff117 / spec): the delete control is LOCAL — recordings still waiting to
/// upload on this device. It is never labelled as account or server deletion, and its result text
/// never implies that accepted data was removed from the service.
struct VoiceSharingSettingsView: View {
    let model: VoiceSharingSettingsModel

    @State private var status: VoiceSharingSettingsModel.ContributionStatus?
    @State private var lastDelete: VoiceSharingSettingsModel.DeleteResult?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Group {
            if model.isSurfaceEnabled {
                content
            } else {
                // The disabled surface has no UI at all rather than a greyed-out shell: a shell
                // invites "why can't I use this" support load for a feature the owner has not
                // activated.
                EmptyView()
            }
        }
    }

    private var content: some View {
        List {
            Section("Voice Sharing") {
                if let status {
                    row("Contribution uploads",
                        value: status.collectionPermitted ? "Active" : "Not active",
                        tint: status.collectionPermitted ? .green : .secondary)
                    switch status.storage {
                    case .knownReady(let count):
                        row("Recordings waiting to upload", value: "\(count)",
                            tint: count == 0 ? .secondary : .primary)
                    case .unknown:
                        // NOT "0": we could not determine what is stored, and saying zero would be
                        // a claim we cannot back.
                        row("Recordings waiting to upload", value: "Unknown", tint: .orange)
                        Text("Some stored recordings cannot be checked right now. Deleting will "
                             + "attempt them all and tell you exactly what could not be resolved.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete recordings on this device")
                }
                .confirmationDialog("Delete recordings still waiting to upload on this device?",
                                    isPresented: $showingDeleteConfirmation,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        lastDelete = model.deletePendingRecordingsOnThisDevice()
                        status = model.status()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.deletionScopeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let lastDelete {
                        Text(deleteSummary(lastDelete))
                            .font(.caption)
                            .foregroundColor(lastDelete.isFullyResolvedLocally ? .secondary : .orange)
                    }
                }
            }

            Section("Limits") {
                Text(model.compiledBoundsDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Voice Sharing")
        .onAppear { status = model.status() }
    }

    /// Reports the purge's own disposition. Every branch states exactly what is known — in
    /// particular a refusal is NOT rendered as "0 deleted", and durably-disqualified survivors are
    /// named rather than folded into a bare deletion count.
    private func deleteSummary(_ result: VoiceSharingSettingsModel.DeleteResult) -> String {
        switch result.disposition {
        case .reconciled(let removed, let durablyDisqualified):
            var text = "Removed \(removed) recording\(removed == 1 ? "" : "s") from this device."
            if durablyDisqualified > 0 {
                text += " \(durablyDisqualified) could not be deleted but will never be uploaded "
                    + "and remain marked for cleanup."
            }
            return text
        case .incomplete(let removed, let survivorsUnknown):
            return "Removed \(removed). \(survivorsUnknown) could not be confirmed as revoked and "
                + "are still on this device — try again while connected."
        case .refused:
            return "Could not check this device's stored recordings, so nothing was deleted. "
                + "Please try again."
        }
    }

    private func row(_ label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(tint)
        }
    }
}