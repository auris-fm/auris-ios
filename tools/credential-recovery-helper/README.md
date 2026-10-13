# Credential recovery helper

A read-only probe that answers "is a credential present under a given keychain access group?"
without reading any value, without writing, and without touching an installed app.

## Where the code lives

The helper is an **Xcode target**: `CredentialRecoveryHelper/main.swift`, built with
`-target CredentialRecoveryHelper`. This directory holds only this note — it deliberately
contains no second copy of the source, because two copies drift and the stale one is the one
that gets built.

## Read-only and narrow, verified in source

- `kSecReturnData` appears **zero** times in any query, so a credential value cannot be returned
  or logged even by accident.
- `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` appear **zero** times: it creates nothing, so
  there is nothing to clean up.
- Only the two **assigned** service keys are accepted. They are the app's own constants —
  `SJSyncV2Token` / `SJRefreshToken` — and any other key is refused **before any query**.

## Service names

The stored service is the app's own construction, traced rather than assumed:

```
KeychainHelper.swift:9    private let prefix = "fm.auris."
KeychainHelper.swift:33   let fullKey = prefix + key
ServerConstants.swift:138 syncingV2TokenKey = "SJSyncV2Token"
```

So the stored service is `fm.auris.SJSyncV2Token`, and the helper builds the same `"fm.auris." + key`.

## Exit codes state what happened

The outcome must be readable from the status alone, so a refusal is never folded into success and
a bare OS status is never sufficient:

| code | meaning |
|---|---|
| 0 | every assigned key was **PRESENT** *and attributed to the requested group* |
| 2 | usage error, or a requested key is **not assigned** to this helper |
| 3 | a key was **not found** — **INCONCLUSIVE about access**, and never read as absence |
| 4 | the store **REFUSED** the read, e.g. `-34018` |
| 5 | present but attributed to a **different group** — the read worked, the wrong thing was read |
| 6 | present with **no usable group attribute** — the group cannot be confirmed, so not a success |

**Success is the narrowest outcome.** A successful `SecItemCopyMatching` alone is not enough: the
returned attributes must carry a well-formed access-group string **equal** to the requested group.
Verified against every payload shape that can reach that branch — matching string → `0`, wrong
string → `5`, and *empty string, non-string, absent attribute, nil result, non-dictionary result,
empty dictionary* → all `6`.

## Run

    xcrun simctl spawn <scratch-device> <app-container>/CredentialRecoveryHelper <accessGroup>

## What the signing experiments actually established — and their limit

Two arrangements were measured on one scratch device, with a trivial control binary confirming
`simctl spawn` itself works:

| signature | result on a scratch simulator |
|---|---|
| ad-hoc, **no** entitlements | runs |
| ad-hoc, **with** `keychain-access-groups` | **refused**: `SimXPCErrorDomain 163 "Security policy issue"` |

**These two results are scoped to these arrangements.** They do not establish that *every*
simulator helper declaring an access group is universally refused, and they do not establish that a
provisioning profile is strictly required — that was an earlier, broader conclusion that this
evidence does not support and which is withdrawn here.

What *is* established for this target: Xcode signs a **simulator** destination with
`codesign --sign -` and no `--entitlements` flag, so `CODE_SIGN_ENTITLEMENTS` does not reach a
simulator artifact — which is why a simulator build of this target shows empty entitlements
despite resolving `Apple Development`. A hand-signature **with** an explicit entitlements file does
attach the group to the artifact, and that artifact was then refused at launch with the same
`163` error.

## Scope — what this does NOT show

**No same-group positive has succeeded.** On an empty store the probe returns **not-found for a
group the reader cannot address**, so not-found never establishes access. The synthetic
add/read positive that would separate "can address the group" from "cannot" remains **unmet**, and
it is a prerequisite for any action against an installed app.

The helper must never be pointed at an owner's install.
