# Build note: GRDBMacrosPlugin host compile — RESOLVED (root cause found)

## RESOLUTION (2026-11-04, commit d62eef196)

**ROOT CAUSE: our own xcodebuild invocation passed `-sdk iphonesimulator`.** Command-line build
settings cascade to ALL targets — including the HOST macro-plugin build — so the plugin was
compiled with the simulator SDK and `-target arm64-apple-ios17.0-simulator` against macOS-only
prebuilt modules. Dropping `-sdk iphonesimulator` and using `-destination` only:

    xcodebuild -project podcasts.xcodeproj -scheme pocketcasts -configuration Debug
      -derivedDataPath /tmp/dd-cmd
      -destination 'platform=iOS Simulator,id=13EB57ED-99BB-4C6F-B855-D31E96028D57'
      build CODE_SIGNING_ALLOWED=YES
    ** BUILD SUCCEEDED **

(Scheme `XcodeTarget_podcasts` is not configured for the test action; the `pocketcasts` scheme is.)

The earlier macosx26.0-vs-26.5 "incompatible target" theory is DEAD: the successful SwiftPM host
build passes `-target arm64-apple-macosx13.0` with the macOS SDK and imports the SAME prebuilt
modules (built at macosx26.5) without complaint — deployment-target differences are tolerated;
PLATFORM differences are not. The incompatibility warnings appeared only when the plugin compile
was handed the iOS simulator target.

Executed controls (real simulator runs): VoiceSharingQuotaRetryFloorTests 7/7 PASSED,
VoiceSharingWithdrawalBindingTests 5/5 PASSED; three allowance-era tests rewritten to the
actual-usage contract; `serviceKeepsSharingAliveAfterTheAssemblyIsReleased` verified failing
IDENTICALLY on untouched base `f16eb328b` (pre-existing baseline, not this change's regression).

The original analysis below is retained for the record; its synthesis (SDK/prebuilt/toolchain
mismatch inside the service) was an inference, and the flag-cascade above is the verified
mechanism — an instrument error on my side of the invocation, not a defect in the repo's package
configuration.

---


Date: 2026-11-04. Tree: `voice-sharing-uploads` `b34660ce2`. Xcode 26.6 (17F113), only Xcode installed.
macOS 26.7.1. Toolchain: Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), **default host target
`arm64-apple-macosx26.0`** (verified with `swiftc --version` and an empty `-typecheck`).
Simulator SDK: iPhoneSimulator26.5. All experiments ran in the ISOLATED derived-data dir
`/tmp/dd-cmd`; the shared SourcePackages caches were never modified.

## The failing invocation (verbatim, from `-verbose`, isolated dir)

`SwiftDriver GRDBMacrosPlugin normal arm64 (in target 'GRDBMacrosPlugin' from project 'Modules')` —
a generated project, built by the package build service, with (abbreviated to the decisive flags):

    builtin-SwiftDriver -- <toolchain>/usr/bin/swiftc -module-name GRDBMacrosPlugin
      @<Objects>/GRDBMacrosPlugin.SwiftFileList -DSWIFT_PACKAGE -DDEBUG
      -target arm64-apple-macosx26.5            <-- INJECTED BY A FLAG EXPERIMENT (see below)
      -Xcc -I<checkout>/Sources/_SwiftSyntaxCShims/include   <-- same
      -sdk .../iPhoneSimulator26.5.sdk
      -target arm64-apple-ios17.0-simulator     <-- THE SERVICE'S OWN TARGET, APPENDED AFTER OURS
      ...
      -explicit-module-build                    <-- EXPLICIT MODULES MODE
      ...

Two facts visible in the invocation itself:
1. The service compiles the macro plugin **with the app's simulator target**
   (`-target arm64-apple-ios17.0-simulator`), not a host target.
2. It uses **`-explicit-module-build`**. In this mode, where `SwiftSyntax` resolves from is NOT
   decided by `-I` flags on this invocation — which is why `OTHER_SWIFT_FLAGS`/`SWIFT_INCLUDE_PATHS`
   probes never moved the resolution error. (An earlier `-Xcc -I` probe DID reach this compile —
   it produced `redefinition of module '_SwiftSyntaxCShims'` — so flags arrive, they just do not
   decide module resolution here.)

