# Gate audit — spec 2741a0ca (allowed gates only)

Commit: `VoiceSharingUploadQueue` count-on-disk + this audit.
Allowed gates, verbatim: collect = sharing on. Admit = fewer than 32 audio records on disk.
Upload = sharing on, owner and epoch match, network, backoff due, under 7 days.
Delete = accepted, final refusal, 7 days, sharing off.

Every condition below can stop, hold, skip or delete a recording. Each is mapped to a gate, or
removed.

## Collect (segment completion → durable queue)

| # | Condition | Location | Maps to | Action |
|---|---|---|---|---|
| 1 | `event.isGateControl` | `VoiceSharingContributionSink.swift:99` | not a recording (gate-control marker) | keep |
| 2 | `.started` / `.cancelled` kinds | `VoiceSharingContributionSink.swift:102` | not a completed recording | keep |
| 3 | `pendingSlots >= maxPendingEvents` (16) | `VoiceSharingContributionSink.swift:105` | **none** | **REMOVED** — now pressure-counted, capture still enqueued |
| 4 | collector FIFO cap `maxPendingSignals` (64) | `VoiceSharingCollector.swift:878` | **none** | **REMOVED** — counts pressure, never discards |
| 5 | collector sample budget `maxAggregateRetainedSamples` | `VoiceSharingCollector.swift:879` | **none** | **REMOVED** — same |
| 6 | `submit` FIFO cap + sample budget | `VoiceSharingCollector.swift:1104` | **none** | **REMOVED** — same |
| 7 | `metadataByteCeiling` | `VoiceSharingContributionSink.swift:173` | per-entry format bound, not a gate | keep (record-shape validity) |
| 8 | revocation generation changed | `VoiceSharingContributionSink.swift:153,179,188` | sharing off | keep |

## Admit (durable queue)

| # | Condition | Location | Maps to | Action |
|---|---|---|---|---|
| 9 | record count ≥ 32 on disk | `VoiceSharingUploadQueue.swift:845` | **fewer than 32 records** | keep (the gate) |
| 10 | count unreadable | `VoiceSharingUploadQueue.swift:926,847` | admit gate unsatisfiable | **REFUSES** (spec ruling) — logged `count_unknown`, not sticky, never touches drain/upload/delete |
| 11 | `audioTooLarge` / `metadataTooLarge` at prepare | `VoiceSharingUploadQueue.swift:838,839` | per-entry format bound (new captures) | keep |
| 11a | stored entry metadata oversized/unreadable/unbindable | `VoiceSharingUploadQueue.swift:3853+` | **none** | **REMOVED** — `.unready`: sent unbound, counted, expires at 7 days (ruling 2) |
| 12 | `revocationHoldLocked`, `retryHoldLocked` | `VoiceSharingUploadQueue.swift:834` | sharing off (revocation) / backoff (retry) | keep |
| 13 | root listing bound (was 64 names) | `VoiceSharingUploadQueue.swift:145` | **none** | **FIXED** — `maxRootEntries = 32*4+64`; over-cap queues now enumerate |

## Upload / drain

| # | Condition | Location | Maps to | Action |
|---|---|---|---|---|
| 14 | `revocationHoldLocked`, `retryHoldLocked` | scheduler drain admission | sharing off / backoff due | keep |
| 15 | revocation intent present on disk | `VoiceSharingUploadQueue.swift:602` | sharing off | keep |
| 16 | retry hold intent present | `VoiceSharingUploadQueue.swift:604` | backoff due | keep |
| 17 | root listing overflow | `VoiceSharingUploadQueue.swift:605` | **none** | now bounded by `maxRootEntries`, so a legal queue never hits it |
| 18 | owner/epoch mismatch | uploader binding | owner and epoch match | keep |
| 19 | network failure | uploader transport | network | keep (retryable) |
| 20 | not-before stamp unexpired | `VoiceSharingUploadQueue.swift:625` | backoff due | keep |
| 20a | attempt record unreadable / count uncertain | `VoiceSharingUploadQueue.swift:527,536` | **none** | **REMOVED** — treated as DUE, logged, record rewritten (ruling 1) |
| 21 | 7-day age | uploader/queue retention | under 7 days | keep |

## Delete

| # | Condition | Location | Maps to | Action |
|---|---|---|---|---|
| 22 | decided rejection marker | purge gate | final refusal | keep |
| 23 | removal intent | purge gate | sharing off | keep |
| 24 | `.legacyUnknown` / nil cause | purge gate | **none** | keep (never deletes) |
| 25 | accepted + 7 days | retention sweep | accepted / 7 days | keep |
| 26 | orphan sidecar sweep | `VoiceSharingUploadQueue.swift:~2900` | deletes sidecars, never a recording | keep |
| 27 | 409 after 5xx | *removed* per spec 418d3d05 | — | removed |

