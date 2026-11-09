import Foundation

/// Offers due recordings to the server, oldest first.
///
/// One loop, one recording at a time, and one rule for what an answer means:
///
/// | answer | outcome |
/// |---|---|
/// | `2xx` | accepted — delete |
/// | `401` | sign-in expired — refresh, retry |
/// | any other `4xx` | final refusal — delete |
/// | anything else, or no answer | retry with backoff |
///
/// A recording that fails never blocks the others: the loop moves on and that entry alone waits.
final class VoiceSharingUploader {

    /// Exponential backoff, capped at one hour. Memory-only, so a restart simply tries again.
    static let maximumBackoff: TimeInterval = 60 * 60

    /// One HTTP answer, reduced to what the loop decides on.
    enum Answer: Equatable {
        case response(status: Int)
        /// No answer at all: transport failure, timeout, or a cancelled request.
        case noAnswer
        /// The request was never made because sharing was no longer permitted. Not a server
        /// answer: the recording is deleted under the sharing-off rule, never retried.
        case cancelled
    }

    enum Outcome: Equatable {
        case accepted
        case refused(status: Int)
        case requiresSignIn
        case retry(delay: TimeInterval)
        /// Nothing was due, or the queue was empty.
        case idle
    }

    private let queue: VoiceSharingQueue
    private let send: (VoiceSharingQueue.Entry, @escaping () -> Bool) async -> Answer
    private let refreshSignIn: () async -> Bool
    /// The account and epoch this process is currently signed in and enrolled under. An entry whose
    /// recorded identity differs is deleted: it belongs to an account or epoch that is no longer live.
    private let currentIdentity: () -> (account: String, epoch: String)?
    /// The user's live sharing choice. Turning it off deletes every local recording.
    private let sharingEnabled: () -> Bool
    private let now: () -> Date
    private let log: (String) -> Void

    /// Consecutive retryable failures, per entry, used only to grow the backoff delay.
    private var failures: [String: Int] = [:]

    init(
        queue: VoiceSharingQueue,
        send: @escaping (VoiceSharingQueue.Entry, @escaping () -> Bool) async -> Answer,
        refreshSignIn: @escaping () async -> Bool,
        currentIdentity: @escaping () -> (account: String, epoch: String)?,
        sharingEnabled: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.queue = queue
        self.send = send
        self.refreshSignIn = refreshSignIn
        self.currentIdentity = currentIdentity
        self.sharingEnabled = sharingEnabled
        self.now = now
        self.log = log
    }

    /// Seconds until the earliest recording leaves its backoff window, if any is waiting.
    func secondsUntilNextRetry() async -> TimeInterval? {
        await queue.secondsUntilNextRetry()
    }

    /// One pass over the queue: sends every due recording until none remain.
    ///
    /// Returns the outcomes actually produced, so a caller (and a test) can see what happened rather
    /// than inferring it from the filesystem alone.
    @discardableResult
    func drain() async -> [Outcome] {
        // Sharing off deletes every local recording, before any other question is asked: the user's
        // withdrawal is not a reason to hold or skip the bytes, it is a reason to remove them.
        if !sharingEnabled() {
            await queue.deleteAll(reason: "sharing-off")
            return []
        }
        await deleteEntriesBelongingToAnotherIdentity()

        var outcomes: [Outcome] = []
        // `dueEntries()` deletes expired recordings as a side effect, which is itself an outcome of
        // the pass even though nothing was sent.
        var due = await queue.dueEntries()
        while let entry = due.first {
            // Consent is re-read before EVERY request, not just at the start of the pass: a
            // withdrawal that lands while an earlier request is in flight must stop the next one
            // from ever reaching the network.
            guard sharingEnabled() else {
                await queue.deleteAll(reason: "sharing-off")
                return outcomes
            }
            let outcome = await attempt(entry)
            outcomes.append(outcome)
            if case .retry = outcome {
                // This entry is now inside its backoff window; the rest of the pass continues.
                due = await queue.dueEntries().filter { $0.name != entry.name }
            } else {
                due = await queue.dueEntries()
            }
        }
        return outcomes
    }

    /// Removes recordings stamped with an account or epoch that is not the current live one.
    ///
    /// An entry that cannot be read is deleted too: the spec's list permits removing a recording that
    /// cannot be parsed, and an unreadable entry could never be sent.
    private func deleteEntriesBelongingToAnotherIdentity() async {
        guard let identity = currentIdentity() else { return }
        for entry in await queue.entries() {
            guard let data = try? Data(contentsOf: entry.metadataURL),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let epoch = record["enrollment_epoch"] as? String
            else {
                await queue.delete(entry, reason: "unreadable")
                continue
            }
            if epoch != identity.epoch {
                await queue.delete(entry, reason: "epoch-changed")
            } else if let account = record["account"] as? String, account != identity.account {
                await queue.delete(entry, reason: "account-changed")
            }
        }
    }