## Package configuration (facts, not inference)

Prebuilt (per DerivedData and per the isolated dir, re-fetched by the service after I moved the
isolated copy aside): `SourcePackages/prebuilts/swift-syntax/603.0.2/swiftlang-6.3.3.1.3-macosx26.5-MacroSupport`
with `lib/libMacroSupport.a` and `Modules/` only — no `Sources/`. Its signed
`swiftlang-6.3.3.1.3-macosx26.5.json` manifest declares:
- `includePath`: `Sources/_SwiftLibraryPluginProviderCShims/include` and
  `Sources/_SwiftSyntaxCShims/include` — relative to the swift-syntax CHECKOUT
  (`Modules/.build/checkouts/swift-syntax`), where those directories exist and are complete.
- Module slices shipped: `arm64-apple-macos.swiftmodule` and `x86_64-apple-macos.swiftmodule` ONLY.
- `strings` on the swiftmodule binary records **`macosx26.5`** and compiler
  `6.3.3.1.3` (same toolchain version string as ours).

## Controlled experiments (all in `/tmp/dd-cmd`)

1. BASELINE: `unable to resolve module dependency: 'SwiftSyntax'` for all three imports, preceded by
   warnings `module file .../SwiftCompilerPlugin.swiftmodule/{arm64,x86_64}-apple-macos.swiftmodule is
   incompatible with this Swift compiler: built for incompatible target`.
2. `MACOSX_DEPLOYMENT_TARGET=26.5`: no change (the service's own `-target` still wins).
3. `OTHER_SWIFT_FLAGS="-target arm64-apple-macosx26.5 -Xcc -I<checkout cshims include>"`:
   our `-target` is appended BEFORE the service's, which overrides it. Same three resolve errors.
4. OUTSIDE xcodebuild, decisive: `swiftc -typecheck -target arm64-apple-macosx26.5 -I <prebuilt>/Modules t.swift`
   (`import SwiftSyntax`) → the incompatibility error DISAPPEARS; the only remaining error is
   `missing required module '_SwiftSyntaxCShims'`, which the previous team-confirmed probe fixes by
   also passing the checkout include path (exit 0). So with a **matching host target plus the C-shim
   include**, the prebuilt is importable by our compiler.
5. `SWIFT_ENABLE_EXPLICIT_MODULES=NO` (a real build setting): the error CLASS changed to
   `could not find module 'SwiftSyntax' for target 'arm64-apple-ios-simulator'; found: arm64-apple-macos,
   x86_64-apple-macos, at: <prebuilt>/Modules/SwiftSyntax.swiftmodule` — classic resolution now
   searches the prebuilt dir but asks for **ios-simulator slices, which the prebuilt does not ship**.

## Synthesis (labeled as synthesis)

The prebuilt ships macOS-host slices only, keyed `macosx26.5`. The package service compiles the
plugin target with the app's `-target arm64-apple-ios17.0-simulator`. Under explicit modules the
scanner/verifier refuses the macos slices ("built for incompatible target" — our default host
target is 26.0 vs the slices' 26.5), leaving "unable to resolve". Under classic resolution the
mismatch is stated outright: it wants ios-simulator slices that do not exist. Nothing I found in
`Package.swift` (requirement form pinning), xcodebuild settings, or user defaults changes which
prebuilt is selected or what target the plugin is given. The toolchain's ONLY supported control is
the CLI flag `swift build --disable-experimental-prebuilts` (verified in
`swift package --help`; default is ENABLED), which xcodebuild's package service does not expose.

## Ask for review routing

This is a machine/toolchain-level mismatch (SDK 26.5 prebuilt vs macosx26.0 default host target vs
ios-simulator plugin target) inside the generated Modules PIF, which I cannot steer from the
project or from Package.swift without deleting shared caches or mutating the Xcode install —
both still require @spec's word. Candidate fixes for whoever routes this:
(a) a complete/correct prebuilt for THIS toolchain+SDK pair, (b) a supported way to make the
package service build the plugin for the host, or (c) authorization to delete the shared
`SourcePackages/prebuilts/swift-syntax` cache entry so the service re-fetches a matching one.
