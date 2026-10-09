#!/usr/bin/env bash
#
# Regenerates the SwiftLint input file list used by the SwiftLint build phase.
#
# The phase is a script phase, so Xcode decides whether to run it by comparing
# its declared inputs against its declared outputs. Declaring only
# `.swiftlint.yml` makes the phase permanently up to date after the first build,
# which silently stops a lint violation from failing the build. Declaring the
# linted sources keeps the phase skipped on unchanged builds while still
# re-linting after any Swift edit.
#
# Run this (and commit the result) when Swift files are added or removed:
#   ./scripts/build-phases/gen-swiftlint-sources.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
OUT="$1"

# Mirrors the `excluded:` list in .swiftlint.yml, so the two cannot disagree.
git ls-files '*.swift' \
  | grep -vE '^(build|\.claude|BuildTools/\.build|DerivedData|fastlane|Modules/\.build|Modules/[^/]+/\.build|Pods|Scripts|vendor)/' \
  | grep -vE '^(Modules/(Server|Utils|DataModel|GRDBMacros))/' \
  | sed 's|^|$(SRCROOT)/|' \
  > "$OUT"

echo "wrote $(wc -l < "$OUT" | tr -d ' ') paths to $OUT"
