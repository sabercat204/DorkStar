#!/usr/bin/env bats
# tests/bats/test_enumerate_databases.bats — unit tests for the Tier 3
# `--databases` live-summary mode of `enumerate_run` (task 15I.1).
#
# Strategy: materialise real fixture SQLite databases on disk (the
# capture path runs real `sqlite_safe_copy` + real `sqlite3` queries)
# and point the relevant `*_PATH_OVERRIDE` env vars at them. Homes
# walk is driven by `MACAUDIT_USERS_DIR_OVERRIDE` so the fixture dir
# fully replaces `/Users`. `MACAUDIT_FDA_AVAILABLE` is pre-set so the
# probe never tries to read the real system TCC.db.

bats_require_minimum_version 1.5.0

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/surfaces.sh"
  # shellcheck source=/dev/null
  source "${LIB}/sqlite.sh"
  # shellcheck source=/dev/null
  source "${LIB}/tcc.sh"
  # shellcheck source=/dev/null
  source "${LIB}/sysdb.sh"
  # shellcheck source=/dev/null
  source "${LIB}/xprotect.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"
  # shellcheck source=/dev/null
  source "${LIB}/enumerate.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-enumdb.XXXXXX")"
  utils_tmpdir_init >/dev/null

  # Isolate $HOME under the fixture so per-user home walks are
  # deterministic. HOME is the first entry `_enumerate_tier3_homes`
  # emits, so we give it a fixture user tree and drop a TCC.db + a
  # quarantine DB underneath.
  ORIG_HOME="${HOME}"
  FAKE_USERS="${FIXTURE_DIR}/Users"
  mkdir -p "${FAKE_USERS}"
  FAKE_HOME="${FAKE_USERS}/alice"
  mkdir -p "${FAKE_HOME}"
  HOME="${FAKE_HOME}"
  export HOME

  # Route the homes walk at the fixture /Users tree.
  MACAUDIT_USERS_DIR_OVERRIDE="${FAKE_USERS}"
  export MACAUDIT_USERS_DIR_OVERRIDE

  # Default the FDA probe state to "no" so any test that cares can
  # flip it on via the override. The probe is memoised, so clearing
  # the variable in teardown is essential.
  unset MACAUDIT_FDA_AVAILABLE
}

teardown() {
  HOME="${ORIG_HOME:-$HOME}"
  export HOME
  unset MACAUDIT_USERS_DIR_OVERRIDE
  unset MACAUDIT_FDA_AVAILABLE
  unset TCC_SYSTEM_PATH_OVERRIDE
  unset KEXTPOLICY_PATH_OVERRIDE
  unset EXECPOLICY_PATH_OVERRIDE
  unset SYSTEMPOLICY_PATH_OVERRIDE
  unset XPROTECT_BUNDLE_OVERRIDE
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "${MACAUDIT_TMPDIR}" ]; then
    rm -rf -- "${MACAUDIT_TMPDIR}" || true
  fi
  unset MACAUDIT_TMPDIR
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

# _make_tcc_db <path> <row_count>
#   Materialise a TCC-shaped SQLite database with <row_count> dummy
#   rows in `access`. Schema mirrors the real TCC.db `access` table
#   closely enough for `SELECT COUNT(*)` to succeed.
_make_tcc_db() {
  local p="$1" n="$2"
  local dir
  dir=$(dirname -- "$p")
  mkdir -p "$dir"
  sqlite3 "$p" <<'SQL'
CREATE TABLE access (
  service TEXT NOT NULL,
  client TEXT NOT NULL,
  client_type INTEGER NOT NULL,
  auth_value INTEGER NOT NULL,
  auth_reason INTEGER NOT NULL,
  auth_version INTEGER NOT NULL,
  last_modified INTEGER NOT NULL,
  indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
  PRIMARY KEY (service, client, client_type, indirect_object_identifier)
);
SQL
  local i=0
  while [ "$i" -lt "$n" ]; do
    sqlite3 "$p" "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified, indirect_object_identifier)
      VALUES ('svc${i}', 'com.example.c${i}', 0, 2, 1, 1, 1700000000, 'UNUSED');"
    i=$((i + 1))
  done
}