    /// Sends one entry and applies its answer. Exposed so a caller can retry a single recording.
    ///
    /// `refreshesRemaining` bounds the sign-in cycle: a refresh that hands back a credential the
    /// server still rejects would otherwise recurse forever and hold the whole drain on one
    /// recording. One refresh per attempt, then the entry backs off and the pass moves on.
    @discardableResult
    func attempt(_ entry: VoiceSharingQueue.Entry, refreshesRemaining: Int = 1) async -> Outcome {
        // Consent and identity are checked immediately before EVERY send: the pass may have begun
        // under one account or while sharing was on, and either can change while an earlier
        // recording is in flight.
        guard sharingEnabled() else {
            await queue.deleteAll(reason: "sharing-off")
            return .idle
        }
        guard await belongsToLiveIdentity(entry) else { return .idle }

        let answer = await send(entry, { [weak self] in
            guard let self else { return false }
            // Read-only here: this runs on the transport's path and must not mutate the queue.
            return self.sharingEnabled() && self.liveIdentityStillMatches(entry)
        })
        let outcome = decide(answer, entry: entry)
        switch outcome {
        case .accepted:
            await queue.delete(entry, reason: "accepted")
        case .refused(let status):
            await queue.delete(entry, reason: "refused-\(status)")
        case .requiresSignIn:
            // The recording is NOT deleted: an expired sign-in says nothing about the recording.
            guard refreshesRemaining > 0 else {
                await scheduleRetry(entry)
                log("refresh exhausted name=\(entry.name) — backing off, not re-sending")
                return .retry(delay: backoffDelay(for: entry))
            }
            let refreshed = await refreshSignIn()
            log("refresh reason=unauthorized success=\(refreshed) name=\(entry.name)")
            if refreshed {
                return await attempt(entry, refreshesRemaining: refreshesRemaining - 1)
            }
            await scheduleRetry(entry)
            return .retry(delay: backoffDelay(for: entry))
        case .retry:
            await scheduleRetry(entry)
        case .idle:
            break
        }
        return outcome
    }

    /// Whether this recording still belongs to the live account and enrollment epoch. A recording
    /// from a superseded identity is deleted rather than sent: it describes a session that no
    /// longer exists, and the server would reject it.
    private func belongsToLiveIdentity(_ entry: VoiceSharingQueue.Entry) async -> Bool {
        switch identityVerdict(entry) {
        case .matches: return true
        case .unreadable:
            await queue.delete(entry, reason: "unreadable")
            return false
        case .epochChanged:
            await queue.delete(entry, reason: "epoch-changed")
            return false
        case .accountChanged:
            await queue.delete(entry, reason: "account-changed")
            return false
        }
    }

    /// Read-only form of the same question, for the transport's last-moment check.
    private func liveIdentityStillMatches(_ entry: VoiceSharingQueue.Entry) -> Bool {
        identityVerdict(entry) == .matches
    }

    private enum IdentityVerdict: Equatable {
        case matches, unreadable, epochChanged, accountChanged
    }

    private func identityVerdict(_ entry: VoiceSharingQueue.Entry) -> IdentityVerdict {
        guard let identity = currentIdentity() else { return .accountChanged }
        guard let data = try? Data(contentsOf: entry.metadataURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let epoch = record["enrollment_epoch"] as? String
        else { return .unreadable }
        guard epoch == identity.epoch else { return .epochChanged }
        if let account = record["account"] as? String, account != identity.account {
            return .accountChanged
        }
        return .matches
    }

    /// Maps one answer to its outcome. Pure, so the table can be checked directly.
    func decide(_ answer: Answer) -> Outcome {
        switch answer {
        case .cancelled:
            return .idle
        case .noAnswer:
            return .retry(delay: 0)
        case .response(let status):
            if (200...299).contains(status) { return .accepted }
            if status == 401 { return .requiresSignIn }
            if (400...499).contains(status) { return .refused(status: status) }
            return .retry(delay: 0)
        }
    }

    private func decide(_ answer: Answer, entry: VoiceSharingQueue.Entry) -> Outcome {
        let outcome = decide(answer)
        if case .retry = outcome {
            return .retry(delay: backoffDelay(for: entry))
        }
        return outcome
    }

    private func scheduleRetry(_ entry: VoiceSharingQueue.Entry) async {
        let count = (failures[entry.name] ?? 0) + 1
        failures[entry.name] = count
        let delay = min(pow(2, Double(count - 1)) * 60, Self.maximumBackoff)
        await queue.deferUntil(now().addingTimeInterval(delay), entry: entry)
        log("retry delay=\(Int(delay))s name=\(entry.name)")
    }

    private func backoffDelay(for entry: VoiceSharingQueue.Entry) -> TimeInterval {
        let count = max(failures[entry.name] ?? 1, 1)
        return min(pow(2, Double(count - 1)) * 60, Self.maximumBackoff)
    }
}