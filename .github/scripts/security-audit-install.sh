#!/usr/bin/env bash
# Installs the scanners `security-audit.sh` runs, on a GitHub-hosted Linux x64 runner.
#
# The versions are pinned here and nowhere else. gitleaks and osv-scanner are release binaries
# checked against the SHA-256 their release publishes; semgrep and zizmor are exact PyPI
# versions, whose own dependencies are whatever pip resolves on the day.
# Dependabot does not see this file, so the pins move by hand: change the version
# and the checksum together, taking the checksum from the release's own checksum file.
#
# The same file lives in `core`, `auris-ios` and `auris-android`; keep the three identical.

set -euo pipefail

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
OSV_SCANNER_VERSION=2.7.1
OSV_SCANNER_SHA256=fb7dab19a8bd9bbe5c3189f09d4b7ee1820c9553a23bac202648a56efd2f6ee8
SEMGREP_VERSION=1.186.0
ZIZMOR_VERSION=1.32.0

bin="$RUNNER_TEMP/security-audit-bin"
mkdir -p "$bin"
cd "$bin"

curl -fsSL -o gitleaks.tar.gz \
  "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
echo "$GITLEAKS_SHA256  gitleaks.tar.gz" | sha256sum --check --quiet
tar -xzf gitleaks.tar.gz gitleaks
rm gitleaks.tar.gz

curl -fsSL -o osv-scanner \
  "https://github.com/google/osv-scanner/releases/download/v$OSV_SCANNER_VERSION/osv-scanner_linux_amd64"
echo "$OSV_SCANNER_SHA256  osv-scanner" | sha256sum --check --quiet
chmod +x osv-scanner

pipx install --quiet "semgrep==$SEMGREP_VERSION"
pipx install --quiet "zizmor==$ZIZMOR_VERSION"

echo "$bin" >> "$GITHUB_PATH"