## Controls added

- `test_anOverCapQueueAfterRestartIsStillReadableAndServes` — 32 records + 64 sidecars (>64 root
  names), restart, every record discoverable and servable. **RED before `maxRootEntries`**: the
  queue found zero entries and could not drain.
- `test_recoveryStrayScanIsBoundedAndDoesNotEagerlyMaterialiseTheRoot` — updated to assert the bound
  is finite **and** at least the record limit.
- Existing two override the cap by design (empty/partial dirs are deleted at recovery); no change.
## Rulings applied (spec 2741a0ca, msgs f2f46d0b / 0576a3e0)

1. **Unknown count refuses admission.** Mapped row 10. Logged `count_unknown`, never sticky (every
   admission re-reads), never consulted by drain/upload/delete.
2. **Uncertain attempt record never holds an upload.** Row 20a: treated as due, logged, rewritten.
3. **No local "invalid" verdict deletes or holds.** Row 11a: `refusedUnbindable` is gone. A capture
   whose metadata is unreadable but whose audio exists is `.unready` — it counts toward 32, expires
   by file time, and is offered to the uploader so the server's final refusal decides.

Controls: unknown → refuse → next readable listing admits (not sticky); an unreadable attempt record
treats backoff as due; an unbound capture is not deleted.

---

# Replacement head — rulings a4b417fc + reviewer 307d0bde

The previous head (`ef64b2fbe`) was audited against "nothing about the queue as a whole may stop a
due recording". Reviewer `307d0bde` found the audit had missed real gates; spec `d720ab6c` then fixed
the exact boundary: **an unknown fact about one entry affects only that entry; an unknown fact about
the whole root or owner may refuse only NEW ADMISSIONS, never serving and never an attempt.**

## Gates REMOVED in this head

| # | Condition | Where it was | Why it maps to no allowed gate |
|---|---|---|---|
| 28 | Root listing bounded at `maxQueueEntries*4+64` | `entriesStrictLocked`, wake arithmetic, revocation proof, retry-hold reconciliation, refusal-intent discovery | A bound derived from the cap is exceeded by any inherited over-cap queue (Android Pixel: 104), and that queue cannot drain without first being discovered. Discovery / counting / serving now read `listDirectory(rootDirectory, [])`. A bound survives **only** in the two destructive sweeps, which log `sweep deferred` on overflow. |
| 29 | Recovery purged the oldest records until the queue fit 32 (`reason=over-capacity`) | recovery, `recoverLocked` | **This deleted audio the server never saw.** The 32 limit governs new admissions; nothing authorises deleting recordings. It also truncated an inherited over-cap queue at launch instead of draining it. Replaced by a `disposition=drain-not-delete` log. |
| 30 | `.unready` excluded from serving (`send-unbound`) | `readyEntriesReportingUnknownCoverage`, `readyEntries` | Retained-but-never-sent is a hold. A bind failure is a local opinion; the server owns the verdict. Now served when the failure is about the RECORD (digest mismatch, malformed/duplicate/invalid field), so it reaches admission and the wire. |
| 31 | `isCompleteEntryLocked` (bind-only) used as the serving filter and as attemptability | `readyEntries`, `secondsUntilNextAgeBoundary`, `isAttemptableLocked` | Same: servability is "contains a capture", not "binds locally". |
| 32 | `admitAttempt` required a successful `boundIdentityLocked` | admission | A capture whose record is unreadable still holds audio. Binding now supplies only provenance; absent → the live epoch, which is truthful (this send happened under this enrollment). |
| 33 | Attempt-count write failure released the lease and rethrew | admission | A diagnostic count-write must not stop an upload. Count kept in `attemptCountMemoryOverride`, logged `disposition=memory-only`, attempt proceeds. |
| 34 | `strictOwnerCoverageLocked` threw on any entry's unreadable state, holding every entry | serving + admission | One corrupt directory became a queue-wide hold. Now per-entry: the failing entry is skipped/logged, siblings serve. |
| 35 | `retryHoldLocked` refused every attempt | `beginAttempt` | Unknown retry bookkeeping is not a gate. Logged `disposition=due-now`, attempt proceeds. |
| 36 | `beginAttempt` required strict owner-wide coverage | `beginAttempt` | Per ruling: only the entry's own state may hold its attempt. |
| 37 | Owner-wide unknown coverage on a failed scan | serving | The FAILED SCAN itself still refuses serving (that is the root, not an entry) and still refuses new admissions; what no longer happens is one entry's fault stopping the others. |

