## Formatting

Format all code using the linter formatter:
```bash
make format
```

Both SwiftLint build phases (`PreBuildActions/SwiftLint` and the app target's lenient phase) are
unconditional and run on *every* build. Set `SKIP_LINT=1` to short-circuit them for a local
iteration — `make build_fast` / `make test_fast` already do. `make lint` and CI still enforce the
rules, so nothing reaches review unlinted.

## Building and Running

```bash
make build_staging        # trustworthy build (what verification before a PR should use)
make build_fast           # local iteration: no dSYM, no code signing, no lint, no package re-resolution
```

Build output is tee'd into `artifacts/*.log` (gitignored) and the recipes run under
`set -o pipefail`, so a failed build still exits non-zero and a killed one still leaves its
partial log behind.

### Simulator install (voice / ASR testing)

**Install-over only** for routine sim refreshes. Do **not** `simctl uninstall` before `simctl install`.

Downloaded voice models (SenseVoice, LFM, …) live in Application Support (`Auris/Models`) inside the app container. Uninstall wipes that container and forces a full re-download (~minutes). Android keeps models because `adb install -r` replaces the APK without clearing data — mirror that habit on iOS.

```bash
# Preferred — keeps Application Support / downloaded models
xcrun simctl terminate "$UDID" fm.auris || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" fm.auris
```

Only uninstall when you intentionally want a clean slate.

## Cleaning Build Artifacts

```bash
make clean
```

## Running Tests

```bash
make test_staging
```

### Running a Single Test

```bash
make test_staging ONLY_TESTING=PocketCastsTests/YourTestClass/testMethodName
```

### Running Module Tests

```bash
# DataModel module tests
make test_staging ONLY_TESTING=PocketCastsDataModelTests

# Server module tests
make test_staging ONLY_TESTING=PocketCastsServerTests

# Utils module tests
make test_staging ONLY_TESTING=PocketCastsUtilsTests
```

## Build and test invocation discipline

These rules exist because one lane session was measured spending **154 minutes inside xcodebuild**,
roughly 114 of them avoidable. Each rule names the failure it prevents.

**Always go through `make`.** The `build*` / `test*` targets depend on `ensure_llama_ios`, which
produces `ThirdParty/llama-cpp-build/*/lfm/liblfm_runtime.a`. A bare `xcodebuild` skips that
prerequisite and dies with `Library 'lfm_runtime' not found` — on the Share Extension first,
because the llama link flags are inherited project-wide. That cost ~14 minutes of failed builds
in the session above, in a worktree whose `ThirdParty/llama-cpp-build` had not been built yet.

**Never add `-destination 'generic/platform=iOS Simulator'` yourself.** A generic simulator
destination has no active arch, so `ONLY_ACTIVE_ARCH` cannot narrow `ARCHS`: every source file is
compiled twice and the x86_64 link then fails anyway, because `liblfm_runtime.a` is arm64-only.
The Makefile passes `ARCHS=arm64` on Apple Silicon hosts via `$(SIM_ARCH)` and stays empty on
Intel; the test targets use concrete destinations (`name=` / `id=`), which already resolve to the
host arch.

**Log to a file; never `xcodebuild ... | grep ... | tail`.** `tail` buffers until EOF, so a hung
run prints nothing at all and the kill throws away whatever it had produced. The make targets tee
into `artifacts/*.log` for exactly this reason.

**Narrow `-only-testing` to the class or method under change.** `-only-testing:PocketCastsTests`
means the whole bundle (~150 test files). Two such runs hit their 50-minute outer timeout without
ever producing a verdict, even though the failures being hunted had already printed within
seconds of the run starting.

**Size the outer timeout to the work.** The test targets pass `-test-timeouts-enabled YES
-default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120`, so a stuck
test fails in about a minute and names itself. Wrapping that in `timeout 3000` converts a fast
answer into 50 blind minutes.

**Do not hardcode DerivedData paths across worktrees.** DerivedData is keyed by project path, so
every worktree (and every `/tmp` scratch clone) has its own. One session installed
`podcasts-bmth…` — a `/tmp/rev-pres` clone — while working in a different worktree, i.e. it put
the wrong app on the simulator. Read `CODESIGNING_FOLDER_PATH` from `xcodebuild -showBuildSettings`,
or use `make launch_mac`, which resolves *this* checkout's DerivedData by matching `WorkspacePath`
in each `info.plist` and fails instead of guessing.

**`build_fast` / `test_fast` are for the local loop only.** They add
`-disableAutomaticPackageResolution`, `DEBUG_INFORMATION_FORMAT=dwarf`, `CODE_SIGNING_ALLOWED=NO`
and `SKIP_LINT=1`. Measured on an M1 Max: one-file rebuild 89s → ~50s, no-op build 60s → ~25s.
The unsigned `.app` still installs and launches on a simulator (verified), but do not use these
flags for anything you intend to trust, archive, or put on a device — and do not alternate fast
and normal flags on the same worktree, because each change to the build description invalidates
the cache and costs one full rebuild.

## Architecture

### Modular Structure

The codebase uses Swift Package Manager modules under `Modules/`:

- **DataModel** (`Modules/DataModel/`) - Core data persistence using GRDB. Contains podcast, episode, and playback models. Uses custom GRDB macros for model generation.
- **Server** (`Modules/Server/`) - API communication layer using Protocol Buffers. Depends on DataModel and Utils.
- **Utils** (`Modules/Utils/`) - Shared utilities including localization helpers.
- **DependencyInjection** (`Modules/DependencyInjection/`) - DI container for the app.

### Main App Structure

The main iOS app lives in `podcasts/` with:
- UIKit + SwiftUI hybrid (123+ ViewControllers, XIBs/Storyboards)
- Feature-based organization (Analytics, Bookmarks, Folders, IAP, Player, etc.)
- Multi-platform targets: iOS, watchOS, widgets, App Clip, CarPlay

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `podcasts/` | Main iOS app source |
| `PocketCastsTests/` | Unit tests organized by feature |
| `Pocket Casts Watch App/` | watchOS companion |
| `WidgetExtension/` | Home screen widgets |
| `BuildTools/` | SwiftLint and SwiftGen plugins |

## Data Access - DataManager (Singleton Facade)

All data operations go through `DataManager.sharedManager`:

```swift
// Located at: Modules/DataModel/Sources/PocketCastsDataModel/Public/DataManager.swift
let dataManager = DataManager.sharedManager

// Podcast operations
let podcasts = dataManager.allPodcasts(includeUnsubscribed: false)
let podcast = dataManager.findPodcast(uuid: "...")
dataManager.save(podcast: podcast)

// Episode operations
let episode = dataManager.findEpisode(uuid: "...")
dataManager.save(episode: episode)
let downloadedCount = dataManager.downloadedEpisodeCount()

// Playlist/Filter operations
let playlists = dataManager.allPlaylists(includeDeleted: false)
let episodes = dataManager.playlistEpisodes(for: playlist)

// Up Next queue
let queue = dataManager.allUpNextEpisodes()

// Folder operations
let folders = dataManager.allFolders(includeDeleted: false)
let podcastsInFolder = dataManager.allPodcastsInFolder(folder: folder)
```

## Localization

Strings are managed via SwiftGen. Add new strings to `podcasts/en.lproj/Localizable.strings`:

```swift
/* Description for translators with placeholder info */
"feature_description_key" = "Value with %1$@ placeholder";
```

Use generated `L10n` enum:
```swift
let text = L10n.featureDescriptionKey(value)
```

Key rules:
- Use snake_case keys with pattern: `feature_relevantIdentifier_description`
- Always include comment describing context and placeholders
- Use positional specifiers (`%1$@`, `%2$@`), never string interpolation
- Handle plurals manually with separate `_singular`/`_plural` keys

## Code Style

SwiftLint is configured with opt-in rules. Notable custom rules:
- Use `naturalContentHorizontalAlignment` instead of `.left`/`.right` for RTL support
- Use `.natural` text alignment instead of `.left`
- Never use `LocalizedStringKey` in SwiftUI - use `NSLocalizedString` with L10n

## Themes
- When styling Views, use `@EnvironmentObject private var theme: Theme` and inject `.environmentObject(Theme.sharedTheme)` where the View is used.
- Use `AppTheme.color(for: .primaryText01, theme: theme)` to access themed colors

## Protocol Buffers

Server objects use protobuf. To regenerate after API changes:
```bash
brew install protobuf swift-protobuf  # One-time setup
make update_proto API_PATH=/path/to/pocketcasts-api/api/modules/protobuf/src/main/proto
```

## Verification and cleanup discipline

**A check must be able to fail on the thing it is checking.** Never let a failure look like a pass: don't redirect a command's errors into the signal you read, and treat an empty or silent result as *unknown* rather than clean until the check has been seen failing on a case that should fail. This covers the surface itself — a search that cannot see the answer (a filesystem scan for a file that exists only inside git objects, a log with no per-request lines) is not a check, so prove the instrument can observe the event *before* the event.

**Deleting a branch: decide by what merged, not by dates.** List its PR records — `gh pr list --head <branch> --state all --json number,state,mergedAt,headRefOid` (works after the branch is deleted, and can return several, since a head branch gets reused). Safe means both: a record is `MERGED` with a `mergedAt`, and the branch tip *is* that record's `headRefOid`, so nothing landed after the merge. A SHA alone proves nothing — a closed-unmerged PR prints one too, and its tip matches it — and if the tip moved past the merged head, read the added commits before deciding. The content checks (an ancestor of `main`, or `git cherry` reading zero) confirm but never deny: a later edit in `main` looks like a missing line, and a squash-merged branch is neither an ancestor nor patch-identical. Dates decide nothing — a rebase preserves author dates.

**Removing a worktree: never `--force` past a refusal.** Check `git status --short` in that checkout at the moment of removal. A provably clean checkout does not need the flag; a refusal is the guard telling you to look.

**Attribution: commit authorship is uniform here** — every lane commits as the owner — so `--author` identifies nothing. Use dates and subjects.

Applies to all Auris repos; canonical text lives in core's `CLAUDE.md`.

## PR review discipline

Before any PR merges, **every review comment on it must be addressed** — either fixed in code or rejected with a written reason. Deferral to follow-up tickets is only for comments irrelevant to the PR's changes; anything relevant is handled or rejected-with-reason, never parked. No comment is skipped silently. Addressing comments is **continuous while the PR is open**: keep checking for new comments and handle each as it lands — not a single round. Applies to all Auris repos; canonical text lives in core's CLAUDE.md. The final merge decision is always the owner's (@merlinran).
