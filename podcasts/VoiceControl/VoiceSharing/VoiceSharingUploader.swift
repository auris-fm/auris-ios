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
    private let send: (VoiceSharingQueue.Entry) async -> Answer
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
        send: @escaping (VoiceSharingQueue.Entry) async -> Answer,
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

    /// One pass over the queue: sends every due recording until none remain.
    ///
    /// Returns the outcomes actually produced, so a caller (and a test) can see what happened rather
    /// than inferring it from the filesystem alone.
    @discardableResult
    func drain() async -> [Outcome] {
        // Sharing off deletes every local recording, before any other question is asked: the user's
        // withdrawal is not a reason to hold or skip the bytes, it is a reason to remove them.
        if !sharingEnabled() {
            queue.deleteAll(reason: "sharing-off")
            return []
        }
        deleteEntriesBelongingToAnotherIdentity()

        var outcomes: [Outcome] = []
        // `dueEntries()` deletes expired recordings as a side effect, which is itself an outcome of
        // the pass even though nothing was sent.
        var due = queue.dueEntries()
        while let entry = due.first {
            // Consent is re-read before EVERY request, not just at the start of the pass: a
            // withdrawal that lands while an earlier request is in flight must stop the next one
            // from ever reaching the network.
            guard sharingEnabled() else {
                queue.deleteAll(reason: "sharing-off")
                return outcomes
            }
            let outcome = await attempt(entry)
            outcomes.append(outcome)
            if case .retry = outcome {
                // This entry is now inside its backoff window; the rest of the pass continues.
                due = queue.dueEntries().filter { $0.name != entry.name }
            } else {
                due = queue.dueEntries()
            }
        }
        return outcomes
    }

    /// Removes recordings stamped with an account or epoch that is not the current live one.
    ///
    /// An entry that cannot be read is deleted too: the spec's list permits removing a recording that
    /// cannot be parsed, and an unreadable entry could never be sent.
    private func deleteEntriesBelongingToAnotherIdentity() {
        guard let identity = currentIdentity() else { return }
        for entry in queue.entries() {
            guard let data = try? Data(contentsOf: entry.metadataURL),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let epoch = record["enrollment_epoch"] as? String
            else {
                queue.delete(entry, reason: "unreadable")
                continue
            }
            if epoch != identity.epoch {
                queue.delete(entry, reason: "epoch-changed")
            } else if let account = record["account"] as? String, account != identity.account {
                queue.delete(entry, reason: "account-changed")
            }
        }
    }

    /// Sends one entry and applies its answer. Exposed so a caller can retry a single recording.
    @discardableResult
    func attempt(_ entry: VoiceSharingQueue.Entry) async -> Outcome {
        // The same check immediately before the send: `attempt` is callable on its own.
        guard sharingEnabled() else {
            queue.deleteAll(reason: "sharing-off")
            return .idle
        }
        let answer = await send(entry)
        let outcome = decide(answer, entry: entry)
        switch outcome {
        case .accepted:
            queue.delete(entry, reason: "accepted")
        case .refused(let status):
            queue.delete(entry, reason: "refused-\(status)")
        case .requiresSignIn:
            // The recording is NOT deleted: an expired sign-in says nothing about the recording.
            let refreshed = await refreshSignIn()
            log("refresh reason=unauthorized success=\(refreshed) name=\(entry.name)")
            if refreshed {
                // Try again immediately with the restored credential.
                return await attempt(entry)
            }
            scheduleRetry(entry)
            return .retry(delay: backoffDelay(for: entry))
        case .retry:
            scheduleRetry(entry)
        case .idle:
            break
        }
        return outcome
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

    private func scheduleRetry(_ entry: VoiceSharingQueue.Entry) {
        let count = (failures[entry.name] ?? 0) + 1
        failures[entry.name] = count
        let delay = min(pow(2, Double(count - 1)) * 60, Self.maximumBackoff)
        queue.deferUntil(now().addingTimeInterval(delay), entry: entry)
        log("retry delay=\(Int(delay))s name=\(entry.name)")
    }

    private func backoffDelay(for entry: VoiceSharingQueue.Entry) -> TimeInterval {
        let count = max(failures[entry.name] ?? 1, 1)
        return min(pow(2, Double(count - 1)) * 60, Self.maximumBackoff)
    }
}