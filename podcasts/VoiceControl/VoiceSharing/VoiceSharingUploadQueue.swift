import CryptoKit
import Foundation
import PocketCastsUtils

/// Durable upload queue persistence (spec §Client queue and scheduling, docs commit 270dfa5 lineage).
///
/// hardening after the four properties pinned by
/// VoiceSharingUploadQueueTests:
///
/// * **Complete-entry validation.** Marker presence alone is not readiness. A ready entry is a
/// directory holding regular, non-empty `metadata.json` and `audio.wav` plus `ready.marker`,
/// where the metadata declares the audio's SHA-256 digest and byte count and the actual audio
/// bytes match that declaration. Entries failing validation are removed as abandoned during
/// recovery and filtered from live listings — malformed or partial entries never become
/// upload work.
/// * **Finite persistence limits.** `prepare` enforces `maxQueueEntries` over preparation + ready
/// work and `maxEntryAudioBytes` per audio body, and cleans up its own directory if the
/// metadata write fails after the audio write. Uploader gating cannot bound what persists.
/// * **Durability ordering.** `finalize` synchronizes audio, metadata and the entry directory to
/// storage before the ready marker is published (atomic replace + sync), so the marker never
/// announces an entry whose bytes are not yet durable. The synchronization is routed through an
/// injected `synchronizer` seam; the ordering control pins marker publication strictly after
/// file/directory synchronization. (In-process controls cannot prove crash durability; they pin
/// the ORDER the platform mechanism must follow.)
/// * **One serialized queue owner.** All mutations run on an internal serial queue. Entries are
/// opaque `Entry` handles bound to this queue's root; a forged or foreign handle is refused by
/// every file-accessing method instead of being trusted by path.
///
/// Receipt handling, attempt gating, retry/backoff and network policy remain downstream uploader
/// concerns and are deliberately not here.
final class VoiceSharingUploadQueue {

    /// Per-entry audio ceiling. A compiled ceiling, not an approved activation value; the
    /// uploader validates against the spec's request/clip limits at attempt time.
    static let maxEntryAudioBytes = 16_000 * 2 * 60 * 2 // ≈ 60 s of 16 kHz mono s16le, doubled headroom

    /// Entry-count ceiling over preparation + ready work. Compiled ceiling, not an activation value.
    static let maxQueueEntries = 32

    /// Per-entry metadata ceiling (spec `max_metadata_bytes` is validated against a compiled
    /// ceiling; this is the ceiling, not an activation value).
    static let maxMetadataBytes = 64 * 1024

    /// Queue-age bound for ready entries, measured from CAPTURE. Entries older than this are
    /// removed at recovery and refuse publication — a compiled ceiling, not an activation value.
    ///
    ///: a recording not ACCEPTED within seven days of capture is deleted. Retention
    /// — not a fixed attempt cap — is what bounds how long an unaccepted recording can persist:
    /// the queue retries for as long as the backoff schedule is due, but never past this instant.
    static let maxEntryAge: TimeInterval = 7 * 24 * 60 * 60

    /// QUEUE-WIDE budgets. Per-entry bounds cannot bound the queue: N individually-legal entries
    /// still multiply. These are compiled defaults; like every other numeric limit here they are
    /// implementation bounds, not owner-approved activation values.
    /// THE only queue-WIDE limit is A RECORD count. There is no byte budget: it
    /// required accounting that could not be read, and accounting that cannot be read stops
    /// admission forever — which is what wedged the owner's queue while it held 3.6% of its
    /// allowance. A count of entries on disk cannot fail that way, and it is the bound the spec
    /// actually asks for.
    struct AggregateLimits {
        let maxRecords: Int

        static let `default` = AggregateLimits(maxRecords: VoiceSharingUploadQueue.maxQueueEntries)
    }

    /// Durable proof of attempt ownership. `generation` is the FENCE: identity, not elapsed time,
    /// is what stops a stale owner from releasing or completing a successor's work.
    struct AttemptLease: Equatable {
        let generation: String
        let acquiredAt: Date
        let owner: Int32

        var jsonObject: [String: Any] {
            ["generation": generation,
             "acquiredAt": acquiredAt.timeIntervalSince1970,
             "owner": Int(owner)]
        }

        init(generation: String, acquiredAt: Date, owner: Int32) {
            self.generation = generation
            self.acquiredAt = acquiredAt
            self.owner = owner
        }

        init?(jsonObject: [String: Any]) {
            guard let generation = jsonObject["generation"] as? String,
                  UUID(uuidString: generation) != nil,
                  let acquiredAt = jsonObject["acquiredAt"] as? TimeInterval,
                  acquiredAt > 0, acquiredAt.isFinite,
                  let owner = jsonObject["owner"] as? Int,
                  owner >= 0
            else { return nil }
            self.generation = generation
            self.acquiredAt = Date(timeIntervalSince1970: acquiredAt)
            self.owner = Int32(clamping: owner)
        }
    }

    /// Attempt bounds. Compiled implementation defaults, not owner-approved activation values.
    struct AttemptLimits {
        /// NO ATTEMPT cap at all. Retrying is bounded by
        /// the backoff schedule and by retention (`maxEntryAge`), never by a count. The failures
        /// that matter here are TRANSIENT — a server answering 503 for hours — and any count turns
        /// a temporary outage into permanent data loss. Raising the old five to a thousand only
        /// moved the cliff, so production passes nil and there is nothing to compare against.
        ///
        /// A caller that genuinely needs a budget (a control pinning bounded behaviour) can still
        /// pass one.
        let optionalCap: Int?

        static let `default` = AttemptLimits(optionalCap: nil)
    }

    /// Whether the stored count still permits another attempt. With no cap this is always true:
    /// the count saturates instead of refusing.
    private func admitCountPermits(_ count: Int) -> Bool {
        guard let cap = attemptLimits.optionalCap else { return true }
        return count < cap
    }

    /// Upper bound on bytes this queue itself writes for one entry, excluding the caller's audio and
    /// metadata: `created.at` (a bounded decimal instant), `stage.publishing` (1 byte),
    /// `publication.failed` (1 byte), `ready.marker` (1 byte) and a temporary marker name.
    /// not admission arithmetic any more; it survives as the
    /// sink's worst-case size input.
    static let protocolOverheadBytes = 256

    /// Hard cap on directory entries examined during discovery. A cap checked after an eager listing
    /// does not bound allocation, so listing itself goes through `listDirectoryBounded`, which stops
    /// at the cap and reports overflow. Exceeding it is a refusal: an entry directory that cannot be
    /// examined within the bound has unknowable usage.
    /// Bound on names this queue will examine in ONE directory, sized to what the format can
    /// actually hold rather than to a round number.
    ///
    /// This used to be 64 for the ROOT as well, which was a queue-wedging bug: the root holds one
    /// directory per capture PLUS a retry stamp and an obligation per capture, so ~22 recordings
    /// overflowed it. Overflow made enumeration refuse, and enumeration is how the queue counts,
    /// serves, drains and purges — so a perfectly legal queue became unreadable and undrainable.
    /// Android hit the same shape at 512 names.
    ///
    /// The root bound is therefore derived: the record limit, times the sidecars one capture can
    /// leave, plus headroom for debris. It is still a bound - a directory that cannot be enumerated
    /// within it is not silently half-read - but it can no longer be exceeded by a queue the spec
    /// permits to exist.
    static let maxDirectoryEntries = 64

    /// DEPRECATED bound — retained only for the destructive sweep, never for discovery, counting or
    /// serving. Any bound derived from the cap is
    /// wrong: an inherited over-cap queue (Android's Pixel held 104) exceeds it, and the queue
    /// cannot drain down to the cap without first being discovered. So the name is honest about its
    /// one remaining job.
    static let maxSweptEntries = maxQueueEntries * 4 + 64

    /// The smallest wake a retry-held queue will arm when work is ALREADY due. Positive by
    /// construction: an armed 0 fires the trigger immediately, which re-arms and spins (reviewer
    /// 34aae0fa). That is the one hazard a retry hold must still prevent, while still never
    /// freezing progress.
    static let retryHoldWakeFloorSeconds: TimeInterval = 15

    /// The closed set of file names an entry directory may contain. Accounting and cleanup are
    /// defined over exactly these.
    /// The closed set of fixed file names an entry directory may contain.
    static let knownEntryNames: Set<String> = [
        attemptRecordName, attemptLeaseName,
        audioName, metadataName, createdName, readyMarkerName, stageName, failedName, ownerName
    ]
    /// Prefix of this queue's own temporary marker names (`ready.marker.tmp-<UUID>`). A replacement
    /// that fails after writing the temporary can leave one behind, so it is part of the owned
    /// format and must be both accounted and cleanup-able rather than permanently blocking admission.
    ///
    /// Because the suffix is arbitrary, these names are not a finite set. They are recognised by
    /// prefix + well-formed UUID, and all work over them is budgeted.
    static let temporaryMarkerPrefix = "\(readyMarkerName).tmp-"

    enum PrepareError: Error, Equatable {
        case queueFull
        case audioTooLarge
        case metadataTooLarge
        /// Stored usage could not be determined, so admission is refused rather than assuming the
        /// unknown space is free.
        case accountingUnavailable
        /// Required queue-root backup policy could not be established and read back.
        case storagePolicyUnavailable
        /// RETIRED policy: the case remains because the surviving arithmetic guard
        /// in `recordAttemptLocked` still uses it, but no attempt BUDGET exists any more — an
        /// entry is never refused for counting too many tries. Retention deletes unaccepted
        /// recordings; the count no longer terminates anything.
        case attemptsExhausted
        /// Another owner holds the attempt lease.
        case leaseHeld
        /// A retry delay is still owed: the entry is admitted no earlier than `retryAt`. Distinct
        /// from `leaseHeld` — nobody owns the entry, the schedule does.
        case notYetDue(retryAt: Date)
        /// A completion arrived from an owner that no longer holds the lease.
        case resultStale
        /// A retry reports a DIFFERENT outcome than the durably recorded pending settlement.
        case settlementConflict
        case expired
        /// The ready transition may have occurred but its final synchronization could not be
        /// confirmed. Distinct from every other case here, which are all known-uncommitted. Callers
        /// must reconcile (`reconcilePublication`) rather than assuming either outcome.
        case publicationUncertain
    }

    /// Opaque entry handle. Only names an entry under a root; every accessor validates that the
    /// handle belongs to THIS queue before touching the filesystem.
    struct Entry: Hashable {
        let root: URL
        let name: String
    }

    private static let readyMarkerName = "ready.marker"
    /// Write-once lifecycle stage, created before the marker is published. It is the discriminator
    /// that makes "marker present, no disqualifier" impossible to observe after a restart: an entry
    /// that reached publication always carries `stage.publishing`, and an entry that never did
    /// carries none. A truncated stage file is distinguishable from an absent one.
    private static let stageName = "stage.publishing"
    private static let audioName = "audio.wav"
    /// Suffix for audio a failed delete left behind outside its entry directory.
    static let audioResidueSuffix = ".audio.wav"
    private static let metadataName = "metadata.json"
    /// The IMMUTABLE admission instant: written once at prepare, never refreshed by finalize or a
    /// retried publication. Queue age is measured from here, so a preparation held past the bound
    /// cannot gain a fresh lifetime by being published, and repeated finalize cannot extend it.
    private static let createdName = "created.at"
    /// ACCOUNT ownership, local only. The wire record carries the enrollment
    /// epoch but deliberately no account scope — the pinned intake schema has no such field, and
    /// adding one would change the upload contract. Ownership is therefore recorded HERE, beside
    /// the entry, and compared at admission; it never reaches the server.
    private static let ownerName = "owner.account"
    /// A scope string is a bounded opaque id, never a path or log payload.
    private static let maxOwnerBytes = 256
    /// Upper bound for the immutable instant's file. A timestamp is a short decimal string; anything
    /// larger is a corrupt or foreign object and must be refused without being read.
    /// Durable attempt record. Its PRESENCE means "an attempt started"; its CONTENT is the count. It
    /// is written before a request and never removed at request end, so attempts accumulate across
    /// process restarts as the spec requires.
    static let attemptRecordName = "attempts.json"
    static let maxCreationInstantBytes = 64
    /// Upper bound on the attempt record's size. A larger file is corrupt or foreign, and reading it
    /// to find out would let a hostile object drive allocation.
    static let maxAttemptRecordBytes = 64
    /// Name of the root-scoped lease for an in-flight attempt. It lives NEXT to the entry (inside
    /// the entry directory, as `attempt.lease`) so a stale lease travels with its entry.
    static let attemptLeaseName = "attempt.lease"
    /// Number of fixed lock files. A stable hash maps every entry to exactly ONE of these, so the
    /// same entry always locks the same inode — mutual exclusion holds — while the namespace never
    /// grows. UUID-per-entry locks accumulated forever and, past the root's bounded discovery limit,
    /// permanently disabled admission. Hash collisions only over-serialize unrelated entries.
    static let leaseLockPoolSize = 16
    static let maxRootLockFiles = leaseLockPoolSize

    /// Root-level lease-lock file for an entry. Lives at the ROOT because entry directories are
    /// removed whole by recovery/exhaustion, which would invalidate the lock's inode. The name is
    /// drawn from a FIXED pool so lifetime entries cannot accumulate root artifacts.
    static func rootLeaseLockName(for entryName: String) -> String {
        "attempt.lock.\(stableLockIndex(for: entryName))"
    }

