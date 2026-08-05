#!/bin/sh
#Test harness for manage.sh. Plain POSIX sh plus the stub docker in
#tests/stub - no real docker daemon is touched. Each case builds a fresh
#sandbox of fake app folders, runs manage.sh against it, and asserts on the
#exit status, the output, and the exact docker actions the stub recorded.
#
#  sh tests/run-tests.sh          run everything
#  sh tests/run-tests.sh -v       also show each case's captured output

#The assert helpers use `cond && ok || fail` on purpose (ok never fails),
#and ls on script-generated archive names is safe (no spaces or newlines).
#shellcheck disable=SC2015,SC2012
set -u

#Backups are .tar.bz2, so the roundtrip cases need bzip2 - fail fast with a
#clear message rather than 14 confusing case failures.
if ! command -v bzip2 >/dev/null 2>&1; then
  echo "these tests need bzip2 installed (backup archives are .tar.bz2)" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
SCRIPT="$repo/docker_volumes/manage.sh"
VERBOSE=${1:-}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dockerdance-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
CURRENT=""

#--- tiny framework ----------------------------------------------------------
begin() {
  CURRENT=$1
  SANDBOX="$WORK/$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-')"
  export DD_STATE="$SANDBOX/.state"
  mkdir -p "$SANDBOX" "$DD_STATE"
  : >"$DD_STATE/up"; : >"$DD_STATE/actions"; : >"$DD_STATE/pulled"
  cp "$SCRIPT" "$SANDBOX/manage.sh"
  OUT="$SANDBOX/.out"
  STATUS=0
}

#Make fake app folders in the sandbox
apps() {
  for a in "$@"; do
    mkdir -p "$SANDBOX/$a"
    printf 'services:\n  x:\n    image: busybox\n' >"$SANDBOX/$a/docker-compose.yml"
  done
}

#Run manage.sh in the sandbox with the stub docker first in PATH
run() {
  ( cd "$SANDBOX" && \
    PATH="$here/stub:$PATH" DOCKER_VOLUMES="$SANDBOX/" HEALTH_TIMEOUT=0 TERM=dumb \
    sh manage.sh "$@" ) >"$OUT" 2>&1
  STATUS=$?
  [ -n "$VERBOSE" ] && { echo "--- $CURRENT: manage.sh $* (exit $STATUS)"; sed 's/^/    /' "$OUT"; }
  return 0
}

ok() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL [$CURRENT] $1"
  [ -z "$VERBOSE" ] && sed 's/^/    /' "$OUT" 2>/dev/null
}

assert_status()      { [ "$STATUS" -eq "$1" ] && ok || fail "expected exit $1, got $STATUS"; }
assert_out()         { grep -q "$1" "$OUT" && ok || fail "output should contain: $1"; }
assert_not_out()     { grep -q "$1" "$OUT" && fail "output should NOT contain: $1" || ok; }
assert_action()      { grep -qx "$1" "$DD_STATE/actions" && ok || fail "expected docker action: $1"; }
assert_no_action()   { grep -qx "$1" "$DD_STATE/actions" && fail "unexpected docker action: $1" || ok; }
assert_pulled()      { grep -qx "$1" "$DD_STATE/pulled" && ok || fail "expected a pull for: $1"; }
assert_not_pulled()  { grep -qx "$1" "$DD_STATE/pulled" && fail "should not have pulled: $1" || ok; }
assert_file()        { [ -e "$1" ] && ok || fail "expected file: $1"; }
assert_no_file()     { [ -e "$1" ] && fail "file should not exist: $1" || ok; }

#--- cases -------------------------------------------------------------------

begin "update: all running, all succeed"
apps alpha beta gamma
printf 'alpha\nbeta\ngamma\n' >"$DD_STATE/up"
run update --yes
assert_status 0
assert_out "Updated all 3 apps"
assert_action "STOP:alpha"; assert_action "UP:alpha"
assert_action "STOP:gamma"; assert_action "UP:gamma"

begin "update: carries on past pull and start failures"
apps alpha beta gamma delta
printf 'alpha\nbeta\ngamma\ndelta\n' >"$DD_STATE/up"
echo beta  >"$DD_STATE/fail-pull"
echo gamma >"$DD_STATE/fail-up"
run update --yes
assert_status 1
assert_out "1 failed"
assert_out "1 skipped"
assert_out "skipped: beta"
assert_out "failed:  gamma"
assert_action "UP:delta"          #the run reached the app after the failures
assert_no_action "STOP:beta"      #skipped means untouched

begin "update: stopped apps stay stopped by default, image still pulled"
apps alpha beta gamma
printf 'alpha\n' >"$DD_STATE/up"
run update --yes
assert_status 0
assert_out "left stopped"
assert_action "UP:alpha"
assert_no_action "UP:beta"
assert_no_action "UP:gamma"
assert_pulled beta

begin "update: --stopped=skip leaves stopped apps unpulled"
apps alpha beta
printf 'alpha\n' >"$DD_STATE/up"
run update --yes --stopped=skip
assert_status 1                    #skipped apps make the run non-zero
assert_out "1 skipped"
assert_not_pulled beta
assert_no_action "UP:beta"

begin "update: --stopped=start brings everything up"
apps alpha beta
printf 'alpha\n' >"$DD_STATE/up"
run update --yes --stopped=start
assert_status 0
assert_action "UP:beta"

begin "update: --stopped rejects unknown values"
apps alpha
run update --yes --stopped=banana
assert_status 1
assert_out "must be one of"

