#!/bin/bash
# The grants step is the difference between a speech test that takes 2.6s and
# one that takes 54.8s, and in a full run that difference kills the test at its
# execution allowance. Measured on this machine: a grant issued immediately
# after a fresh erase and boot fails with EPERM — the privacy service is not
# ready — and the same grant succeeds seconds later. This runs the REAL
# grant_test_permissions function against a stub xcrun that is not ready at
# first and recovers, plus one that never recovers.
set -u
SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
PASS=0; FAIL=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; PASS=$((PASS+1)); else echo "FAIL  $2"; FAIL=$((FAIL+1)); fi; }

extract_grants() {
  for fn in tcc_service_name tcc_grant grant_via_simctl grant_via_tcc grant_test_permissions; do
    awk '/^'"$fn"'\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$SCRIPT"
  done
}

# A real TCC database with the columns the fallback writes, so the fallback
# cases exercise real sqlite3 against the real schema shape. Seeded with a
# microphone row copied verbatim from a device where simctl wrote it itself,
# so the fallback's output can be compared against what simctl produces.
#   kTCCServiceMicrophone|fm.auris|0|2|4|1|UNUSED|0
make_fake_tcc_db() {
  local home="$1"
  mkdir -p "$home/Library/Developer/CoreSimulator/Devices/fake-sim/data/Library/TCC"
  sqlite3 "$home/Library/Developer/CoreSimulator/Devices/fake-sim/data/Library/TCC/TCC.db" \
    "CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB, policy_id INTEGER, indirect_object_identifier_type INTEGER, indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB, flags INTEGER, last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), PRIMARY KEY (service, client, client_type, indirect_object_identifier));
     INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified) VALUES ('kTCCServiceMicrophone','fm.auris',0,2,4,1,'UNUSED',0,1794985249);"
}

# The row the fallback wrote must look like the row simctl wrote: same
# kTCCService… spelling, client, client_type, auth_value, auth_reason,
# auth_version, indirect_object_identifier and flags. A row under a name the
# database does not key (the bare simctl name) fails here, as it would on a
# device: the column layout can be right while the grant is meaningless.
check_fallback_row_format() {
  local home="$1" db
  db="$home/Library/Developer/CoreSimulator/Devices/fake-sim/data/Library/TCC/TCC.db"
  local row
  row=$(sqlite3 "$db" "SELECT service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags FROM access WHERE client='fm.auris' AND service='kTCCServiceSpeechRecognition';")
  [ "$row" = "kTCCServiceSpeechRecognition|fm.auris|0|2|4|1|UNUSED|0" ] || return 1
  [ -z "$(sqlite3 "$db" "SELECT client FROM access WHERE service='speech-recognition';")" ] || return 1
  return 0
}

make_stub_xcrun() {
  local dir="$1" fail_first="$2"
  mkdir -p "$dir"
  cat > "$dir/xcrun" <<STUB
#!/bin/bash
# Count only privacy grant attempts. The call shape is
# call "simctl privacy <device> grant <service> <bundle>": the fourth argument
# is "grant".
if [ "\$2" = "privacy" ] && [ "\$4" = "grant" ]; then
        n=\$(cat "$dir/count" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "$dir/count"
    if [ "\$n" -le "$fail_first" ]; then
      echo "Simulator device failed to complete the requested operation." >&2
      exit 1
    fi
    exit 0
fi
exec /usr/bin/xcrun "\$@"
STUB
  chmod +x "$dir/xcrun"
}

run_case() {
  local name="$1" fail_first="$2" want="$3"
  local dir; dir=$(mktemp -d)
  make_stub_xcrun "$dir" "$fail_first"
  {
    echo 'set -euo pipefail'
    echo 'SIMULATOR_ID=fake-sim'
    make_fake_tcc_db "$dir/home"
    echo 'HOME='"\"$dir\""'/home'
    # The real functions verbatim; their xcrun calls are unqualified, so the
    # stub earlier in PATH replaces them.
    extract_grants
    echo 'set +e'
    echo 'grant_test_permissions fm.auris 6 1'
    echo 'echo "GRANTS_RC=$?"'
  } > "$dir/case.sh"
  PATH="$dir:$PATH" timeout 60 bash "$dir/case.sh" > "$dir/out.txt" 2>&1
  local ok=0
  grep -q "GRANTS_RC=$want" "$dir/out.txt" || ok=1
  if [ "$want" = 0 ]; then
    grep -q "GRANTS_RC=0" "$dir/out.txt" || ok=1
  else
    grep -q "could not be granted" "$dir/out.txt" || ok=1
  fi
  report "$ok" "$name"
  sed 's/^/        /' "$dir/out.txt" | tail -3
  rm -rf "$dir"
}

# Microphone: privacy service not ready for the first two tries, then it
# recovers — retry, succeed. Speech never touches simctl: the stub counts one
# grant call per success, so two successes would mean speech asked simctl.
run_case "microphone retries transient EPERM; speech skips simctl entirely" 2 0
# Microphone never lands within the bound: it falls back to the TCC database
# and the step still ends granted.
run_case "a microphone grant that never lands falls back to the TCC database" 99 0

# Speech goes through the TCC database with simctl never consulted, and the
# row it writes must match, field for field, the microphone row simctl itself
# wrote on this machine (format check in check_fallback_row_format, including
# that no row exists under the bare simctl spelling).
run_fallback_case() {
  local name="$1" sqlite_ok="$2" want="$3" want_text="$4"
  local dir; dir=$(mktemp -d)
  # simctl works for microphone here; speech must not call it at all.
  make_stub_xcrun "$dir" 0
  make_fake_tcc_db "$dir/home"
  if [ "$sqlite_ok" != 1 ]; then
    # Break writes, keep the file present: the insert must fail visibly.
    cat > "$dir/sqlite3" <<STUB
#!/bin/bash
case "\$*" in
  *INSERT*) exit 1 ;;
esac
exec /usr/bin/sqlite3 "\$@"
STUB
    chmod +x "$dir/sqlite3"
  fi
  {
    echo 'set -euo pipefail'
    echo 'SIMULATOR_ID=fake-sim'
    echo 'HOME='""$dir""'/home'
    extract_grants
    echo 'set +e'
    echo 'grant_test_permissions fm.auris 3 1'
    echo 'echo "GRANTS_RC=$?"'
  } > "$dir/case.sh"
  PATH="$dir:$PATH" timeout 60 bash "$dir/case.sh" > "$dir/out.txt" 2>&1
  local ok=0
  grep -q "GRANTS_RC=$want" "$dir/out.txt" || ok=1
  grep -q "$want_text" "$dir/out.txt" || ok=1
  if [ "$want" = 0 ]; then
    check_fallback_row_format "$dir/home" \
      || { echo "        the inserted row does not match the row simctl writes"; ok=1; }
    n=$(cat "$dir/count" 2>/dev/null || echo 0)
    [ "$n" = 1 ] || { echo "        simctl saw $n grant calls; speech must make none"; ok=1; }
  fi
  report "$ok" "$name"
  sed 's/^/        /' "$dir/out.txt" | tail -3
  rm -rf "$dir"
}

run_fallback_case "a service simctl never grants is granted via the TCC database" 1 0 "granted via the TCC database"
run_fallback_case "a grant that even the fallback cannot write fails with a reason" 0 1 "could not be granted via the TCC database"

echo "grants self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
