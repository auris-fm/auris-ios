#!/bin/bash
# Prove the Interface Builder cleanup kills what this build started and leaves
# everything else alone.
#
# The stakes are a shared machine: a person's own Xcode runs processes with the
# same names, so a cleanup that matches on name would break their build. These
# cases use fake processes named exactly like the real ones, so the assertions are
# about which processes die, not about how the code reads.
#
# Each case is stated as an outcome: the recorded process must be gone, the decoy
# must still be alive. A version that killed by name fails the decoy case; a
# version that killed nothing fails the recorded case.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/ib-processes.sh"
# shellcheck source=/dev/null
source "$LIB"

PASS=0
FAIL=0

report() {
  if [ "$1" -eq 0 ]; then echo "PASS  $2"; PASS=$((PASS + 1));
  else echo "FAIL  $2"; FAIL=$((FAIL + 1)); fi
}

# A stand-in for an Interface Builder process: a real process whose executable is
# named like the real one, so `ps -o comm=` reports that name. Nothing here
# compiles anything; only identity and survival are under test.
# The copy must be re-signed. A renamed copy of a platform binary keeps its
# original signature, and the kernel kills it on exec (measured: SIGKILL before
# main), which would make every case here fail for a reason unrelated to the code
# under test.
fake_ib() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  cp /bin/sleep "$dir/$name"
  codesign -f -s - --identifier "com.apple.$name" "$dir/$name" >/dev/null 2>&1
  # Output redirected: a background process that inherits this function's stdout
  # keeps the command substitution's pipe open, so `$(fake_ib ...)` would never
  # return even though the pid was already printed.
  "$dir/$name" 300 >/dev/null 2>&1 &
  echo $!
}

alive() { kill -0 "$1" 2>/dev/null; }

# Case 1: a recorded process is stopped, and an unrecorded one with the same name
# survives. This is the pair the whole mechanism exists for.
case_recorded_dies_decoy_lives() {
  local dir; dir=$(mktemp -d)
  local record="$dir/record.tsv"
  : > "$record"

  local ours decoy
  ours=$(fake_ib "$dir/bin" ibtoold)
  decoy=$(fake_ib "$dir/bin2" ibtoold)
  printf '%s\t%s\n' "$ours" "$(ib_start_time "$ours")" >> "$record"

  ib_cleanup "$record" "" 2 >/dev/null 2>&1

  local ok=0
  alive "$ours" && ok=1
  alive "$decoy" || ok=1
  report "$ok" "recorded process stopped, unrecorded decoy untouched"
  kill -KILL "$ours" "$decoy" 2>/dev/null
  rm -rf "$dir"
}

# Case 2: a snapshot records the Interface Builder processes reachable from the
# given root, and nothing else — including a same-named process outside it.
case_snapshot_records_only_the_tree() {
  local dir; dir=$(mktemp -d)
  local record="$dir/record.tsv"
  : > "$record"

  # `inside` runs as a child of the stand-in root below, so it is in the tree; the
  # detached one is not. Both have the same name — the difference the snapshot has
  # to get right is reachability, not naming. The root is a real process (a sleep
  # copy standing in for xcodebuild) so the walk has a tree to descend.
  local leaf inside outside root
  leaf=$(fake_ib "$dir/leaf" ibtool)
  mkdir -p "$dir/root" "$dir/bin"
  cp /bin/sleep "$dir/root/parent"
  cp /bin/sleep "$dir/bin/ibtoold"
  codesign -f -s - --identifier com.apple.auris-ibtest-parent "$dir/root/parent" >/dev/null 2>&1
  codesign -f -s - --identifier com.apple.ibtoold "$dir/bin/ibtoold" >/dev/null 2>&1
  # The root is a script that stays alive as the executable's actual parent. A
  # bare `cmd &` from a function works interactively but not inside this script:
  # the direct child of $! is then bash's fork and the executable is exec'd
  # elsewhere, so pgrep -P finds nothing (measured). The wrapper keeps parent and
  # child in one verifiable line, the shape xcodebuild -> ibtool has.
  cat > "$dir/wrap.sh" <<'WRAP'
#!/bin/bash
"$1" 300 >/dev/null 2>&1 &
"$2" 300 >/dev/null 2>&1 &
wait
WRAP
  chmod +x "$dir/wrap.sh"
  "$dir/wrap.sh" "$dir/root/parent" "$dir/bin/ibtoold" >/dev/null 2>&1 &
  root=$!
  sleep 1
  sleep 1
  # The root wrapper's children are the stand-in for xcodebuild and the Interface
  # Builder process. `inside` is whichever child is named like the real thing.
  outside=$(mktemp -d)/ibtoold
  inside=""
  for p in $(pgrep -P "$root" | tr '\n' ' '); do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in
      */ibtoold) inside="$p" ;;
    esac
  done
  # If no child is named like an Interface Builder process, the snapshot cases
  # have lost their subject and must say so rather than assert against nothing
  # (a vacuous pass).
  if [ -z "$inside" ]; then
    echo "SKIP  snapshot cases (no Interface Builder child under the stand-in root)"
    pkill -KILL -P "$root" 2>/dev/null
    kill -KILL "$leaf" "$root" 2>/dev/null
    rm -rf "$dir" "$(dirname "$outside")"
    return 0
  fi
  mkdir -p "$(dirname "$outside")"
  cp /bin/sleep "$outside"
  codesign -f -s - --identifier com.apple.ibtoold "$outside" >/dev/null 2>&1
  # A new session is not enough: the process would still be this shell's child and
  # so still reachable. Double-fork instead, so it is reparented to launchd — which
  # is exactly what a real `ibtoold` does, and what makes it unidentifiable later.
  python3 - "$outside" <<'PY' >/dev/null 2>&1