begin "dry-run: reports intent, touches nothing"
apps alpha beta
printf 'alpha\n' >"$DD_STATE/up"
run update --dry-run
assert_status 0
assert_out "dry-run"
assert_no_action "STOP:alpha"
assert_not_pulled alpha

begin "backup: roundtrip - archive created 600, restore puts data back"
apps alpha
printf 'alpha\n' >"$DD_STATE/up"
echo "precious" >"$SANDBOX/alpha/data.txt"
run backup alpha
assert_status 0
archive=$(ls "$SANDBOX/backup/alpha_"*.tar.bz2 2>/dev/null | head -1)
assert_file "$archive"
perms=$(ls -l "$archive" | cut -c1-10)
[ "$perms" = "-rw-------" ] && ok || fail "archive should be 600, got $perms"
echo "clobbered" >"$SANDBOX/alpha/data.txt"
run restore --yes alpha
assert_status 0
grep -qx "precious" "$SANDBOX/alpha/data.txt" && ok || fail "restore should bring back the original data"

begin "backup: stopped app is archived where it lies, not started"
apps alpha
run backup alpha
assert_status 0
assert_out "backed up, left stopped"
assert_no_action "STOP:alpha"
assert_no_action "UP:alpha"

begin "archives: prefix apps (vault/vault2) never cross - prune and restore"
apps vault vault2
mkdir -p "$SANDBOX/backup"
#vault's own legacy no-separator archive (pre-0.4.1), and vault2's newer one
echo v1 | tar -cjf "$SANDBOX/backup/vault2026-08-01.tar.bz2" -T /dev/null 2>/dev/null || : >"$SANDBOX/backup/vault2026-08-01.tar.bz2"
sleep 1
: >"$SANDBOX/backup/vault22026-08-03.tar.bz2"
echo "keepme" >"$SANDBOX/vault/data.txt"
run backup vault
assert_status 0
BACKUP_KEEP=1 run backup vault    #prune down to vault's single newest
assert_status 0
assert_file "$SANDBOX/backup/vault22026-08-03.tar.bz2"   #vault2's must survive vault's prune
assert_no_file "$SANDBOX/backup/vault2026-08-01.tar.bz2" #vault's own old one is pruned
echo "clobbered" >"$SANDBOX/vault/data.txt"
run restore --yes vault
assert_status 0
grep -qx "keepme" "$SANDBOX/vault/data.txt" && ok || fail "restore must pick vault's archive, not vault2's"

begin "archives: legacy no-separator format still restores"
apps alpha
echo "old-data" >"$SANDBOX/alpha/keep.txt"
( cd "$SANDBOX" && tar -cjf "backup/alpha2026-08-01.tar.bz2" alpha ) 2>/dev/null \
  || ( mkdir -p "$SANDBOX/backup" && cd "$SANDBOX" && tar -cjf "backup/alpha2026-08-01.tar.bz2" alpha )
rm "$SANDBOX/alpha/keep.txt"
run restore --yes alpha
assert_status 0
assert_file "$SANDBOX/alpha/keep.txt"

begin "lock: a live run blocks, a dead run's lock self-clears"
apps alpha
printf 'alpha\n' >"$DD_STATE/up"
mkdir "$SANDBOX/.dockerdance.lock"
echo "$$" >"$SANDBOX/.dockerdance.lock/pid"   #this test runner: alive
run stop alpha
assert_status 1
assert_out "is active"
sh -c 'exit 0' & dead_pid=$!; wait "$dead_pid" 2>/dev/null
rm -rf "$SANDBOX/.dockerdance.lock"; mkdir "$SANDBOX/.dockerdance.lock"
echo "$dead_pid" >"$SANDBOX/.dockerdance.lock/pid"
run stop alpha
assert_status 0
assert_out "stale lock"
assert_action "STOP:alpha"

begin "restore: a date picks that archive; no date takes the newest"
apps alpha
mkdir -p "$SANDBOX/backup"
echo "january" >"$SANDBOX/alpha/keep.txt"
( cd "$SANDBOX" && tar -cjf "backup/alpha_2026-01-01.tar.bz2" alpha )
sleep 1
echo "february" >"$SANDBOX/alpha/keep.txt"
( cd "$SANDBOX" && tar -cjf "backup/alpha_2026-02-02.tar.bz2" alpha )
echo "clobbered" >"$SANDBOX/alpha/keep.txt"
run restore --yes alpha 2026-01-01
assert_status 0
grep -qx "january" "$SANDBOX/alpha/keep.txt" && ok || fail "dated restore should pick the 2026-01-01 archive"
run restore --yes alpha
assert_status 0
assert_out "older archive(s) also exist"
grep -qx "february" "$SANDBOX/alpha/keep.txt" && ok || fail "undated restore should pick the newest archive"
run restore --yes alpha 2030-12-31
assert_status 1
assert_out "No backup dated 2030-12-31"

begin "prune: runs after update with --prune, not without"
apps alpha
printf 'alpha\n' >"$DD_STATE/up"
run update --yes
assert_no_action "PRUNE"
run update --yes --prune
assert_action "PRUNE"
assert_out "reclaimed 42MB"

begin "prune: standalone command"
apps alpha
run prune --yes
assert_status 0
assert_action "PRUNE"

begin "missing app folder: reported, run continues"
apps alpha gamma
printf 'alpha\ngamma\n' >"$DD_STATE/up"
run start alpha ghost gamma
assert_status 1
assert_out "failed:  ghost"
assert_action "UP:gamma"

#--- summary -----------------------------------------------------------------
echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
