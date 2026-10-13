# Credential recovery helper — read-only, scratch only

A separate signed binary that answers "is a credential present in a given access group?" without
reading any value, without writing, and without touching an installed app.

## Why a separate binary and not a test

An XCTest is HOSTED BY THE APP, so running it installs and launches the app on whatever simulator
it is pointed at. This helper is its own executable: it is copied to a SCRATCH simulator only, and
nothing about it touches an owner's install or store.

## Read-only, verified in source

- `kSecReturnData` appears **zero** times in any query, so no credential value can be returned or
  logged even by accident.
- `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` appear **zero** times: it creates nothing, so
  there is nothing to clean up.

## Run

    xcrun simctl spawn <scratch-device> ./credential-recovery-helper <accessGroup> [service-key ...]

Defaults to the two assigned service names (`SJSyncV2Token`, `SJRefreshToken`) when none are given.

## The signing constraint, measured rather than assumed

| signature | result on a scratch simulator |
|---|---|
| ad-hoc, **no** entitlements | RUNS |
| ad-hoc, **with** `keychain-access-groups` | **REFUSED**: `SimXPCErrorDomain code=163 "Security policy issue"` |

So **a helper that declares a keychain access group needs a real provisioning profile**; ad-hoc
signing cannot carry that entitlement. Verified in both directions on the same scratch device, with
a trivial control binary confirming `simctl spawn` itself works.

Without the entitlement the helper runs and reports the honest answer for a group it cannot
address:

    SJSyncV2Token: UNREADABLE osstatus=-34018 — a refusal is NOT absence

`-34018` is `errSecMissingEntitlement`: the reader cannot address that group. It is reported as a
refusal, never as absence, which is the distinction every earlier negative in this investigation
turned on.
