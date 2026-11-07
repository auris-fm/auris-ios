# Phase-2 wire fixtures, revision 2 (post GO-review fix)

Regenerated from the fix commit (head posted in #ios:8eb13b8b). Exported by
`test_exportPhase2WireFixturesForCrossClientParity` on test sim 3A1CAECE; every case BIND-VERIFIED
through the production validator before export; manifest digests re-verified after copy-out.

R1 was refused by server intake:
1. `observations.execution.outcome` carried routing tokens (`succeeded`) — wire enum is
   {success, failure, refused, cancelled}.
2. Completed wake stages carried no `decision` — the server files a decision-less completed wake
   under `request/` instead of `wake-request/`.

R2 changes, all asserted by controls (encoder output + binding + real-engine durable path):
- wake-required-command: wake decision `detected`, execution outcome `success`
- grace-no-wake: wake decision `rejected`, execution outcome `success`
- empty-result-with-language: wake decision `detected`; execution `not_run`/`client_refused`
  (unobserved execution states no outcome — note: client_refused here is the encoder fixture's
  chosen not_run reason; the producer maps not_run+client_refused to `refused` at report sites)
- New capture session `phase2-parity-wire2-7c2e67d4b`, so R1 bytes cannot be confused with R2.
- Manifest records `wire_revision: 2` and the R1 refusal reason.

Old exported bytes remain immutable; this is a new set.