    /// Stable, dependency-free hash: FNV-1a over the entry name.
    static func stableLockIndex(for entryName: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in entryName.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Int(hash % UInt64(leaseLockPoolSize))
    }
    static let maxAttemptLeaseBytes = 256
    /// How long a lease is considered live without renewal. A killed owner cannot renew, so after
    /// this window another owner may reclaim. Compiled bound, not an activation value.
    /// App-private queue storage root (Application Support, per account-agnostic feature dir).
    /// Created lazily by callers; the queue itself requires the directory to exist at init.
    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceContributions", isDirectory: true)
    }

    static let attemptLeaseDuration: TimeInterval = 120
    /// SATURATION point of the stored attempt counter.
    ///
    /// This is not a cap and not a budget: the counter increments up to this value and then stays
    /// put, and NOTHING is refused for reaching it. It exists only so the record's JSON number
    /// cannot grow without bound, and so the count remains readable PERMANENTLY as a diagnostic:
    /// "this recording has failed at least N times".
    static let attemptCountSaturation = 1_000
    /// Present when publication failed and its cleanup could not complete. Such an entry is never
    /// exposed as ready, even if the ready marker survived.
    /// Present when this attempt definitively failed. Written before any removal attempt.
    private static let failedName = "publication.failed"
    /// DURABLE owner-wide revocation intent: written and synced
    /// before any purge mutation, so a crash or a failed disqualification cannot leave a fresh
    /// queue that serves an unmarked survivor. While this file exists, the owner is HELD: nothing
    /// serves or admits. It is removed only by a fully reconciled purge.
    private static let revocationIntentName = "revocation.intent"

    let rootDirectory: URL
    private let fileManager: FileManager
    /// Storage-synchronization seam: fsync-equivalent for a file or directory path. Production
    /// default performs a real sync; controls inject a recorder to pin ordering.
    /// Testable time source for the immutable queue-age bound.
    private let clock: () -> Date
    private let synchronizer: (_ path: URL, _ isDirectory: Bool) throws -> Void
    private let failureRecordWriter: (URL, Data) throws -> Void

    /// Whether the most recent refused publication could be disqualified DURABLY. `unavailable`
    /// means neither the failure record nor marker removal succeeded, so only this process knows the
    /// entry is unpublishable — a restart cannot be protected by in-memory state.
    /// Outcome of a publication attempt. The spec requires three distinct states: a generic thrown
    /// error must not erase the difference between "definitely not committed" and "may have
    /// committed".
    enum PublicationOutcome: Equatable {
        /// Durable success: the entry is ready and its readiness is confirmed on disk.
        case committed
        /// Known to precede the ready transition: the entry is not ready and never will be.
        case uncommitted
        /// The ready transition may have occurred but its final synchronization could not be
        /// confirmed. Neither success nor rejection: the same immutable identity must be reconciled
        /// under the queue owner before any attempt, and a fresh instance applies the same rules.
        case uncertain
    }

    /// Entries whose ready transition this instance could not confirm. An in-process HINT only: it
    /// is never treated as proof of non-publication, and reconciliation derives its verdict from
    /// durable state alone so a fresh instance reaches the same answer.
    private var uncertainEntriesLocked: Set<Entry> = []
    /// Injectable marker-installation seam. Exists so the atomic-replacement failure path (which may
    /// install the marker and still throw) is testable: FileManager's replacement API lives in an
    /// extension and cannot be overridden.
    private let markerReplacer: (URL, URL) throws -> URL?
    private var aggregateLimits: AggregateLimits
    /// The live account + enrollment identity, or nil when the process cannot establish one.
    ///
    /// UNBOUND (`nil`) means this queue was constructed without identity authority — every existing
    /// test and caller. Binding is explicit (`bindIdentity`), so the no-identity behaviour of an
    /// unbound queue is unchanged. Once BOUND, a reader that returns nil is a FAILED identity read
    /// (signed out, epoch not yet loaded) and admission refuses: that is the startup case where a
    /// surviving entry must not be uploaded before enrollment is known.
    private let currentIdentityLocked: (() -> VoiceSharingUploadIdentity?)?
    private var identityIsBound: Bool { currentIdentityLocked != nil }
    /// Installs the live identity reader. Read under the queue's serial queue on every admission, so
    /// a transition between admissions is observed rather than pinned at construction.

    private let attemptLimits: AttemptLimits
    /// In-flight ownership is deliberately IN-MEMORY only: a live request belongs to the process
    /// that opened it, so a killed process cannot leave one behind. The durable file records that an
    /// attempt STARTED (so the count survives restart) but is never read as "still running".
    private var inFlightAttempts: [Entry: AttemptLease] = [:]

    /// OWNER-WIDE hold (round 66): set when a purge could not durably reconcile. While held, no
    /// entry may serve, admit, or begin an attempt — the in-memory view and storage disagree, and
    /// only a later purge whose barriers all succeed may release the hold. This is the honest
    /// answer to "the disqualification might not be durable": refuse everything rather than
    /// report success or miscount an unmarked survivor as disqualified.
    private var revocationHoldLocked = false
    /// Bumped whenever ANYTHING a snapshot displays about the queue changes — the hold, its origin,
    /// or the ready count — so a snapshot can prove its queue read was not split by a concurrent
    /// purge, hold transition, or enqueue.
    private var holdGeneration = 0

    /// Re-derive the generation from the displayed queue facts after every mutation.
    /// The count a snapshot would display, computed under the serial queue WITHOUT going through
    /// the serving path's fail-closed gates (a held queue still has a count; it is simply not
    /// served). Used only to detect a change, never exposed as a count.
    /// AGE eligibility for one entry, in ONE place. The served set
    /// (`readyEntriesReportingUnknownCoverage`), the change signature and therefore the model's
    /// count all consult this, so a version can never disagree with what is actually served
    ///. A FUTURE marker date is not fresh — a clock skew must not extend an
    /// entry's life — and an unreadable date is `nil`, i.e. outside the served set.
    private func isWithinAgeBoundLocked(_ entry: Entry) -> Bool {
        guard let age = markerAgeLocked(entry) else { return false }
        // A FUTURE date is not fresh. The future-date rule is UNCHANGED: an
        // admission instant ahead of the reading clock does not serve. A tolerance was drafted here
        // and REJECTED — widening eligibility to paper over a clock disagreement would hide a real
        // ordering/clocks problem rather than fix it, and it would change expiry semantics. The
        // defect that produced the negative age is therefore addressed at its SOURCE: the reading
        // clock is coherent with the writing clock (see `clock`), not excused after the fact.
        return age >= 0 && age <= Self.maxEntryAge
    }

    /// AGE is measured from the entry's IMMUTABLE admission instant (`created.at`), which is the
    /// only timestamp that cannot be refreshed by a later write. The marker's file mtime is not
    /// used: it is stamped with real time at publication, so under an injected clock it can appear
    /// in the future and would exclude a perfectly fresh entry (found by the diagnostics added for
    ///). An unreadable instant is "age unknown" — never "fresh" and never
    /// "ancient" (the old `distantPast` fallback).
    private func markerAgeLocked(_ entry: Entry) -> TimeInterval? {
        // AN UNPERSISTED reset is the authority: if a previous repair
        // could not be written, the chosen instant is used for BOTH serving and ageing until it can
        // be. Without this the disk value (still invalid) was re-read, so the served set excluded the
        // entry the repair had just accepted, and its retention clock never advanced.
        let now = clock().timeIntervalSince1970
        if let unpersisted = resetInstantsLocked[entry.name] {
            return max(0, now - unpersisted)
        }
        // UNTRUSTED age is repaired, not honoured (spec, Android parity): a missing, unreadable or
        // future instant is reset to now and the entry reads as age 0 — fresh, so it serves and its
        // retention clock starts now. An entry that is not structurally complete never reaches this
        // reader for a reset (the resetters check completeness first), which keeps recovery's
        // treatment of partial work unchanged.
        switch captureInstantReadingLocked(entry) {
        case .untrusted(let reason):
            // THE guard lives here, not in the callers. The comment
            // above claimed every caller checked completeness first; two did not — the served-set
            // age rule and its diagnostic — so a PARTIAL entry could have its instant rewritten by a
            // routine that is supposed to repair published work only. A repair is a WRITE, and writes
            // on state we could not validate are how recovery's treatment of incomplete work
            // silently changed. Incomplete entries keep their instant and stay recovery's business.
            guard isCompleteEntryLocked(at: entry) else {
                // Not repairable here and not "fresh": an age we may not act on.
                return nil
            }
            resetUntrustedAgeLocked(entry, observed: reason)
            return 0
        case .trusted(let age):
            return age
        }
    }

    /// The pre-reset reader, unchanged in behaviour, used where the caller needs the RAW instant
    /// (the structural completeness classifier must not repair anything it inspects).
    private func markerAgeWithoutRepairLocked(_ entry: Entry) -> TimeInterval? {
        guard let created = creationSecondsLocked(in: entryDirectoryLocked(for: entry)) else { return nil }
        // THE age is computed in the same epoch space the instant was written.
        // `created.at` is stored as seconds since 1970; converting it back through
        // `Date(timeIntervalSince1970:)` and subtracting in the 2001 reference space rounds
        // independently on the way in and out, which can land the reconstructed instant a fraction
        // of a microsecond AHEAD of the very reading that wrote it — a negative age for a brand-new
        // entry, the original epoch failure (`age(-0s)`). Subtracting the stored double from the
        // clock's own 1970 reading keeps both operands in one representation: the same instant
        // yields exactly zero, and only a genuinely later write reads positive.
        return clock().timeIntervalSince1970 - created
    }

    /// Diagnostic split of the count's exclusions. Kept because a count of 0 has three very
    /// different meanings and conflating them has already hidden a real eligibility mismatch.
    enum ReadyExclusion: Equatable {
        case insideBound(Int)
        case noneInsideBound(incomplete: Int, undurable: Int, unreadableDate: Int, futureDate: Int, agedOut: Int)
    }

    func readyCountDiagnostics() -> ReadyExclusion {
        serialQueue.sync {
            var incomplete = 0, undurable = 0, unreadableDate = 0, futureDate = 0, agedOut = 0, inside = 0
            for entry in entriesLocked() {
                guard isCompleteEntryLocked(at: entry) else { incomplete += 1; continue }
                guard (try? confirmDurableLocked(directory: entryDirectoryLocked(for: entry))) != nil else {
                    undurable += 1; continue
                }
                guard let age = markerAgeLocked(entry) else { unreadableDate += 1; continue }
                if age < 0 { futureDate += 1 }
                else if age > Self.maxEntryAge { agedOut += 1 }
                else { inside += 1 }
            }
            return inside > 0
                ? .insideBound(inside)
                : .noneInsideBound(incomplete: incomplete, undurable: undurable,
                                   unreadableDate: unreadableDate, futureDate: futureDate, agedOut: agedOut)
        }
    }

    private func readyEntryCountLocked() -> Int {
        readyCountLocked()
    }

    /// The SAME membership rule the serving authority uses: complete, durability-confirmed, and
    /// within the age bound. Duplicated deliberately rather than calling the full authority, which
    /// can throw and hold — the count is a display detail, but it must not count anything the
    /// authority would refuse to serve.
    func readyCountLocked() -> Int {
        entriesLocked().filter { entry in
            guard isCompleteEntryLocked(at: entry),
                  (try? confirmDurableLocked(directory: entryDirectoryLocked(for: entry))) != nil
            else { return false }
            return isWithinAgeBoundLocked(entry)
        }.count
    }

    /// Seconds until the NEXT entry crosses the age bound, so a timely refresh can be scheduled
    /// instead of the displayed count silently going stale on an idle screen.
    /// `nil` when nothing is waiting on time.
    /// The earliest outstanding retry boundary, for the upload trigger's ONE bounded wake
    ///: a pass that ends with every entry behind its not-before boundary
    /// has no other wake — the scheduler contract explicitly delegates the "retry boundary
    /// passing" re-invoke to callers. Nil = no outstanding boundary. An unaccountable root
    /// (listing failure/overflow) or an unparseable stamp reports 0 — wake now; admission
    /// re-checks everything fail-closed, so an early wake can never send anything prematurely.
    /// Whether a retry wake would make PROGRESS for this entry.
    ///
    /// A wake is worth arming only for work the NEXT pass can attempt. A boundary is not "due
    /// work" merely because its instant has passed: if admission will refuse, the next pass
    /// changes nothing, re-arms at the same instant, and the trigger spins in a zero-sleep
    /// self-reoffer loop that keeps the app awake while uploading nothing.
    ///
    /// So this mirrors `admitAttempt`'s NON-MUTATING gates, in the same order, and answers:
    /// * `.dueWork(delay)` — admission would attempt it now or at `delay`;
    /// * `.notWork` — a fact that admission refuses on and that no wake can change (debris,
    /// unready entry, spent count, a hold over this entry's owner);
    /// * `.unknown` — a fact that could not be READ. Unknown is never "due now" and never
    /// "nothing to do": it arms nothing and waits for an ordinary signal (lifecycle event, new
    /// publication, or the uploader's own completion re-offer), because polling on unknown
    /// state is exactly the loop this rule forbids.
    ///
    /// Deliberately shared with admission rather than restated: `revocationHoldLocked`,
    /// `retryHoldLocked`, `strictOwnerCoverageLocked`, `inFlightAttempts` and the count ceiling are
    /// the SAME facts `admitAttempt` consults (VoiceSharingUploadQueue.swift:1335-1360). A private
    /// copy would drift and re-open the loop.
    private enum RetryWakeProspect {
        case dueWork(TimeInterval)
        case notWork
        case unknown
    }

    private func retryWakeProspectLocked(forEntryNamed entryName: String, at now: TimeInterval) -> RetryWakeProspect {
        // only A SHARING-OFF hold stops work. A retry hold used
        // to answer `.notWork` too, which meant an unreadable retry record permanently suppressed
        // every entry's retry wake — the queue would never schedule the very retry that would have
        // cleared the hold. Unknown retry state is due now, so it never blocks the wake either.
        if revocationHoldLocked { return .notWork }
        guard UUID(uuidString: entryName) != nil else { return .notWork } // not an entry: debris
        let entryDir = rootDirectory.appendingPathComponent(entryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: entryDir.path, isDirectory: &isDirectory),
            isDirectory.boolValue else { return .notWork } // purged entry: orphan debris
        let entry = Entry(root: rootDirectory, name: entryName)
        // SENDABLE, not COMPLETE: the wake must use the same predicate the
        // serving and upload paths use, or a readable-but-malformed or digest-mismatched recording
        // that earns a RETRYABLE server response loses its automatic retry — it would need another
        // utterance or a restart to be sent again. `isCompleteEntryLocked` additionally demands a
        // successful LOCAL binding, which is not a server fact.
        guard isServedEntryLocked(at: entry) else { return .notWork }
        // AN ATTEMPT already in flight owns this entry: its own completion re-offers (the trigger's
        // drainWasRefused/workPending handoff), so a wake here would race it for nothing.
        if inFlightAttempts[entry] != nil { return .notWork }
        // STRICT owner coverage is the same authority the serving query and admission use: another
        // entry's unreadable state holds attempts for the WHOLE owner. Unreadable ⇒ UNKNOWN.
        let discovered: [Entry]
        do {
            discovered = try strictOwnerCoverageLocked()
        } catch {
            return .unknown
        }
        guard discovered.contains(entry) else { return .notWork }
        guard let spent = try? attemptCountLocked(for: entry) else {
            // UNCERTAIN count = BACKOFF due. An unreadable attempt count
            // must not hold the upload; admission proceeds and the record is rewritten.
            return .dueWork(0)
        }
        guard admitCountPermits(spent) else {
            // The numeric saturation point: admission refuses, so a boundary is not progress.
            return .notWork
        }
        // The owed delay, read WITHOUT retiring it (retiring stays admission's job).
        let obligationURL = rootDirectory.appendingPathComponent(Self.obligationPrefix + entryName)
        switch readObligationKindLocked(at: obligationURL) {
        case .absent:
            break
        case .unknown:
            // AN UNCERTAIN attempt record never holds an upload. Treat the
            // backoff as DUE: log it, and the next admission rewrites the record. Waiting for a
            // record we cannot read is indistinguishable from waiting forever, and the uploader's
            // worst case is one extra attempt the server refuses.
            FileLog.shared.addMessage(
                "[VoiceSharing] attempt record uncertain entry=\(entryName) backoff=treated-due")
            FileLog.shared.forceFlush()
            return .dueWork(0)
        case .owed(let instant):
            if instant.isNaN {
                FileLog.shared.addMessage(
                    "[VoiceSharing] attempt record unparseable entry=\(entryName) backoff=treated-due")
                FileLog.shared.forceFlush()
                return .dueWork(0)
            }
            return .dueWork(max(0, instant - now))
        }
        let url = rootDirectory.appendingPathComponent(Self.notBeforeName(for: entryName))
        switch Self.statKind(of: url) {
        case .absent:
            // No delay owed: this entry is admissible NOW, which is work, and the pass that arrives
            // here already reported it. Nothing to arm.
            return .notWork
        case .failure:
            return .unknown
        case .present:
            break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
            size.bytes > 0, size.bytes <= Self.maxSettlementRecordBytes,
            let data = try? Data(contentsOf: url),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let stamp = object["notBefore"] as? Double, stamp.isFinite else {
            return .unknown
        }
        return .dueWork(max(0, stamp - now))
    }

    /// What the durable obligation record says about a owed delay.
    enum OwedDelayKind {
        case absent
        case owed(TimeInterval)
        /// Present but unreadable: the delay is UNKNOWN, which is not permission to proceed.
        case unknown
    }

    /// Reads an obligation record WITHOUT retiring it. Mirrors the admission reader's fail-closed
    /// discipline: an unreadable record is unknown, never absent.
    private func readObligationKindLocked(at url: URL) -> OwedDelayKind {
        switch Self.statKind(of: url) {
        case .absent: return .absent
        case .failure: return .unknown
        case .present: break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular, size.bytes > 0,
            size.bytes <= Self.maxSettlementRecordBytes,
            let data = try? Data(contentsOf: url),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let owed = object["notBefore"] as? Double else { return .unknown }
        return .owed(owed)
    }

    /// The seconds until the next retry boundary that a wake could actually ACT on, or `nil` when
    /// there is none.
    ///
    /// — the PROGRESS rule. Only boundaries over entries the next pass can
    /// attempt count. An unreadable root listing, an unreadable owed delay, or an unknown attempt
    /// count answer `nil`: "unknown" must never be reported as `0`, because a zero delay becomes a
    /// zero-sleep Task in the trigger that re-offers itself forever without progress. Unknown
    /// state waits for an ordinary signal (lifecycle event, new publication, or the uploader's own
    /// completion re-offer) instead of polling; those paths already exist.
    ///
    /// Debris is skipped in every direction: an unparseable stamp, a stamp over a purged entry, a
    /// malformed entry name. A DUE boundary over a servable entry reports `0` so the next pass
    /// attempts it — admission re-checks fail-closed on arrival, so an early wake can never spend
    /// an early attempt.
    func secondsUntilNextRetryBoundary() -> TimeInterval? {
        serialQueue.sync { () -> TimeInterval? in
            // OWNER-WIDE holds first: under either hold `admitAttempt`
            // refuses every entry, so no boundary is due work. Checked here as well as in the per-
            // entry prospect so a hold answers `nil` even before the listing is read — the same
            // refusal the drain's admission applies, from the same two flags.
            //
            // READ from storage, exactly as `recoverLocked` derives them: the
            // in-memory flags are only as fresh as the last reconciliation this instance performed,
            // and a marker written by a settling pass must hold THIS instance's wake arithmetic the
            // moment it lands on disk. A discovery FAILURE is a hold, never an absence.
            if intentDiscovery(revocationIntentPath) != .absent { return nil }
            // A RETRY hold may not suppress the wake for work still in the future:
            // returning `nil` for every held entry stopped the wake that would have drained the
            // queue, so an unreadable retry record froze progress indefinitely.
            //
            // BUT A ZERO delay still self-REOFFERS. If the earliest boundary is ALREADY due, an
            // armed wake of 0 fires the trigger immediately and re-arms forever without progress —
            // the exact loop the original control was written against. Under a retry hold the wake
            // is therefore CLAMPED to a positive floor: the queue keeps waking, but cannot spin.
            if revocationHoldLocked { return nil }
            // UNBOUNDED: this decides the next wake, i.e. it is discovery.
            // A bound here let an over-cap root look unreadable and stop the wake arithmetic, which
            // in turn stopped the drain that would have brought the queue back under the cap.
            let listed: [URL]
            do { listed = try listDirectory(rootDirectory, []) } catch { return nil }
            let now = clock().timeIntervalSince1970
            var earliest: TimeInterval?
            for url in listed {
                let recordName = url.lastPathComponent
                guard recordName.hasPrefix(Self.notBeforePrefix) else { continue }
                let entryName = String(recordName.dropFirst(Self.notBeforePrefix.count))
                // an UNREADABLE or malformed record is debris, not live work.
                // Returning 0 here let one orphaned stamp (the simulator has ten) suppress another
                // live entry's future retry indefinitely. Debris is SKIPPED; only live boundaries
                // produce a wake.
                guard UUID(uuidString: entryName) != nil else { continue }
                // AN UNREADABLE or oversized stamp is an unknown delay, not A REASON to skip
                // . Skipping it before reaching the "unknown means due" helper
                // meant an entry whose own delay record is corrupt never got a retry wake at all —
                // the queue-wide gate was fixed but the boundary loop re-imposed it per entry.
                // The prospect helper below already maps unknown to due-now.
                switch fileSizeIfRegularLocked(at: url) {
                case nil:
                    // UNKNOWN size: unreadable now. An unknown delay is due now, so schedule it
                    // rather than letting one corrupt record suppress a real retry.
                    earliest = min(earliest ?? .infinity, Self.retryHoldWakeFloorSeconds)
                    continue
                case let size? where !(size.isRegular && size.bytes > 0
                    && size.bytes <= Self.maxSettlementRecordBytes):
                    earliest = min(earliest ?? .infinity, Self.retryHoldWakeFloorSeconds)
                    continue
                case .some:
                    break
                }
                switch retryWakeProspectLocked(forEntryNamed: entryName, at: now) {
                case .unknown, .notWork:
                    // No wake: unknown state waits for a real signal, and a fact admission refuses
                    // on cannot be changed by waking up.
                    continue
                case .dueWork(let delay):
                    earliest = min(earliest ?? .infinity, delay)
                }
            }
            // READ from storage, exactly as `recoverLocked` derives it: the
            // in-memory flag is only as fresh as the last reconciliation THIS instance performed,
            // and a marker that lands after construction must still govern the wake arithmetic.
            let retryHeld = retryHoldLocked
                || intentDiscovery(rootDirectory.appendingPathComponent(Self.retryHoldIntentName))
                    != .absent
            if let earliest, retryHeld, earliest <= 0 {
                // Due already, and the retry schedule is unsettled: arm the floor instead of 0.
                return Self.retryHoldWakeFloorSeconds
            }
            return earliest
        }
    }

    func secondsUntilNextAgeBoundary() -> TimeInterval? {
        serialQueue.sync {
            let ages = entriesLocked()
                .filter { isCompleteEntryLocked(at: $0) }
                .filter { (try? confirmDurableLocked(directory: entryDirectoryLocked(for: $0))) != nil }
                .compactMap { markerAgeLocked($0) }
                .filter { $0 >= 0 && $0 <= Self.maxEntryAge }
            // The NEAREST expiry is the OLDEST eligible entry (largest age), not the youngest
            // `ages.min` waited for the newest entry's expiry and left the
            // oldest displayed for almost a full extra retention period.
            guard let oldest = ages.max() else { return nil }
            return max(0, Self.maxEntryAge - oldest)
        }
    }

    // MARK: - Change notification

    private var contentObservers: [UUID: () -> Void] = [:]
    private let contentObserverLock = NSLock()

    /// Announces every change to a fact the surface displays (hold, origin, ready count).
    @discardableResult
    func addContentObserver(_ observer: @escaping () -> Void) -> UUID {
        contentObserverLock.lock(); defer { contentObserverLock.unlock() }
        let token = UUID()
        contentObservers[token] = observer
        return token
    }

    func removeContentObserver(_ token: UUID) {
        contentObserverLock.lock(); defer { contentObserverLock.unlock() }
        contentObservers.removeValue(forKey: token)
    }

    private func bumpHoldGenerationForContentChange() {
        let signature = QueueContentSignature(held: revocationHoldLocked,
                                              originUnknown: revocationOriginUnknownLocked,
                                              readyCount: readyEntryCountLocked())
        guard signature != lastQueueSignature else { return }
        lastQueueSignature = signature
        holdGeneration &+= 1
        // Notified OUTSIDE the serial queue's critical section: listeners re-read the queue.
        let observers: [() -> Void]
        contentObserverLock.lock()
        observers = Array(contentObservers.values)
        contentObserverLock.unlock()
        if !observers.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                for observer in observers { observer() }
            }
        }
    }

    private var lastQueueSignature: QueueContentSignature?

    private struct QueueContentSignature: Equatable {
        let held: Bool
        let originUnknown: Bool
        let readyCount: Int
    }

    var currentHoldGeneration: Int { serialQueue.sync { holdGeneration } }

    private func setRevocationHold(_ held: Bool, originUnknown: Bool = false) {
        revocationHoldLocked = held
        revocationOriginUnknownLocked = originUnknown
        bumpHoldGenerationForContentChange()
    }
    /// True when the revocation hold exists because its evidence could not be READ. Reported as
    /// `unknownCoverage`, not `revocationHeld`.
    private var revocationOriginUnknownLocked = false

    private var revocationIntentPath: URL {
        serialQueueSafeRoot.appendingPathComponent(Self.revocationIntentName)
    }

    private var serialQueueSafeRoot: URL { rootDirectory }

    /// Injectable directory listing. Exists so accounting failure is testable: FileManager's
    /// `contentsOfDirectory(at:includingPropertiesForKeys:)` is defined in an extension and cannot
    /// be overridden by a subclass.
    private let listDirectory: (URL, [URLResourceKey]) throws -> [URL]
    /// Bounded listing. Returns at most `maxSweptEntries (for the root) or maxDirectoryEntries (inside an entry)` names along with whether more existed.
    /// so callers refuse on overflow instead of allocating an unbounded array first.
    private let listDirectoryBounded: (URL, [URLResourceKey], Int) throws -> (urls: [URL], overflowed: Bool)
    /// Intent-discovery seam: defaults to the REAL required-stat. Injectable
    /// so a discovery FAILURE is observable in isolation — a real POSIX stat failure on the intent
    /// path is always accompanied by an unreadable root, which would mask the hold's effect.
    private let intentDiscovery: (URL) -> StatKind
    private let backupExcluder: (URL) throws -> Void
    private var recoveryPending = true
    private let serialQueue = DispatchQueue(label: "fm.auris.voicesharing.uploadqueue")

    /// Creates the queue over `rootDirectory` and runs recovery: entries that are not complete
    /// (including abandoned preparation, foreign directories and malformed entries) are removed;
    /// complete ready entries are kept intact.
    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        synchronizer: @escaping (_ path: URL, _ isDirectory: Bool) throws -> Void = VoiceSharingUploadQueue.defaultSynchronizer,
        failureRecordWriter: @escaping (URL, Data) throws -> Void = {
            try $1.write(to: $0, options: .atomic)
        },
        markerReplacer: @escaping (URL, URL) throws -> URL? = {
            try FileManager.default.replaceItemAt($0, withItemAt: $1)
        },
        aggregateLimits: AggregateLimits = .default,
        attemptLimits: AttemptLimits = .default,
        listDirectory: @escaping (URL, [URLResourceKey]) throws -> [URL] = { url, keys in
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        },
        listDirectoryBounded: @escaping (URL, [URLResourceKey], Int) throws
            -> (urls: [URL], overflowed: Bool) = VoiceSharingUploadQueue.defaultBoundedLister
    ,
        intentDiscovery: @escaping (URL) -> StatKind = { VoiceSharingUploadQueue.statKind(of: $0) },
        currentIdentity: (() -> VoiceSharingUploadIdentity?)? = nil,
        backupExcluder: @escaping (URL) throws -> Void = VoiceSharingUploadQueue.defaultBackupExcluder
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.clock = clock
        self.synchronizer = synchronizer
        self.failureRecordWriter = failureRecordWriter
        self.markerReplacer = markerReplacer
        self.aggregateLimits = aggregateLimits
        self.attemptLimits = attemptLimits
        self.listDirectory = listDirectory
        self.listDirectoryBounded = listDirectoryBounded
        self.intentDiscovery = intentDiscovery
        self.currentIdentityLocked = currentIdentity
        self.backupExcluder = backupExcluder
        // Recovery can publish state too, so establish storage policy before touching retained entries.
        serialQueue.sync { _ = try? establishStoragePolicyLocked() }
    }

    private static func defaultBackupExcluder(_ root: URL) throws {
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    /// Root-only and checked before use: a deleted/recreated root cannot inherit cached approval.
    private func establishStoragePolicyLocked() throws {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            var root = URL(fileURLWithPath: rootDirectory.path, isDirectory: true)
            root.removeAllCachedResourceValues()
            if try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
                try backupExcluder(root)
                root.removeAllCachedResourceValues()
                guard try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
                    throw PrepareError.storagePolicyUnavailable
                }
            }
        } catch {
            throw PrepareError.storagePolicyUnavailable
        }
        if recoveryPending {
            recoveryPending = false
            recoverLocked()
        }
    }

    /// Test seam: the REAL bounded listing, so injected wrappers can fail selectively.
    static func testBoundedListing(_ url: URL, _ keys: [URLResourceKey], _ limit: Int) throws -> ([URL], Bool) {
        try VoiceSharingUploadQueue.defaultBoundedLister(url, keys, limit)
    }

    /// Test seam: the REAL synchronizer, so injected wrappers can fail selectively and delegate
    /// the rest to production behaviour.
    static func testSynchronizer(path: URL, isDirectory: Bool) throws {
        try defaultSynchronizer(path: path, isDirectory: isDirectory)
    }

    /// REAL synchronization: stat/open/fsync results are checked and failures THROW — a storage
    /// layer that cannot confirm durability must fail publication, not silently accept it.
    private static func defaultSynchronizer(path: URL, isDirectory: Bool) throws {
        var statBuffer = stat()
        guard stat(path.path, &statBuffer) == 0 else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                          userInfo: [NSFilePathErrorKey: path.path])
        }
        // Directories cannot be opened for writing; fsync them read-only via the descriptor.
        let fd = open(path.path, isDirectory ? O_RDONLY : O_WRONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: Preparation

    /// Writes audio and metadata into a new entry directory, enforcing the finite limits. The
    /// entry is not ready and never appears in `readyEntries` until `finalize` marks it.
    /// A failure after the directory exists removes that directory — failed preparation leaves
    /// nothing behind.
    func prepare(metadata: Data, audio: Data) throws -> Entry {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            // AUTHORITATIVE admission path: a held owner admits nothing. Preflight refusal alone
            // is not enough — callers that never ask for preflight exist.
            guard !revocationHoldLocked else { throw PrepareError.accountingUnavailable }
            let name = UUID().uuidString
            let entryDirectory = rootDirectory.appendingPathComponent(name, isDirectory: true)
            do {
                guard audio.count <= Self.maxEntryAudioBytes else { throw PrepareError.audioTooLarge }
                guard metadata.count <= Self.maxMetadataBytes else { throw PrepareError.metadataTooLarge }
                // ADMISSION counts complete entries on disk. Read from the disk
                // every time, never from a running tally: a tally drifts the moment any write,
                // removal or crash disagrees with it, and the queue then refuses within its limit
                // forever. A count also cannot become "unknown" the way a byte measure can — the
                // whole failure mode this replaces.
                // THE gate needs A REAL count. "Fewer than 32 records on
                // disk" is unsatisfiable when the disk cannot be read, so an uncountable root
                // refuses. This is admission-only and never sticky: the next call re-reads, and
                // succeeds as soon as the listing works.
                guard let count = try? entryCountOnDiskLocked() else {
                    throw PrepareError.accountingUnavailable
                }
                guard count < aggregateLimits.maxRecords else { throw PrepareError.queueFull }
                try fileManager.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
                try audio.write(to: entryDirectory.appendingPathComponent(Self.audioName), options: .atomic)
                try metadata.write(to: entryDirectory.appendingPathComponent(Self.metadataName), options: .atomic)
                // One immutable admission instant for the whole queue lifetime of this entry.
                let createdAt = String(clock().timeIntervalSince1970)
                try Data(createdAt.utf8).write(to: entryDirectory.appendingPathComponent(Self.createdName), options: .atomic)
                // Record the account that owns this entry, so admission can tell "same epoch,
                // different account" apart from a genuine continuation.
                if let readOwner = currentIdentityLocked, let owner = readOwner() {
                    let data = Data(owner.accountScope.utf8)
                    guard data.count <= Self.maxOwnerBytes else { throw PrepareError.metadataTooLarge }
                    let ownerURL = entryDirectory.appendingPathComponent(Self.ownerName)
                    try data.write(to: ownerURL, options: .atomic)
                    // DURABILITY: ownership backs a publication decision, so it must be on stable
                    // storage before the entry can become ready — a marker that outlives a lost
                    // owner file would let recovery admit an unattributed entry.
                    // Failure here is publication-uncertain, not a silently missing owner.
                    do {
                        try synchronizer(ownerURL, false)
                        try synchronizer(entryDirectory, true)
                    } catch {
                        throw PrepareError.publicationUncertain
                    }
                }
                return Entry(root: rootDirectory, name: name)
            } catch {
                let rolledBack = (try? fileManager.removeItem(at: entryDirectory)) != nil
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=prepare-rollback "
                        + "entry=\(name) removed=\(rolledBack)")
                    // FORCE the flush (FileLog buffers 100 entries): a removal line must be on disk
                    // before the process can be terminated, or the diagnosis dies with it.
                    FileLog.shared.forceFlush()
                throw error
            }
        }
    }

    /// Measured, NON-CONSUMING admission check for callers that must refuse before allocating
    /// (the contribution sink encodes its WAV copies only if the budget can carry the worst-case
    /// entry). `prepare` remains the exact authority at write time.
    /// Preflight for the contribution sink, and it answers ONE question: is there room for another
    /// record?. The `forBytes:` parameter is GONE rather than ignored: a size-shaped
    /// argument would advertise a byte bound the queue no longer enforces.
    func hasAdmissionAllowance() -> Bool {
        serialQueue.sync {
            guard (try? establishStoragePolicyLocked()) != nil else { return false }
            // WHICH intent it is decides. A sharing-off / withdrawal intent
            // whose state is UNKNOWN refuses admission, because the COLLECT gate is "sharing is
            // proven on" and an unreadable withdrawal marker proves nothing.
            //
            // A RETRY hold does not refuse admission. It is an
            // internal write-ahead marker — `attempt.pause.intent` — set when a settlement's
            // not-before stamp could not be published, so the retry schedule is unprovable. It is
            // not the sharing-off intent and not a server backoff, so it is not on the allowed
            // admit gate list ("fewer than 32 with audio", count unknown, sharing-off state
            // unknown). A new clip goes on disk and waits like any other; the unprovable schedule
            // is handled where it belongs, per entry, by treating unknown retry state as due now.
            guard !revocationHoldLocked else { return false }
            // AN UNCOUNTABLE root refuses admission. The gate is "fewer than
            // 32 audio records ON DISK", and a count that could not be taken cannot satisfy it. So
            // this refuses — but only this: the refusal is logged with `count_unknown`, it is never
            // sticky (every admission re-reads the disk, so the next segment is admitted the moment
            // the listing reads again), and it touches nothing but new admissions. Drain, upload and
            // delete use the per-entry gates and never consult this.
            do {
                let count = try entryCountOnDiskLocked()
                lastCompleteEntryCountLocked = count
                lastCountWasUnknown = false
                return count < aggregateLimits.maxRecords
            } catch {
                // RECORDED, not just refused: a refusal the operator cannot attribute is the same
                // blind spot as a silent drop.
                lastCompleteEntryCountLocked = nil
                lastCountWasUnknown = true
                logCoverageUnknownOnce(reason: "count_unknown")
                return false
            }
        }
    }

    /// HOW many captures holding audio are on disk, counted fresh.
    ///
    /// A DISQUALIFIED capture still occupies A SLOT *while it still holds audio* (reviewer
    /// 07a7bb51). It is retained precisely because it has not been removed yet, so counting only
    /// servable entries would let a queue of retained failures admit past its limit.
    ///
    /// BUT A DIRECTORY is not A CAPTURE. Counting directories (the first version of this) let 32
    /// empty or metadata-only debris directories refuse a real recording — a wedge built out of
    /// nothing, since no audio existed to drain. The limit is "fewer than 32 audio records on
    /// disk", so the identity counted is the capture ID and the predicate is "holds audio".
    ///
    /// Counting on disk rather than in memory is what keeps the limit honest across restarts and
    /// removals. Throws when the root cannot be listed — the caller decides whether that is a
    /// refusal (prepare) or an admission (the sink's preflight).
    private func entryCountOnDiskLocked() throws -> Int {
        // STRICT, not lenient: `entriesLocked` turns an unreadable root into `[]` so the count
        // would silently read as ZERO — an unreadable queue reported as empty, the one misreading
        // this change must not reintroduce.
        var ids = Set<String>()
        for entry in try entriesStrictLocked() {
            // A DIRECTORY is not A CAPTURE. The rule is "capture IDs still
            // holding audio" (746aa9c2), so an empty or metadata-only directory occupies no slot —
            // counting directories let 32 debris directories refuse a real recording, which is a
            // wedge built out of nothing at all.
            if entryHoldsAudioLocked(entry) { ids.insert(entry.name.uppercased()) }
        }
        // AUDIO residue counts too: a failed delete can leave a capture's audio behind with its
        // directory gone. Same identity space — canonical, so one capture is one slot.
        ids.formUnion(try audioResidueIDsLocked())
        return ids.count
    }

    /// Does this entry directory contain a real audio file? Size is not judged: a corrupt or
    /// empty audio file is still audio the server may want to refuse — the count is about
    /// occupancy, and the server owns the verdict on the bytes.
    private func entryHoldsAudioLocked(_ entry: Entry) -> Bool {
        switch audioPresenceLocked(entry) {
        case .present, .unknown: return true
        case .absent: return false
        }
    }

    /// ABSENT vs UNKNOWN for a capture's audio. `fileExists`-style
    /// predicates collapse a permission fault into "absent", which made the count UNDER-REPORT an
    /// audio file it simply could not stat — an unreadable queue reading as empty, the misreading
    /// this whole audit exists to remove. Unknown is treated as HOLDING audio: it may refuse a new
    /// admission (the count is not provably under 32), and it never affects any other entry.
    private enum AudioPresence { case present, absent, unknown }
    private func audioPresenceLocked(_ entry: Entry) -> AudioPresence {
        switch Self.statKind(of: entryDirectoryLocked(for: entry).appendingPathComponent(Self.audioName))
        {
        case .present: return .present
        case .absent: return .absent
        case .failure: return .unknown
        }
    }

    /// Audio left behind by a failed delete, counted by SUFFIX, not by directory: a trailing entry
    /// that could not be removed keeps its bytes in a `*.audio.wav`-shaped name (or the entry's own
    /// directory). Sidecar-only leftovers (retry stamps, obligations, locks) are not captures — they
    /// hold no audio — and never count. This is why the rule is "capture IDs still
    /// holding audio" rather than "names in the root".
    private func audioResidueIDsLocked() throws -> Set<String> {
        var ids = Set<String>()
        for url in try listDirectory(rootDirectory, []) {
            let name = url.lastPathComponent
            guard name.hasSuffix(Self.audioResidueSuffix),
                  let id = UUID(uuidString: String(name.dropLast(Self.audioResidueSuffix.count)))
            else { continue }
            // Canonical, so a residue file is the SAME slot as its capture's directory rather than
            // a second one (`UUID` parses case-insensitively; duplicates collapse in the set).
            ids.insert(id.uuidString.uppercased())
        }
        return ids
    }

    /// ONE line per distinct cause, so an uncountable root stays attributable without flooding the
    /// log on every capture. Admission still proceeds — the log records why the count was skipped,
    /// it does not gate anything.
    private var lastCoverageUnknownReasonLocked: String?
    private func logCoverageUnknownOnce(reason: String) {
        guard lastCoverageUnknownReasonLocked != reason else { return }
        lastCoverageUnknownReasonLocked = reason
        FileLog.shared.addMessage(
            "[VoiceSharing] queue count-unavailable reason=\(reason) admission=allowed")
        FileLog.shared.forceFlush()
    }

    /// Consent revocation between prepare and finalize: removes an UNREADY entry, releasing its
    /// charge. A ready entry is refused (publication goes through the settlement protocol, never
    /// an unowned delete), a foreign handle is a refusal, and a cleanup FAILURE throws with the
    /// entry left in place — retained, never silently "gone".
    @discardableResult
    func discardUnready(_ entry: Entry) throws -> Bool {
        try serialQueue.sync {
            // Mutation and version commit in ONE critical section: `removeItem` has already
            // returned by the time the bump reads the post-removal state, so there is no window in
            // which the changed content carries the old version.
            defer { bumpHoldGenerationForContentChange() }
            return try discardUnreadyLocked(entry)
        }
    }

    private func discardUnreadyLocked(_ entry: Entry) throws -> Bool {
        guard entry.root == rootDirectory,
            UUID(uuidString: entry.name) != nil,
            !entry.name.contains("/")
        else { throw CocoaError(.fileNoSuchFile) }
        let directory = try validatedEntryDirectoryLocked(entry)
        switch Self.statKind(of: directory.appendingPathComponent(Self.readyMarkerName)) {
        case .present:
            return false
        case .failure:
            throw PrepareError.accountingUnavailable
        case .absent:
            break
        }
        // DIAGNOSTIC (content-free): an UNREADY entry is being discarded here. Caller-aggregate
        // counts alone leave these entries unexplained.
        FileLog.shared.addMessage(
            "[VoiceSharing] queue removal reason=discard-unready entry=\(entry.name) starting")
        FileLog.shared.forceFlush()
        do {
            try fileManager.removeItem(at: directory)
            FileLog.shared.addMessage(
                "[VoiceSharing] queue removal reason=discard-unready entry=\(entry.name) removed=true")
            FileLog.shared.forceFlush()
        } catch {
            // Cleanup failure: the entry REMAINS (charged, unready). Never collapse into gone.
            FileLog.shared.addMessage(
                "[VoiceSharing] queue removal reason=discard-unready entry=\(entry.name) removed=false — retained")
            FileLog.shared.forceFlush()
            throw PrepareError.accountingUnavailable
        }
        return true
    }

    /// Consent revocation (withdrawal, sign-out, switch-off, lease loss): removes every entry —
    /// ready, unready or disqualified — together with its root-level bookkeeping (settlement
    /// records). The stable lock pool and the root itself are not removed. In-memory attempt state
    /// is cleared under the serial queue. Removal failures leave the offending entry in place
    /// (still charged) and are counted in the result; they never abort the whole purge.
    /// Consent revocation purge — FAIL-EXPLICIT, bounded, durable:
    /// * Bounded listing with explicit overflow: an unbounded or collapsed listing failure
    /// REFUSES the purge (`nil` result) instead of masquerading as "nothing to remove".
    /// * A settlement record is removed only after its entry's removal SUCCEEDED — evidence
    /// must never outlive-or-orphan wrongly: entry first, then its settlement proof.
    /// * An entry whose removal FAILS is DISQUALIFIED in place (`publication.failed` disposal
    /// intent): it can never serve after restart, and it stays charged.
    /// * The root directory is synchronized after the removals, so a crash cannot resurrect a
    /// purged recording from a stale directory entry.
    enum PurgeOutcome: Equatable {
        /// Every retained entry was removed or durably disqualified, and every barrier confirmed.
        /// `retained` counts survivors that are KNOWN-disqualified.
        case reconciled(removed: Int, retained: Int)
        /// A removal or disqualification could not be completed AND confirmed durable. The
        /// owner-wide hold is SET: nothing serves or admits until a later purge fully reconciles.
        case held(removed: Int, retained: Int)
        /// The root could not be listed (I/O failure or overflow past the bound). Nothing was
        /// attempted; the hold keeps whatever value it already had.
        case refused
    }

    /// Owner-wide revocation of every retained contribution. Semantics:
    ///
    /// - EXPLICIT about what could not be proven: `.refused` when the root cannot be listed at all
    /// or overflows (never collapsed into "nothing to remove"); `.held` when a durable
    /// disqualification or barrier could not be confirmed.
    /// - Disqualification is a TWO-STEP durable write: marker bytes are synced as a FILE (a
    /// directory barrier alone does not persist a file's bytes), then the entry directory, then
    /// the root. Any failure clears the "disqualified" claim — an unmarked survivor is reported
    /// as retained, never as disqualified.
    /// - Any unreconciled step sets the owner-wide hold; only a fully reconciled purge clears it.
    @discardableResult
    func purgeAll() -> PurgeOutcome {
        serialQueue.sync { purgeLocked() }
    }

    private func purgeLocked() -> PurgeOutcome {
        reconciledRemovalLocked(
            targets: nil, intentPath: revocationIntentPath,
            removalReason: "consent-revocation-purge",
            setHold: { setRevocationHold($0, originUnknown: $1) })
    }

    /// THE shared reconciled removal machinery: durable intent before
    /// any mutation, bounded listing, mark-then-remove, survivor re-disqualification, root
    /// barrier, and intent retirement only after full reconcile. The owner-wide consent purge
    /// runs it unbounded (targets nil, revocation intent, owner-wide hold); a refused entry
    /// runs it BOUNDED to its name (per-entry deletion intent, per-entry hold). The consent
    /// path's observable behavior is unchanged by this refactor.
    /// `setHold(false)` may only be reached when every barrier reconciled; retirement failures
    /// re-hold before the in-memory hold clears.
    private func reconciledRemovalLocked(
        targets: Set<String>?, intentPath: URL, removalReason: String,
        setHold: (_ held: Bool, _ originUnknown: Bool) -> Void
    ) -> PurgeOutcome {
        // DURABLE intent before any mutation. If this cannot be written and
        // synced, the purge must not start: a partial revocation with no on-disk record is exactly
        // the state a fresh queue would mistake for "nothing happened". The memory hold is set
        // regardless, so even an unwritable intent refuses serving for this process.
        do {
            try failureRecordWriter(intentPath, Data([0x01]))
            try synchronizer(intentPath, false)
            try synchronizer(rootDirectory, true)
        } catch {
            setHold(true, false) // KNOWN: we could not even record the intent
            return .refused
        }
        setHold(true, false) // KNOWN: the intent is on disk
        let listing: [URL]
        do {
            // UNBOUNDED: proving revocation means seeing every entry.
            // A bound turned "the queue is large" into "revocation cannot be proven", refusing the
            // very wake that would drain it.
            listing = try listDirectory(rootDirectory, [.isDirectoryKey])
        } catch {
            return .refused
        }
        var removed = 0
        var retained = 0
        var reconciled = true
        for item in listing {
            let name = item.lastPathComponent
            guard UUID(uuidString: name) != nil || Self.parseSettlementName(name) != nil else {
                continue
            }
            // BOUNDED targets (reviewer on the consent scope): a scoped purge touches only the
            // named entries and their settlement evidence — never the neighbours.
            if let targets, !targets.contains(name),
                !targets.contains(Self.parseSettlementName(name) ?? "") {
                continue
            }
            if let settlementEntry = Self.parseSettlementName(name) {
                // Settlement evidence: removed only when its entry is already gone; one orphaned
                // by a FAILED entry removal survives as evidence of that entry's disposition.
                if listing.contains(where: { $0.lastPathComponent == settlementEntry }) {
                    reconciled = false
                    continue
                }
            }
            // MARK-THEN-REMOVE: an entry is DISQUALIFIED before any deletion attempt, so a
            // partially-failing recursive removal cannot leave a half-damaged entry that still
            // qualifies.
            if UUID(uuidString: name) != nil {
                guard disqualifyLocked(item) else {
                    // Cannot prove this entry will never serve after restart: leave it ALONE (no
                    // deletion, no "disqualified" claim) and hold the owner.
                    reconciled = false
                    retained += 1
                    continue
                }
            }
            do {
                // DIAGNOSTIC (content-free): purge removes this entry. Logged per-entry — an
                // aggregate count alone cannot attribute a named entry's removal.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=\(removalReason) "
                        + "entry=\(name) starting")
                FileLog.shared.forceFlush()
                try fileManager.removeItem(at: item)
                removed += 1
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=\(removalReason) "
                        + "entry=\(name) removed=true")
                FileLog.shared.forceFlush()
            } catch {
                retained += 1
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=\(removalReason) "
                        + "entry=\(name) removed=false — retained")
                FileLog.shared.forceFlush()
                // A RECURSIVE removal can delete children (including publication.failed) before
                // failing on another child, so the marker written above is not proof it survived.
                // Re-establish durable disqualification on the SURVIVOR, or hold the owner
                // . Nothing here may assume the earlier claim still holds.
                if UUID(uuidString: name) != nil, !survivorIsDurablyDisqualifiedLocked(item) {
                    reconciled = false
                }
            }
        }
        // Root barrier: the listing must reflect the removals. Failure means on-disk truth is
        // unknown, so the hold cannot be released.
        do { try synchronizer(rootDirectory, true) } catch { reconciled = false }
        if let targets {
            let targetEntries = Set(inFlightAttempts.keys.filter { targets.contains($0.name) })
            inFlightAttempts = inFlightAttempts.filter { !targetEntries.contains($0.key) }
            uncertainEntriesLocked.subtract(targetEntries)
        } else {
            inFlightAttempts.removeAll()
            uncertainEntriesLocked.removeAll()
        }
        // The hold may be released only when every barrier reconciled, and the durable intent must
        // be removed before the in-memory hold is cleared — otherwise a crash between the two
        // leaves a queue that serves while storage still records an unfinished revocation.
        if reconciled {
            do {
                try fileManager.removeItem(at: intentPath)
                try synchronizer(rootDirectory, true)
                // The origin must be re-derived at every transition: leaving it
                // set would mislabel a LATER, genuine failed revocation as unknown coverage.
                setHold(false, false)
            } catch {
                // Intent could not be retired: stay held. A fresh instance would re-derive it.
                setHold(true, false) // KNOWN: the intent is still on disk
                reconciled = false
            }
        } else {
            setHold(true, false) // KNOWN: barriers failed to reconcile
        }
        return reconciled ? .reconciled(removed: removed, retained: retained)
                          : .held(removed: removed, retained: retained)
    }

    /// Re-establishes (and proves) durable disqualification of a SURVIVOR after a failed removal.
    /// Returns true only when the marker is present AND its bytes are confirmed synced. Rewriting
    /// is safe: the marker's content carries no information beyond "revoked".
    private func survivorIsDurablyDisqualifiedLocked(_ entry: URL) -> Bool {
        disqualifyLocked(entry)
    }

    /// WHY an entry is disqualified, recorded IN the marker (spec, old-cap resume).
    ///
    /// The marker used to carry a single `0x01` — "revoked", with no cause. That made every
    /// disqualification equal at purge time, so an entry quarantined by the OLD attempt cap was
    /// deleted on update exactly like one the server had permanently rejected. The distinction is
    /// not cosmetic: a cap quarantine is a CLIENT bookkeeping accident and the recording is still
    /// good, while a decided rejection is the server refusing that specific recording forever.
    enum DisqualificationCause: String {
        /// The server decided this RECORDING is unacceptable (contract/record rejection). Terminal.
        case decidedRejection
        /// Removal/disposal intents (opt-out, refusal purge, owner scope) — deliberately deleted.
        case removal
        /// A marker whose content says nothing (the legacy bare `0x01`, or an unparseable
        /// payload). It records no decision by anyone, so it never authorises deleting a
        /// recording. Deliberate intents write a real cause and are never legacy.
        case legacyUnknown

        /// Only a decided rejection or a DELIBERATE removal intent authorises deletion. An
        /// unknown cause must be resurrected.
        var authorisesDeletion: Bool { self == .decidedRejection || self == .removal }
    }

    /// Durably disqualifies one entry: marker bytes synced as a FILE, then the entry directory.
    /// Returns FALSE if any step fails — the caller must then make no disqualification claim and
    /// must not delete the entry.
    private func disqualifyLocked(_ item: URL,
                                  cause: DisqualificationCause = .removal) -> Bool {
        let intent = item.appendingPathComponent(Self.failedName)
        do {
            // THE cause is the marker'S CONTENT. Legacy markers are a single `0x01`; they are read
            // as `.legacyUnknown` (the conservative reading — an unknown cause never authorises
            // deletion of a recording someone might still want), see `disqualificationCauseLocked`.
            try failureRecordWriter(intent, Data(cause.rawValue.utf8))
            try synchronizer(intent, false)
            try synchronizer(item, true)
            return true
        } catch {
            return false
        }
    }

    /// Reads the recorded disqualification cause. A LEGACY marker (`0x01`, or anything unparseable
    /// as a cause name) reads as `.legacyUnknown`: the old build never recorded a reason, so an
    /// unknown cause must never authorise deleting a recording. This is DISTINCT from `.removal`:
    /// a deliberate removal intent writes its cause and DOES authorise deletion; a marker that
    /// says nothing does not. `nil` means NO marker at all.
    private func disqualificationCauseLocked(at directory: URL) -> DisqualificationCause? {
        let intent = directory.appendingPathComponent(Self.failedName)
        guard Self.statKind(of: intent) == .present else { return nil }
        guard let data = try? Data(contentsOf: intent) else { return .legacyUnknown }
        // A legacy single byte, or any unrecognised payload, is not evidence of a decision.
        if data == Data([0x01]) { return .legacyUnknown }
        guard let text = String(data: data, encoding: .utf8),
            let parsed = DisqualificationCause(rawValue: text)
        else { return .legacyUnknown }
        return parsed
    }

    /// Atomically marks a prepared entry ready after its bytes are durable: audio and metadata are
    /// synchronized, then the entry directory is synchronized, and only then is the marker written
    /// (atomic replace) and synchronized. A crash before the marker leaves an unready entry that
    /// recovery removes.
    func finalize(_ entry: Entry) throws {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            defer { bumpHoldGenerationForContentChange() }
            let directory = try validatedEntryDirectoryLocked(entry)
            // Publication must not launder an over-age preparation into a fresh lifetime: the
            // creation instant is immutable, so an entry past the bound refuses publication.
            if let createdAt = creationInstantLocked(in: directory),
                clock().timeIntervalSince(createdAt) > Self.maxEntryAge {
                throw PrepareError.expired
            }
            let marker = directory.appendingPathComponent(Self.readyMarkerName)
            let stage = directory.appendingPathComponent(Self.stageName)
            // The lifecycle stage is recorded before publication begins, so that after any crash the
            // presence of this file means "publication was attempted and may not have completed".
            // Written with the plain (non-atomic) route so a crash HERE leaves nothing rather than a
            // half-written discriminator: an entry with no stage file and no marker never published.
            // Deliberately not routed through the injectable failure-record seam: this write is part
            // of the publication protocol, and letting failure injection suppress it would remove the
            // discriminator that the restart guarantee depends on.
            if !fileManager.fileExists(atPath: stage.path) {
                try Data([0x01]).write(to: stage, options: .atomic)
                // No post-write re-check is needed: admission reserved `protocolOverheadBytes`,
                // which strictly bounds every file this queue writes for an entry beyond the
                // caller's blobs (created.at ≈ 18 B, stage/marker/failure 1 B each). A re-check
                // that can never fire would be untested dead code, not a defence — so the
                // reservation is kept honest by `test_exactLimitAdmissionAccountsForProtocolOverhead`
                // measuring the real on-disk footprint instead.
            }
            // PUBLICATION protocol — one commit point, and the order is chosen so that the commit
            // point is the LAST fallible action.
            //
            // Spec (voice-recording-uploads.md): durability of the immutable bytes is established
            // before readiness; readiness is published atomically and its directory synchronization
            // confirmed before durable success is reported. A failure known to precede the ready
            // transition is uncommitted. A ready transition that may have occurred but whose final
            // synchronization cannot be confirmed is UNCERTAIN, not success and not rejection.
            //
            // The ordering exists because every design that clears a discriminator after publishing
            // readiness leaves a window: removing that discriminator can succeed and its sync can
            // fail, returning the entry to "marker with no disqualifier". The stage file is therefore
            // cleared before the marker is published, and nothing fallible follows publication.
            try synchronizer(directory.appendingPathComponent(Self.audioName), false)
            try synchronizer(directory.appendingPathComponent(Self.metadataName), false)
            // created.at is recovery AUTHORITY (immutable age basis), so its contents must be durable
            // before readiness too; otherwise a restart can lose the very bound the entry relies on.
            try synchronizer(directory.appendingPathComponent(Self.createdName), false)
            try synchronizer(directory, true)

            // Clear the stage while the marker does not yet exist: the entry is then a plain
            // prepared entry, and a failure here is unambiguously uncommitted.
            try fileManager.removeItem(at: stage)
            try synchronizer(directory, true)

            let temporary = directory.appendingPathComponent("\(Self.readyMarkerName).tmp-\(UUID().uuidString)")
            try Data([0x01]).write(to: temporary, options: .atomic)
            do {
                _ = try markerReplacer(marker, temporary)
            } catch {
                // The replacement installs the marker and THEN throws (or throws after installing).
                // Whatever the reason, a marker may now exist, so this is a possible transition and
                // must not be classified as definitely-uncommitted.
                uncertainEntriesLocked.insert(entry)
                throw PrepareError.publicationUncertain
            }

            // THE commit point. The marker now exists. The three synchronizations below are
            // CONFIRMATION work, and they are fallible: this is why the outcome is tri-state rather
            // than an absence of fallible steps. If confirmation cannot be completed we do not know
            // whether a later process will see the marker. That is `uncertain`, and it must be
            // REPORTED as such — never silently downgraded to success or to "definitely uncommitted".
            do {
                try synchronizer(marker, false)
                try synchronizer(directory, true)
                try synchronizer(rootDirectory, true)
            } catch {
                // Mark it uncertain IN PROCESS only as a hint for this instance; it is deliberately
                // not proof of non-publication and is never consulted by reconciliation. A fresh
                // instance sees the same durable state and reaches the same verdict.
                uncertainEntriesLocked.insert(entry)
                throw PrepareError.publicationUncertain
            }
        }
    }

    /// Enumerates at most `limit` names and reports whether the directory holds more. Stops pulling
    /// from the enumerator at the cap, so allocation is bounded by `limit` rather than by directory
    /// size.
    /// A single step of enumeration: either a URL, or the error that stopped iteration.
    enum EnumerationStep {
        case url(URL)
        case failure(Error)
    }

    /// Injectable enumeration source. `nil` means "use the real FileManager enumerator". Exists so a
    /// MID-ENUMERATION error can be tested on this runner, where filesystem permissions do not
    /// reliably produce one.
    static let defaultEnumeratorSource: ((URL, [URLResourceKey]) -> AnySequence<EnumerationStep>)? = nil

    static let defaultBoundedLister: (URL, [URLResourceKey], Int) throws -> (urls: [URL], overflowed: Bool) =
        VoiceSharingUploadQueue.boundedLister(with: nil)

    /// Builds a bounded lister over an optional injected enumeration source. Shared by the default
    /// lister and by tests that need a mid-iteration failure.
    static func boundedLister(
        with source: ((URL, [URLResourceKey]) -> AnySequence<EnumerationStep>)?
    ) -> (URL, [URLResourceKey], Int) throws -> (urls: [URL], overflowed: Bool) {
        { directory, keys, limit in
            // ONE path: the injected source and the real enumerator both produce
            // `EnumerationStep` sequences that are processed by `boundedListing`.
            let steps = source?(directory, keys)
                ?? VoiceSharingUploadQueue.realSteps(directory, keys)
            return try boundedListing(over: steps, limit: limit)
        }
    }

    /// The production path over a step sequence: stops at the cap, and THROWS if iteration ended on
    /// an error rather than on the cap. A truncated listing is never reported as complete.
    static func boundedListing(
        over steps: AnySequence<EnumerationStep>, limit: Int
    ) throws -> (urls: [URL], overflowed: Bool) {
        var urls: [URL] = []
        for step in steps {
            switch step {
            case .url(let url):
                if urls.count >= limit { return (urls, true) }
                urls.append(url)
            case .failure(let error):
                throw error
            }
        }
        return (urls, false)
    }

    /// Adapts the REAL FileManager enumerator into the same `EnumerationStep` sequence that the
    /// injected control produces, so there is exactly ONE step-processing path. Errors from the
    /// enumerator are yielded as `.failure` rather than captured in a side channel: a control that
    /// supplies `.failure` therefore exercises the identical code that a real enumeration error
    /// takes, which a parallel implementation could not guarantee.
    static func realSteps(
        _ directory: URL, _ keys: [URLResourceKey]
    ) -> AnySequence<EnumerationStep> {
        // FileManager reports enumeration errors to the error HANDLER; `nextObject` never yields an
        // Error object. So the handler must CAPTURE the error and the iterator must surface it as
        // `.failure` — discarding it here (as an earlier version did) silently loses unread storage.
        final class PendingError { var error: Error? }
        let pending = PendingError()
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                // Capture, then stop: continuing would keep skipping storage we could not read.
                pending.error = error
                return false
            })
        else {
            return AnySequence([.failure(CocoaError(.fileReadUnknown))])
        }
        return AnySequence { () -> AnyIterator<EnumerationStep> in
            AnyIterator {
                // Checked IMMEDIATELY after the read that may have triggered it, and before any URL
                // is yielded, so an error can never be reordered behind a later result.
                let object = enumerator.nextObject()
                if let error = pending.error {
                    pending.error = nil
                    return .failure(error)
                }
                guard let object else { return nil }
                // A non-URL element is not a name we can account for; refuse rather than substitute.
                guard let url = object as? URL else {
                    return .failure(CocoaError(.fileReadUnknown))
                }
                return .url(url)
            }
        }
    }


    // MARK: Attempt ownership

    /// Number of attempts already started for this entry. Read from durable state so the count
    /// survives process restarts.
    func attemptCount(for entry: Entry) throws -> Int {
        try serialQueue.sync { try attemptCountLocked(for: entry) }
    }

    /// The lease THIS process holds for the entry, if any. `beginAttempt` acquires it internally;
    /// a caller that must report a result (the uploader) needs the same token, and reading it back
    /// is strictly narrower than exposing lease acquisition itself.
    func currentLease(for entry: Entry) throws -> AttemptLease? {
        try serialQueue.sync {
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }
            return inFlightAttempts[entry]
        }
    }

    /// Whether this process currently owns a live request for the entry.
    func isAttemptInFlight(_ entry: Entry) -> Bool {
        serialQueue.sync { inFlightAttempts[entry] != nil }
    }

    /// Whether the entry has attempts remaining.
    func isAttemptable(_ entry: Entry) throws -> Bool {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            return try isAttemptableLocked(entry)
        }
    }

    /// The admitted attempt: the lease AND the attempt number, returned TOGETHER. Reviewer
    /// 7dd1e357: three separate reads (beginAttempt → currentLease → attemptNumber) let a reclaim
    /// land in between, so the uploader could settle using a SUCCESSOR's lease. One transaction
    /// produces one immutable token, and only that token may settle.
    struct AdmittedAttempt {
        let lease: AttemptLease
        let attemptNumber: Int
        /// The identity this attempt was admitted under (reviewer/spec: attempt-lifetime fencing).
        /// Nil for an UNBOUND queue, meaning "no identity authority in this process" — the caller
        /// then has nothing to fence against, exactly as before. A bound queue always supplies it.
        let identity: VoiceSharingUploadIdentity?
    }

    /// Admits one attempt atomically. Returns nil when the entry is owned elsewhere or exhausted.
    ///
    /// Optional `deferUntil` is the ENFORCED not-before discipline: a caller
    /// that must wait for a policy delay persists that instant here, so any owner — including a
    /// fresh one after restart or reclaim — is refused until it passes. An advisory delay returned
    /// to a caller is not enforcement; this is.
    func admitAttempt(_ entry: Entry) throws -> AdmittedAttempt? {
        try serialQueue.sync { () -> AdmittedAttempt? in
            // every refusal below names its own fixed reason. Without this, one
            // generic "admission-refused" made distinct conditions indistinguishable in the log
            // and forced inference from source instead of reading what actually happened. Fixed
            // vocabulary only: no values from disk, no counts that identify content.
            func refuse(_ reason: String) -> AdmittedAttempt? {
                FileLog.shared.addMessage(
                    "[VoiceSharing] admit refusal entry=\(entry.name) reason=\(reason)")
                FileLog.shared.forceFlush()
                return nil
            }
            guard !revocationHoldLocked else {
                FileLog.shared.addMessage("[VoiceSharing] admit refusal reason=revocation-hold")
                FileLog.shared.forceFlush()
                throw PrepareError.accountingUnavailable
            }
            // AN UNKNOWN retry-STATE fact is not A GATE on an attempt (reviewer
            // 066e2a70 item 2). This threw, and it is the path the UPLOADER actually calls, so the
            // gate survived here even after beginAttempt was corrected. Unknown retry bookkeeping
            // means DUE now; it may only refuse new admissions.
            if retryHoldLocked {
                FileLog.shared.addMessage(
                    "[VoiceSharing] admit entry=\(entry.name) reason=retry-state-unknown disposition=due-now")
                FileLog.shared.forceFlush()
            }
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }
            try refuseIfNotYetDueLocked(entry)
                // (the not-yet-due hold logs its own reason inside)
            guard inFlightAttempts[entry] == nil else { return refuse("already-in-flight") }
            let discovered: [Entry]
            do {
                discovered = try strictOwnerCoverageLocked()
            } catch {
                FileLog.shared.addMessage("[VoiceSharing] admit refusal reason=coverage-unavailable")
                FileLog.shared.forceFlush()
                throw error
            }
            guard discovered.contains(entry) else { return refuse("not-in-owner-coverage") }
            // ORDINARY account ownership: an entry belongs to the account that
            // created it, and only that account may send it. The enrollment EPOCH in the entry's
            // durable metadata is PROVENANCE stamped on the record, never an admission gate: a
            // re-enrollment moves the server's opaque epoch without invalidating audio this
            // account already captured, so a surviving entry is not refused merely because the
            // epoch moved.
            // Resolve the entry's own binding ONCE; it is what this attempt is fenced to for its
            // whole lifetime (no second parse that could drift).
            var admittedIdentity: VoiceSharingUploadIdentity?
            if let readIdentity = currentIdentityLocked {
                // A BOUND queue refuses when an account cannot be established at all.
                guard let live = readIdentity() else { return refuse("live-identity-unavailable") }
                // A LOCAL binding is not an admission gate ( rulings 2 + reviewer
                // 307d0bde item 1). A capture whose metadata is unreadable, malformed or
                // digest-mismatched still holds audio the server has never seen; refusing it here
                // is the hold the ruling forbids. The binding supplies only the record's OWN
                // provenance (its enrollment epoch) and a diagnostic capture id, so when it is
                // unavailable the attempt proceeds with the account scope alone and the server owns
                // the verdict. Only a MISSING capture (no audio) is refused.
                guard entryHoldsAudioLocked(entry) else { return refuse("capture-audio-absent") }
                let bound = try? boundIdentityLocked(of: entry)
                // ABSENT owner means this entry predates sign-in and belongs to no account yet:
                // it cannot be attributed, so it is refused (never inherited by the current account).
                guard case .present(let capturedScope) = try ownerScopeLocked(for: entry) else {
                    return refuse("entry-owner-absent")
                }
                guard capturedScope == live.accountScope else {
                    return refuse("account-mismatch")
                }
                // THE epoch is provenance, AND the record cannot supply it here. The account is
                // what binds an attempt; the epoch only travels with the record.
                // For an entry the client cannot bind there is no recorded epoch to read, and the
                // deployed schema refuses an empty one — so the attempt carries the LIVE epoch,
                // which is truthful provenance: this send happened under this enrollment. Without
                // a live epoch the identity cannot be formed and the server could not accept the
                // record anyway, so the refusal is honest rather than a fabricated value.
                let epoch = bound?.enrollmentEpoch ?? live.enrollmentEpoch
                guard !epoch.isEmpty else { return refuse("enrollment-epoch-unavailable") }
                admittedIdentity = VoiceSharingUploadIdentity(
                    accountScope: capturedScope, enrollmentEpoch: epoch)
            }
            guard let lease = try acquireLeaseLocked(for: entry) else {
                return refuse("lease-held-or-unavailable")
            }
            do {
                guard try isAttemptableLocked(entry) else {
                    // GONE with the cap: there is no exhaustion path left to this
                    // branch — no count refuses an entry. It stays as the fail-closed guard for a
                    // CORRUPT stored count, which is the only way `isAttemptableLocked` can now
                    // return false for a complete, ready entry.
                    // The removal is best-effort here — a failure leaves the entry
                    // visible-but-unservable via the limit itself.
                    let complete = isCompleteEntryLocked(at: entry)
                    if complete {
                        let marked = (try? validatedEntryDirectoryLocked(entry))
                            .map { disqualifyLocked($0, cause: .decidedRejection) } ?? false
                        // DIAGNOSTIC (content-free): this is the only admission path that
                        // quarantines. Without it an entry can stop serving with no trace of why.
                        FileLog.shared.addMessage(
                            "[VoiceSharing] queue quarantine reason=attempts-exhausted "
                                + "entry=\(entry.name) marked=\(marked)")
                            // FORCE the flush (FileLog buffers 100 entries): a removal line must be on disk
                            // before the process can be terminated, or the diagnosis dies with it.
                            FileLog.shared.forceFlush()
                    }
                    releaseLeaseLocked(for: entry, owner: lease)
                    // isAttemptable false ALSO covers incomplete/unbound entries:
                    // the completeness branch above is the discriminator, so the refusal reason
                    // must follow it, not assume exhaustion.
                    // Reuse the Boolean captured ONCE above: a second read after
                    // disqualification could observe the mutated state and mislabel exhaustion.
                    return refuse(complete ? "attempts-exhausted" : "entry-not-attemptable")
                }
            } catch {
                releaseLeaseLocked(for: entry, owner: lease)
                throw error
            }
            // The attempt is CONSUMED here — the same transaction that grants the lease — and the
            // resulting number is what the caller settles with. Reading either separately would
            // reintroduce the window identified.
            do {
                try recordAttemptLocked(entry)
            } catch {
                // A DIAGNOSTIC count-WRITE failure must not stop the upload ( ruling,
                // item 2). The count exists to space retries and to report; a
                // disk that cannot be written is exactly when an upload matters most. Keep the
                // count in memory, log it, and let the attempt proceed — the lease stays held.
                attemptCountMemoryOverride[entry] = (attemptCountMemoryOverride[entry] ?? 0) + 1
                FileLog.shared.addMessage(
                    "[VoiceSharing] attempt count write failed entry=\(entry.name) "
                        + "reason=\(type(of: error)) disposition=memory-only attempt-proceeds")
                FileLog.shared.forceFlush()
            }
            // INVARIANT: any throwing admission step after the lease is acquired must release it
            // before rethrowing. This count read is such a step — it runs outside the cleanup
            // catches above. Disclosed limitation: no fault control reaches it (the injected-fault
            // attempts either landed before the read or desynchronised the record), so this is
            // inspection-justified consistency, not a demonstrated fix.
            let count: Int
            do {
                count = try attemptCountLocked(for: entry)
            } catch {
                releaseLeaseLocked(for: entry, owner: lease)
                throw error
            }
            inFlightAttempts[entry] = lease
            return AdmittedAttempt(lease: lease, attemptNumber: count, identity: admittedIdentity)
        }
    }

    /// Persists a not-before instant for the entry (survives restart, applies to every owner).
    /// Durable retry-hold: engaged when a not-before barrier cannot be published. Written and
    /// synced before the error propagates, so a fresh instance re-derives the hold from disk
    /// instead of resuming an unbounded retry.
    static let retryHoldIntentName = "attempt.pause.intent"
    /// The EXACT pending retry obligation: entry identity AND
    /// the original boundary, persisted before its owner is released. A scan of surviving stamps
    /// cannot prove a failed stamp never existed — this record is what proves one did. Written
    /// per entry as `attempt.obligation.<entryName>`.
    static let obligationPrefix = "attempt.obligation."
    private var retryHoldLocked = false

    /// WRITE-AHEAD: the pause intent is durably established before the
    /// boundary publication is attempted, so a boundary failure can never leave "released lease,
    /// no durable statement". A failed intent write engages the memory hold AND throws — it is
    /// never swallowed into a best-effort claim.
    private func engageRetryHoldLocked() throws {
        retryHoldLocked = true
        let url = rootDirectory.appendingPathComponent(Self.retryHoldIntentName)
        let data = Data([0x01])
        do {
            try failureRecordWriter(url, data)
            try synchronizer(url, false)
            try synchronizer(rootDirectory, true)
        } catch {
            // The memory hold stands even though the durable statement could not land; the
            // uncertainty propagates rather than pretending the hold is durable.
            throw PrepareError.publicationUncertain
        }
    }

    /// Persists the per-entry retry obligation: `notBefore` (the ORIGINAL server minimum is
    /// already inside it — computed once by the policy) is durable before the owner can release.
    private func writeObligationLocked(_ boundary: Date, for entry: Entry) throws {
        let url = rootDirectory.appendingPathComponent(Self.obligationPrefix + entry.name)
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["entry": entry.name,
                             "notBefore": boundary.timeIntervalSince1970],
            options: [.sortedKeys]) else {
            throw PrepareError.accountingUnavailable
        }
        try failureRecordWriter(url, data)
        try synchronizer(url, false)
        try synchronizer(rootDirectory, true)
    }

    /// Bounded required-read of an obligation record. Unknown/oversized/malformed is UNKNOWN
    /// (which holds) — it is never treated as absence.
    private func readObligationLocked(_ entry: Entry) -> Double? {
        let url = rootDirectory.appendingPathComponent(Self.obligationPrefix + entry.name)
        switch Self.statKind(of: url) {
        case .absent: return nil
        case .failure: return .nan // unknown ⇒ caller holds
        case .present: break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
            size.bytes > 0, size.bytes <= Self.maxSettlementRecordBytes,
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stamp = object["notBefore"] as? Double, stamp.isFinite,
            // IDENTITY: the stored entry must name THIS file's entry.
            let namedEntry = object["entry"] as? String,
            namedEntry == entry.name
        else { return .nan }
        return stamp
    }

    /// BOUNDED reconciliation: a fresh retry-held queue can
    /// never start a retry (admission refuses), so success-only clearing would deadlock. This path
    /// lifts the hold only after required state is re-confirmed: the intent is required-stat'd,
    /// every surviving stamp is bounded-parsed, and the removal is barriered. any uncertainty
    /// keeps the hold and reports it; nothing here trusts memory.
    @discardableResult
    func reconcileRetryHold() -> Bool {
        serialQueue.sync { () -> Bool in
            // EXPLICIT three-WAY: unknown intent state RETAINS the hold —
            // only proven absence can lift it, never an unreadable root.
            switch intentDiscovery(rootDirectory.appendingPathComponent(Self.retryHoldIntentName)) {
            case .failure:
                retryHoldLocked = true
                return false
            case .absent:
                retryHoldLocked = false
                return true
            case .present:
                break
            }
            // Every surviving stamp must be bounded-parseable and well-named, otherwise the
            // boundary state is unprovable and the hold stands.
            // UNBOUNDED. An over-cap root is exactly when the retry
            // boundary matters most, so it must not be the thing that makes it unprovable.
            let listed: [URL]
            do { listed = try listDirectory(rootDirectory, []) } catch {
                retryHoldLocked = true
                return false
            }
            // Obligations are proved too: a scanned-stamp walk cannot prove
            // a failed stamp never existed, so reconciliation checks the pending-obligation
            // records — an unparseable one keeps the hold.
            for url in listed
            where url.lastPathComponent.hasPrefix(Self.obligationPrefix) {
                guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
                    size.bytes > 0, size.bytes <= Self.maxSettlementRecordBytes,
                    let data = try? Data(contentsOf: url),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    object["notBefore"] is Double,
                    let entryName = object["entry"] as? String,
                    UUID(uuidString: entryName) != nil
                else {
                    retryHoldLocked = true
                    return false
                }
            }
            for url in listed where url.lastPathComponent.hasPrefix(Self.notBeforePrefix) {
                let name = url.lastPathComponent
                guard UUID(uuidString: String(name.dropFirst(Self.notBeforePrefix.count))) != nil,
                    let size = fileSizeIfRegularLocked(at: url), size.isRegular,
                    size.bytes > 0, size.bytes <= Self.maxSettlementRecordBytes,
                    (try? Data(contentsOf: url)) != nil,
                    ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url)))
                        as? [String: Any])?["notBefore"] is Double
                else {
                    retryHoldLocked = true
                    return false
                }
            }
            // State proven: remove the intent with barriers, then lift.
            do {
                try fileManager.removeItem(
                    at: rootDirectory.appendingPathComponent(Self.retryHoldIntentName))
                try synchronizer(rootDirectory, true)
                retryHoldLocked = false
                return true
            } catch {
                retryHoldLocked = true
                return false
            }
        }
    }

    /// Clears the write-ahead pause intent after a successful boundary publication. A FAILED
    /// clear RETAINS the hold (fail closed): an unprovable clear is not a clear.
    private func clearRetryHoldIfEstablishedLocked() {
        let url = rootDirectory.appendingPathComponent(Self.retryHoldIntentName)
        do {
            try fileManager.removeItem(at: url)
            try synchronizer(rootDirectory, true)
            retryHoldLocked = false
        } catch {
            retryHoldLocked = true
        }
    }

    /// Publishes a not-before stamp with REAL error propagation: write, file barrier, root barrier.
    /// A failure of any stage throws — never a silent advisory delay.
    private func publishNotBeforeLocked(_ instant: Date, for entry: Entry) throws {
        let url = rootDirectory.appendingPathComponent(Self.notBeforeName(for: entry.name))
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["notBefore": instant.timeIntervalSince1970]) else {
            throw PrepareError.accountingUnavailable
        }
        try failureRecordWriter(url, data)
        try synchronizer(url, false)
        try synchronizer(rootDirectory, true)
    }

    /// Refuses an attempt that is not yet due.
    ///
    /// AN UNREADABLE delay is not A DELAY. This used to throw
    /// `leaseHeld` for an unreadable obligation, an unstattable stamp or an unparseable one — a
    /// queue-wide retry hold on the path the UPLOADER actually calls, which is the last surviving
    /// form of the gate 066e2a70 item 2 removed elsewhere. Unknown retry state means DUE now.
    /// A READABLE future deadline still refuses, and that is the distinction that matters: the
    /// server's minimum keeps applying, while the client's inability to read its own bookkeeping
    /// stops withholding a recording.
    private func refuseIfNotYetDueLocked(_ entry: Entry) throws {
        // THE obligation is authoritative: a missing stamp does not mean no
        // delay is owed — the obligation record proves it even when stamp publication failed.
        if let owed = readObligationLocked(entry) {
            // NaN is an unreadable delay, not an infinite one: due now.
            if owed.isNaN {
                FileLog.shared.addMessage(
                    "[VoiceSharing] admit entry=\(entry.name) reason=obligation-unknown disposition=due-now")
                FileLog.shared.forceFlush()
            } else if clock().timeIntervalSince1970 < owed {
                // not-YET-DUE must be DISTINGUISHABLE from "someone else owns this entry"
                // the
                // caller's budget/stopping rules depend on knowing a delay is owed.
                FileLog.shared.addMessage("[VoiceSharing] admit refusal reason=obligation-not-yet-due")
                FileLog.shared.forceFlush()
                throw PrepareError.notYetDue(retryAt: Date(timeIntervalSince1970: owed))
            }
            // Due (or unreadable, hence due): retire the obligation so it cannot outlive its
            // purpose. An unreadable one is retired too — it has already been treated as due, and
            // leaving it would re-hold the entry on the next pass for no reason.
            try? fileManager.removeItem(
                at: rootDirectory.appendingPathComponent(Self.obligationPrefix + entry.name))
            try? synchronizer(rootDirectory, true)
        }
        let url = rootDirectory.appendingPathComponent(Self.notBeforeName(for: entry.name))
        // REQUIRED-stat + bounded read: no `fileExists`, no unbounded `Data`.
        switch Self.statKind(of: url) {
        case .absent: return
        case .failure:
            // Cannot stat it: unknown, hence due now. Logged so the state is attributable.
            FileLog.shared.addMessage(
                "[VoiceSharing] admit entry=\(entry.name) reason=notbefore-unknown disposition=due-now")
            FileLog.shared.forceFlush()
            return
        case .present: break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
            size.bytes > 0, size.bytes <= Self.maxSettlementRecordBytes,
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stamp = object["notBefore"] as? Double, stamp.isFinite
        else {
            // Unparseable/oversized/non-regular: unknown, hence due now. The record is RETIRED
            // below by the due path, so a corrupt stamp cannot hold the entry every pass.
            FileLog.shared.addMessage(
                "[VoiceSharing] admit entry=\(entry.name) reason=notbefore-unreadable disposition=due-now")
            FileLog.shared.forceFlush()
            try? fileManager.removeItem(at: url)
            try? synchronizer(rootDirectory, true)
            return
        }
        if clock().timeIntervalSince1970 < stamp {
            FileLog.shared.addMessage("[VoiceSharing] admit refusal reason=notbefore-not-yet-due")
            FileLog.shared.forceFlush()
            throw PrepareError.notYetDue(retryAt: Date(timeIntervalSince1970: stamp))
        }
        // Due: retire the record so it cannot outlive its purpose.
        try? fileManager.removeItem(at: url)
        try? synchronizer(rootDirectory, true)
    }

    static let notBeforePrefix = "attempt.notbefore."

    static func notBeforeName(for entryName: String) -> String {
        notBeforePrefix + entryName
    }

    /// Acquires single-request ownership and consumes one attempt. Returns `false` when another
    /// request owns the entry or its attempts are exhausted.
    @discardableResult
    func beginAttempt(_ entry: Entry) throws -> Bool {
        try serialQueue.sync {
            // A REVOCATION hold is A GATE ("sharing off"); A RETRY hold is not.
            // The ruling is explicit: "an unknown fact about the whole root or owner may refuse only
            // NEW admissions, never an attempt." `retryHoldLocked` is an unknown bookkeeping fact
            // about retry state, so it may not spend a due recording's turn. It no longer throws
            // here; it is logged and the attempt proceeds.
            guard !revocationHoldLocked else { throw PrepareError.accountingUnavailable }
            if retryHoldLocked {
                FileLog.shared.addMessage(
                    "[VoiceSharing] attempt entry=\(entry.name) reason=retry-state-unknown disposition=due-now")
                FileLog.shared.forceFlush()
            }
            // The enforced retry boundary applies at every entry point.
            try refuseIfNotYetDueLocked(entry)
            guard inFlightAttempts[entry] == nil else { return false }
            // Handle identity is checked before coverage (a foreign handle is a refusal, not a
            // coverage question). Clarification 7e9606b: attempts must then honor
            // unknown coverage even for an already-held entry handle. The STRICT owner-wide
            // coverage authority is the same one the serving query uses: root listing AND every
            // entry's required state must be KNOWN, not merely the target entry's — another
            // entry's stat/read failure holds attempts for the whole owner.
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }
            // PER-ENTRY coverage, not owner-WIDE. This
            // used `strictOwnerCoverageLocked`, so one unreadable sibling entry stopped every
            // attempt: a due recording lost its turn to a fact about a different recording. Only
            // this entry's own state may hold its attempt, and unreadable state means DUE now
            // rather than an invented delay.
            _ = try? strictOwnerCoverageLocked()
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/"),
                Self.statKind(of: entryDirectoryLocked(for: entry)) == .present
            else { return false }
            // every non-dispatch path settles explicitly: a lease acquired here must never survive
            // a later refusal or throw, or the entry would be blocked by its own failed attempt.
            let lease = try acquireLeaseLocked(for: entry)
            guard let lease else { return false }
            do {
                // Ready/count checks run after the claim so only the owner mutates shared state.
                guard try isAttemptableLocked(entry) else {
                    // GONE with the cap: with no attempt
                    // budget `isAttemptableLocked` can no longer refuse for a large count, so this
                    // deletion path has no reachable condition. It is kept as the fail-closed
                    // removal for a CORRUPT count that slipped through validation, which is the
                    // only remaining reason an entry would be complete and unservable.
                    if isCompleteEntryLocked(at: entry),
                       let count = try? attemptCountLocked(for: entry),
                       !admitCountPermits(count) {
                        let removed = (try? fileManager.removeItem(
                            at: entryDirectoryLocked(for: entry))) != nil
                        // DIAGNOSTIC (content-free): this path DELETES a complete entry.
                        FileLog.shared.addMessage(
                            "[VoiceSharing] queue removal reason=attempts-exhausted "
                                + "entry=\(entry.name) removed=\(removed)")
                            // FORCE the flush (FileLog buffers 100 entries): a removal line must be on disk
                            // before the process can be terminated, or the diagnosis dies with it.
                            FileLog.shared.forceFlush()
                    }
                    releaseLeaseLocked(for: entry, owner: lease)
                    return false
                }
                try recordAttemptLocked(entry)
            } catch {
                releaseLeaseLocked(for: entry, owner: lease)
                throw error
            }
            inFlightAttempts[entry] = lease
            return true
        }
    }

    /// Releases single-request ownership. Only the CURRENT owner's release deletes the lease; a
    /// stale owner (whose lease was reclaimed after expiry) must not delete its successor's.

    /// Outcome of an upload attempt, applied atomically with ownership validation.
    enum AttemptOutcome: String {
        /// Delivered: the entry is removed and the lease released, atomically.
        case delivered
        /// Retryable failure: only the lease is released; the entry stays for the next attempt.
        case retryableFailure
        /// Permanent failure: the entry is removed (content-free terminal state).
        case abandoned
        /// LEGACY durable disqualification ( supersedes retention for NEW
        /// refusals: both legs now DELETE; see the uploader's 400 branch and discovery's
        /// record-refused purge). The outcome and its reconciliation remain because entries
        /// already quarantined on disk must still reconcile exactly. Retained semantics
        ///: bytes and metadata retained,
        /// never selected for another attempt, recoverable by inspection.
        case quarantined
    }

    /// Applies an attempt result. The caller's lease is REVALIDATED under the entry's flock before
    /// anything happens: an intervening expiry/reclaim means this result is stale and must be
    /// refused — an old owner must not delete an entry a successor is now uploading.
    /// Durable record of WHICH settlement transition is pending for an entry. Written at the ROOT
    /// (outside removable scopes) before any mutation and removed only after the mutation is
    /// durably confirmed. This is what makes reconciliation exact: the absent lease/entry is
    /// reconciled as THIS transition, not merely as "some owner did something".
    static let settlementRecordName = "attempt.settlement"
    static func settlementRecordName(for entryName: String) -> String {
        "\(settlementRecordName).\(entryName).json"
    }
    static let maxSettlementRecordBytes = 256

    enum SettlementPhase: String {
        /// The transition is authorized but not yet durably completed.
        case pending
        /// The transition was applied AND its durability barrier succeeded.
        case confirmed
    }

    struct SettlementRecord {
        let generation: String
        let owner: Int32
        let outcome: AttemptOutcome
        var phase: SettlementPhase = .pending

        var jsonObject: [String: Any] {
            ["generation": generation,
             "owner": Int(owner),
             "outcome": outcome.rawValue,
             "phase": phase.rawValue]
        }

        /// Strict parse: malformed records are UNKNOWN pending state and must refuse settlement,
        /// never be treated as absent intent or overwritten by a fresh transition.
        static func parse(_ data: Data) -> SettlementRecord? {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let generation = obj["generation"] as? String,
                  let owner = obj["owner"] as? Int,
                  let outcomeRaw = obj["outcome"] as? String,
                  let outcome = AttemptOutcome(rawValue: outcomeRaw),
                  let phaseRaw = obj["phase"] as? String,
                  let phase = SettlementPhase(rawValue: phaseRaw),
                  Int32(exactly: owner) != nil else { return nil }
            return SettlementRecord(generation: generation, owner: Int32(exactly: owner)!,
                                    outcome: outcome, phase: phase)
        }

        func encoded() throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
            guard data.count <= VoiceSharingUploadQueue.maxSettlementRecordBytes else {
                throw PrepareError.accountingUnavailable
            }
            return data
        }
    }

    /// Best-effort retirement of a settled record: the confirmed phase already made completion
    /// durable, so cleanup failure leaves a record reconciliation still accepts.
    private func clearSettlementBestEffort(for entryName: String) {
        let url = rootDirectory.appendingPathComponent(Self.settlementRecordName(for: entryName))
        try? fileManager.removeItem(at: url)
        try? synchronizer(rootDirectory, true)
    }

    /// Entry name encoded in a well-formed root settlement record name, else nil.
    static func parseSettlementName(_ fileName: String) -> String? {
        guard fileName.hasPrefix(settlementRecordName + "."),
              fileName.hasSuffix(".json") else { return nil }
        let entryName = String(fileName.dropFirst((settlementRecordName + ".").count)
            .dropLast(".json".count))
        guard UUID(uuidString: entryName) != nil else { return nil }
        return entryName
    }

    /// Recovery for settlement records whose owner is gone. PENDING records are never touched:
    /// they are the only reconciliation state their owner or a fresh successor has. CONFIRMED
    /// records (completion already durable) are verified against on-disk state and retired.
    func recoverAbandonedSettlements() {
        serialQueue.sync {
            recoverAbandonedSettlementsLocked()
        // Refusal deletion intents reconcile EXPLICITLY: an intent
        // whose entry is proven absent is retired through the durable helpers here — never by
        // the debris sweep; an intent whose entry survived stays durable and held for the
        // serving sweeps' scoped-purge retries.
        reconcileRefusalIntentsLocked()
            bumpHoldGenerationForContentChange()
        }
    }

    /// The body, for callers ALREADY on the serial queue.
    private func recoverAbandonedSettlementsLocked() {
        // A BOUND may guard only the destructive sweep. This pass REMOVES
        // things, so it is the one place a bound is allowed — and a deferred sweep is LOGGED
        // rather than silently skipped, so an over-cap root shows up as work waiting instead of
        // disappearing.
        guard let listed = try? listDirectoryBounded(
            rootDirectory, [.isDirectoryKey], Self.maxSweptEntries) else {
            FileLog.shared.addMessage("[VoiceSharing] sweep deferred reason=listing-failed")
            FileLog.shared.forceFlush()
            return
        }
        if listed.overflowed {
            FileLog.shared.addMessage(
                "[VoiceSharing] sweep deferred reason=over-bound entries=\(listed.urls.count) bound=\(Self.maxSweptEntries)")
            FileLog.shared.forceFlush()
        }
        for url in listed.urls {
            let entryName = Self.parseSettlementName(url.lastPathComponent)
            guard let entryName else { continue }
            let directory = rootDirectory.appendingPathComponent(entryName, isDirectory: true)
            switch Self.statKind(of: url) {
            case .absent, .failure:
                continue
            case .present:
                break
            }
            // (2): read and validate the CURRENT record UNDER the entry lock,
            // with the same bounded/regular-file reader the apply path uses. A pre-lock read can
            // be stale: another owner may retire the old record and publish a new settlement
            // before this lock is obtained, and acting on the stale record could delete it.
            let lock = try? LeaseLock(entryName: entryName, rootDirectory: rootDirectory)
            guard let lock else { continue }
            defer { lock.close() }
            do { try lock.lockExclusive() } catch { continue }
            guard fileSizeIfRegularLocked(at: url).map({ $0.isRegular && $0.bytes > 0 && $0.bytes <= Self.maxSettlementRecordBytes }) == true,
                  let data = try? Data(contentsOf: url),
                  let record = SettlementRecord.parse(data) else {
                // Unknown pending state is never deleted by recovery: only its owner path may
                // classify it. Leave it; applyAttemptResult will refuse with accountingUnavailable.
                continue
            }
            switch record.phase {
            case .pending:
                // The transition may not have been applied; the pending record is the only thing
                // that lets its owner (or a fresh successor) reconcile the exact transition.
                // Recovery must not retire it — applyAttemptResult handles every pending case:
                // entry present (apply), entry absent (repeat the root barrier and complete).
                continue
            case .confirmed:
                // Completion is durable: verify state matches, then retire.
                let stateOK: Bool
                switch record.outcome {
                case .delivered, .abandoned:
                    stateOK = Self.statKind(of: directory) == .absent
                case .retryableFailure:
                    stateOK = Self.statKind(
                        of: directory.appendingPathComponent(Self.attemptLeaseName)) == .absent
                case .quarantined:
                    // Quarantine completion = failed marker PRESENT (bytes retained, unservable)
                    // AND lease gone. Marker absence means the disqualification did not land.
                    stateOK = Self.statKind(
                        of: directory.appendingPathComponent(Self.failedName)) == .present
                        && Self.statKind(
                            of: directory.appendingPathComponent(Self.attemptLeaseName)) == .absent
                }
                guard stateOK else { continue }
                try? fileManager.removeItem(at: url)
                try? synchronizer(rootDirectory, true)
            }
        }
    }

    /// Whether the given owner token still holds the lease. Verify the
    /// durable state still matches the recorded outcome, then retire the record best-effort.
    private func reconcileConfirmedSettlement(
        _ record: SettlementRecord, entry: Entry, directory: URL) throws {
        switch record.outcome {
        case .delivered, .abandoned:
            guard Self.statKind(of: directory) == .absent else {
                // Confirmed says removed; state says present. Unexplainable: refuse.
                throw PrepareError.accountingUnavailable
            }
        case .retryableFailure:
            guard Self.statKind(of: directory.appendingPathComponent(Self.attemptLeaseName)) == .absent
            else {
                throw PrepareError.accountingUnavailable
            }
        case .quarantined:
            guard Self.statKind(of: directory.appendingPathComponent(Self.failedName)) == .present,
                Self.statKind(of: directory.appendingPathComponent(Self.attemptLeaseName)) == .absent
            else {
                throw PrepareError.accountingUnavailable
            }
        }
        clearSettlementBestEffort(for: entry.name)
    }

    /// `retryNotBefore` publishes the enforced retry boundary INSIDE the settlement transaction:
    /// lease is validated first, so a stale owner can never write a successor's boundary
    ///, and the stamp lands only if the lease is live.
    func applyAttemptResult(
        _ entry: Entry, lease: AttemptLease, outcome: AttemptOutcome,
        retryNotBefore: Date? = nil
    ) throws {
        // Boundary classification: any filesystem/barrier error inside means the settlement's
        // outcome is UNKNOWN. PrepareErrors thrown deliberately keep their meaning; raw I/O errors
        // become `.publicationUncertain`.
        do {
            try applyAttemptResultLocked(entry, lease: lease, outcome: outcome,
                                         retryNotBefore: retryNotBefore)
        } catch let error as PrepareError {
            throw error
        } catch {
            throw PrepareError.publicationUncertain
        }
    }

    private func applyAttemptResultLocked(
        _ entry: Entry, lease: AttemptLease, outcome: AttemptOutcome, retryNotBefore: Date?) throws {
        try serialQueue.sync {
            // handle validation is restored — this entry must belong to THIS
            // root and carry a name this queue could have minted, before any path is constructed.
            guard entry.root == rootDirectory,
                UUID(uuidString: entry.name) != nil,
                !entry.name.contains("/")
            else { throw CocoaError(.fileNoSuchFile) }

            let lock = try LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
            defer { lock.close() }
            try lock.lockExclusive()
            let directory = entryDirectoryLocked(for: entry)
            let settlementURL = rootDirectory.appendingPathComponent(
                Self.settlementRecordName(for: entry.name))

            enum IntentRead { case record(SettlementRecord); case absent; case unknown }
            // (3): oversized, nonregular, unreadable or malformed intent is
            // UNKNOWN pending state — refuse, never treat as absent or overwrite as fresh.
            func readSettlement() throws -> IntentRead {
                switch Self.statKind(of: settlementURL) {
                case .absent:
                    return .absent
                case .failure:
                    return .unknown
                case .present:
                    // (2): the reader checks the REGULAR-FILE kind too, not
                    // only the size bound.
                    guard let size = fileSizeIfRegularLocked(at: settlementURL),
                        size.isRegular, size.bytes > 0,
                        size.bytes <= Self.maxSettlementRecordBytes else {
                        return .unknown
                    }
                    guard let data = try? Data(contentsOf: settlementURL),
                          let record = SettlementRecord.parse(data) else {
                        return .unknown
                    }
                    return .record(record)
                }
            }
            // (1): the intent file ITSELF is barrier-confirmed (file, then its
            // naming directory), not just the root.
            func writeSettlement(_ record: SettlementRecord) throws {
                let data = try record.encoded()
                try data.write(to: settlementURL, options: [.atomic])
                try synchronizer(settlementURL, false)
                try synchronizer(rootDirectory, true)
            }
            /// (1): before every DESTRUCTIVE continuation on a recorded intent,
            /// re-confirm that the intent is durably in place (content re-read + file + root
            /// barriers, under the lock). An unconfirmed record must not authorize deletion.
            func confirmIntentDurability(_ expected: SettlementRecord) throws {
                let reread = try readSettlement()
                guard case .record(let live) = reread,
                      live.generation == expected.generation,
                      live.owner == expected.owner,
                      live.outcome == expected.outcome,
                      live.phase == expected.phase else {
                    throw PrepareError.publicationUncertain
                }
                try synchronizer(settlementURL, false)
                try synchronizer(rootDirectory, true)
            }
            /// (2): clearing is two-phase. First REWRITE the record as
            /// `confirmed` and barrier it — that write is what makes completion durable and
            /// recoverable. Only then remove the record. If the final removal or its barrier
            /// fails, the confirmed record survives and retry/fresh-instance reconciliation
            /// still succeeds.
            func confirmPhase(_ record: SettlementRecord) throws {
                var confirmed = record
                confirmed.phase = .confirmed
                // the atomic rewrite REPLACES the inode — fsyncing the
                // previous pending file proves nothing about the replacement. Every journal
                // rewrite synchronizes FILE first, then its naming directory. A file-barrier
                // failure retains the recovery state (the atomic temp either lands or not; the
                // record is re-readable either way) and refuses success.
                let data = try confirmed.encoded()
                try data.write(to: settlementURL, options: [.atomic])
                try synchronizer(settlementURL, false)
                try synchronizer(rootDirectory, true)
            }


            // Record the pending transition DURABLY before mutating anything. A crash between
            // this write and the mutation leaves the intent recoverable; a crash after mutation
            // but before confirmation leaves it reconcilable. The record binds generation, owner
            // AND outcome, so a retry can only complete the exact transition it started.
            let intentRead = try readSettlement()
            let recorded: SettlementRecord?
            switch intentRead {
            case .unknown:
                // Unknown pending state: refuse rather than guess or overwrite.
                throw PrepareError.accountingUnavailable
            case .record(let prior):
                // (1): identity and outcome are checked before the phase
                // dispatch — a surviving confirmed record must not let a foreign token or a
                // contradictory outcome claim success.
                guard prior.generation == lease.generation else {
                    throw PrepareError.resultStale
                }
                guard prior.outcome == outcome else {
                    // Contradictory retry: the recorded transition says something else; a
                    // different outcome would claim a removal it never authorized.
                    throw PrepareError.settlementConflict
                }
                if prior.phase == .confirmed {
                    // The transition was applied and its durability barrier SUCCEEDED. Completion
                    // is durable; this call (and any later retry) just verifies and cleans up.
                    try reconcileConfirmedSettlement(prior, entry: entry, directory: directory)
                    inFlightAttempts.removeValue(forKey: entry)
                    return
                }
                // (1): an UNCONFIRMED record must not authorize deletion until
                // its own durability is re-established under this lock.
                // an UNCONFIRMED record must not authorize deletion. The
                // barrier failure surfaces raw here (uncertain outcome) — an already-CONFIRMED
                // record never needs this re-confirmation, so a retry after the confirmed-phase
                // barrier failed is not blocked by "unknown intent durability".
                try confirmIntentDurability(prior)
                recorded = prior
            case .absent:
                // No pending record: this is a FRESH settlement, which requires the lease to be
                // live and owned by this caller. Absence without intent is not settled success.
                let current = leaseOwnerLocked(
                    at: directory.appendingPathComponent(Self.attemptLeaseName))
                guard Self.statKind(of: directory) == .present,
                    let held = current, held.generation == lease.generation
                else { throw PrepareError.resultStale }
                let fresh = SettlementRecord(
                    generation: lease.generation, owner: lease.owner, outcome: outcome)
                // If the intent cannot be durably recorded, the transition must not start:
                // uncertain, ownership retained, retry starts over from a live lease.
                try writeSettlement(fresh)
                recorded = fresh
            }
            guard let recorded else { throw PrepareError.accountingUnavailable }

            // A lock serializes transitions; it does not make failed filesystem operations succeed
            // or persist. Settlement failures propagate as UNCERTAIN and keep the intent record
            // (and the caller's ownership) so the exact transition can be retried.
            func confirmEntryRemovalDurability() throws {
                try synchronizer(rootDirectory, true)
            }
            func confirmLeaseRemovalDurability() throws {
                try synchronizer(directory, true)
            }
            /// Two-phase completion: first make the CONFIRMED phase durable (that write is the
            /// recoverable completion), then remove the record best-effort. A failure in the final
            /// removal leaves a confirmed record that reconciliation still accepts.
            func finishSettlement() throws {
                try confirmPhase(recorded)
                clearSettlementBestEffort(for: entry.name)
                inFlightAttempts.removeValue(forKey: entry)
            }

            switch Self.statKind(of: directory) {
            case .failure:
                throw PrepareError.publicationUncertain
            case .absent:
                // Pending ENTRY removal landed but was not confirmed: repeat the root barrier.
                // Quarantine may never take this path: quarantine claims
                // marker-present retention — an absent directory proves the bytes are GONE, so
                // claiming quarantine success here would be a lie.
                guard recorded.outcome != .quarantined else {
                    FileLog.shared.addMessage(
                        "[VoiceSharing] queue quarantine reconciliation entry=\(entry.name) "
                            + "state=directory-absent outcome=uncertain")
                    FileLog.shared.forceFlush()
                    throw PrepareError.publicationUncertain
                }
                do { try confirmEntryRemovalDurability() } catch {
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
                return
            case .present:
                break
            }

            let leaseURL = directory.appendingPathComponent(Self.attemptLeaseName)
            let current = leaseOwnerLocked(at: leaseURL)
            if let held = current, held.generation != lease.generation {
                // A successor owns the entry now; our pending transition is obsolete.
                try? fileManager.removeItem(at: settlementURL)
                throw PrepareError.resultStale
            }
            if current == nil {
                switch Self.statKind(of: leaseURL) {
                case .failure:
                    throw PrepareError.publicationUncertain
                case .absent:
                    // Pending LEASE-only removal landed but was not confirmed: repeat the barrier.
                    // Quarantine participates: the marker was written before
                    // the lease release, so a pending quarantine with a gone lease reconciles by
                    // RE-CONFIRMING the retained directory + marker — never resultStale.
                    if recorded.outcome == .quarantined {
                        guard Self.statKind(of: directory.appendingPathComponent(Self.failedName))
                            == .present else {
                            // Marker false can mean sync-failed-after-write, not absence (spec
                            // de1b7a0f): log uncertainty, retain everything, refuse success.
                            FileLog.shared.addMessage(
                                "[VoiceSharing] queue quarantine reconciliation entry=\(entry.name) "
                                    + "state=marker-unconfirmed retention=intact")
                            FileLog.shared.forceFlush()
                            throw PrepareError.publicationUncertain
                        }
                        do { try confirmLeaseRemovalDurability() } catch {
                            throw PrepareError.publicationUncertain
                        }
                        try finishSettlement()
                        return
                    }
                    guard recorded.outcome == .retryableFailure else {
                        throw PrepareError.resultStale
                    }
                    do { try confirmLeaseRemovalDurability() } catch {
                        throw PrepareError.publicationUncertain
                    }
                    try finishSettlement()
                    return
                case .present:
                    throw PrepareError.resultStale
                }
            }

            // The lease is live and ours: apply the recorded outcome.
            switch outcome {
            case .quarantined:
                // RETAIN, don't destroy: a contract rejection must not delete
                // the recording. Disqualify in place — the durable publication.failed intent makes
                // the entry unservable while keeping every byte — confirm the marker before the
                // lease is released (a lease release without the marker would let the entry be
                // selected again), then complete the settlement. A failed marker or barrier
                // retains everything and propagates uncertainty: fail closed toward retention.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue quarantine reason=contract-rejected "
                        + "entry=\(entry.name) starting")
                FileLog.shared.forceFlush()
                guard disqualifyLocked(directory, cause: .decidedRejection) else {
                    // A false here can mean the marker write failed after landing (sync failure),
                    // so the state is UNKNOWN — log confirmation-failed, never "absent".
                    FileLog.shared.addMessage(
                        "[VoiceSharing] queue quarantine reason=contract-rejected "
                            + "entry=\(entry.name) marker-state=unknown confirmation-failed "
                            + "retention=intact")
                    FileLog.shared.forceFlush()
                    throw PrepareError.publicationUncertain
                }
                do { try synchronizer(rootDirectory, true) } catch {
                    throw PrepareError.publicationUncertain
                }
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue quarantine reason=contract-rejected "
                        + "entry=\(entry.name) retained=true unservable=true flush=completed")
                FileLog.shared.forceFlush()
                do {
                    try fileManager.removeItem(at: leaseURL)
                    try confirmLeaseRemovalDurability()
                } catch {
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
            case .delivered, .abandoned:
                // DIAGNOSTIC (content-free): logged before the operation so a deletion whose
                // confirmation then throws is still attributable — the exact gap an unlogged
                // removal would leave.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=settled outcome=\(outcome) "
                        + "entry=\(entry.name) starting")
                FileLog.shared.forceFlush()
                do {
                    try fileManager.removeItem(at: directory)
                    try confirmEntryRemovalDurability()
                    FileLog.shared.addMessage(
                        "[VoiceSharing] queue removal reason=settled outcome=\(outcome) "
                            + "entry=\(entry.name) removed=true flush=completed")
                    FileLog.shared.forceFlush()
                } catch {
                    FileLog.shared.addMessage(
                        "[VoiceSharing] queue removal reason=settled outcome=\(outcome) "
                            + "entry=\(entry.name) removal-state=unknown")
                    FileLog.shared.forceFlush()
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
            case .retryableFailure:
                // DURABLE boundary before release: the not-before stamp is
                // part of this settlement, written while the lease is verified-live. A failed
                // barrier is never swallowed: the owner-wide hold engages until reconciliation,
                // because a released lease without its boundary is exactly the advisory-delay
                // fail-open state this design forbids.
                if let boundary = retryNotBefore {
                    // 1. WRITE-AHEAD the exact obligation: entry identity + original boundary are
                    // durable before the intent, stamp or anything else. If the stamp later fails
                    // to land, this record still proves a delay was owed.
                    try writeObligationLocked(boundary, for: entry)
                    // 2. Owner-wide hold marker, also write-ahead.
                    try engageRetryHoldLocked()
                    // 3. Boundary publication. On failure the hold (memory + disk) stands and the
                    // uncertainty propagates; the lease is not released.
                    do {
                        try publishNotBeforeLocked(boundary, for: entry)
                    } catch {
                        throw PrepareError.publicationUncertain
                    }
                    // 4. Release, then clear — a failed clear keeps the hold (fail closed).
                    do {
                        try fileManager.removeItem(at: leaseURL)
                        try confirmLeaseRemovalDurability()
                    } catch {
                        throw PrepareError.publicationUncertain
                    }
                    try finishSettlement()
                    clearRetryHoldIfEstablishedLocked()
                    return
                }
                do {
                    try fileManager.removeItem(at: leaseURL)
                    try confirmLeaseRemovalDurability()
                } catch {
                    throw PrepareError.publicationUncertain
                }
                try finishSettlement()
            }
        }
    }

    /// Whether the given owner token still holds the lease. A stale completion must check this
    /// before reporting a result: elapsed time alone does not prove the old writer died.
    func stillOwns(_ entry: Entry, lease: AttemptLease?) -> Bool {
        serialQueue.sync {
            guard let lease, let current = leaseOwnerLocked(
                at: entryDirectoryLocked(for: entry).appendingPathComponent(Self.attemptLeaseName))
            else { return false }
            return current.generation == lease.generation
        }
    }

    /// Releases single-request ownership. Does not remove the durable record: the attempt is spent.
    /// Releases single-request ownership. Only the CURRENT owner's release deletes the lease; a
    /// stale owner (whose lease was reclaimed after expiry) must not delete its successor's.
    func endAttempt(_ entry: Entry) {
        serialQueue.sync {
            let lease = inFlightAttempts.removeValue(forKey: entry)
            releaseLeaseLocked(for: entry, owner: lease)
        }
    }

    /// Records an attempt without taking ownership. Prefer `beginAttempt`, which does both atomically.
    func recordAttempt(_ entry: Entry) throws {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            return try recordAttemptLocked(entry)
        }
    }

    /// `Entry.root` is the QUEUE root, not the entry's own directory. The attempt record must live
    /// inside the entry directory; at the queue root recovery would (correctly) delete it as a stray.
    private func attemptRecordURL(for entry: Entry) -> URL {
        entryDirectoryLocked(for: entry).appendingPathComponent(Self.attemptRecordName)
    }

    /// Reads the durable attempt count.
    ///
    /// Only a CONFIRMED absence means zero. A missing file is absence; an unreadable, oversized,
    /// malformed or negative record is not — treating those as zero would silently reset the retry
    /// budget and let an entry retry forever. They throw instead, so the caller must refuse.
    /// Where an entry's recorded owner stands. ABSENT and UNKNOWN are different facts: an entry
    /// prepared before sign-in has no owner (absent), while an owner file that exists but cannot be
    /// read is unreadable storage. Collapsing both into nil would report a fault as a benign
    /// absence, which is the same class of error the attempt record refuses to make.
    private enum OwnerState { case present(String); case absent }

    /// Reads the account recorded beside the entry at preparation. Throws on unreadable storage so
    /// admission refuses rather than guessing; `.absent` means "not yet attributed".
    private func ownerScopeLocked(for entry: Entry) throws -> OwnerState {
        let directory = try validatedEntryDirectoryLocked(entry)
        let url = directory.appendingPathComponent(Self.ownerName)
        switch Self.statKind(of: url) {
        case .absent:
            return .absent
        case .failure:
            throw PrepareError.accountingUnavailable
        case .present:
            break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxOwnerBytes,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { throw PrepareError.accountingUnavailable }
        return .present(text)
    }

    /// Attempt counts whose DURABLE write failed, held in memory so the count is not lost and not
    /// silently reset to zero.
    private var attemptCountMemoryOverride: [Entry: Int] = [:]

    private func attemptCountLocked(for entry: Entry) throws -> Int {
        let directory = try validatedEntryDirectoryLocked(entry)
        let url = directory.appendingPathComponent(Self.attemptRecordName)
        // An in-memory count supersedes the disk one only when the last write failed: the disk value
        // is then stale, and reading it would under-report attempts and re-crowd the server.
        if let inMemory = attemptCountMemoryOverride[entry] { return inMemory }
        // `fileExists` returns false for MANY failures, not just absence. Only ENOENT means "no
        // attempts yet"; any other error is unreadable storage and must refuse, otherwise a
        // permission fault would reset the retry budget.
        switch VoiceSharingUploadQueue.statKind(of: url) {
        case .absent:
            return 0
        case .failure:
            throw PrepareError.accountingUnavailable
        case .present:
            break
        }
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxAttemptRecordBytes
        else { throw PrepareError.accountingUnavailable }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict.count == 1,
              let value = dict["attempts"] as? Int,
              value >= 0, value <= Self.attemptCountSaturation
        else { throw PrepareError.accountingUnavailable }
        return value
    }

    /// An entry may only be attempted when it is COMPLETE and READY. Attempting an entry mid-
    /// preparation would upload a record that does not exist yet, and would spend one of its
    /// attempts on a state the spec never permits to be exposed.
    private func isAttemptableLocked(_ entry: Entry) throws -> Bool {
        // Validate the handle FIRST: a foreign or malformed Entry is an error, not a "not ready"
        // answer, and its absence must never be reported as a benign false.
        _ = try validatedEntryDirectoryLocked(entry)
        // the count no longer gates servability at all. An entry that has failed a
        // thousand times is exactly as attemptable as a fresh one; retention removes unaccepted
        // recordings, and the backoff schedule spaces the retries.
        // ATTEMPTABILITY is "CONTAINS A CAPTURE", not "BINDS locally" ( ruling 2,
        // item 1). Requiring a successful binding here was the second local gate:
        // the first was admission's identity read, and together they meant a capture the client
        // could not parse was never offered to the server. An entry holding audio is attemptable.
        // A DECIDED rejection still blocks the attempt. That is not a local verdict: the marker is
        // written from the server's own final refusal (`publication.failed`), and it is what keeps a
        // quarantined entry out of the wire. What must not block is a local inability to bind.
        if case .disqualified = try entryStateLocked(at: entry) { return false }
        // A CAPTURE still being written is not attemptable. This is not a local verdict on a
        // recording: an `.incomplete` entry has no audio and no marker yet, so there is nothing to
        // send. Only `.unready` (audio present, record unusable) is the case the ruling frees.
        guard isServedEntryLocked(at: entry) else { return false }
        // AN UNREADABLE count is not A REASON to hold. This call used to
        // THROW, so a malformed or unreadable `attempts.json` stopped the upload before the
        // count-write fallback in `admitAttempt` could ever run — the fallback repaired the write
        // path while the read path still refused. The count spaces retries; it is not a gate.
        let count: Int
        do { count = try attemptCountLocked(for: entry) } catch {
            FileLog.shared.addMessage(
                "[VoiceSharing] attempt count unreadable entry=\(entry.name) "
                    + "reason=\(type(of: error)) disposition=due-now")
            FileLog.shared.forceFlush()
            return true
        }
        return admitCountPermits(count)
    }

    /// Writes the attempt record and confirms its durability. Returns only after the record and its
    /// containing directory have been synchronized, so a crash cannot lose a counted attempt and let
    /// the entry be retried past its budget. Ambiguous persistence surfaces as `.publicationUncertain`
    /// for the attempt rather than permitting an uncounted request.
    private func recordAttemptLocked(_ entry: Entry) throws {
        let directory = try validatedEntryDirectoryLocked(entry)
        // Read-increment-write is a lost-update race across instances: two could read the same
        // count and both write the same "next", spending one attempt for two requests. The whole
        // transition serializes under the SAME per-entry flock the lease uses.
        let lock = try LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
        defer { lock.close() }
        try lock.lockExclusive()
        let current = try attemptCountLocked(for: entry)
        // A caller-supplied budget (a control) still refuses; production has none.
        guard admitCountPermits(current) else {
            throw PrepareError.attemptsExhausted
        }
        // SATURATE: the counter stops growing at the
        // representation bound and the attempt PROCEEDS. Refusing here was the 1,001st-attempt
        // cliff that disqualified healthy retryable work; a large count is no reason to stop
        // retrying a recording. `&+` cannot trap, and the guard below still catches a corrupt
        // negative/garbage record.
        let next = min(current &+ 1, Self.attemptCountSaturation)
        guard next > current || current >= Self.attemptCountSaturation else {
            throw PrepareError.accountingUnavailable
        }
        let url = directory.appendingPathComponent(Self.attemptRecordName)
        let data = try JSONSerialization.data(
            withJSONObject: ["attempts": next], options: [.sortedKeys])
        guard data.count <= Self.maxAttemptRecordBytes else {
            throw PrepareError.accountingUnavailable
        }
        do {
            try data.write(to: url, options: [.atomic])
            try synchronizer(url, false)
            try synchronizer(directory, true)
        } catch {
            // The write may or may not have landed. Do not hand out a request whose attempt is not
            // known to be counted.
            throw PrepareError.publicationUncertain
        }
    }

    /// Acquires the durable attempt lease. Succeeds when there is no lease, or when the existing one
    /// has EXPIRED (its owner died and cannot renew). Records `acquiredAt` so expiry is decided from
    /// durable state, not from this process's memory.
    private func acquireLeaseLocked(for entry: Entry) throws -> AttemptLease? {
        let directory = try validatedEntryDirectoryLocked(entry)
        let lease = directory.appendingPathComponent(Self.attemptLeaseName)
        // Serialize the whole read-decide-delete/create transition against other processes. Without
        // this, two expired reclaimers can both read the old generation and the later remover would
        // delete the first reclaimer's successor lease.
        let lock = try LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
        defer { lock.close() }
        try lock.lockExclusive()
        // Policy decision first (absent or expired), then an EXCLUSIVE os claim. `stat` then
        // `write` is check-then-act: two instances can both observe absence and both replace the
        // file. `O_CREAT|O_EXCL` is the atomic primitive — exactly one caller creates the file.
        if case .present = Self.statKind(of: lease) {
            guard let existing = leaseOwnerLocked(at: lease) else {
                // A lease we cannot parse cannot be safely stolen or trusted.
                throw PrepareError.accountingUnavailable
            }
            guard clock().timeIntervalSince(existing.acquiredAt) > Self.attemptLeaseDuration else {
                return nil
            }
            // Expired: remove the dead lease, but only if it is still the same generation. If
            // another instance reclaimed it first, our removal must not delete their new lease.
            guard reclaimExpiredLeaseLocked(lease, expected: existing.generation) else {
                return nil
            }
        }
        return try claimLeaseLocked(at: lease, directory: directory)
    }

    /// Creates the lease with `O_CREAT|O_EXCL`, so only ONE caller can succeed even under a
    /// simultaneous race. Records a fresh owner token: identity, not elapsed time, is what fences.
    private func claimLeaseLocked(at lease: URL, directory: URL) throws -> AttemptLease {
        let token = AttemptLease(
            generation: UUID().uuidString,
            acquiredAt: clock(),
            owner: ProcessInfo.processInfo.processIdentifier)
        let payload = try JSONSerialization.data(
            withJSONObject: token.jsonObject, options: [.sortedKeys])
        let fd = lease.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        }
        guard fd >= 0 else {
            // `EEXIST` means someone else claimed it first: a refusal, not a failure.
            if errno == EEXIST { throw PrepareError.leaseHeld }
            throw PrepareError.publicationUncertain
        }
        do {
            let written = payload.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, buffer.count)
            }
            close(fd)
            guard written == payload.count else { throw PrepareError.publicationUncertain }
            // An unconfirmed lease is not an owned lease.
            try synchronizer(lease, false)
            try synchronizer(directory, true)
        } catch {
            try? fileManager.removeItem(at: lease)
            throw PrepareError.publicationUncertain
        }
        return token
    }

    /// Removes an expired lease only when its generation still matches, so a concurrent reclaim
    /// cannot cause us to delete a successor's lease.
    private func reclaimExpiredLeaseLocked(_ lease: URL, expected: String) -> Bool {
        guard let current = leaseOwnerLocked(at: lease), current.generation == expected else {
            return false
        }
        return (try? fileManager.removeItem(at: lease)) != nil
    }

    /// Reads the lease owner token, bounded in size. Absence returns nil.
    private func leaseOwnerLocked(at lease: URL) -> AttemptLease? {
        guard case .present = Self.statKind(of: lease) else { return nil }
        guard let size = fileSizeIfRegularLocked(at: lease), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxAttemptLeaseBytes
        else { return nil }
        guard let data = try? Data(contentsOf: lease),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let token = AttemptLease(jsonObject: dict)
        else { return nil }
        return token
    }

    /// Fences a stale owner. A release from an owner that no longer holds the lease must not delete
    /// the successor's lease, and a stale completion must not be treated as current.
    private func releaseLeaseLocked(for entry: Entry, owner: AttemptLease?) {
        let directory = entryDirectoryLocked(for: entry)
        let lease = directory.appendingPathComponent(Self.attemptLeaseName)
        // An exact NONNIL owned token is required. A nil owner (an instance that never acquired)
        // must not remove whatever lease exists — that could delete another owner's lease. An
        // unknown or unreadable current identity is also refused: trust nothing we cannot confirm.
        guard let owner else { return }
        let lock = try? LeaseLock(entryName: entry.name, rootDirectory: rootDirectory)
        lock?.closeAfter { [self] in
            guard let current = leaseOwnerLocked(at: lease) else { return }
            guard current.generation == owner.generation else { return }
            try? fileManager.removeItem(at: lease)
            try? synchronizer(directory, true)
        }
    }

    /// Exclusive advisory lock over a STABLE per-entry file at the QUEUE root. `flock(LOCK_EX)`
    /// serializes claim/reclaim/release across instances and processes.
    ///
    /// The file lives at the ROOT, not inside the entry directory: recovery and exhaustion remove
    /// entry directories whole, which would destroy the lock file and its inode — a re-created file
    /// is a different inode, and two instances would then lock different locks. The root scan in
    /// `recoverLocked` skips well-formed lock files for exactly this reason.
    ///
    /// The descriptor is opened once with a single `open(O_CREAT|O_RDWR)` (no exists-check race)
    /// and closed EXACTLY once: `close` invalidates the stored descriptor, so `defer`/`closeAfter`
    /// and `deinit` cannot double-close — a reused descriptor number could otherwise close an
    /// unrelated file or socket.
    final class LeaseLock {
        private var fd: Int32

        init(entryName: String, rootDirectory: URL) throws {
            let url = rootDirectory.appendingPathComponent(
                VoiceSharingUploadQueue.rootLeaseLockName(for: entryName))
            fd = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return open(path, O_CREAT | O_RDWR, 0o600)
            }
            guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        }

        /// Test-only non-blocking acquisition.
        func tryLockForTesting() throws {
            guard fd >= 0, !locked else { return }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileReadUnknown) }
            locked = true
        }

        func lockExclusive() throws {
            guard fd >= 0, !locked else {
                if locked { return }
                throw CocoaError(.fileReadUnknown)
            }
            guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileReadUnknown) }
            locked = true
        }

        /// Runs `body` under the exclusive lock, then releases and closes.
        func closeAfter(_ body: () -> Void) {
            do { try lockExclusive() } catch { close(); return }
            body()
            close()
        }

        func close() {
            let descriptor = fd
            fd = -1
            if locked { flock(descriptor, LOCK_UN) }
            locked = false
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        private var locked = false
        deinit { close() }
    }

    /// Releases the lease. Best-effort: an unreleased lease still expires, so a failure here costs a
    /// delay, not a permanently blocked entry.
    private func releaseLeaseLocked(for entry: Entry) {
        let directory = entryDirectoryLocked(for: entry)
        try? fileManager.removeItem(at: directory.appendingPathComponent(Self.attemptLeaseName))
        try? synchronizer(directory, true)
    }

    /// Reads a lease's acquisition instant, bounded in size.
    private func leaseInstantLocked(at url: URL) -> Date? {
        guard let size = fileSizeIfRegularLocked(at: url), size.isRegular,
              size.bytes > 0, size.bytes <= Self.maxAttemptLeaseBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(text), seconds.isFinite, seconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Test-only: acquires a lease and returns its owner token, so a control can later assert that
    /// a reclaimed lease is no longer owned by this token.
    func beginLeaseForTesting(_ entry: Entry) throws -> AttemptLease? {
        try serialQueue.sync {
            guard inFlightAttempts[entry] == nil else { return inFlightAttempts[entry] }
            let lease = try acquireLeaseLocked(for: entry)
            if let lease { inFlightAttempts[entry] = lease }
            return lease
        }
    }

    /// Test-only: tightens the budget of an existing instance. A second instance cannot be used to
    /// simulate consumed capacity because its construction runs recovery, which removes entries that
    /// are still preparing.
    func setAggregateLimitsForTesting(_ limits: AggregateLimits) {
        serialQueue.sync { aggregateLimits = limits }
    }

    // MARK: Publication reconciliation

    /// Re-establishes the full durability barrier for an entry that already has a marker. Used by
    /// reconciliation and by recovery: an entry is only exposed as ready once this succeeds.
    /// Throws when durability cannot be confirmed, which the caller maps to an uncertain outcome.
    private func confirmDurableLocked(directory: URL) throws {
        try synchronizer(directory.appendingPathComponent(Self.audioName), false)
        try synchronizer(directory.appendingPathComponent(Self.metadataName), false)
        // THE age sidecar is not part of durability. Confirming it obligated on a
        // file the entry does not depend on for validity, so an unreadable `created.at` held coverage
        // for the whole owner — the recording's durability was being decided by its timestamp.
        // The audio and metadata are the recording, and they, the marker and the directories are
        // synced exactly as before.
        try synchronizer(directory, true)
        try synchronizer(directory.appendingPathComponent(Self.readyMarkerName), false)
        try synchronizer(directory, true)
        try synchronizer(rootDirectory, true)
    }

    /// Reconciles an entry whose publication outcome is uncertain, under the SAME serialized owner
    /// that attempts publication. The spec requires this before any attempt, and requires the same
    /// rules on a fresh instance.
    ///
    /// The decision is made from durable state only, so it is identical in this process and after a
    /// restart:
    /// * the immutable record must bind completely (canonical digest, WAV/audio binding, shape);
    /// * the entry must be within its age and resource bounds;
    /// * a marker whose namespace could not be confirmed is not trusted merely because it exists.
    ///
    /// A `stage.publishing` record means the transition was interrupted before it could be
    /// confirmed, so the entry is unavailable and removed by bounded cleanup. Otherwise an intact,
    /// fully validated entry is confirmed.
    @discardableResult
    func reconcilePublication(_ entry: Entry) -> PublicationOutcome {
        serialQueue.sync {
            guard (try? establishStoragePolicyLocked()) != nil else { return .uncertain }
            let directory = entryDirectoryLocked(for: entry)
            guard fileManager.fileExists(atPath: directory.path) else { return .uncommitted }
            let marker = directory.appendingPathComponent(Self.readyMarkerName)
            let failed = directory.appendingPathComponent(Self.failedName)
            if fileManager.fileExists(atPath: failed.path) { return .uncommitted }
            guard fileManager.fileExists(atPath: marker.path) else { return .uncommitted }
            // Fully validate before exposing: the entry must still be the immutable record it claims
            // to be, within bounds. Anything less is not a confirmable publication.
            guard boundEntryLocked(at: entry) != nil else { return .uncommitted }
            // PRESENCE is not confirmation. After an uncertain transition the marker may be visible
            // while its durability was never established, so reconciliation must re-establish the
            // same barrier: contents, the marker's own durability, its directory entry and the root
            // link. If that cannot be confirmed the entry stays withheld as uncertain.
            guard (try? confirmDurableLocked(directory: directory)) != nil else { return .uncertain }
            return .committed
        }
    }

    // MARK: Listing and access

    /// All complete, ready entries within the queue-age bound, in finalize order (marker mtime;
    /// name as the deterministic tiebreak).
    /// Clarification 7e9606b: discovery covers disposal/disqualification intents as well as
    /// audio/metadata, and UNKNOWN coverage must HOLD serving, not read as "nothing ready".
    /// This tri-state result distinguishes a genuinely empty queue from a root that could not be
    /// scanned: callers that cannot handle `.unknownCoverage` must not serve.
    enum ReadyDiscovery {
        case known([Entry])
        /// The owner is HELD by an unproven revocation: purge barriers did not reconcile, and the
        /// durable intent is on disk. Only a purge that proves every barrier may release it.
        case revocationHeld
        /// Coverage could not be DETERMINED (listing/stat/read/durability failure, or an intent
        /// whose presence could not even be ESTABLISHED). Serving is held all the same, but this is
        /// not evidence that a revocation failed.
        case unknownCoverage
    }

    /// THE strict owner-wide coverage authority: root listing, every entry's required state, AND
    /// every ready entry's durability confirmation must be KNOWN. Serving queries and attempt
    /// gates share this one implementation so neither can hold a weaker standard than the other.
    private func strictOwnerCoverageLocked() throws -> [Entry] {
        try establishStoragePolicyLocked()
        let all = try entriesStrictLocked()
        for entry in all {
            // UNREADABLE metadata is per-ENTRY, never owner-WIDE ( ruling 2, reviewer
            // 307d0bde item 3). Previously any entry that failed to parse threw out of here and
            // took the WHOLE owner's serving and admission with it — one corrupted record held
            // every other capture hostage. A local inability to read a record is not evidence about
            // any other record, so it is skipped, not propagated.
            guard let state = try? entryStateLocked(at: entry) else { continue }
            // an unconfirmable READY marker is UNKNOWN coverage for the whole
            // owner — the attempt gate must hold exactly where the serving query holds. Entries
            // still being prepared (incomplete, no marker) are known-incomplete; durability
            // confirmation does not apply to them.
            if case .bound = state {
                guard (try? confirmDurableLocked(directory: entryDirectoryLocked(for: entry))) != nil
                else {
                    // Same rule: an unconfirmable marker disqualifies THIS entry. It is not proof
                    // that a sibling entry is unconfirmable.
                    FileLog.shared.addMessage(
                        "[VoiceSharing] coverage entry=\(entry.name) reason=marker-unconfirmable disposition=skip-entry")
                    FileLog.shared.forceFlush()
                    continue
                }
                // OWNERSHIP is part of the shared authority: an owner file that
                // exists but cannot be read is UNKNOWN coverage for the WHOLE owner, exactly like an
                // unconfirmable marker — not a quiet per-entry skip. `ownerScopeLocked` throws for
                // unreadable storage and returns `.absent` only for a genuinely missing file, so a
                // fault can never be mistaken for "not attributed yet".
                if currentIdentityLocked != nil {
                    guard (try? ownerScopeLocked(for: entry)) != nil else {
                        FileLog.shared.addMessage(
                            "[VoiceSharing] coverage entry=\(entry.name) reason=owner-unreadable disposition=skip-entry")
                        FileLog.shared.forceFlush()
                        continue
                    }
                }
            }
        }
        return all
    }

    /// The last discovery's per-entry account, for controls and diagnostics.
    private(set) var lastDiscoveryDiagnostic = ""

    /// The complete-entry count this queue measured from disk at its last recovery, and whether it
    /// could be measured at all. Diagnostics and controls only — every admission re-counts, so the
    /// limit is never served from a stale value.
    private(set) var lastCompleteEntryCountLocked: Int?
    /// Set when the last recovery could not count the root. Admission still proceeds.
    private(set) var lastCountWasUnknown = false

    private func recordBudgetFromDiskLocked() {
        do {
            let count = try entryCountOnDiskLocked()
            lastCompleteEntryCountLocked = count
            lastCountWasUnknown = false
            FileLog.shared.addMessage(
                "[VoiceSharing] queue record count recomputed from disk records=\(count) "
                    + "maxRecords=\(aggregateLimits.maxRecords)")
        } catch {
            lastCompleteEntryCountLocked = nil
            lastCountWasUnknown = true
            FileLog.shared.addMessage(
                "[VoiceSharing] queue record count unmeasurable reason=\(error) admission=allowed")
        }
        FileLog.shared.forceFlush()
    }

    /// ORPHANED attempt sidecars removed by the last recovery (spec, orphaned sidecars): retry
    /// stamps and obligations whose recording no longer exists. Counted and named so the removal
    /// is attributable — the owner's queue held nine with no recording behind them.
    private(set) var removedOrphanSidecars = 0
    /// Orphan sidecars whose removal FAILED: reported separately from
    /// successes, because a failed sweep means the retry state is still on disk and the next pass
    /// will try again — the opposite of a silent loss.
    private(set) var failedOrphanSidecars = 0
    /// Removal, reporting success honestly. A missing file counts as removed (the postcondition
    /// "not there" holds); any other error does not.
    private static func removeStraySidecar(_ url: URL, _ fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            guard (error as NSError).domain == NSCocoaErrorDomain,
                (error as NSError).code == NSFileNoSuchFileError
            else { return false }
            return true
        }
    }
    private(set) var orphanSidecarNames: [String] = []

    func readyEntriesReportingUnknownCoverage() -> ReadyDiscovery {
        serialQueue.sync {
            guard (try? establishStoragePolicyLocked()) != nil else { return .unknownCoverage }
            // an absent-entry intent whose retirement failed (e.g. the root
            // barrier after a successful removal) is retried at every serving pass, not only at
            // recovery — the sweeps visit existing entries only, so the reconciler runs here.
            reconcileRefusalIntentsLocked()
            // OWNER-WIDE hold: an unreconciled purge means the on-disk set is not provable, so
            // NOTHING may serve. Reported as unknown coverage (the same all-or-nothing channel
            // every caller already handles), never as an empty known set.
            if revocationHoldLocked {
                return revocationOriginUnknownLocked ? .unknownCoverage : .revocationHeld
            }
            // coverage is all-OR-NOTHING for the owner. Any required check
            // whose outcome is UNKNOWN (listing failure, required-stat failure, required-file
            // read failure, unconfirmable durability) holds serving for the WHOLE root — one
            // inaccessible entry must not coexist with `.known(others)`.
            let all: [Entry]
            do { all = try strictOwnerCoverageLocked() } catch { return .unknownCoverage }
            var ready: [Entry] = []
            // DIAGNOSTIC (epoch investigation): WHY an entry that the legacy path reports as ready
            // is absent here. Both paths must agree about the same disk, so any disagreement is a
            // real inconsistency rather than a scheduling artifact.
            var excluded: [String] = []
            for entry in all {
                // PER-ENTRY refusal hold: an entry with a durable deletion
                // intent never serves, and the serving sweep retries its SCOPED purge
                // automatically. Failure holds only THIS entry — the others keep serving.
                // the proven-stage-absence protection applies to
                // retries too — an intent-bearing entry with an active publication stage (or
                // an UNKNOWN stage status) is never deleted.
                let heldIntentKind = intentDiscovery(deletionIntentPathLocked(entry.name))
                if refusedIntentNamesLocked.contains(entry.name) || heldIntentKind != .absent {
                    if heldIntentKind == .failure {
                        lastDiscoveryDiagnostic = "intent stat failed for \(entry.name)"
                        return .unknownCoverage
                    }
                    let stageKind = Self.statKind(of: entryDirectoryLocked(for: entry)
                        .appendingPathComponent(Self.stageName))
                    guard stageKind == .absent else {
                        if stageKind == .failure { return .unknownCoverage }
                        // Active stage under a deletion intent: never deleted; excluded.
                        excluded.append("\(entry.name):refusal-held(active-stage)")
                        continue
                    }
                    do { try purgeRefusedEntryLocked(entry, cause: "held-retry") }
                    catch {
                        refusedIntentNamesLocked.insert(entry.name)
                        excluded.append("\(entry.name):refusal-held")
                        continue
                    }
                    excluded.append("\(entry.name):purged(refused-retry)")
                    continue
                }
                let state: EntryState
                do { state = try entryStateLocked(at: entry) } catch {
                    // PER-ENTRY, not owner-WIDE.
                    // One unreadable entry returning `.unknownCoverage` here stopped serving for
                    // every entry — a single corrupt directory became a queue-wide hold, which is
                    // the wedge in another costume. The entry is excluded and logged; its siblings
                    // keep serving.
                    FileLog.shared.addMessage(
                        "[VoiceSharing] serving entry=\(entry.name) reason=state-unreadable disposition=skip-entry")
                    FileLog.shared.forceFlush()
                    excluded.append("\(entry.name):state-unreadable")
                    continue
                }
                switch state {
                case .bound:
                    // THE only case that may fall through to the age check and ready.append.
                    break
                case .unready:
                    //, corrected item 1: a capture the
                    // client cannot bind is STILL served. "Retained but never sent" is a hold with
                    // extra steps — the first version of this branch excluded it here and only
                    // logged `send-unbound`, which established no upload path at all. The server
                    // owns the verdict on the bytes, so the entry falls through to `ready` exactly
                    // like a bound one; only its identity/provenance read is skipped downstream.
                    break
                case .disqualified:
                    // only A DECIDED rejection may delete (spec, old-cap resume). The marker now
                    // records WHY; the marker used to say only "revoked", so this branch deleted a
                    // cap-quarantined recording on update exactly as it deletes a server-refused
                    // one. A cause that does not authorise deletion is never
                    // purged here: it is excluded and left intact.
                    // ABSENCE or an unreadable marker is not A DECIDED rejection (reviewer
                    // 3dd6876c item 1). The entry was classified `.disqualified` a moment ago, so
                    // a cause that cannot now be READ is a state change we cannot adjudicate:
                    // fail closed on coverage rather than deleting a recording on a guess.
                    guard let cause = disqualificationCauseLocked(
                        at: entryDirectoryLocked(for: entry)) else {
                        lastDiscoveryDiagnostic = "disqualification cause unreadable for \(entry.name)"
                        return .unknownCoverage
                    }
                    guard cause.authorisesDeletion else {
                        excluded.append("\(entry.name):notDeletable(\(cause.rawValue))")
                        continue
                    }
                    // A durable publication.failed intent WITHOUT an active publication stage
                    // is a PERMANENT server refusal (or a purge whose removal never completed):
                    // deletes it.: entryStateLocked
                    // returns.disqualified on the failed marker before checking the stage, so
                    // the stage absence must be PROVEN here — an entry carrying both markers
                    // (failed intent + still-active stage) is never deleted, and a stage stat
                    // failure is UNKNOWN coverage, not a deletion.
                    let stageKind = Self.statKind(of: entryDirectoryLocked(for: entry)
                        .appendingPathComponent(Self.stageName))
                    guard stageKind == .absent else {
                        if stageKind == .failure { return .unknownCoverage }
                        excluded.append("\(entry.name):notBound(\(state))")
                        continue
                    }
                    do { try purgeRefusedEntryLocked(entry, cause: "server-refusal") }
                    catch {
                        refusedIntentNamesLocked.insert(entry.name)
                        excluded.append("\(entry.name):refusal-held(server-refusal)")
                        continue
                    }
                    excluded.append("\(entry.name):purged(server-refusal)")
                    continue
                case .incomplete:
                    // incomplete entries must never reach the serving
                    // gate — a prepared-but-unfinalized entry with a fresh created.at is not
                    // ready. Retained, never served, never deleted here.
                    excluded.append("\(entry.name):notBound(\(state))")
                    continue
                }
                // CONFIRMED durability, PER entry. This
                // used to be assumed: `strictOwnerCoverageLocked` verified every entry and threw if
                // any failed, so reaching here "meant it held". That authority is now per-entry and
                // no longer throws, so the check must happen HERE, for this entry only — otherwise
                // an unconfirmable entry is silently served.
                guard (try? confirmDurableLocked(directory: entryDirectoryLocked(for: entry))) != nil
                else {
                    excluded.append("\(entry.name):unconfirmed-durability")
                    continue
                }
                // ATTRIBUTABILITY, PER entry: an owner file that exists but cannot be READ means
                // this entry's account is unknown, so it cannot be attributed to anyone and must
                // not be served. Only THIS entry — a sibling with a readable owner keeps serving.
                if currentIdentityLocked != nil, (try? ownerScopeLocked(for: entry)) == nil {
                    // `ownerScopeLocked` throws for unreadable/non-regular storage and returns
                    // `.absent` only for a genuinely missing file, so a fault can never be
                    // mistaken for "not attributed yet".
                    excluded.append("\(entry.name):owner-unreadable")
                    continue
                }
                // ONE age rule shared with the count signature and the change version
                // a future (skewed) date is not fresh, and an unreadable
                // date cannot claim freshness.
                if isWithinAgeBoundLocked(entry) {
                    ready.append(entry)
                } else {
                    let age = markerAgeLocked(entry).map { String(format: "%.0f", $0) } ?? "unreadable"
                    excluded.append("\(entry.name):age(\(age)s of max \(Int(Self.maxEntryAge)))")
                }
            }
            lastDiscoveryDiagnostic = "all=\(all.count) ready=\(ready.count) "
                + "excluded=[\(excluded.joined(separator: ", "))]"
            return .known(ready.sorted { lhs, rhs in
                let lDate = creationInstantLocked(in: entryDirectoryLocked(for: lhs)) ?? .distantPast
                let rDate = creationInstantLocked(in: entryDirectoryLocked(for: rhs)) ?? .distantPast
                if lDate == rDate { return lhs.name < rhs.name }
                return lDate < rDate
            })
        }
    }

    func readyEntries() -> [Entry] {
        serialQueue.sync {
            guard (try? establishStoragePolicyLocked()) != nil else { return [] }
            // retry absent-entry intent reconciliation from serving too.
            reconcileRefusalIntentsLocked()
            // LEGACY serving path also honors the SHARING-OFF hold: an empty
            // list, never a stale one — this path has no unknown-coverage channel.
            // It does not honor the retry hold: a retry hold is
            // unknown bookkeeping, and excluding every recording from serving on it withheld the
            // whole queue from the drain. Unknown retry state is due now.
            guard !revocationHoldLocked else { return [] }
            // The legacy path has no unknown-coverage channel, so it must FAIL closed: if the
            // strict owner authority cannot prove every entry's required state (unreadable
            // ownership included), serve nothing rather than the entries that happen to parse.
            if currentIdentityLocked != nil {
                guard (try? strictOwnerCoverageLocked()) != nil else { return [] }
            }
            // purge permanently refused entries before listing, so the served
            // set and the usage bound never count bytes the record check has rejected or the
            // server has refused for good. Any proven-state uncertainty must fail closed: the
            // sweep serves nothing rather than guessing (the same discipline as coverage).
            // Per-entry refusal holds + automatic scoped retry. The legacy
            // path has no per-entry hold channel, so a HELD entry simply cannot serve here:
            // purge failures leave the entry on disk, excluded from the served list.
            do {
                for entry in try entriesStrictLocked() {
                    // 2+3: intent stat failure => fail closed (serve
                    // nothing); active/unknown stage under an intent => never deleted.
                    let heldIntentKind = intentDiscovery(deletionIntentPathLocked(entry.name))
                    if refusedIntentNamesLocked.contains(entry.name) || heldIntentKind != .absent {
                        // Unconfirmable intent => the entry cannot prove it is not held: hold
                        // only it (per-entry hold) — never an owner-wide stop.
                        if heldIntentKind == .failure { continue }
                        let stageKind = Self.statKind(of: entryDirectoryLocked(for: entry)
                            .appendingPathComponent(Self.stageName))
                        guard stageKind == .absent else {
                            if stageKind == .failure { throw PrepareError.accountingUnavailable }
                            continue // active stage: never deleted; never serves
                        }
                        try? purgeRefusedEntryLocked(entry, cause: "held-retry")
                        continue // purged or still held: either way it never serves here
                    }
                    switch try entryStateLocked(at: entry) {
                    case .unready:
                        // Ruling 2: no local verdict deletes OR holds. It is left in place and it
                        // is still served — the server judges the bytes, not this process. (The
                        // strict path made the same correction; both must agree or the two serving
                        // queries disagree about the same entry.)
                        break
                    case .disqualified:
                        // only A DECIDED rejection may delete (spec, old-cap resume) — the same
                        // authority as the strict path above. A cap quarantine is excluded and
                        // left intact for the recovery resume to serve.
                        //
                        // `nil` means ABSENCE **or an unreadable
                        // marker**, and defaulting it to a deletable cause let a marker that
                        // vanished between classification and this read authorise a deletion.
                        // Deletion now needs an AFFIRMATIVELY read cause, in both paths.
                        let directory = entryDirectoryLocked(for: entry)
                        guard let cause = disqualificationCauseLocked(at: directory) else {
                            throw PrepareError.accountingUnavailable
                        }
                        guard cause.authorisesDeletion else { continue }
                        // deletion requires a durable failed intent
                        // AND proven stage absence (see the strict path above).
                        let stageKind = Self.statKind(
                            of: directory.appendingPathComponent(Self.stageName))
                        guard stageKind == .absent else {
                            if stageKind == .failure { throw PrepareError.accountingUnavailable }
                            continue
                        }
                        try purgeRefusedEntryLocked(entry, cause: "server-refusal")
                    case .bound, .incomplete:
                        continue
                    }
                }
            } catch { return [] }
            // the final legacy list is rebuilt from all complete
            // entries, so it must apply the per-entry refusal hold itself — a bindable held
            // survivor (or one whose intent cannot be confirmed absent) never serves.
            return entriesLocked()
                .filter {
                    !refusedIntentNamesLocked.contains($0.name)
                        && intentDiscovery(deletionIntentPathLocked($0.name)) == .absent
                }
                // A SERVED entry contains A CAPTURE, not necessarily A BINDING (
                // ruling 2). Bind-only filtering silently dropped exactly the unbound captures the
                // strict path had just decided to serve; both queries must agree on servability.
                .filter { isServedEntryLocked(at: $0) }
                // ATTRIBUTABILITY, PER entry — the same rule the strict path applies. Without
                // this the two serving queries disagree about the same disk (the strict one
                // excludes an entry whose owner cannot be read; this one served it).
                .filter {
                    currentIdentityLocked == nil || (try? self.ownerScopeLocked(for: $0)) != nil
                }
                // Exposure also requires CONFIRMED durability, not just a structurally valid marker:
                // after an uncertain transition a marker may be visible without durable backing.
                .filter { (try? self.confirmDurableLocked(directory: self.entryDirectoryLocked(for: $0))) != nil }
                // ONE age rule for the whole type (reconfirmed by the clock-ordering
                // regression): the served set must use the SAME immutable `created.at` rule as
                // `readyEntriesReportingUnknownCoverage`, not the marker's wall-clock mtime. The two
                // disagreed — mtime is stamped from real time at publication, so under a different
                // clock the legacy path served an entry the discovery had excluded, and the count
                // and the served set described different disks.
                .filter { isWithinAgeBoundLocked($0) }
                .sorted { lhs, rhs in
                    let lDate = modificationDateLocked(of: rootDirectory.appendingPathComponent(lhs.name))
                    let rDate = modificationDateLocked(of: rootDirectory.appendingPathComponent(rhs.name))
                    if lDate == rDate { return lhs.name < rhs.name }
                    return lDate < rDate
                }
        }
    }

    /// Read-only identity of a prepared entry, re-derived from its OWN persisted bytes. The
    /// uploader uses this to check a receipt against what was actually queued — never against a
    /// value carried in memory that may not match disk.
    func boundIdentity(of entry: Entry) throws -> VoiceSharingRecordBinding.BoundEntry {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            return try boundIdentityLocked(of: entry)
        }
    }

    /// Lock-held variant: REENTRANT-SAFE. `admitAttempt` already runs inside `serialQueue`, so it
    /// must call this rather than the public entry point (calling `sync` from inside the same
    /// serial queue deadlocks, which is exactly what a crash on first use showed).
    private func boundIdentityLocked(of entry: Entry) throws
        -> VoiceSharingRecordBinding.BoundEntry {
        let directory = try validatedEntryDirectoryLocked(entry)
        let metadata = try Data(contentsOf: directory.appendingPathComponent(Self.metadataName))
        let audio = try Data(contentsOf: directory.appendingPathComponent(Self.audioName))
        return try VoiceSharingRecordBinding.bind(envelope: metadata, audio: audio)
    }

    /// Attempts already consumed for this entry (durable count, survives restart).
    func attemptNumber(for entry: Entry) throws -> Int {
        try serialQueue.sync { try attemptCountLocked(for: entry) }
    }

    func metadata(of entry: Entry) throws -> Data {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            return try Data(contentsOf: try validatedEntryDirectoryLocked(entry).appendingPathComponent(Self.metadataName))
        }
    }

    func audio(of entry: Entry) throws -> Data {
        try serialQueue.sync {
            try establishStoragePolicyLocked()
            return try Data(contentsOf: try validatedEntryDirectoryLocked(entry).appendingPathComponent(Self.audioName))
        }
    }

    /// Deletes the entire entry: audio, metadata and marker leave the disk.
    func remove(_ entry: Entry) throws {
        try serialQueue.sync {
            defer { bumpHoldGenerationForContentChange() }
            _ = try validatedEntryDirectoryLocked(entry)
            try fileManager.removeItem(at: entryDirectoryLocked(for: entry))
            // DIAGNOSTIC (content-free): the only deliberate purge of complete recordings.
            // Every purge names its cause, so a consented recording never disappears unexplained.
            FileLog.shared.addMessage(
                "[VoiceSharing] queue removal reason=explicit-purge entry=\(entry.name) removed=true")
                // FORCE the flush (FileLog buffers 100 entries): a removal line must be on disk
                // before the process can be terminated, or the diagnosis dies with it.
                FileLog.shared.forceFlush()
        }
    }

    ///: a recording the server refuses permanently, or
    /// that the client's own record check rejects, is deleted from the queue AT ONCE by routing
    /// it through the SAME reconciled removal machinery as the owner-wide consent purge
    /// (`reconciledRemovalLocked`: durable intent before mutation, mark-then-remove, survivor
    /// re-disqualification, root barrier, intent retired only after full reconcile) — BOUNDED
    /// to this one entry, with a PER-ENTRY hold: a refusal never sets the owner-wide hold, and
    /// its failure never blocks other entries from serving.
    private func purgeRefusedEntryLocked(_ entry: Entry, cause: String) throws {
        let name = entry.name
        let outcome = reconciledRemovalLocked(
            targets: [name],
            intentPath: deletionIntentPathLocked(name),
            removalReason: "record-refused-purge cause=\(cause)",
            setHold: { held, _ in
                if held { refusedIntentNamesLocked.insert(name) }
                else { refusedIntentNamesLocked.remove(name) }
            })
        guard case .reconciled = outcome else {
            refusedIntentNamesLocked.insert(name) // KNOWN: the intent is on disk
            throw PrepareError.accountingUnavailable
        }
        bumpHoldGenerationForContentChange()
    }

    /// LIVE expiry.
    ///
    /// Retention used to be VISIBILITY-only in a running process: `isWithinAgeBoundLocked` hid an
    /// entry past `maxEntryAge`, so it stopped serving and stopped uploading, but its bytes stayed
    /// on disk until a reconstruction swept them. A long-lived process (an app that stays resident,
    /// as the sim one does) would therefore hold expired recordings forever — retention promised
    /// "deleted", not "invisible".
    ///
    /// This removes them through the SAME reconciled path every other per-entry removal uses:
    /// durable deletion intent → disqualify (prove it can never serve again) → remove → retire the
    /// intent with a root barrier. Nothing here is a new bespoke protocol, and a failure leaves the
    /// standard per-entry hold so the ordinary sweeps retry it — never a silent skip.
    ///
    /// A FUTURE or UNREADABLE instant is not expired: it is an unresolved age, which retention may
    /// not act on (deleting on unreadable state is the one irreversible mistake available here).
    @discardableResult
    func expireAgedOutEntries() -> Int {
        serialQueue.sync { expireAgedOutEntriesLocked() }
    }

    private func expireAgedOutEntriesLocked() -> Int {
        var expired = 0
        // STORAGE policy first: the age reader needs it, and an entry cannot be judged before the
        // root it lives under is known to be the one we own.
        guard (try? establishStoragePolicyLocked()) != nil else {
            FileLog.shared.addMessage(
                "[VoiceSharing] queue expiry deferred: storage policy unavailable")
            FileLog.shared.forceFlush()
            return 0
        }
        for entry in entriesLocked() {
            // A malformed name is not an entry, and the age reader is the ONE age rule used by
            // serving and by the diagnostic count — retention must not invent a second one.
            guard UUID(uuidString: entry.name) != nil else { continue }
            guard let age = markerAgeLocked(entry) else { continue } // unresolved age: not expired
            // AT the bound means EXPIRED: a recording "not accepted
            // within seven days of capture" is deleted seven days after capture, not a second
            // later. Serving keeps `<=` (the instant it stops serving is the instant it is
            // deleted), so the two rules meet exactly and neither a gap nor an overlap exists.
            guard age >= Self.maxEntryAge else { continue }
            // DO not ask `isCompleteEntryLocked` HERE: it applies the SAME age bound and classifies
            // an expired entry as `.incomplete` — the very state this sweep exists to remove. Asking
            // it made every expired entry invisible to retention (found by the red control: age
            // 604801s, "skip incomplete"). The structural evidence below is the honest question:
            // is this a PUBLISHED recording (marker present, no disqualifier), or abandoned work?
            let directory = entryDirectoryLocked(for: entry)
            // DESTRUCTIVE expiry needs proven absence. `!=.present`
            // admitted `.failure` — an UNREADABLE stage or disqualifier — so a recording whose
            // state could not be read was deleted on the assumption that the evidence against
            // deletion was missing. Only `.present` (never published / already disqualified) and
            // `.absent` (proven) may delete; `stage` unreadable leaves the recording and its charge
            // alone for a later pass.
            guard Self.statKind(of: directory.appendingPathComponent(Self.readyMarkerName))
                == .present else { continue }
            guard Self.statKind(of: directory.appendingPathComponent(Self.failedName))
                == .absent else { continue }
            guard Self.statKind(of: directory.appendingPathComponent(Self.stageName))
                == .absent else { continue }
            do {
                try purgeRefusedEntryLocked(entry, cause: "age-exceeded")
                expired += 1
            } catch {
                // The per-entry hold is set by the purge itself: the ordinary sweeps retry it.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue expiry deferred entry=\(entry.name) reason=purge-failed")
                FileLog.shared.forceFlush()
            }
        }
        return expired
    }

    /// Durable per-entry deletion intent. Written, retired, and discovered by the EXISTING
    /// durable helpers (failureRecordWriter + synchronizer + bounded root listing): discovery
    /// lands in `refusedIntentNamesLocked` at recovery, and the serving sweep retries the
    /// scoped purge for every held entry automatically.
    static let deletionIntentPrefix = "deletion.intent."

    /// Test accessor for the per-entry deletion intent path, so a control can assert the intent was
    /// RETIRED after a live expiry rather than left dangling on disk.
    func expiredIntentPathForTesting(name: String) -> String {
        deletionIntentPathLocked(name).path
    }
    private var refusedIntentNamesLocked: Set<String> = []
    private func deletionIntentPathLocked(_ name: String) -> URL {
        rootDirectory.appendingPathComponent("\(Self.deletionIntentPrefix)\(name)")
    }

    /// Discovers durable per-entry refusal intents into the per-entry hold. Uses the BOUNDED
    /// root listing; a listing failure or overflow cannot account the root, so it falls back to
    /// the owner-wide unknown-origin hold (fail closed, house standard for unaccountable roots).
    /// Explicitly reconciles the discovered refusal intents: PROVEN-ABSENT entry => retire the
    /// durable record (removal + root barrier); retirement failure keeps the hold. Surviving
    /// entries keep their intent and are retried by the serving sweeps through the shared
    /// scoped purge.
    private func reconcileRefusalIntentsLocked() {
        for name in refusedIntentNamesLocked {
            let entry = Entry(root: rootDirectory, name: name)
            guard Self.statKind(of: entryDirectoryLocked(for: entry)) == .absent else { continue }
            let intentPath = deletionIntentPathLocked(name)
            // absence alone is not durable retirement — it is exactly the
            // state left when a prior pass removed the record but its root barrier failed.
            // Visibility is confirmed only by the root barrier; until it succeeds the hold stays.
            if Self.statKind(of: intentPath) == .absent {
                do {
                    try synchronizer(rootDirectory, true)
                    refusedIntentNamesLocked.remove(name)
                    FileLog.shared.addMessage(
                        "[VoiceSharing] queue removal reason=record-refused-intent-retired entry=\(name)")
                    FileLog.shared.forceFlush()
                } catch {
                    FileLog.shared.addMessage(
                        "[VoiceSharing] queue removal reason=record-refused-intent-retire-failed entry=\(name)")
                    FileLog.shared.forceFlush()
                }
                continue
            }
            do {
                try fileManager.removeItem(at: intentPath)
                try synchronizer(rootDirectory, true)
                refusedIntentNamesLocked.remove(name)
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=record-refused-intent-retired entry=\(name)")
                FileLog.shared.forceFlush()
            } catch {
                // Retirement could not be confirmed: keep the hold; the next pass retries.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=record-refused-intent-retire-failed entry=\(name)")
                FileLog.shared.forceFlush()
            }
        }
    }

    private func discoverRefusalIntentsLocked() {
        do {
            // UNBOUNDED: this is discovery. Overflow used to set a
            // REVOCATION hold for the whole queue on a large root — the most damaging form of the
            // Android bug, since it stops serving and draining at once.
            let urls = try listDirectory(rootDirectory, [])
            for url in urls {
                let name = url.lastPathComponent
                guard name.hasPrefix(Self.deletionIntentPrefix) else { continue }
                let entryName = String(name.dropFirst(Self.deletionIntentPrefix.count))
                if UUID(uuidString: entryName) != nil {
                    refusedIntentNamesLocked.insert(entryName) // KNOWN: the intent is on disk
                }
            }
        } catch {
            setRevocationHold(true, originUnknown: true)
        }
    }

    // MARK: Internals (all called on serialQueue)

    private func entryDirectoryLocked(for entry: Entry) -> URL {
        rootDirectory.appendingPathComponent(entry.name, isDirectory: true)
    }

    /// A handle is honored only if it names a directory directly under THIS queue's root and its
    /// name is a single path component this queue could have minted.
    private func validatedEntryDirectoryLocked(_ entry: Entry) throws -> URL {
        guard entry.root == rootDirectory,
            UUID(uuidString: entry.name) != nil, // names this queue could have minted (uppercase UUID)
            !entry.name.contains("/")
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = entryDirectoryLocked(for: entry)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return directory
    }

    /// The queue's OWNED on-disk format for one entry directory: a FLAT set of regular files drawn
    /// from a closed set of names. Accounting is therefore bounded by `knownNames.count` stat calls
    /// per entry, not by whatever happens to be in the directory.
    ///
    /// Anything else — nested directories, unknown files, symlinks — is outside the owned format and
    /// makes the footprint unknowable. That is a refusal, not an invitation to enumerate: an
    /// attacker-controlled or debris directory must not be able to inflate or hide usage.
    /// not bounded by a fixed name set: the UUID suffix permits arbitrarily many such names, so a
    /// bounded number of files can become an unbounded number of temporary names. Cleanup therefore
    /// operates under an explicit entry budget (below) and fails closed when it is exceeded, rather
    /// than claiming a bound it does not have.
    private func cleanupTemporaryMarkersLocked(in directory: URL) {
        // Bounded discovery of our own temporaries. If the directory overflows the cap we simply do
        // not clean: the files stay on disk. Cleanup never tidies less than it can see, and a failed
        // removal leaves the file in place rather than being reported as reclaimed space.
        guard let listed = try? listDirectoryBounded(directory, [], Self.maxDirectoryEntries),
              !listed.overflowed else { return }
        for file in listed.urls {
            let name = file.lastPathComponent
            guard name.hasPrefix(Self.temporaryMarkerPrefix),
                  UUID(uuidString: String(name.dropFirst(Self.temporaryMarkerPrefix.count))) != nil
            else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func countEntriesLocked() -> Int {
        entriesLocked().count
    }

    private func entriesLocked() -> [Entry] {
        // Lenient variant for read paths that must not fail (recovery, listing). The ADMISSION count
        // must not use this: an unreadable root would then look like an empty queue.
        (try? entriesStrictLocked()) ?? []
    }

    /// Enumerates entry directories and PROPAGATES a root listing failure. Used by accounting: an
    /// unreadable root must refuse admission, never read as "nothing stored".
    private func entriesStrictLocked() throws -> [Entry] {
        let contents: [URL]
        do {
            // DISCOVERY is unbounded. A bound here was the Android bug in
            // iOS clothes: an inherited over-cap queue — the Pixel had 104 records — listed MORE
            // names than the bound, so discovery refused, and a queue that cannot be discovered
            // cannot count, serve or drain. It could never get back under the cap, because getting
            // under the cap requires draining. Discovery, counting and serving therefore read the
            // whole listing; only the destructive sweep is bounded (`sweptEntriesLocked`), and a
            // deferred sweep is logged rather than silently skipped.
            contents = try listDirectory(rootDirectory, [])
        } catch {
            throw PrepareError.accountingUnavailable
        }
        return contents
            .filter { $0.hasDirectoryPath }
            .map { Entry(root: rootDirectory, name: $0.lastPathComponent) }
    }

    /// The immutable admission instant recorded at prepare, or nil when absent/unparseable.
    ///
    /// Bounded read: the instant is a short decimal string, so an oversized file is a corrupt or
    /// foreign object, not a large time. Size is checked from attributes before the content is
    /// loaded, so a huge file cannot be read into memory to discover it is not a timestamp.
    private func creationInstantLocked(in directory: URL) -> Date? {
        guard let seconds = creationSecondsLocked(in: directory) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The stored admission instant AS STORED: raw seconds since 1970, unconverted. Age arithmetic
    /// must use this form — see `markerAgeLocked` for why the `Date` round-trip is not safe.
    /// AGE_RESET counter (spec: untrusted age, Android parity). Counted, never silent.
    private(set) var ageResetCount = 0
    var ageResetCountForTesting: Int { serialQueue.sync { ageResetCount } }

    /// THE untrusted-AGE rule: a MISSING, UNREADABLE or FUTURE capture instant on an otherwise
    /// complete recording is RESET to now — persisted, counted with a reason line — and the
    /// recording is SERVED.
    ///
    /// The previous doctrine was "never expired", which protected the recording from a wrong
    /// deletion but kept a future-dated entry FOREVER: it never served and never aged out, so it sat
    /// in the queue permanently with no way out. A clock that moved (or a poisoned instant) must not
    /// be able to strand a recording, so the instant is repaired instead of honoured.
    ///
    /// This is a REPAIR, not a licence to serve arbitrary state: it applies only to an entry that is
    /// structurally complete (its audio, metadata, marker and stage have already been validated by
    /// the caller), and only to the instant. A failed write still serves the entry with now in
    /// memory and retries at the next recovery — refusing to serve because the repair could not be
    /// persisted would reintroduce the stranding.
    /// RESET instants kept in memory. A failed disk write used to leave
    /// nothing behind: `markerAgeLocked` then recomputed a FRESH zero from the still-invalid disk
    /// value on every call, so serving and ageing disagreed (the served set read the invalid value
    /// and excluded the entry) and retention never advanced. One instant per entry, chosen once and
    /// reused, is what makes "served now, ages from now" true under a write fault.
    private var resetInstantsLocked: [String: TimeInterval] = [:]

    @discardableResult
    private func resetUntrustedAgeLocked(_ entry: Entry, observed: String) -> Bool {
        let directory = entryDirectoryLocked(for: entry)
        // ONE instant per entry: a repeat repair of the same entry reuses the first choice, so the
        // age advances monotonically instead of restarting at zero on every read.
        let isFirstRepair = resetInstantsLocked[entry.name] == nil
        let now = resetInstantsLocked[entry.name] ?? clock().timeIntervalSince1970
        resetInstantsLocked[entry.name] = now
        // ONE repair, ONE count: AGE_RESET counts ENTRIES whose instant was replaced, not every read
        // that re-derives it. Several paths consult the age within one pass (classification,
        // serving, retention), and counting each turned one repair into three.
        if isFirstRepair { ageResetCount += 1 }
        // DIAGNOSTIC (content-free): an instant was rewritten. Without this line a poisoned capture
        // time is indistinguishable from one that was always correct. Logged ONCE per repair for the
        // same reason the counter is: the same entry is read by several paths in one pass.
        if isFirstRepair {
            FileLog.shared.addMessage(
                "[VoiceSharing] age reset reason=\(observed) entry=\(entry.name)")
            FileLog.shared.forceFlush()
        }
        do {
            // THROUGH the injectable writer: the persistence fault must
            // be drivable, or the in-memory fallback below cannot be shown to work. `String.write`
            // reached the filesystem directly and no injection point could fail it.
            try persistResetInstantLocked(now, for: entry)
            // PERSISTED — BUT the memory copy stays. Removing it re-exposed the entry to a fresh
            // repair whenever a later read found the value untrusted (a file replaced under a
            // different clock, a re-stat), which double-counted AGE_RESET and re-chose the instant.
            // The in-memory value is the SAME value just written, so keeping it cannot disagree with
            // disk; recovery clears it only after re-reading a trusted on-disk instant.
            return true
        } catch {
            // SERVE and age from the in-MEMORY instant. The disk value stays untrusted, so
            // `markerAgeLocked` keeps returning THIS instant (not a fresh zero), and the next
            // recovery retries the write.
            FileLog.shared.addMessage(
                "[VoiceSharing] age reset persist-failed entry=\(entry.name) "
                    + "serving-from-memory-instant")
            FileLog.shared.forceFlush()
            return false
        }
    }

    /// Writes a chosen reset instant to the entry's sidecar. Shared by the first repair and by the
    /// recovery retry so both write the SAME value through the SAME injectable seam.
    private func persistResetInstantLocked(_ instant: TimeInterval, for entry: Entry) throws {
        let directory = entryDirectoryLocked(for: entry)
        let url = directory.appendingPathComponent(Self.createdName)
        // REPLACE, not overwrite: an oversized sidecar, or one that is not a regular
        // file at all, cannot be truncated into a valid one. only those shapes are removed first —
        // an ordinary file is written over in place, because remove-then-write would lose the age
        // outright if the write then failed, turning a repairable sidecar into a missing one.
        let attributes = fileSizeIfRegularLocked(at: url)
        if attributes?.isRegular != true {
            if (try? FileManager.default.removeItem(at: url)) == nil,
               Self.statKind(of: url) != .absent {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try failureRecordWriter(url, Data(String(instant).utf8))
    }

    /// THE effective instant: what this instance will ACT on for an entry, ignoring nothing.
    ///
    /// Precedence: an in-memory reset (chosen once, possibly not yet persisted) wins, then a
    /// trusted on-disk instant, then a repair performed now. `nil` means the instant could not be
    /// established at all (an oversized/corrupt sidecar), which is an UNKNOWN age — not a reason to
    /// delete or to refuse a structurally valid recording.
    private func effectiveInstantLocked(_ entry: Entry) -> TimeInterval? {
        if let unpersisted = resetInstantsLocked[entry.name] {
            // RETRY the pending write here. Every path that
            // needs the age comes through this accessor, so retrying at exactly one of them
            // (recovery) meant an entry whose sidecar was still missing was never written again by
            // serving, retention or classification — the fallback lived until the process died.
            // The written instant is the one already chosen, never a new one.
            if (try? persistResetInstantLocked(unpersisted, for: entry)) != nil {
                resetInstantsLocked.removeValue(forKey: entry.name)
            }
            return unpersisted
        }
        switch captureInstantReadingLocked(entry) {
        case .trusted(let age):
            // A trusted on-disk instant SUPERSEDES any memory copy: it is the durable authority and
            // the repair has been completed, so the entry leaves the pending set for good.
            resetInstantsLocked.removeValue(forKey: entry.name)
            return clock().timeIntervalSince1970 - age
        case .untrusted(let reason):
            resetUntrustedAgeLocked(entry, observed: reason)
            return resetInstantsLocked[entry.name] ?? clock().timeIntervalSince1970
        }
    }

    /// RECOVERY-SIDE repair: fix an untrusted instant on a recording that is otherwise intact,
    /// before recovery classifies anything by age. Structural evidence is checked without the age
    /// rule (marker present, not disqualified, audio and metadata readable and binding), so the one
    /// thing being repaired cannot be the thing being judged.
    ///
    /// A recording that is genuinely incomplete is left alone: recovery keeps its existing
    /// treatment, and no instant is invented for work that never became a recording.
    private func repairUntrustedAgeOnRecoveryLocked(_ entry: Entry, directory: URL) {
        // A PENDING fallback is retried, not skipped. The
        // reading reports an in-memory reset as `.trusted`, so recovery used to return here and the
        // write was never retried — the fallback became permanent for the life of the process. The
        // retry keeps the ORIGINAL chosen instant, so the recording does not get a fresh lifetime
        // every launch.
        switch captureInstantReadingLocked(entry) {
        case .trusted: return
        case .untrusted: break
        }
        guard Self.statKind(of: directory.appendingPathComponent(Self.readyMarkerName))
            == .present else { return }
        guard Self.statKind(of: directory.appendingPathComponent(Self.failedName))
            == .absent else { return }
        guard Self.statKind(of: directory.appendingPathComponent(Self.stageName))
            == .absent else { return }
        // The recording's OWN content must be present and binding: a marker over unreadable audio is
        // not a recording to repair, it is debris.
        guard let audioSize = fileSizeIfRegularLocked(at: directory.appendingPathComponent(Self.audioName)),
            audioSize.isRegular, audioSize.bytes > 0,
            audioSize.bytes <= Self.maxEntryAudioBytes,
            let metadataSize = fileSizeIfRegularLocked(at: directory.appendingPathComponent(Self.metadataName)),
            metadataSize.isRegular, metadataSize.bytes > 0,
            metadataSize.bytes <= Self.maxMetadataBytes,
            let audioData = try? Data(contentsOf: directory.appendingPathComponent(Self.audioName)),
            let metadataData = try? Data(contentsOf: directory.appendingPathComponent(Self.metadataName)),
            (try? VoiceSharingRecordBinding.bind(envelope: metadataData, audio: audioData)) != nil
        else { return }
        let reason: String
        switch captureInstantReadingLocked(entry) {
        case .trusted: return
        case .untrusted(let why): reason = why
        }
        resetUntrustedAgeLocked(entry, observed: reason)
    }

    /// How this entry's capture instant reads: trusted (with its age), or untrusted for a stated
    /// reason. The reason is what the AGE_RESET line records.
    private enum CaptureInstantReading {
        case trusted(TimeInterval)
        case untrusted(String) // "missing" | "empty" | "unreadable" | "future" | "oversized"
    }

    /// Reads the instant and classifies it WITHOUT repairing: the caller decides, because a
    /// structurally INCOMPLETE entry must keep its existing treatment (recovery's job, not a reset).
    private func captureInstantReadingLocked(_ entry: Entry) -> CaptureInstantReading {
        // A served-from-memory reset is TRUSTED for this instance: the instant is known, it is just
        // not yet on disk.
        if let unpersisted = resetInstantsLocked[entry.name] {
            return .trusted(max(0, clock().timeIntervalSince1970 - unpersisted))
        }
        let directory = entryDirectoryLocked(for: entry)
        let url = directory.appendingPathComponent(Self.createdName)
        guard Self.statKind(of: url) == .present else { return .untrusted("missing") }
        // AN OVERSIZED instant is corrupt, not untrusted: a file past the bound is a foreign or
        // damaged object, and repairing it would adopt its directory as a recording instead of
        // letting recovery remove it. Its contents are never read (the bound is checked from
        // attributes), and the entry stays refused.
        // AN OVERSIZED or non-REGULAR sidecar is just another untrusted age (which
        // amends f2d68c23 for age sidecars only). It is never read — the bound is checked from
        // attributes — and it is REPLACED rather than honoured, held or refused. An age sidecar is
        // not part of a recording's validity or of owner coverage; the owner is never held for one.
        let attributes = fileSizeIfRegularLocked(at: url)
        guard let attributes, attributes.isRegular, attributes.bytes > 0,
            attributes.bytes <= Self.maxCreationInstantBytes else {
            return .untrusted(attributes?.isRegular == true ? "oversized" : "not-a-regular-file")
        }
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8),
            let seconds = TimeInterval(text), seconds.isFinite
        else { return .untrusted("unreadable") }
        let age = clock().timeIntervalSince1970 - seconds
        // A FUTURE instant is not "very fresh": it is a wrong instant, and honouring it strands the
        // entry (never served, never aged out). A NEGATIVE age is that case, and the epoch-space
        // subtraction below makes a genuinely-now instant read exactly zero.
        return age < 0 ? .untrusted("future") : .trusted(age)
    }

    private func creationSecondsLocked(in directory: URL) -> TimeInterval? {
        let url = directory.appendingPathComponent(Self.createdName)
        guard let size = fileSizeIfRegularLocked(at: url),
            size.isRegular, size.bytes > 0, size.bytes <= Self.maxCreationInstantBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8),
            let seconds = TimeInterval(text), seconds.isFinite
        else { return nil }
        // BOTH representations must be present: an entry without its immutable instant cannot have
        // its lifetime bounded, so it is incomplete rather than "fresh".
        return seconds
    }

    /// Complete-entry validation, FAIL-CLOSED, STAT-FIRST and BOUND:
    /// * sizes and file kinds from attributes before any content is loaded;
    /// * a recorded publication failure disqualifies the entry outright;
    /// * the age bound uses the IMMUTABLE creation instant, never the marker's mtime;
    /// * readiness requires the persisted envelope to BIND to the audio bytes through the shared
    /// record/WAV authority (canonical record digest, capture/epoch identity, real PCM16 mono
    /// 16 kHz header) — not merely a matching digest field.
    // No in-process quarantine state exists. It cannot stand as evidence of non-publication: an
    // instance that remembers "I did not publish this" can disagree with a fresh instance that sees
    // the same durable state, and the contract requires both to agree. Ambiguity is therefore
    // expressed by `uncertainEntriesLocked` (a hint only) and resolved from disk.

    ///: `fileExists`/`try?` collapse I/O failure into absence, so one
    /// inaccessible entry could coexist with `.known(otherEntries)`. The strict state read
    /// distinguishes: REQUIRED-check failure (unknown) throws; genuine absence or a durable
    /// disqualifier classifies the entry.
    private enum EntryState {
        case bound(VoiceSharingRecordBinding.BoundEntry)
        case disqualified
        /// A CAPTURE holding audio that cannot be bound locally: its metadata is unreadable, or a
        /// record check rejects it. forbids a local verdict here — there is
        /// no local "invalid", only the server's final refusal — so this is not debris and not a
        /// deletion cause. It counts toward the record limit, expires by file time, and is offered
        /// to the uploader so the server can decide. `flatBound` is nil, so nothing that requires a
        /// binding may touch it.
        case unready
        case incomplete

        var flatBound: VoiceSharingRecordBinding.BoundEntry? {
            if case .bound(let b) = self { return b }
            return nil
        }
    }

    private func entryStateLocked(at entry: Entry) throws -> EntryState {
        let directory = entryDirectoryLocked(for: entry)
        let marker = directory.appendingPathComponent(Self.readyMarkerName)
        let audioURL = directory.appendingPathComponent(Self.audioName)
        let metadataURL = directory.appendingPathComponent(Self.metadataName)

        func requiredFileKind(_ url: URL) throws -> StatKind {
            switch Self.statKind(of: url) {
            case .failure: throw PrepareError.accountingUnavailable
            case .absent: return .absent
            case .present: return .present
            }
        }
        func readIfPresent(_ url: URL) throws -> Data? {
            // Absent => nil (classified by the caller); present-but-unreadable => UNKNOWN.
            guard try requiredFileKind(url) == .present else { return nil }
            guard let data = try? Data(contentsOf: url) else {
                throw PrepareError.accountingUnavailable
            }
            return data
        }

        // Disposal/disqualification intents are DURABLE state: present => disqualified;
        // stat failure => unknown coverage (never "absent" by collapse).
        if try requiredFileKind(directory.appendingPathComponent(Self.failedName)) == .present {
            return .disqualified
        }
        // A recorded publication stage means publication began. Until the marker is confirmed and
        // the stage cleared, the entry is not trustworthy — this is the discriminator that makes
        // "marker present with no disqualifier" unreachable for a restart.
        if try requiredFileKind(directory.appendingPathComponent(Self.stageName)) == .present {
            return .disqualified
        }
        guard try requiredFileKind(marker) == .present else { return .incomplete }
        // THE recording is validated independently of its age sidecar (reviewer, second round on
        // 444cde13f). `created.at` no longer participates in completeness at all: not its absence,
        // not its emptiness, not its size, not its readability. Every one of those used to classify
        // or throw here, and recovery DELETES or holds what this returns — so a perfectly good
        // recording was destroyed, or its coverage withheld, purely because its age could not be
        // read. The age is repaired (see `markerAgeLocked` / `repairUntrustedAgeOnRecoveryLocked`)
        // and, when it cannot be persisted, served from the in-memory instant. If neither is
        // available the age bound is unknown and the entry is not served by the age rule — but it
        // is still a valid recording, and retention still decides its fate, rather than a stat.
        if let effective = effectiveInstantLocked(entry) {
            let createdAt = Date(timeIntervalSince1970: effective)
            // FUTURE instants are recovery'S BUSINESS too: classifying them here let a caller-past
            // clock — a lease control seeding an expired lease, a device whose clock moved back —
            // turn a good entry into debris recovery DELETES. The reset repairs the instant; this
            // classifier only applies the age BOUND, and only in the direction it can trust.
            guard clock().timeIntervalSince(createdAt) <= Self.maxEntryAge else { return .incomplete }
        }
        // NO LOCAL "INVALID" VERDICT. This block used to classify an entry
        // INCOMPLETE when its metadata was oversized, empty or unreadable — and recovery DELETES
        // incomplete entries. So a size or parse opinion held locally could destroy a recording the
        // server had never seen. Now the shape only decides whether the entry is BOUND; the bytes
        // are sent either way and the server's final refusal is what deletes. Only the absence of
        // audio or metadata is a missing recording — there is nothing to send.
        let audioKind = try requiredFileKind(audioURL)
        let metadataKind = try requiredFileKind(metadataURL)
        if audioKind == .absent || metadataKind == .absent { return .incomplete }
        // Audio exists but metadata does not read: still a capture holding audio. It counts toward
        // the record limit and expires by file time (ruling 2), so it is COMPLETE-unbound rather
        // than debris — `unready` carries the bytes to the uploader without a binding.
        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw PrepareError.accountingUnavailable
        }
        guard let metadataData = try? Data(contentsOf: metadataURL),
            let bound = try? VoiceSharingRecordBinding.bind(envelope: metadataData, audio: audioData)
        else {
            FileLog.shared.addMessage(
                "[VoiceSharing] entry metadata unusable entry=\(entry.name) disposition=send-unbound")
            FileLog.shared.forceFlush()
            return .unready
        }
        return .bound(bound)
    }

    private func boundEntryLocked(at entry: Entry) -> VoiceSharingRecordBinding.BoundEntry? {
        // Lenient wrapper for cleanup/recovery contexts. Coverage-sensitive callers use
        // entryStateLocked.
        (try? entryStateLocked(at: entry))?.flatBound
    }

    private func isCompleteEntryLocked(at entry: Entry) -> Bool {
        boundEntryLocked(at: entry) != nil
    }

    /// may this entry be offered to the server?
    ///
    /// A bound entry is served, as always. So is an entry whose record exists but no longer agrees
    /// with itself — a digest mismatch or an unparseable record: those are exactly the cases the
    /// ruling says must be SENT, because only the server may issue the final refusal that deletes
    /// them. `isCompleteEntryLocked` alone dropped them, which made "retained for the uploader" a
    /// promise the serving path never kept.
    ///
    /// It is deliberately not "any directory with audio". The binding also enforces the audio
    /// representation (float/stereo/rate/truncation) the server's own `wav_validate.ts` mirrors;
    /// a recording that cannot be represented is not one this build may claim to convert, and
    /// serving it would ship bytes no client ever produced. Those keep their existing verdicts.
    private func isServedEntryLocked(at entry: Entry) -> Bool {
        guard entryHoldsAudioLocked(entry) else { return false }
        if isCompleteEntryLocked(at: entry) { return true }
        // Unbound but audio present: served only when the failure is about the RECORD's integrity
        // rather than the audio's representability.
        switch boundFailureLocked(at: entry) {
        case .digestMismatch, .audioDigestMismatch, .malformedJSON, .duplicateKey,
             .nonFiniteNumber, .missingField, .unknownField, .invalidField,
             //, ruling a4b417fc ruling 2: a READABLE pair whose audio is
             // malformed, wrongly sized or not the representation claimed is still a capture the
             // server must judge. The first version of this split excluded these, which was a local
             // invalid verdict — the exact class of gate the ruling removes. Server's final refusal
             // deletes it; only an entry with NO readable pair is held.
             .audioSizeMismatch, .audioSampleCountMismatch, .invalidAudio:
            return true
        case .none:
            return false
        }
    }

    /// The binding failure for an entry, for the servability split above and for diagnostics.
    private func boundFailureLocked(at entry: Entry) -> VoiceSharingRecordBinding.BindingError? {
        do {
            _ = try boundIdentityLocked(of: entry)
            return nil
        } catch let error as VoiceSharingRecordBinding.BindingError {
            return error
        } catch {
            // A READ failure is not a verdict about the record: treat it as not-served rather than
            // guessing which side of the split it belongs to.
            return nil
        }
    }

    /// Result of an error-reporting, no-follow stat. Distinguishes "not there" from "could not
    /// tell", which `fileExists` cannot: it collapses every failure into `false`.
    enum StatKind { case present, absent, failure }

    /// Stats `url` without following symlinks and WITHOUT conflating failure with absence. Only an
    /// actual `ENOENT` yields `.absent`.
    static func statKind(of url: URL) -> StatKind {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        if result == 0 { return .present }
        return errno == ENOENT ? .absent : .failure
    }

    /// (isRegularFile, byte size) via attributes — no content is read.
    private func fileSizeIfRegularLocked(at url: URL) -> (isRegular: Bool, bytes: Int)? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let isRegular = values?.isRegularFile, let bytes = values?.fileSize else { return nil }
        return (isRegular, bytes)
    }

    private func modificationDateLocked(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Recovery: anything under the root that is not a complete entry is removed — abandoned
    /// preparation, foreign directories, malformed entries, stray files. The finite limits are
    /// RE-ESTABLISHED here over what survives: entries past the queue-age bound are removed, and
    /// if more than `maxQueueEntries` complete entries remain (e.g. the ceiling was lowered), the
    /// OLDEST are removed until the count is within bounds. Complete ready entries within bounds
    /// are kept byte-for-byte.
    private func recoverLocked() {
        // A fresh instance re-derives the hold from STORAGE, never from memory (reviewer
        // 35e67a87): an intent file left by an interrupted/failed revocation keeps the owner held
        // across restart, so an unmarked survivor can never be served. Clearing it requires a
        // reconciliation pass that proves every barrier — i.e. a successful purge, not a restart.
        // EXPLICIT required-STAT, not fileExists: `fileExists` collapses
        // "cannot determine" into "absent", which would RESUME serving after an unreadable root.
        // Unknown discovery must hold the whole owner, exactly like every other unknown state.
        // A failed discovery is a hold whose ORIGIN is unknown — it must not be reported as
        // "a revocation failed", which would offer the user a remedy that may not apply.
        switch intentDiscovery(revocationIntentPath) {
        case .present:
            setRevocationHold(true) // KNOWN: the intent was read and is present
        case .absent:
            setRevocationHold(false)
        case .failure:
            setRevocationHold(true, originUnknown: true)
        }
        // The retry hold re-derives the same way: an `attempt.pause.intent` left by a failed
        // not-before barrier keeps admission held across restart until reconciliation.
        switch intentDiscovery(rootDirectory.appendingPathComponent(Self.retryHoldIntentName)) {
        case .present: retryHoldLocked = true
        case .absent: retryHoldLocked = false
        case .failure: retryHoldLocked = true // unknown ⇒ hold
        }
        // DURABLE per-ENTRY refusal intents: discovered into the per-entry
        // hold via the BOUNDED root listing; the serving sweeps retry each held entry's
        // scoped purge automatically.
        refusedIntentNamesLocked.removeAll()
        discoverRefusalIntentsLocked()
        // THE budget is recomputed from what is actually on disk. Every
        // accounting read already walks the entries, so there is no cached total to drift — but
        // the recompute is made EXPLICIT and LOGGED here, at the one point the queue learns its
        // own contents, so a disagreement between belief and disk is attributable instead of
        // silently refusing later admissions.
        recordBudgetFromDiskLocked()
        removedOrphanSidecars = 0
        failedOrphanSidecars = 0
        orphanSidecarNames.removeAll()
        var complete: [(entry: Entry, readyDate: Date)] = []
        for entry in entriesLocked() {
            let directory = entryDirectoryLocked(for: entry)
            // Bounded cleanup of this queue's own stale temporary markers before completeness is
            // judged: a failed replacement can strand one, and leaving it would block admission
            // forever with a name that is ours, not debris.
            cleanupTemporaryMarkersLocked(in: directory)
            // REPAIR before any age-BASED classification. A complete
            // recording whose instant is missing, unreadable or future used to be classified
            // INCOMPLETE here and DELETED — before the repair could ever run, because the repair is
            // guarded on completeness. A startup with a bad age was therefore destructive. The
            // repair runs first, and only over entries whose RECORDING is otherwise intact, so the
            // reset happens before anything judges the entry by its age.
            repairUntrustedAgeOnRecoveryLocked(entry, directory: directory)
            guard isCompleteEntryLocked(at: entry) else {
                // Clarification 7e9606b: a disposal/disqualification intent (`publication.failed`)
                // is DISCOVERED state, not incompleteness — its cleanup deliberately could not
                // complete. The entry is RETAINED: never served (the binding refuses it), still
                // owned and charged by accounting. Deleting it here would erase the failure
                // evidence and let a fresh scan re-admit the content.
                if fileManager.fileExists(atPath: directory.appendingPathComponent(Self.failedName).path) {
                    continue
                }
                // A CAPTURE holding audio is not incomplete. `.unready`
                // means the metadata could not be bound — not that the recording is missing. It is
                // kept: it counts toward the limit, it is offered to the uploader, and the 7-day
                // expiry removes it. Deleting it here would let a local parse opinion destroy a
                // recording the server never saw, which is exactly what the ruling forbids.
                if case .unready = (try? entryStateLocked(at: entry)) ?? .incomplete {
                    continue
                }
                let removed = (try? fileManager.removeItem(at: directory)) != nil
                // DIAGNOSTIC (content-free): recovery DELETES an incomplete entry. An entry that
                // vanishes between runs with no removal line cannot be told from one never written.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue removal reason=incomplete-on-recovery "
                        + "entry=\(entry.name) removed=\(removed)")
                    // FORCE the flush (FileLog buffers 100 entries): a removal line must be on disk
                    // before the process can be terminated, or the diagnosis dies with it.
                    FileLog.shared.forceFlush()
                continue
            }
            // Ordering uses the immutable creation instant; age is already enforced by the
            // completeness check above (which reads the same instant).
            let createdAt = creationInstantLocked(in: directory) ?? .distantPast
            complete.append((entry, createdAt))
        }
        // NO OVER-CAP purge on recovery.
        // This pass DELETED the oldest recordings until the queue fit the 32-record cap. That maps
        // to no allowed gate: the limit governs NEW admissions, and nothing authorises deleting
        // audio the server has never seen. It also made the cap unreachable in the other direction —
        // an inherited over-cap queue (Android's Pixel: 104) was silently truncated at launch
        // instead of drained. An over-cap queue is legal and must be served and drained. The limit
        // reasserts itself naturally because admission refuses new captures while it is exceeded.
        if complete.count > Self.maxQueueEntries {
            FileLog.shared.addMessage(
                "[VoiceSharing] queue over cap records=\(complete.count) ceiling=\(Self.maxQueueEntries) "
                    + "disposition=drain-not-delete")
            FileLog.shared.forceFlush()
        }
        // Stray regular files directly under the root are not entries; remove them so the root
        // stays queue-owned. Discovery here is BOUNDED too: construction must not eagerly
        // materialise an oversized root just because recovery tolerates failures. On overflow we
        // skip cleanup (fail-closed) rather than enumerate past the bound.
        // A DEFERRED sweep must PERFORM no deletion. The
        // first version of this logged "deferred" and then swept the TRUNCATED list anyway, which
        // is worse than not logging: `liveEntries` was built from the prefix, so a retry sidecar
        // whose recording directory sat beyond the bound looked orphaned and was DELETED. Removing
        // live retry state on a partial view is exactly the destructive gate this audit exists to
        // remove, so overflow now returns before anything is removed.
        let listedSweep: (urls: [URL], overflowed: Bool)
        do {
            listedSweep = try listDirectoryBounded(
                rootDirectory, [.isDirectoryKey], Self.maxSweptEntries)
        } catch {
            listedSweep = ([], true) // unlistable: nothing may be deleted either
        }
        if listedSweep.overflowed {
            FileLog.shared.addMessage(
                "[VoiceSharing] sweep deferred reason=over-bound pass=stray-orphans "
                    + "entries=\(listedSweep.urls.count) removed=0")
            FileLog.shared.forceFlush()
        } else {
            let listed = listedSweep
            // WHICH entries still exist, established once: an attempt sidecar is only meaningful
            // while its recording does. Orphans are what is left after an entry was removed, and
            // they were previously kept forever — the owner's queue showed nine of them with no
            // recordings behind them (spec, orphaned sidecars).
            // CANONICAL identities. Entry names are compared as
            // UPPERCASE uuid strings, so a lowercase directory — which `UUID(uuidString:)` reads
            // happily — is the SAME entry. Comparing raw names let such an entry lose its retry
            // stamps and obligations.
            //
            // AND absence must be proven (same item). A failed `resourceValues` lookup used to be
            // read as "not an entry", which DELETED a live entry's retry state on an unreadable
            // fact. An entry whose directory kind cannot be read is treated as ALIVE: the sweep
            // skips it, because the only safe reading of unknown evidence is the one that deletes
            // nothing.
            var liveEntries = Set<String>()      // canonical UUID strings
            var liveEntryNames = Set<String>()   // the SAME identities, as they are spelled on disk
            for item in listed.urls {
                let name = item.lastPathComponent
                guard let canonical = UUID(uuidString: name) else { continue }
                switch (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory {
                case .some(true):
                    liveEntries.insert(canonical.uuidString)
                    liveEntryNames.insert(name)
                case .some(false):
                    continue // a regular FILE named like a UUID: not an entry, not our business
                case .none:
                    // Unreadable facts about a UUID-named item: keep its sidecars.
                    liveEntries.insert(canonical.uuidString)
                    liveEntryNames.insert(name)
                }
            }
            for stray in listed.urls
            where !((try? stray.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) {
                // Lease locks are OWNED root files, not debris: removing one would invalidate the
                // inode live lock holders rely on. Only well-formed names are skipped; anything
                // else is debris as before.
                let name = stray.lastPathComponent
                if name.hasPrefix("attempt.lock."),
                   let index = Int(name.dropFirst("attempt.lock.".count)),
                   index >= 0, index < Self.leaseLockPoolSize {
                    continue
                }
                // Settlement records are the durable intent a crashed owner (or its successor)
                // still needs to reconcile. Deleting one here would erase the only recovery
                // state. Well-formed names are preserved here; `recoverAbandonedSettlements`
                // reconciles and retires them explicitly.
                if name.hasPrefix(Self.settlementRecordName + "."),
                   name.hasSuffix(".json"),
                   Self.parseSettlementName(name) != nil {
                    continue
                }
                // The hold intents ARE the durable evidence for owner-wide holds: recovery reads
                // them into memory, and deleting them here would let a SECOND fresh queue forget
                // the hold. They are reconciled explicitly, never swept.
                if name == Self.retryHoldIntentName || name == Self.revocationIntentName {
                    continue
                }
                // Not-before stamps are DURABLE retry statements, not debris: they are what makes
                // a policy delay apply to a fresh owner after restart. Deleting them here (as this
                // debris sweep used to) silently turned every enforced delay back into an advisory
                // one on the next launch — exactly what the reviewer rejected.
                if name.hasPrefix(Self.notBeforePrefix),
                   let owner = UUID(uuidString: String(name.dropFirst(Self.notBeforePrefix.count))) {
                    // AN ORPHAN is swept: the delay belongs to a recording that is gone, so it can
                    // neither be honoured nor erase anything retryable. Counted and named, because
                    // a silent removal of retry state is indistinguishable from losing it.
                    if liveEntries.contains(owner.uuidString) || liveEntryNames.contains(
                        String(name.dropFirst(Self.notBeforePrefix.count))) { continue }
                    // COUNT what was actually removed. Counting before
                    // the attempt reported a failed removal as a success, which is precisely the
                    // "silently lost retry state" the log exists to rule out.
                    if VoiceSharingUploadQueue.removeStraySidecar(stray, fileManager) {
                        removedOrphanSidecars += 1
                        orphanSidecarNames.append(name)
                    } else {
                        failedOrphanSidecars += 1
                    }
                    continue
                }
                // Retry obligations are the SAME class: the write-ahead proof
                // that a delay was owed. Sweeping one on restart erases the only record of the
                // original server minimum.
                if name.hasPrefix(Self.obligationPrefix),
                   let owner = UUID(uuidString: String(name.dropFirst(Self.obligationPrefix.count))) {
                    // ORPHANS are swept for the same reason as not-before stamps: an obligation
                    // proves what a RECORDING is owed, and owes it nothing once the recording is
                    // gone. Live entries keep theirs — that is the guarantee above.
                    if liveEntries.contains(owner.uuidString) { continue }
                    // COUNT what was actually removed. Counting before
                    // the attempt reported a failed removal as a success, which is precisely the
                    // "silently lost retry state" the log exists to rule out.
                    if VoiceSharingUploadQueue.removeStraySidecar(stray, fileManager) {
                        removedOrphanSidecars += 1
                        orphanSidecarNames.append(name)
                    } else {
                        failedOrphanSidecars += 1
                    }
                    continue
                }
                // Per-entry refusal deletion intents are the SAME class:
                // the durable evidence a held survivor (or an orphaned intent's reconciliation)
                // still needs. Sweeping one on recovery would let a SECOND fresh queue forget
                // the hold. reconcileRefusalIntentsLocked reconciles/retires them explicitly.
                if name.hasPrefix(Self.deletionIntentPrefix),
                   UUID(uuidString: String(name.dropFirst(Self.deletionIntentPrefix.count))) != nil {
                    continue
                }
                try? fileManager.removeItem(at: stray)
            }
            if removedOrphanSidecars > 0 || failedOrphanSidecars > 0 {
                // ONE reason line per sweep, naming what went: an orphan sweep that removed retry
                // state silently would be indistinguishable from losing that state to a bug.
                FileLog.shared.addMessage(
                    "[VoiceSharing] queue sidecar sweep reason=orphaned-entry removed=\(removedOrphanSidecars) "
                        + "failed=\(failedOrphanSidecars) "
                        + "names=\(orphanSidecarNames.prefix(8).joined(separator: ","))")
                FileLog.shared.forceFlush()
            }
        } // end of the non-overflowed sweep: a deferred sweep deletes nothing
        // Settlement records are recovery state, not debris: reconcile-retire them here. Runs
        // ALREADY on the serial queue, so the in-place variant is used — the public entry point
        // takes the queue itself and would trap (deadlock) called from inside it.
        recoverAbandonedSettlementsLocked()
        // Refusal deletion intents reconcile EXPLICITLY: an intent
        // whose entry is proven absent is retired through the durable helpers here — never by
        // the debris sweep; an intent whose entry survived stays durable and held for the
        // serving sweeps' scoped-purge retries.
        reconcileRefusalIntentsLocked()
        bumpHoldGenerationForContentChange()
    }
}