# _make_kextpolicy_db <path> <user_rows> <mdm_rows>
_make_kextpolicy_db() {
  local p="$1" u="$2" m="$3"
  mkdir -p "$(dirname -- "$p")"
  sqlite3 "$p" <<'SQL'
CREATE TABLE kext_policy (team_id TEXT, bundle_id TEXT, allowed INTEGER, developer_name TEXT, flags INTEGER);
CREATE TABLE kext_policy_mdm (team_id TEXT, bundle_id TEXT, allowed INTEGER, developer_name TEXT, flags INTEGER);
SQL
  local i=0
  while [ "$i" -lt "$u" ]; do
    sqlite3 "$p" "INSERT INTO kext_policy VALUES ('T${i}', 'com.u.${i}', 1, 'Dev${i}', 0);"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$m" ]; do
    sqlite3 "$p" "INSERT INTO kext_policy_mdm VALUES ('TM${i}', 'com.m.${i}', 1, 'DevM${i}', 0);"
    i=$((i + 1))
  done
}

# _make_execpolicy_db <path>
#   Build an ExecPolicy DB with all three snapshotable tables present
#   and known row counts. Caller can omit tables by passing fewer
#   arguments; the basic form always materialises every table.
_make_execpolicy_db() {
  local p="$1"
  mkdir -p "$(dirname -- "$p")"
  sqlite3 "$p" <<'SQL'
CREATE TABLE legacy_exec_history_v4 (x INTEGER);
CREATE TABLE policy_scan_cache       (x INTEGER);
CREATE TABLE provisional_policy      (x INTEGER);
INSERT INTO legacy_exec_history_v4 VALUES (1), (2);
INSERT INTO policy_scan_cache       VALUES (1), (2), (3);
INSERT INTO provisional_policy      VALUES (1);
SQL
}

# _make_systempolicy_db <path> <rows>
_make_systempolicy_db() {
  local p="$1" n="$2"
  mkdir -p "$(dirname -- "$p")"
  sqlite3 "$p" "CREATE TABLE authority (id INTEGER PRIMARY KEY);"
  local i=0
  while [ "$i" -lt "$n" ]; do
    sqlite3 "$p" "INSERT INTO authority (id) VALUES (${i});"
    i=$((i + 1))
  done
}

# _make_quarantine_db <path> <rows>
_make_quarantine_db() {
  local p="$1" n="$2"
  mkdir -p "$(dirname -- "$p")"
  sqlite3 "$p" "CREATE TABLE LSQuarantineEvent (LSQuarantineEventIdentifier TEXT PRIMARY KEY);"
  local i=0
  while [ "$i" -lt "$n" ]; do
    sqlite3 "$p" "INSERT INTO LSQuarantineEvent VALUES ('uuid-${i}');"
    i=$((i + 1))
  done
}

# -----------------------------------------------------------------------------
# Happy path — every source populated, every labelled line present
# -----------------------------------------------------------------------------

