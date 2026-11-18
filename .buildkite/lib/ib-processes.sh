#!/bin/bash
# Record which Interface Builder processes a build started, and stop only those.
#
# Interface Builder compiles storyboards through a helper launched inside the
# simulator runtime. Those processes do not stay in the job's process tree:
# `ibtoold` reparents itself to launchd, and its `IBAgent-iOS` helpers are children
# of the daemon rather than of the build. Cancelling a job therefore leaves all of
# them running — measured on a hung run: the job, xcodebuild and the script were
# gone while thirty Interface Builder processes survived.
#
# They cannot be found by name. This Mac is shared, and a person's own Xcode
# starts processes with the same names; killing by name would break their build.
# Nor can they be found by TMPDIR: `ibtoold` asks the system for the per-user
# temporary directory through confstr(_CS_DARWIN_USER_TEMP_DIR), which ignores the
# TMPDIR environment variable (measured: a compile under a custom TMPDIR still
# created its FIFO folder under /var/folders). Start time alone is not enough
# either, since a long build overlaps anything else started on the machine.
#
# What does identify them is the process tree while it is still intact. So the
# tree is walked repeatedly during the build and every Interface Builder process
# reachable from it is recorded, with its start time. A process first seen already
# detached is not proven to be ours: it is left running and named in the report.
#
# Identity is pid plus start time. A pid alone can be reused; a recorded pid whose
# start time has changed is a different process and must not be killed.

# Every pid reachable from $1, including $1 itself.
ib_descendants() {
  local all=" $1 " frontier="$1"
  while [ -n "$frontier" ]; do
    local next=""
    local p k kids
    for p in $frontier; do
      kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
      for k in $kids; do
        case "$all" in
          *" $k "*) ;;
          *) all="$all$k "; next="$next $k" ;;
        esac
      done
    done
    frontier="$next"
  done
  echo "$all"
}

# The start time of a pid, empty if it no longer exists. Used as the second half
# of its identity, so a reused pid is never mistaken for the recorded process.
ib_start_time() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

ib_is_ib_process() {
  case "$(ps -o comm= -p "$1" 2>/dev/null)" in
    */ibtool|*/ibtoold|*/IBAgent-iOS) return 0 ;;
    *) return 1 ;;
  esac
}

# One snapshot: append "pid<TAB>start time" for every Interface Builder process in
# the tree rooted at $2 that is not already in the record at $1.
#
# Daemons appear throughout a build, and some leave the tree early, so a single
# snapshot at the end would miss them. This is called on a timer instead.
ib_record_snapshot() {
  local record="$1" root="$2" p start
  touch "$record"
  for p in $(ib_descendants "$root"); do
    ib_is_ib_process "$p" || continue
    start="$(ib_start_time "$p")"
    [ -n "$start" ] || continue
    # Already recorded: the start time is what makes re-recording unnecessary.
    grep -q "^$p	" "$record" 2>/dev/null && continue
    printf '%s\t%s\n' "$p" "$start" >> "$record"
  done
}

# Stop the recorded processes and report what survived.
#
# Order matters. The simulator is shut down first: a helper wedged mapping the
# runtime's dyld shared cache sits in an uninterruptible kernel wait, where no
# signal reaches it, and it is released only when the runtime goes away. Killing
# first would report processes that were about to clear on their own.
#
# Nothing is ever waited on. `wait` on a process in an uninterruptible wait would
# block this cleanup too, which is the failure it exists to bound.
#
# Prints the pids still alive afterwards; returns 1 if any remain, 0 if none do.
ib_cleanup() {
  local record="$1" simulator="$2" grace="${3:-10}"
  local pid start survivors=""

  if [ -n "$simulator" ]; then
    xcrun simctl shutdown "$simulator" 2>/dev/null || true
  fi

  # Helpers and daemons before the clients that spawned them, so a client cannot
  # relaunch a helper between the two passes.
  local order
  for order in IBAgent-iOS ibtoold ibtool; do
    while IFS=$'\t' read -r pid start; do
      [ -n "${pid:-}" ] || continue
      case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
        */"$order") ;;
        *) continue ;;
      esac
      # Same process as recorded? A reused pid has a different start time.
      [ "$(ib_start_time "$pid")" = "$start" ] || continue
      kill -TERM "$pid" 2>/dev/null || true
    done < "$record"
  done

  local waited=0
  while [ "$waited" -lt "$grace" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  for order in IBAgent-iOS ibtoold ibtool; do
    while IFS=$'\t' read -r pid start; do
      [ -n "${pid:-}" ] || continue
      case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
        */"$order") ;;
        *) continue ;;
      esac
      [ "$(ib_start_time "$pid")" = "$start" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done < "$record"
  done

  sleep 2
  while IFS=$'\t' read -r pid start; do
    [ -n "${pid:-}" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(ib_start_time "$pid")" = "$start" ] || continue
    survivors="$survivors $pid"
  done < "$record"

  if [ -n "$survivors" ]; then
    echo "still running after shutdown, SIGTERM and SIGKILL:$survivors" >&2
    return 1
  fi
  return 0
}

# Interface Builder processes on the machine that this build never recorded.
# Reported, never killed: they may belong to a person's own Xcode.
ib_unrecorded() {
  local record="$1" p
  touch "$record"
  for p in $(pgrep -x ibtool; pgrep -x ibtoold; pgrep -f 'IBAgent-iOS'); do
    grep -q "^$p	" "$record" 2>/dev/null || echo "$p"
  done | sort -un
}