## Gates KEPT and their justification

| # | Condition | Location | Maps to |
|---|---|---|---|
| 38 | `.disqualified` (decided rejection marker written from the server's final refusal) | `isAttemptableLocked` | final refusal |
| 39 | no audio present | `isAttemptableLocked`, admission | nothing to send (not a recording) |
| 40 | owner file unreadable / owner absent | serving filter, admission | owner match (an attempt must be attributable) |
| 41 | `.incomplete` (being written) | serving, `isAttemptableLocked` | not yet a capture |
| 42 | WAV representation invalid (float/stereo/rate/truncated) | `isServedEntryLocked` | not a gate on a RECORD: this build cannot represent the audio, and the server's `wav_validate.ts` mirrors it |

## Controls added / amended

- `test_anOverCapQueueAfterRestartReachesTheUploadPath` — **NEW, ruling 1**: seeds 104 records (the
  Android Pixel shape) through the real prepare/finalize path with a raised cap, plus a due stamp on
  each; restarts; asserts all 104 are served **and** the first is admitted, i.e. reaches the upload
  path. Red-proof: with the old recovery purge this control lost 72 recordings at launch.
- `test_aLocallyUnbindableCaptureIsSentAndTheServersRefusalDeletesIt` — **NEW, item 1**: corrupts
  metadata, then walks the real path through admission and the uploader to the transport; asserts the
  body left, the attempt is attributed to the owning account, and a scripted `422 integrity_mismatch`
  removes the files.
- `test_anAttemptCountWriteFailureStillUploads` — **NEW, item 2**: injected `failureRecordWriter` for
  `attempts.json`; the request still leaves and the server's refusal settles it.
- Amended away from the owner-wide premise (item 3 / `d720ab6c`): `test_attemptGateShares…` (renamed
  behaviour: an unreadable sibling no longer spends a due attempt), `test_attemptsWithHeldHandles…`,
  `test_createdAtReadFailure…`, `test_inaccessibleRequiredFile…` (renamed to `…HoldsOnlyThatEntry`),
  `test_unreadableOwnership…`.
- Amended for ruling 2 (digest mismatch is SENT, not held): `test_wrongRecordDigestIsRejected`,
  `test_metadataTamperedOutsideItsDigestIsRejected`, `test_entryWithDigestMismatchIsRemovedByRecovery`,
  `test_tamperedPersistedAudioNeverServes`, and the unreadable-metadata retention control now asserts
  it IS served.
- Injection seams moved from `listDirectoryBounded` to `listDirectory` in 4 controls: discovery reads
  the unbounded lister, so the old seams injected into a call that no longer happens and the controls
  were passing for the wrong reason.

## Known pre-existing failures (verified by stashing this whole tree at `ef64b2fbe`)

`VoiceSharingRefusalDeletionTests` 10 of 19, `VoiceSharingClockOrderingRegressionTests` 3 of 4,
`VoiceSharingCollectorTests` 3 of 38, `VoiceSharingContributionSinkTests` 4 of 41,
`VoiceSharingAccountModelTests`, `CloudProducerInterleavingControls`, `CloudRouteSupersedeTests`.
Identical with this tree stashed. Out of scope here and NOT folded in.

## Round after `b9e4089fa` — reviewer `1af78cf5` / `066e2a70`, spec `7e0e89fb`

### Gates removed in this round

| # | Gate | Where | Why it maps to nothing |
|---|------|-------|------------------------|
| 43 | Overflowing stray sweep logged "deferred" but still deleted from the TRUNCATED listing | `VoiceSharingUploadQueue.swift` `recoverLocked` stray sweep | Not a gate at all — a **destructive regression I introduced**. `liveEntries` was built from the prefix, so a live retry sidecar whose directory fell past the bound looked orphaned and was deleted. Overflow now returns before any removal. |
| 44 | `admitAttempt` threw on `retryHoldLocked` | `admitAttempt` | Unknown retry bookkeeping on **the path the uploader calls**. `beginAttempt` had been fixed; this one was missed, so the gate survived in production. Unknown retry state ⇒ DUE NOW (spec `d720ab6c`). |
| 45 | `isAttemptableLocked` threw on an unreadable `attempts.json` | `isAttemptableLocked` | The count spaces retries; it is not a gate. The write-path fallback could never run because the read path refused first. |
| 46 | `.audioSizeMismatch`, `.audioSampleCountMismatch`, `.invalidAudio` held serving | `isServedEntryLocked` | Readable pair, invalid representation ⇒ a **local** invalid verdict. The server's `wav_validate.ts` owns it; its final refusal deletes. Only an entry with no readable pair is held. |
| 47 | `entryHoldsAudioLocked` read a stat failure as "absent" | `entryHoldsAudioLocked` | Collapsed unknown into absent, so the limit **under-reported** an unstat-able audio file. Unknown now counts as holding audio. |

### Kept, and why

- `entriesStrictLocked()` still throws when the whole root cannot be listed → `.unknownCoverage`. A root-level unknown is not a per-entry fact.
- Recovery's `.failure` intent discovery still holds with unknown origin.
- A decided rejection (`publication.failed`) still blocks an attempt: it derives from the server's own final refusal, not from the client.

### Controls

| Control | Red proof |
|---------|-----------|
| `test_anOverflowingStraySweepDeletesNoLiveRetryState` | Reverting only the overflow skip fails this one control, nothing else. |
| `test_captureWithMalformedAudioIsSentAndTheServersRefusalDeletesIt` | Malformed WAV reaches transport; `415 unsupported_audio` deletes it. |
| `test_malformedAttemptRecordStillUploads` | Unreadable `attempts.json` still reaches transport. |
| `test_anOverCapQueueAfterRestartReachesTheUploadPath` | Extended: drains through the real uploader to a transport that records the capture ID. |
| `test_emptyAndMetadataOnlyDirectoriesNeverOccupySlots` (07a7bb51 a) | Red on the old directory count. |
| `test_thirtyTwoAudioHoldingEntriesRefuseTheNextCapture` (07a7bb51 b) | The other half, so "count nothing" cannot pass. |

### Baseline correction (spec `7e0e89fb`)

`spec` was right that `ef64b2fbe` is my own uncleared commit and cannot serve as a baseline. Measured at the cleared base `f90548c88`:

| Class | At `f90548c88` | Verdict |
|-------|---------------|---------|
| `VoiceSharingContributionSinkTests` | 41/41 **pass** | My regressions — being resolved |
| `VoiceSharingCollectorTests` | 38/38 **pass** | My regressions — being resolved |
| `VoiceSharingRefusalDeletionTests` | 19/19 **pass** | My regressions — being resolved |
| `VoiceSharingClockOrderingRegressionTests` | 3/4 (2 tests) | Genuinely pre-existing |
| `VoiceSharingAccountModelTests` | 10/13 (9 tests) | Genuinely pre-existing |

### Open, awaiting `spec`'s call

15 controls in `VoiceSharingRefusalDeletionTests` / `VoiceSharingContributionSinkTests` seed their "refused" entry by corrupting audio **locally**, then assert it never serves and is purged. Under `2741a0ca` that premise is gone — these now serve and are retained. The purge machinery is still required for genuine *server* refusals. Not retargeting the fixtures without a ruling.

### Resolution of the 15 controls (spec `84f7065a`, reviewer `c0303918`)

Reseeded, **not retired** — the refusal half of each control was rewritten, the purge/barrier/crash
mechanic each control exists for was left intact.

| Control | How the refused entry is produced |
|---------|-----------------------------------|
| `test_aRecordCheckRejectionIsDeletedAtOnceByServing` | Driven: uploader → `422 integrity_mismatch` → `abandoned` |
| `test_strictDiscoveryDeletesARefusedRecordCheckAndCoverageStaysKnown` | Driven |
| `test_aFreshReconstructionDoesNotResurrectARefusedRecordCheck` | Driven |
| `test_aNeighbouringValidEntryIsUntouchedByARefusalPurge` | Driven, one entry only |
| `test_aFailedRemovalFailsClosedAndReconcilesOnReconstruction` | `decidedRejection` marker (removal is faulted, so a driven refusal never settles) |
| `test_aRefusalPurgeFailureHoldsOnlyTheRefusedEntry` | `decidedRejection` marker, same reason |
| `test_aCrashAfterTheIntentBeforeRemovalResumesOnTheNextPass` | `decidedRejection` marker, same reason |
| `test_aBarrierFailureBeforeThePurgeMutationFailsClosed` | `decidedRejection` marker, same reason |

New control `test_localCorruptionAloneDoesNotCreateADecidedRejection` is the negative half the
reviewer asked for: a locally corrupted record now **serves**, is **not deleted**, and has **no**
`publication.failed` marker. Nothing the client decides locally may delete or hold a recording.

`driveServerRefusal` fails hard rather than skipping: a skip there would report green while proving
nothing about the refusal. Two controls used it where the faulted remover prevented settlement; that
surfaced as two silent skips, now replaced with the durable marker.

### Collector controls (spec `2741a0ca`)

The in-process FIFO cap and the aggregate sample budget are **retired as dropping gates** — pressure
is counted and logged, work is retained, and the durable queue's record limit is the one admission
gate. Four controls asserted the old bounds and are amended to the ruled behaviour.

**TRADE-OFF, stated plainly:** retained in-memory work is no longer capped by `maxPendingSignals` or
`maxAggregateRetainedSamples`. A blocked sink can grow the FIFO. The ledger (`aggregateAudioSamples`)
and `overflowCount` are what an operator can see; there is no longer a bound that discards. This is a
memory-pressure exposure accepted to satisfy "no in-process cap may discard a capture", and it should
be watched on device.

### Verified green (head, after all of the above)

| Class | Result |
|-------|--------|
| `VoiceSharingUploadQueueTests` | 142/142 |
| `VoiceSharingUploaderTests` | 43/43 |
| `VoiceSharingContributionSinkTests` | 41/41 |
| `VoiceSharingRefusalDeletionTests` | 20/20, no skips |
| `VoiceSharingCollectorTests` | 38/38 |
| `VoiceSharingClockOrderingRegressionTests` | pre-existing: same 2 tests, same 3 assertions as `f90548c88` |
| `VoiceSharingAccountModelTests` | pre-existing: 9 tests, identical to `f90548c88` |

## Round after `90a49d5f7` — reviewer `4f98b831` / `508baa51`, spec `80982a60`

### The last retry-state gates (066e2a70 item 2, completed)

| Gate | Where | Why it maps to nothing |
|------|-------|------------------------|
| 48 | `refuseIfNotYetDueLocked` threw `leaseHeld` for a NaN obligation | `refuseIfNotYetDueLocked` | Unreadable delay, not an infinite one. This ran below `admitAttempt`'s guard, so the uploader still refused. Unknown ⇒ due now. |
| 49 | Same, for an unstattable not-before stamp | `refuseIfNotYetDueLocked` | Unknown ⇒ due now. |
| 50 | Same, for an unparseable/oversized/non-regular stamp | `refuseIfNotYetDueLocked` | Unknown ⇒ due now; the corrupt record is retired so it cannot re-hold every pass. |
| 51 | `retryHoldLocked` returned `.notWork` from the wake prospect | `retryWakeProspectLocked` | A retry hold suppressed every entry's retry wake, so the queue never scheduled the retry that would clear it. |
| 52 | Retry-hold intent and flag both returned `nil` from the boundary reader | `secondsUntilNextRetryBoundary` | Same freeze, in wake arithmetic. |
| 53 | `readyEntries()` returned `[]` under a retry hold | `readyEntries` (legacy path) | Withheld the whole queue from the drain on unknown bookkeeping. |

**A hold that MUST survive, and now does, precisely:** a retry hold still refuses **new admissions**
(`hasAdmissionAllowance`), read from storage so a marker that lands after construction governs it.
It never gates serving or an attempt.

**One hazard the removal created, and the clamp that fixes it:** with the hold no longer returning
`nil`, an ALREADY-DUE boundary armed a wake of **0**, which fires the trigger immediately and re-arms
forever without progress. Under a retry hold the wake is now clamped to
`retryHoldWakeFloorSeconds` (15s): the queue keeps waking, but cannot spin. This is the original
`test_aDueBoundaryUnderARetryHoldArmsNoWake` worry, preserved.

### High-water-mark log (spec `a4b417fc` / `80982a60`)

`VoiceSharingCollector` records `peakPendingSignals` and `peakRetainedSamples` at both enqueue
points, under the lock, and logs ONE content-free line per NEW peak:

    [VoiceSharing] handoff high-water peak_fifo=<n> peak_retained_samples=<n> capture=<uuid>

`retained` is in samples; pcm_s16le so device bytes = `samples * 2`. This is how the accepted
memory-pressure exposure is seen on a device instead of inferred from absence.

### Controls corrected in this round

- `test_anOverflowingStraySweepDeletesNoLiveRetryState` — reviewer `508baa51` was right that the
  original seeded an EMPTY UUID directory, which recovery may sweep as incomplete, so it proved "an
  orphan survived the skip". It now seeds a **real published capture** through the production writer
  and injects a deterministic bounded listing that reports overflow and returns only the sidecars,
  so the sidecar is inside the prefix and the live directory beyond it. Red-proof confirmed against
  the live capture's retry state.
- `test_unreadableDelayRecordsStillUpload` — malformed stamp and NaN obligation, through the uploader.
- `test_aFailedStampWriteDoesNotStopAHealthySiblingsRetry` — per-entry, never owner-wide.
- Five controls amended from "the hold withholds serving" to "the hold withholds admission".