@test "enumerate_run --databases: happy path renders every labelled line" {
  # Pretend FDA succeeded and sudo is available so no gates trip.
  MACAUDIT_FDA_AVAILABLE=yes
  export MACAUDIT_FDA_AVAILABLE
  utils_has_sudo() { return 0; }

  # --- System TCC.db (7 rows) ----------------------------------------
  sys_tcc="${FIXTURE_DIR}/system/TCC.db"
  _make_tcc_db "${sys_tcc}" 7
  TCC_SYSTEM_PATH_OVERRIDE="${sys_tcc}"
  export TCC_SYSTEM_PATH_OVERRIDE

  # --- Per-user TCC.db for alice (the fixture $HOME) -----------------
  alice_tcc="${FAKE_HOME}/Library/Application Support/com.apple.TCC/TCC.db"
  _make_tcc_db "${alice_tcc}" 3

  # --- KextPolicy (4 user, 2 mdm) ------------------------------------
  kp="${FIXTURE_DIR}/KextPolicy"
  _make_kextpolicy_db "${kp}" 4 2
  KEXTPOLICY_PATH_OVERRIDE="${kp}"
  export KEXTPOLICY_PATH_OVERRIDE

  # --- ExecPolicy (2,3,1) --------------------------------------------
  ep="${FIXTURE_DIR}/ExecPolicy"
  _make_execpolicy_db "${ep}"
  EXECPOLICY_PATH_OVERRIDE="${ep}"
  export EXECPOLICY_PATH_OVERRIDE

  # --- SystemPolicy (5 rows) -----------------------------------------
  sp="${FIXTURE_DIR}/SystemPolicy"
  _make_systempolicy_db "${sp}" 5
  SYSTEMPOLICY_PATH_OVERRIDE="${sp}"
  export SYSTEMPOLICY_PATH_OVERRIDE

  # --- Per-user quarantine (2 rows) for alice ------------------------
  alice_q="${FAKE_HOME}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
  _make_quarantine_db "${alice_q}" 2

  # --- XProtect bundle with a version plist --------------------------
  xp="${FIXTURE_DIR}/XProtect.bundle"
  mkdir -p "${xp}/Contents"
  cat > "${xp}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>2173</string>
</dict>
</plist>
PLIST
  XPROTECT_BUNDLE_OVERRIDE="${xp}"
  export XPROTECT_BUNDLE_OVERRIDE

  run enumerate_run --databases
  [ "${status}" -eq 0 ]

  # Header
  echo "${output}" | grep -qx 'TIER 3 — SECURITY DATABASES (live)'

  # System TCC — 7 rows
  echo "${output}" | grep -qE '^  System TCC rows:[[:space:]]+7$'

  # Per-user TCC line for alice — uses `~alice/Library/...TCC.db` shape
  echo "${output}" | grep -qE '^  ~alice/Library/\.\.\.TCC\.db:[[:space:]]+3$'

  # KextPolicy two lines
  echo "${output}" | grep -qE '^  KextPolicy \(kext_policy\):[[:space:]]+4$'
  echo "${output}" | grep -qE '^  KextPolicy \(kext_policy_mdm\):[[:space:]]+2$'

  # ExecPolicy per-table lines
  echo "${output}" | grep -qE '^  ExecPolicy \(legacy_exec_history_v4\):[[:space:]]+2$'
  echo "${output}" | grep -qE '^  ExecPolicy \(policy_scan_cache\):[[:space:]]+3$'
  echo "${output}" | grep -qE '^  ExecPolicy \(provisional_policy\):[[:space:]]+1$'

  # SystemPolicy authority rows
  echo "${output}" | grep -qE '^  SystemPolicy authority rows:[[:space:]]+5$'

  # Quarantine for alice
  echo "${output}" | grep -qE '^  ~alice/\.\.\.QuarantineEventsV2:[[:space:]]+2$'

  # Auth rules + rights — rely on sysdb curated sets. Counts are
  # whatever sysdb_authdb_{rule,right}_names emit (rules = 0 in
  # Phase 1, rights = the curated list). Just assert labels and a
  # decimal value.
  echo "${output}" | grep -qE '^  Auth rules captured:[[:space:]]+[0-9]+$'
  echo "${output}" | grep -qE '^  Auth rights captured:[[:space:]]+[0-9]+$'

  # XProtect bundle version
  echo "${output}" | grep -qE '^  XProtect bundle version:[[:space:]]+2173$'
}

# -----------------------------------------------------------------------------
# FDA unavailable — system TCC, KextPolicy (both lines), and ExecPolicy
# -- skipped with the `fda-unavailable` reason
# -----------------------------------------------------------------------------

