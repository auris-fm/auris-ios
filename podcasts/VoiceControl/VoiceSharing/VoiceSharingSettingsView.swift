import SwiftUI

/// Voice Sharing settings — BUILT DISABLED.
///
/// Renders nothing unless `VoiceSharingSettingsModel.surfaceEnabled` is true (compiled `false`).
/// When it does render, no control here can enable collection: the toggles that exist are local
/// preferences, deletion routes through the queue's owner-wide purge, and every state value is a
/// READ-ONLY projection. See `VoiceSharingSettingsModel` for the invariants.
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
                    row("Stored contributions", value: "\(status.readyEntries)",
                        tint: status.held ? .orange : .secondary)
                    if status.held {
                        Text("Some stored contributions cannot be reconciled right now. "
                             + "Deleting will keep them revoked and will tell you if it could not finish.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete my voice contributions")
                }
                .confirmationDialog("Delete all stored voice contributions?",
                                    isPresented: $showingDeleteConfirmation,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        lastDelete = model.deleteAllContributions()
                        status = model.status()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } footer: {
                if let lastDelete {
                    // Honest reporting: an incomplete revocation is stated, never rounded up to
                    // success. A refusal says so without pretending nothing was attempted.
                    Text(deleteSummary(lastDelete))
                        .font(.caption)
                        .foregroundColor(lastDelete.fullyRevoked ? .secondary : .orange)
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

    private func deleteSummary(_ result: VoiceSharingSettingsModel.DeleteResult) -> String {
        if result.fullyRevoked {
            return "Deleted \(result.removed) contribution\(result.removed == 1 ? "" : "s")."
        }
        return "Deleted \(result.removed). \(result.retained) could not be fully revoked and remain "
            + "revoked but retained — please try again while connected."
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
