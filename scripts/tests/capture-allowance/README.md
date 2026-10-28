# Capture allowance host controls

Run from the repository root:

```sh
make -f scripts/tests/capture-allowance/Makefile test-host test-owner
```

These macOS controls compile the production Foundation/CryptoKit/Darwin ledger and token owner directly. They use synthetic finite limits and an injected established window; production still refuses missing authority.

`test-host` exercises actual process death at the named transaction barriers, separate-process initializer contention, restart, window refusal, and account isolation. Recovery with one-record and two-record budgets distinguishes settling an old charge from issuing a separately charged fresh reservation. Child processes have bounded waits and are joined.

`test-owner` covers cached-memory admission, single-use tokens, record/byte exhaustion, no refund, stale refill and take checks independently, lifecycle invalidation, same-process contention, and each file/directory synchronization fault. Its numbered fault receipts include the corresponding file/directory name. Corrupt or missing established accounting and unknown leftovers must remain closed with bytes preserved.

Injected synchronization failures and actual child death do not establish persistence through machine power loss. Queue removal controls in the XCTest target do not establish network delivery. Binaries and receipts belong under `artifacts/capture-allowance`, not this source directory.