import os, sys
target = sys.argv[1]
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        os.execv(target, [target, '300'])
    os._exit(0)
os.wait()
PY
  sleep 1
  local detached
  detached=$(pgrep -f "$outside" | head -1)

  ib_record_snapshot "$record" "$leaf"
  local ok=0
  grep -q "^$inside	" "$record" && ok=1
  grep -q "^$detached	" "$record" && ok=1
  report "$ok" "snapshot of a leaf records no unrelated processes"

  : > "$record"
  ib_record_snapshot "$record" "$root"
  # The root has two children: the stand-in for xcodebuild and the Interface
  # Builder process. Only the latter belongs in the record: the assertion is that
  # the record holds exactly that process — not its sibling, not the detached one.
  ok=0
  # The wrapper's other child (the stand-in for xcodebuild) is not an Interface
  # Builder process and must not be in the record either.
  n_recorded=$(wc -l < "$record" | tr -d ' ')
  [ "$n_recorded" -eq 1 ] || ok=1
  if ! grep -q "^$inside	" "$record"; then
    ok=1
  fi
  if grep -q "^$detached	" "$record"; then
    ok=1
  fi
  report "$ok" "snapshot records exactly the tree's Interface Builder processes and not the detached one"

  kill -KILL "$leaf" "$root" "$inside" "$detached" 2>/dev/null
  pkill -KILL -P "$root" 2>/dev/null
  rm -rf "$dir" "$(dirname "$outside")"
}

# Case 3: a reused pid is not killed. The record holds a start time that no longer
# matches, which is what a recycled pid looks like.
case_reused_pid_is_not_killed() {
  local dir; dir=$(mktemp -d)
  local record="$dir/record.tsv"
  local victim
  victim=$(fake_ib "$dir/bin" ibtoold)
  printf '%s\t%s\n' "$victim" "Thu Jan  1 00:00:00 1970" > "$record"

  ib_cleanup "$record" "" 2 >/dev/null 2>&1
  local ok=0
  alive "$victim" || ok=1
  report "$ok" "pid whose start time differs from the record is left running"
  kill -KILL "$victim" 2>/dev/null
  rm -rf "$dir"
}

# Case 4: unrecorded processes are named, so a run can report what it did not touch
# rather than silently leaving the machine dirty.
case_unrecorded_are_reported() {
  local dir; dir=$(mktemp -d)
  local record="$dir/record.tsv"
  : > "$record"
  local decoy
  decoy=$(fake_ib "$dir/bin" ibtoold)
  local listed
  listed="$(ib_unrecorded "$record")"
  local ok=0
  grep -q "^$decoy$" <<< "$listed" || ok=1
  report "$ok" "an unrecorded Interface Builder process is reported"
  kill -KILL "$decoy" 2>/dev/null
  rm -rf "$dir"
}

# Case 5: the cleanup returns failure when something survives, so the run is marked
# failed rather than reporting a clean stop it did not achieve.
case_survivor_is_a_failure() {
  local dir; dir=$(mktemp -d)
  local record="$dir/record.tsv"
  # A recorded process that ignores SIGTERM and cannot be SIGKILLed either is what
  # a helper wedged in an uninterruptible kernel wait looks like. That state cannot
  # be produced on demand, so the survival path is exercised by making the kill
  # step a no-op for a live recorded process: the assertion is that a survivor is
  # reported as failure rather than as a clean stop.
  local victim
  victim=$(fake_ib "$dir/bin" ibtoold)
  printf '%s\t%s\n' "$victim" "$(ib_start_time "$victim")" > "$record"
  kill() { :; }
  ib_cleanup "$record" "" 1 >/dev/null 2>&1
  local status=$?
  unset -f kill
  local ok=0
  [ "$status" -eq 1 ] || ok=1
  report "$ok" "a surviving process makes the cleanup report failure"
  command kill -KILL "$victim" 2>/dev/null
  rm -rf "$dir"
}

case_recorded_dies_decoy_lives
case_snapshot_records_only_the_tree
case_reused_pid_is_not_killed
case_unrecorded_are_reported
case_survivor_is_a_failure

echo "ib-processes self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
