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
