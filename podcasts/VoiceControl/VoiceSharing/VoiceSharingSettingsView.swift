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

    /// The single live snapshot the surface renders from; updated by the model's subscription.
    @State private var liveState: VoiceSharingSettingsModel.LiveState?
    /// ONE published value carrying every displayed field, so the two UI parts cannot disagree.
    @State private var published: VoiceSharingSettingsModel.PublishedViewState?
    /// The highest publication sequence applied, so an out-of-order delivery is rejected here and
    /// not just at the producer.
    @State private var appliedSequence = -1
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

    /// The model owns the change detection; the view just mirrors the published value.
    private var subscription: some View {
        content
            .onAppear {
                liveState = model.liveState()
                published = model.publishedViewState(for: liveState!)
                stateObserver = model.addStateObserver { sent in
                    // Two independent protections (reviewer f62b19a4): the main-actor hop for
                    // SwiftUI state, and a sequence check so a delivery that arrives LATE cannot
                    // overwrite a newer one — enqueue order alone does not preserve read order.
                    let apply: () -> Void = {
                        guard sent.sequence > appliedSequence else { return }
                        appliedSequence = sent.sequence
                        liveState = sent.state
                        published = model.publishedViewState(for: sent.state)
                    }
                    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
                }
                // ONE entry point: refreshLiveState publishes AND arms the time-driven refresh
                // (an aged entry or a lapsing lease changes the display with no other event), so
                // appearance does not need a second arm.
                model.refreshLiveState()
            }
            .onDisappear {
                if let stateObserver { model.removeStateObserver(stateObserver) }
                stateObserver = nil
            }
    }

    /// Titles are keyed around what the app actually knows; `.unknown` says nothing about why.
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
            let view = published ?? model.publishedViewState(for: model.liveState())
            let stopped = view.guidance
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
                row(L10n.voiceSharingRowUploads,
                    value: view.live.policyPermits == true ? L10n.voiceSharingValueActive : L10n.voiceSharingValueNotActive,
                    tint: view.live.policyPermits == true ? .green : .secondary)
                switch view.storage {
                case .knownReady(let count):
                    row(L10n.voiceSharingRowWaiting, value: "\(count)",
                        tint: count == 0 ? .secondary : .primary)
                case .unknown:
                    // NOT "0": we could not determine what is stored, and saying zero would be a
                    // claim we cannot back.
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
                        // A purge moves the queue's hold generation: refresh so the surface shows
                        // the post-purge truth rather than the pre-purge snapshot.
                        model.refreshLiveState()
                        liveState = model.liveState()
                        published = model.publishedViewState(for: model.liveState())
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
        .navigationTitle(L10n.voiceSharingSectionTitle)
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
/// Account operations remain distinct from the existing device-only recording controls.
@MainActor
struct VoiceSharingAccountView: View {
    @ObservedObject var accountModel: VoiceSharingAccountModel
    let localModel: VoiceSharingSettingsModel?
    let surfaceEnabled: () -> Bool
    let originatingSession: String?
    init(accountModel: VoiceSharingAccountModel, localModel: VoiceSharingSettingsModel?, surfaceEnabled: @escaping () -> Bool) {
        self.accountModel = accountModel
        self.localModel = localModel
        self.surfaceEnabled = surfaceEnabled
        self.originatingSession = accountModel.accountActionSession
    }
    private var controlsAvailable: Bool { surfaceEnabled() && accountModel.canAct(in: originatingSession) }
    @State private var disclosureConfirmation = false
    @State private var deletionConfirmation = false

    var body: some View {
        Group {
            if controlsAvailable {
                accountContent
            } else {
                Text(L10n.voiceSharingAccountUnavailable)
            }
        }
        .navigationTitle(L10n.voiceSharingAccountTitle)
    }

    private var accountContent: some View {
        List {
            Section(L10n.voiceSharingSectionTitle) {
                LabeledContent(L10n.voiceSharingAccountPlan, value: accountModel.membership.map { $0.plan == .pro ? "Pro" : "Free" } ?? L10n.voiceSharingValueUnknown)
                LabeledContent(L10n.voiceSharingAccountMembership, value: accountModel.membership.map { $0.voiceSharingEnrolled ? L10n.voiceSharingValueActive : L10n.voiceSharingValueNotActive } ?? L10n.voiceSharingValueUnknown)
                Text(L10n.voiceSharingAccountPurpose)
                Text(L10n.voiceSharingAccountBackgroundSpeech).font(.caption).foregroundStyle(.secondary)
                if !accountModel.enrollmentAvailable {
                    Text(L10n.voiceSharingAccountDisclosureUnavailable).font(.caption)
                }
                Button(L10n.voiceSharingAccountEnroll) { disclosureConfirmation = true }
                    .disabled(!accountModel.enrollmentAvailable || accountModel.busy)
                    .confirmationDialog(L10n.voiceSharingAccountEnroll, isPresented: $disclosureConfirmation, titleVisibility: .visible) {
                        Button(L10n.voiceSharingAccountConfirmDisclosure) { enroll(confirmed: true) }
                        Button(L10n.cancel, role: .cancel) { enroll(confirmed: false) }
                    } message: {
                        Text(L10n.voiceSharingAccountPurpose + " " + L10n.voiceSharingAccountBackgroundSpeech)
                    }
                // Local stop is available even while enrollment or refresh is waiting.
                Button(L10n.voiceSharingAccountWithdraw, role: .destructive) {
                    guard controlsAvailable else { return }
                    Task {
                        guard controlsAvailable else { return }
                        await accountModel.withdraw() }
                }
                if !membershipSummary.isEmpty { Text(membershipSummary).font(.caption) }
                if accountModel.refreshUnavailable { Text(L10n.voiceSharingAccountRefreshFailed).font(.caption) }
                Button(L10n.voiceSharingAccountRefresh) {
                    guard controlsAvailable else { return }
                    Task {
                        guard controlsAvailable else { return }
                        await accountModel.refresh() }
                }.disabled(accountModel.busy)
                Button(L10n.voiceSharingAccountRetry) {
                    guard controlsAvailable else { return }
                    Task {
                        guard controlsAvailable else { return }
                        await accountModel.retryMembership() }
                }.disabled(accountModel.busy)
                if cleanupNeedsAttention {
                    Text(accountModel.localCleanupUnavailable ? L10n.voiceSharingAccountCleanupUnavailable : L10n.voiceSharingAccountCleanupUnresolved).font(.caption)
                    Button(L10n.voiceSharingAccountRetryCleanup) {
                        guard controlsAvailable else { return }
                        accountModel.retryLocalCleanup()
                    }
                }
            }
            Section {
                Button(L10n.voiceSharingAccountDeleteAccepted, role: .destructive) { deletionConfirmation = true }
                    .disabled(accountModel.deletionStatus == .sending)
                    .confirmationDialog(L10n.voiceSharingAccountDeleteAccepted, isPresented: $deletionConfirmation, titleVisibility: .visible) {
                        Button(L10n.voiceSharingAccountDeleteAccepted, role: .destructive) { deleteAccepted(confirmed: true) }
                        Button(L10n.cancel, role: .cancel) { deleteAccepted(confirmed: false) }
                    } message: { Text(L10n.voiceSharingAccountDeleteScope) }
                if !deletionSummary.isEmpty { Text(deletionSummary).font(.caption) }
                if accountModel.deletionStatus == .unavailable || accountModel.deletionStatus == .unauthorized {
                    Button(L10n.voiceSharingAccountRetry) {
                        guard controlsAvailable else { return }
                        Task {
                        guard controlsAvailable else { return }
                        await accountModel.retryDeletion() }
                    }
                }
            } footer: { Text(L10n.voiceSharingAccountDeleteScope) }
            if let localModel {
                NavigationLink(L10n.voiceSharingAccountLocalRecordings) {
                    VoiceSharingAccountLocalView(accountModel: accountModel, localModel: localModel,
                                                 originatingSession: originatingSession, surfaceEnabled: surfaceEnabled)
                }
            }
        }
        .task {
            guard controlsAvailable else { return }
            await accountModel.refresh()
        }
    }

    /// The confirmation callbacks used by the real buttons; declining never changes local intent.
    @discardableResult
    func enroll(confirmed: Bool) -> Task<Void, Never>? {
        guard confirmed, controlsAvailable else { return nil }
        return Task {
                        guard controlsAvailable else { return }
                        await accountModel.enroll(disclosureConfirmed: true) }
    }
    @discardableResult
    func deleteAccepted(confirmed: Bool) -> Task<Void, Never>? {
        guard confirmed, controlsAvailable else { return nil }
        return Task {
                        guard controlsAvailable else { return }
                        await accountModel.deleteAcceptedData(confirmed: true) }
    }

    private var cleanupNeedsAttention: Bool {
        guard let result = accountModel.localCleanup else { return accountModel.localCleanupUnavailable }
        switch result.disposition {
        case .reconciled(_, let disqualified): return disqualified > 0
        case .incomplete, .refused: return true
        }
    }

    private var membershipSummary: String {
        switch accountModel.membershipStatus {
        case .idle: return ""
        case .loading: return L10n.voiceSharingAccountChecking
        case .disclosureUnavailable: return L10n.voiceSharingAccountDisclosureUnavailable
        case .confirmationRequired: return L10n.voiceSharingAccountConfirmDisclosure
        case .unavailable: return L10n.voiceSharingAccountOperationFailed
        case .conflict: return L10n.voiceSharingAccountConflict
        case .unauthorized: return L10n.voiceSharingAccountSignInAgain
        case .refused: return L10n.voiceSharingAccountRefused
        case .enrolled: return L10n.voiceSharingAccountEnrolled
        case .withdrawnServerConfirmed: return L10n.voiceSharingAccountWithdrawn
        case .withdrawalUnconfirmed: return L10n.voiceSharingAccountWithdrawalPending
        }
    }
    private var deletionSummary: String {
        switch accountModel.deletionStatus {
        case .idle: return ""
        case .sending: return L10n.voiceSharingAccountChecking
        case .unavailable: return L10n.voiceSharingAccountOperationFailed
        case .unauthorized: return L10n.voiceSharingAccountSignInAgain
        case .refused: return L10n.voiceSharingAccountRefused
        case .pending: return L10n.voiceSharingAccountDeletionPending
        }
    }
}

@MainActor
final class VoiceSharingAccountController: PCHostingController<VoiceSharingAccountView> {
    let accountModel: VoiceSharingAccountModel
    let localModel: VoiceSharingSettingsModel?
    init(accountModel: VoiceSharingAccountModel, localModel: VoiceSharingSettingsModel?, surfaceEnabled: @escaping () -> Bool) {
        self.accountModel = accountModel
        self.localModel = localModel
        super.init(rootView: VoiceSharingAccountView(accountModel: accountModel, localModel: localModel, surfaceEnabled: surfaceEnabled))
    }
    @MainActor dynamic required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A pushed local-recording destination retains the original account binding too.
@MainActor
private struct VoiceSharingAccountLocalView: View {
    @ObservedObject var accountModel: VoiceSharingAccountModel
    let localModel: VoiceSharingSettingsModel
    let originatingSession: String?
    let surfaceEnabled: () -> Bool
    var body: some View {
        if surfaceEnabled() && accountModel.canAct(in: originatingSession) {
            VoiceSharingSettingsView(model: localModel)
        } else { Text(L10n.voiceSharingAccountUnavailable) }
    }
}
