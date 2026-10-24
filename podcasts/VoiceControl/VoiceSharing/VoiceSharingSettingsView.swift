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
    /// The single live snapshot the surface renders from; updated by the model's subscription.
    @State private var liveState: VoiceSharingSettingsModel.LiveState?
    @State private var stateObserver: UUID?
    @State private var lastDelete: VoiceSharingSettingsModel.DeleteResult?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Group {
            if model.isSurfaceEnabled {
                subscription
            } else {
                // The disabled surface has no UI at all rather than a greyed-out shell: a shell
                // invites "why can't I use this" support load for a feature the owner has not
                // activated.
                EmptyView()
            }
        }
    }

    /// Titles are keyed around what the app actually knows; `.unknown` deliberately says nothing
    /// about why.
    /// The model owns the change detection; the view just mirrors the published snapshot.
    private var subscription: some View {
        content
            .onAppear {
                liveState = model.liveState()
                stateObserver = model.addStateObserver { updated in
                    liveState = updated
                    status = model.status()
                }
                model.refreshLiveState()
            }
            .onDisappear {
                if let stateObserver { model.removeStateObserver(stateObserver) }
                stateObserver = nil
            }
    }

    private func title(for reason: VoiceSharingSettingsModel.StoppedReason) -> String {
        switch reason {
        case .notStopped: return L10n.voiceSharingStatusOn
        case .noActiveLease, .unknown: return L10n.voiceSharingStatusPaused
        case .notEnrolled, .turnedOffLocally: return L10n.voiceSharingStatusOff
        case .storageHeld, .storageUnreadable: return L10n.voiceSharingStatusStopped
        }
    }

    private var content: some View {
        List {
            // WHY sharing is stopped and what the user can do about it, from the model's live
            // projection (spec 62d39f8f). Present only when something is actually blocking.
            // ONE snapshot for the whole render: the status read and the guidance both come from
            // this single LiveState, so the surface never mixes a cached permit with fresh reads
            // (reviewer 8ae2b980). The snapshot is refreshed by the model's subscription, so the
            // surface tracks real state changes instead of freezing the first read.
            let live = liveState ?? model.liveState()
            let stopped = model.recoveryGuidance(for: live)
            if stopped.reason != .notStopped {
                Section {
                    Text(title(for: stopped.reason))
                        .font(.headline)
                    if let action = stopped.action {
                        Text(action)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(L10n.voiceSharingSectionTitle) {
                if let status {
                    row(L10n.voiceSharingRowUploads,
                        value: status.collectionPermitted ? L10n.voiceSharingValueActive : L10n.voiceSharingValueNotActive,
                        tint: status.collectionPermitted ? .green : .secondary)
                    switch status.storage {
                    case .knownReady(let count):
                        row(L10n.voiceSharingRowWaiting, value: "\(count)",
                            tint: count == 0 ? .secondary : .primary)
                    case .unknown:
                        // NOT "0": we could not determine what is stored, and saying zero would be
                        // a claim we cannot back.
                        row(L10n.voiceSharingRowWaiting, value: L10n.voiceSharingValueUnknown, tint: .orange)
                        Text(L10n.voiceSharingUnknownStorageExplainer)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .revocationInDoubt:
                        // Count is deliberately not shown: the set is unprovable until a purge
                        // reconciles. The reason row above already offers the verified remedy.
                        row(L10n.voiceSharingRowWaiting, value: L10n.voiceSharingValueNotConfirmed, tint: .orange)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text(L10n.voiceSharingDeleteLocal)
                }
                .confirmationDialog(L10n.voiceSharingDeleteLocalConfirm,
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