---
name: debugging-with-logs
description: Use when debugging the Pocket Casts iOS app with live log streaming — building for simulator, launching, and viewing OSLog output during development
---

# Debugging with Live Logs

## Overview

Build the app for iOS Simulator, launch it, and stream OSLog output in one command. Simulator processes are native Mac processes, so `log stream` works directly.

## Quick Reference

```bash
# Build + launch + app subsystem logs (default)
make debug

# Build + launch + ALL process logs (includes system/framework)
make debug_all

# Build and launch only (no log tail)
make launch_mac

# Raw log stream — app-only (filter by library/binary, excludes all frameworks)
log stream --predicate 'sender BEGINSWITH "podcasts."' --level debug --style compact

# Raw log stream — entire process (includes system/framework logs)
log stream --process podcasts --level debug --style compact
```

## Log Filters

| Command | Scope |
|---------|-------|
| `sender BEGINSWITH "podcasts."` | App binary/library only (strictest — excludes all frameworks, system, and third-party libraries) |
| `make debug` | Build + launch + app-only logs |
| `--process podcasts` / `make debug_all` | All logs from the podcasts process (includes system, frameworks, ASR, audio) |

## Tips

- `--color always` can be added when piping to a human terminal (omit for agent use — ANSI codes create noise)
- `--style compact` shows timestamp + process + message on one line
- Add `--predicate 'category == "voice"'` to narrow to a specific log category
- Simulator microphone works via the Mac's built-in mic — grant permission in System Settings → Privacy & Security → Microphone
