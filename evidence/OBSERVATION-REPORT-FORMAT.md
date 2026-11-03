# Observation report format (lane-neutral)

Written because the Android lane said it would report "in the @ios format": that format
should not live inside an iOS-specific receipt. Nothing here is iOS-specific.

## Why a format at all

Most of the cost in this sequence came from observations that were true but scoped wider
than the evidence behind them. The format exists to make the scope of every statement
auditable by a reader who was not present.

## Rules

1. **Name the surface.** Every observation says where it was read: a file path, a
   screenshot, a device query, a server log. "The log said X" is not evidence when the
   log has several writers.

2. **Name the emitter, and whether it is exclusive.** For each line: which process or
   component produced it, and whether anything else could have produced the same line.
   On iOS the `debug_log` is shared between the app and the test host, so a line is only
   app-side evidence if it can *only* come from the app process. An unqualified line is
   not evidence about the app.

3. **State the domain the observation stops at.** A control that replaces a production
   collaborator with a stub/closure covers only what the stub still exercises. The stub
   removes a whole downstream domain from the claim. Say which domain you stopped at.
   (cloud, d7615dbf; reviewer, a459dbd5)

4. **Timestamp to the second, verbatim.** Do not summarise or round. Two clocks compared
   is a *candidate* correlation, not an identity — clock skew is unmeasured, two events in
   one second are indistinguishable, and outcomes that collapse onto one client line cannot
   be separated. Promotion to identification needs origin logs. (spec, a91a907e)

5. **Absence is "not observed", never "did not happen".** A failure with no correlation id
   is reported as *not observed end to end*. It is not evidence that nothing was sent.
   Where a client can distinguish the two without a server, say so explicitly: e.g.
   "no request was attempted" vs "a request was attempted and refused".

6. **Separate verdict from evidence.** A red/green verdict without the artifact identity
   behind it is not reproducible. Pair every measurement with the exact build it measured.
   A red receipt must show the changed code was actually compiled into what ran;
   otherwise it may be a stale binary and proves nothing.

7. **State what would have falsified it.** If a control could not be made red, say that
   plainly rather than implying a red exists. A narrow receipt with its scope stated is
   worth more than a red manufactured to satisfy the format.

## The gap no single lane can close

Between a client-side local count and a server-side arrival count there is a domain —
"left the device, never arrived" — that neither side observes. It is closed only by scope
statements plus origin logs, never by either side extrapolating. (cloud, d7615dbf)
