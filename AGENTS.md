## Building and Testing

When the `xcode` MCP server is available, prefer it for building, testing, running the app and more. Otherwise:

```bash
make build_staging
make test_staging  # PocketCastsTests only, not the module tests
make test_staging ONLY_TESTING=PocketCastsTests/YourTestClass/testMethodName
make test_staging ONLY_TESTING=PocketCastsDataModelTests  # or PocketCastsServerTests, PocketCastsUtilsTests, PocketCastsAnalyticsTests
```

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

## Formatting

In Claude Code, a hook (`.claude/hooks/swiftlint.sh`) autocorrects each edited Swift file and reports the violations it can't fix. Otherwise, run `make lint_changed` to lint the branch's changes, or `make format` to autocorrect. `make format` covers the whole repo, so it can also change unrelated files.

## Architecture

- `podcasts/`: the iOS app, a UIKit and SwiftUI hybrid with XIBs and storyboards, organized by feature. CarPlay lives in `podcasts/CarPlay/`.
- Other targets: `Pocket Casts Watch App/`, `Pocket Casts TV App/`, `Pocket Casts App Clip/`, `WidgetExtension/`, `Share Extension/`.
- `PocketCastsTests/`: app unit tests.
- `BuildTools/`: pins the SwiftLint and SwiftGen versions.
- `Modules/Package.swift`: a single Swift package, with targets in `Modules/Sources/` and tests in `Modules/Tests/`:
  - **PocketCastsDataModel**: GRDB persistence. All data access goes through `DataManager.shared` (`Public/DataManager.swift`).
  - **PocketCastsServer**: the API client, using Protocol Buffers.
  - **PocketCastsUtils**: shared utilities.
  - **PocketCastsAnalytics**: `Analytics`, the Tracks and logging adapters, and the A/B test provider. Add new events to `AnalyticsEvent.swift`.

## Localization

Add strings to `podcasts/en.lproj/Localizable.strings`. The build regenerates the SwiftGen `L10n` enum, used as `L10n.featureDescriptionKey(value)`.

```
/* Context for translators, including what each placeholder is */
"feature_relevantIdentifier_description" = "Value with %1$@ placeholder";
```

- Use positional specifiers (`%1$@`, `%2$@`), never string interpolation.
- Handle plurals with separate `_singular` and `_plural` keys.
- Never use `LocalizedStringKey` in SwiftUI. Use `L10n` instead.

## Code Style

For RTL support, use `.natural` text alignment and `naturalContentHorizontalAlignment` instead of `.left`/`.right`. Custom SwiftLint rules enforce this.

## Themes

- In SwiftUI, use `@EnvironmentObject private var theme: Theme`, inject `.environmentObject(Theme.shared)` where the view is used, and read colors with `AppTheme.color(for: .primaryText01, theme: theme)`.
- `ThemeColor.swift` and `ThemeStyle.swift` are generated. Edit `scripts/themes/theme.csv`, then run `make generate_colors`.

## Protocol Buffers

After API changes, regenerate the server objects (the script installs `protobuf` and `swift-protobuf` with Homebrew):

```bash
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