@test "enumerate_run --databases: FDA-gated lines skip with 'fda-unavailable'" {
  MACAUDIT_FDA_AVAILABLE=no
  export MACAUDIT_FDA_AVAILABLE
  utils_has_sudo() { return 0; }

  # No overrides set for the FDA-gated surfaces — the FDA gate trips
  # before the path is ever touched. We still need XProtect to be
  # skippable so the test output is predictable.
  XPROTECT_BUNDLE_OVERRIDE="${FIXTURE_DIR}/missing-bundle"
  export XPROTECT_BUNDLE_OVERRIDE

  run enumerate_run --databases
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -qE '^  System TCC rows:[[:space:]]+--- \(skipped: fda-unavailable\)$'
  echo "${output}" | grep -qE '^  KextPolicy \(kext_policy\):[[:space:]]+--- \(skipped: fda-unavailable\)$'
  echo "${output}" | grep -qE '^  KextPolicy \(kext_policy_mdm\):[[:space:]]+--- \(skipped: fda-unavailable\)$'
  echo "${output}" | grep -qE '^  ExecPolicy:[[:space:]]+--- \(skipped: fda-unavailable\)$'
}

# -----------------------------------------------------------------------------
# No sudo — SystemPolicy line skipped with `no-sudo`
# -----------------------------------------------------------------------------

@test "enumerate_run --databases: SystemPolicy line skips with 'no-sudo'" {
  MACAUDIT_FDA_AVAILABLE=yes
  export MACAUDIT_FDA_AVAILABLE
  utils_has_sudo() { return 1; }

  run enumerate_run --databases
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -qE '^  SystemPolicy authority rows:[[:space:]]+--- \(skipped: no-sudo\)$'
}

# -----------------------------------------------------------------------------
# XProtect bundle missing — version line skipped with `missing`
# -----------------------------------------------------------------------------

@test "enumerate_run --databases: XProtect version skips with 'missing' when bundle is absent" {
  MACAUDIT_FDA_AVAILABLE=yes
  export MACAUDIT_FDA_AVAILABLE
  utils_has_sudo() { return 0; }

  XPROTECT_BUNDLE_OVERRIDE="${FIXTURE_DIR}/does-not-exist.bundle"
  export XPROTECT_BUNDLE_OVERRIDE

  run enumerate_run --databases
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -qE '^  XProtect bundle version:[[:space:]]+--- \(skipped: missing\)$'
}

# -----------------------------------------------------------------------------
# --all dispatch — Tier 3 block is printed alongside Tier 1 / Tier 2
# -----------------------------------------------------------------------------

@test "enumerate_run --all: Tier 3 header is present alongside Tier 1 and Tier 2" {
  MACAUDIT_FDA_AVAILABLE=no
  export MACAUDIT_FDA_AVAILABLE
  utils_has_sudo() { return 1; }

  XPROTECT_BUNDLE_OVERRIDE="${FIXTURE_DIR}/missing-bundle"
  export XPROTECT_BUNDLE_OVERRIDE

  run enumerate_run --all
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -qx 'TIER 1 — PERSISTENCE (live)'
  echo "${output}" | grep -qx 'TIER 2 — PREFERENCES (live)'
  echo "${output}" | grep -qx 'TIER 3 — SECURITY DATABASES (live)'
}

# -----------------------------------------------------------------------------
# Default (no flag) dispatch — should now include Tier 3
# -----------------------------------------------------------------------------

@test "enumerate_run (no flag): Tier 3 header is present by default" {
  MACAUDIT_FDA_AVAILABLE=no
  export MACAUDIT_FDA_AVAILABLE
  utils_has_sudo() { return 1; }

  XPROTECT_BUNDLE_OVERRIDE="${FIXTURE_DIR}/missing-bundle"
  export XPROTECT_BUNDLE_OVERRIDE

  run enumerate_run
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -qx 'TIER 3 — SECURITY DATABASES (live)'
}
