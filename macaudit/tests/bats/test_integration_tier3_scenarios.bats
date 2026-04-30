#!/usr/bin/env bats
# tests/bats/test_integration_tier3_scenarios.bats — end-to-end
# integration scenarios for tasks 16.18 through 16.22 of the macaudit
# spec. Completes the Tier 3 integration coverage begun in
# test_integration_tier3_anomalies.bats (scenarios 16.13–16.17) with
# the remaining cross-cutting behaviours: graceful degradation when
# FDA is unavailable, the safe-copy invariant that never mutates
# source databases, two cross-surface correlation scenarios, and the
# determinism invariant across two back-to-back baselines.
#
# Each test:
#
#   * Creates a per-test $FIXTURE_DIR and seeds it as a fake $HOME
#     with the Library subdirs the Tier 1 / Tier 2 walks need so they
#     do not error out before Tier 3 runs (including the per-user
#     Application Support/com.apple.TCC parent).
#   * Pins the relevant `*_PATH_OVERRIDE` env var(s) at fixture files
#     so no test ever touches /Library or /var.
#   * Pins MACAUDIT_FDA_AVAILABLE / MACAUDIT_MDM_MANAGED / MACAUDIT_PPPC_JSON
#     where needed to avoid real probes and to drive the R1/R4 rules.
#   * Uses `--tier all --user-only` so Tier 3 captures but no sudo is
#     required for Tier 1 / Tier 2.
#   * Writes the audit delta to ${FIXTURE_DIR}/delta.json via --output
#     and reads from that file rather than parsing ${output}, which
#     may be contaminated by stderr in the bats environment.
#   * Tears everything down (rm -rf FIXTURE_DIR + unsets every env
#     var the test set) in teardown.
#
# The fixture SQLite builders `_make_tcc_db`, `_make_kextpolicy_db`,
# and `_make_systempolicy_db` are duplicated verbatim from the
# anomalies file rather than shared — bats does not load helpers
# across files and duplication keeps each suite self-contained.

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Fixtures + shared helpers
# ---------------------------------------------------------------------------

setup() {
  MACAUDIT="${BATS_TEST_DIRNAME}/../../macaudit.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-tier3s.XXXXXX")"
  FAKE_HOME="${FIXTURE_DIR}/home"
  mkdir -p -- "${FAKE_HOME}/Library/LaunchAgents"
  mkdir -p -- "${FAKE_HOME}/Library/Preferences"
  # Per-user TCC.db location — the Tier 3 walk probes this path on
  # every enumerable home. Creating the parent keeps the walk from
  # logging a benign "path unreadable" during baseline.
  mkdir -p -- "${FAKE_HOME}/Library/Application Support/com.apple.TCC"

  # A scratch bin dir for ad-hoc PATH-shims. Empty by default;
  # individual tests populate it and prepend to PATH.
  SHIM_DIR="${FIXTURE_DIR}/bin"
  mkdir -p -- "${SHIM_DIR}"

  ORIG_PATH="${PATH}"
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH

  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    chmod -R u+rwX "${FIXTURE_DIR}" 2>/dev/null || true
    rm -rf -- "${FIXTURE_DIR}" || true
  fi

  # Unset every env override any scenario in this file may have set
  # so the next test starts from a clean slate.
  unset MACAUDIT_FDA_AVAILABLE
  unset MACAUDIT_MDM_MANAGED
  unset TCC_SYSTEM_PATH_OVERRIDE
  unset KEXTPOLICY_PATH_OVERRIDE
  unset EXECPOLICY_PATH_OVERRIDE
  unset SYSTEMPOLICY_PATH_OVERRIDE
  unset XPROTECT_BUNDLE_OVERRIDE
  unset SECURITY_CMD_OVERRIDE
  unset PROFILES_CMD_OVERRIDE
  unset SPCTL_STATUS_OVERRIDE
  unset SPCTL_DEVID_OVERRIDE
  unset SYSTEM_PLUGIN_DIR_OVERRIDE
  unset THIRD_PARTY_PLUGIN_DIR_OVERRIDE
  unset QUARANTINE_PATH_OVERRIDE
  unset MACAUDIT_PPPC_JSON
  unset MACAUDIT_BATS_CODESIGN_RC
  unset MACAUDIT_BATS_CODESIGN_STDERR
}

# ---------------------------------------------------------------------------
# Fixture builders — SQLite shape helpers
# ---------------------------------------------------------------------------
# Factored after the reference builders in test_integration_tier3_anomalies.bats
# so both Tier 3 integration suites share one understanding of the
# fixture schemas. bats does not load helper files across .bats files,
# so we duplicate the function bodies here verbatim rather than source
# them.

# _make_tcc_db <path> <auth_reason1> [<auth_reason2>...]
#   Materialise a TCC.db with one row per auth_reason argument. Every
#   row uses a unique client so the compound primary key stays
#   collision-free.
_make_tcc_db() {
  local p="$1"
  shift
  local dir
  dir=$(dirname -- "$p")
  mkdir -p -- "$dir"
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
  local i=0 reason
  for reason in "$@"; do
    sqlite3 "$p" "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified, indirect_object_identifier) VALUES ('kTCCServiceAccessibility', 'com.example.c${i}', 0, 2, ${reason}, 1, 1700000000, 'UNUSED');"
    i=$((i + 1))
  done
}

# _make_kextpolicy_db <path> <user_row_count> <mdm_row_count>
#   Build a KextPolicy DB with <user_row_count> rows in kext_policy
#   and <mdm_row_count> rows in kext_policy_mdm. Team IDs and bundle
#   IDs are deliberately disjoint across the two tables so the
#   R4 matcher sees the user rows as unmatched.
_make_kextpolicy_db() {
  local p="$1" u="$2" m="$3"
  mkdir -p -- "$(dirname -- "$p")"
  sqlite3 "$p" <<'SQL'
CREATE TABLE kext_policy (team_id TEXT, bundle_id TEXT, allowed INTEGER, developer_name TEXT, flags INTEGER, PRIMARY KEY (team_id, bundle_id));
CREATE TABLE kext_policy_mdm (team_id TEXT, bundle_id TEXT, allowed INTEGER, developer_name TEXT, flags INTEGER, PRIMARY KEY (team_id, bundle_id));
SQL
  local i=0
  while [ "$i" -lt "$u" ]; do
    sqlite3 "$p" "INSERT INTO kext_policy VALUES ('TEAMU${i}', 'com.user.kext.${i}', 1, 'DevU${i}', 0);"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$m" ]; do
    sqlite3 "$p" "INSERT INTO kext_policy_mdm VALUES ('TEAMM${i}', 'com.mdm.kext.${i}', 1, 'DevM${i}', 0);"
    i=$((i + 1))
  done
}

# _make_quarantine_db <path>
#   Build a minimal LSQuarantineEvent DB with one event row so the
#   quarantine_events capture has something to snapshot. The schema
#   matches the on-disk macOS shape only in the columns the snapshot
#   pass reads (EventID primary key + a handful of forensic fields);
#   additional live-system columns we don't read are omitted.
_make_quarantine_db() {
  local p="$1"
  mkdir -p -- "$(dirname -- "$p")"
  sqlite3 "$p" <<'SQL'
CREATE TABLE LSQuarantineEvent (
  LSQuarantineEventIdentifier TEXT PRIMARY KEY,
  LSQuarantineTimeStamp REAL,
  LSQuarantineAgentBundleIdentifier TEXT,
  LSQuarantineAgentName TEXT,
  LSQuarantineDataURLString TEXT,
  LSQuarantineSenderName TEXT,
  LSQuarantineSenderAddress TEXT,
  LSQuarantineTypeNumber INTEGER,
  LSQuarantineOriginTitle TEXT,
  LSQuarantineOriginURLString TEXT,
  LSQuarantineOriginAlias BLOB
);
INSERT INTO LSQuarantineEvent VALUES (
  '11111111-2222-3333-4444-555555555555',
  700000000.0,
  'com.example.browser',
  'ExampleBrowser',
  'https://example.com/file.dmg',
  'Example',
  'example@example.com',
  2,
  'Example',
  'https://example.com/',
  NULL
);
SQL
}

# ---------------------------------------------------------------------------
# 16.18 — FDA unavailable graceful degradation
# ---------------------------------------------------------------------------
# When Full Disk Access is unavailable (the common case on a
# freshly-installed system with no TCC consent yet), baseline must
# still succeed cleanly. The three FDA-protected surfaces (system
# TCC.db, KextPolicy, ExecPolicy) land in `header.skipped_paths` with
# `reason: "fda-unavailable"`; non-FDA Tier 3 surfaces (SystemPolicy,
# AuthorizationDB, per-user quarantine) are still captured. Exit code
# must be 0 — an inaccessible FDA-gated surface is not an error.

@test "16.18 FDA unavailable records fda-unavailable skip rows for TCC/KextPolicy/ExecPolicy and exits 0" {
  # Seed the non-FDA Tier 3 surfaces the scenario asserts on:
  #   * XProtect bundle via XPROTECT_BUNDLE_OVERRIDE (shape from 16.16).
  #   * Per-user LSQuarantineEventsV2 DB under the fake home so
  #     quarantine_capture_user has something to snapshot.
  # The FDA-protected surfaces are deliberately NOT overridden so
  # `tcc_system_path` and the KextPolicy / ExecPolicy defaults resolve
  # to the real production paths and skipped_paths records the
  # canonical "/Library/..." / "/var/db/..." strings the header
  # schema documents.
  local bundle="${FIXTURE_DIR}/XProtect.bundle"
  mkdir -p -- "${bundle}/Contents"
  cat > "${bundle}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>2173</string>
</dict>
</plist>
PLIST

  local qe="${FAKE_HOME}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
  _make_quarantine_db "${qe}"

  # `security authorizationdb read` PATH-shim that serves a canonical
  # mechanisms plist for every invocation — same pattern as scenario
  # 16.14. The mechanisms content is deliberately benign (two builtin
  # mechanisms); the scenario does not assert on authdb anomalies, it
  # only asserts at least one authdb entry was captured.
  local seed="${FIXTURE_DIR}/authdb_seed.json"
  printf '%s' '{"class":"evaluate-mechanisms","shared":true,"timeout":30,"tries":10000,"mechanisms":["builtin:policy-banner","builtin:authenticate,privileged"]}' \
    > "${seed}"
  local authdb_xml="${FIXTURE_DIR}/authdb.xml"
  plutil -convert xml1 -o "${authdb_xml}" "${seed}"
  local security_shim="${SHIM_DIR}/security"
  cat > "${security_shim}" <<SHIM
#!/bin/bash
cat "${authdb_xml}"
exit 0
SHIM
  chmod +x "${security_shim}"

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      XPROTECT_BUNDLE_OVERRIDE="${bundle}" \
      SECURITY_CMD_OVERRIDE="${security_shim}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]
  [ -f "${baseline}" ]

  # Header must report fda_available=false.
  local header
  header=$(head -n 1 -- "${baseline}")
  [ "$(printf '%s' "${header}" | jq -r '.fda_available')" = "false" ]

  # Every FDA-protected path must appear in skipped_paths with reason
  # "fda-unavailable". We test each independently so a regression on
  # any single surface surfaces on its own.
  local tcc_skip
  tcc_skip=$(printf '%s' "${header}" | jq -c \
    '.skipped_paths[]
       | select(.path == "/Library/Application Support/com.apple.TCC/TCC.db")
       | select(.reason == "fda-unavailable")')
  [ -n "${tcc_skip}" ]

  local kext_skip
  kext_skip=$(printf '%s' "${header}" | jq -c \
    '.skipped_paths[]
       | select(.path == "/var/db/SystemPolicyConfiguration/KextPolicy")
       | select(.reason == "fda-unavailable")')
  [ -n "${kext_skip}" ]

  local exec_skip
  exec_skip=$(printf '%s' "${header}" | jq -c \
    '.skipped_paths[]
       | select(.path == "/var/db/SystemPolicyConfiguration/ExecPolicy")
       | select(.reason == "fda-unavailable")')
  [ -n "${exec_skip}" ]

  # Non-FDA Tier 3 surfaces still capture. Each must be present in
  # the body: authdb (via `security authorizationdb read`), xprotect
  # (via the override bundle), and quarantine_events (via the seeded
  # per-user DB).
  local body_count
  body_count=$(wc -l < "${baseline}" | tr -d ' ')
  [ "${body_count}" -gt 1 ]

  local authdb_count xp_count qe_count
  authdb_count=$(tail -n +2 -- "${baseline}" \
    | jq -r 'select(.surface == "authdb") | .path' \
    | wc -l | tr -d ' ')
  [ "${authdb_count}" -ge 1 ]

  xp_count=$(tail -n +2 -- "${baseline}" \
    | jq -r --arg p "${bundle}" 'select(.surface == "xprotect" and .path == $p) | .path' \
    | wc -l | tr -d ' ')
  [ "${xp_count}" = "1" ]

  qe_count=$(tail -n +2 -- "${baseline}" \
    | jq -r --arg p "${qe}" 'select(.surface == "quarantine_events" and .path == $p) | .path' \
    | wc -l | tr -d ' ')
  [ "${qe_count}" = "1" ]
}

# ---------------------------------------------------------------------------
# 16.19 — SQLite safe-copy preserves originals (P10' / P16)
# ---------------------------------------------------------------------------
# The Tier 3 capture pipeline funnels every SQLite source file through
# `sqlite_safe_copy`, which reads the DB plus its -wal / -shm
# sidecars but never writes to any of them. This scenario hashes every
# source file and every sidecar before baseline, runs baseline against
# the full Tier 3 surface set, and re-hashes. Every hash must be
# unchanged — the capture must never touch the originals.

@test "16.19 Tier 3 baseline never mutates source SQLite databases or their -wal/-shm sidecars" {
  # Build one fixture per FDA-protected surface and seed sibling -wal
  # / -shm files with known bytes. The -wal / -shm contents do not
  # need to be valid WAL frames — the safe-copy pipeline reads them
  # verbatim and writes the scratch copy into MACAUDIT_TMPDIR, so
  # invariance is a property of the hash, not of the byte layout.
  local tcc_sys="${FIXTURE_DIR}/TCC.db"
  _make_tcc_db "${tcc_sys}" 1 2
  printf 'tcc-wal-fixture-bytes' > "${tcc_sys}-wal"
  printf 'tcc-shm-fixture-bytes' > "${tcc_sys}-shm"

  local kp="${FIXTURE_DIR}/KextPolicy"
  _make_kextpolicy_db "${kp}" 1 1
  printf 'kext-wal-fixture-bytes' > "${kp}-wal"
  printf 'kext-shm-fixture-bytes' > "${kp}-shm"

  local ep="${FIXTURE_DIR}/ExecPolicy"
  mkdir -p -- "$(dirname -- "${ep}")"
  sqlite3 "${ep}" "CREATE TABLE policy (id INTEGER PRIMARY KEY);"
  printf 'exec-wal-fixture-bytes' > "${ep}-wal"
  printf 'exec-shm-fixture-bytes' > "${ep}-shm"

  local sp="${FIXTURE_DIR}/SystemPolicy"
  sqlite3 "${sp}" "CREATE TABLE authority (id INTEGER PRIMARY KEY);"
  printf 'sys-wal-fixture-bytes' > "${sp}-wal"
  printf 'sys-shm-fixture-bytes' > "${sp}-shm"

  # Per-user quarantine DB under the fake home so quarantine_capture_user
  # exercises the safe-copy path for its real production location.
  local qe="${FAKE_HOME}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
  _make_quarantine_db "${qe}"
  printf 'qe-wal-fixture-bytes' > "${qe}-wal"
  printf 'qe-shm-fixture-bytes' > "${qe}-shm"

  # Collect every source-file path into one list so the before/after
  # snapshots iterate identically.
  local sources="${FIXTURE_DIR}/sources.txt"
  : > "${sources}"
  local f
  for f in \
    "${tcc_sys}" "${tcc_sys}-wal" "${tcc_sys}-shm" \
    "${kp}" "${kp}-wal" "${kp}-shm" \
    "${ep}" "${ep}-wal" "${ep}-shm" \
    "${sp}" "${sp}-wal" "${sp}-shm" \
    "${qe}" "${qe}-wal" "${qe}-shm"
  do
    [ -e "${f}" ] || continue
    printf '%s\n' "${f}" >> "${sources}"
  done

  # Snapshot hashes before baseline.
  local before="${FIXTURE_DIR}/before.txt"
  local after="${FIXTURE_DIR}/after.txt"
  : > "${before}"
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    printf '%s\t%s\n' "${f}" \
      "$(shasum -a 256 -- "${f}" 2>/dev/null | awk '{print $1}')" \
      >> "${before}"
  done < "${sources}"

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      KEXTPOLICY_PATH_OVERRIDE="${kp}" \
      EXECPOLICY_PATH_OVERRIDE="${ep}" \
      SYSTEMPOLICY_PATH_OVERRIDE="${sp}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  # Re-snapshot and diff.
  : > "${after}"
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    printf '%s\t%s\n' "${f}" \
      "$(shasum -a 256 -- "${f}" 2>/dev/null | awk '{print $1}')" \
      >> "${after}"
  done < "${sources}"

  run diff -u "${before}" "${after}"
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 16.20 — TCC MDM-without-profile cross-surface correlation (R1)
# ---------------------------------------------------------------------------
# A TCC row with auth_reason == 6 (MDM policy-set) whose client is
# absent from the installed PPPC profile set is the canonical
# "MDM-without-profile" signal: the grant claims MDM provenance but
# no configuration-profile payload backs it up. The anomaly fires on
# TWO surfaces:
#
#   * `tcc_mdm_without_profile` — on the TCC entry itself (via
#     tcc_detect_anomalies during capture).
#   * `correlation:tcc_mdm_without_profile` — as a dedicated
#     correlation entry under path `correlation://...` (via
#     baseline_correlate's R1 pass).
#
# Both must land in `tier3.suspicious`, and the delta's exit code
# must be 3.

@test "16.20 TCC MDM-without-profile fires on TCC entry AND as correlation entry, exits 3" {
  local tcc_sys="${FIXTURE_DIR}/TCC.db"
  # Seed one row with auth_reason=6 (MDM policy-set) and an invented
  # client identifier. The client will be absent from the (empty)
  # PPPC profile list, triggering both the capture-time anomaly and
  # the correlation-pass rule.
  _make_tcc_db "${tcc_sys}" 6
  # The _make_tcc_db helper auto-names clients as `com.example.c0`
  # for the first row; we mutate the row's client so the assertion
  # keys off the documented "com.x.app" identifier from the spec.
  sqlite3 "${tcc_sys}" "UPDATE access SET client='com.x.app' WHERE auth_reason=6;"

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      MACAUDIT_PPPC_JSON='[]' \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      MACAUDIT_PPPC_JSON='[]' \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  # The TCC entry lands in tier3.suspicious carrying the
  # tcc_mdm_without_profile rule (capture-time anomaly).
  local tcc_rule_count
  tcc_rule_count=$(printf '%s' "${delta}" | jq -r --arg p "${tcc_sys}" \
    '[.tiers["3"].suspicious[]
        | select(.path == $p)
        | .anomalies[]
        | select(.rule == "tcc_mdm_without_profile")]
      | length')
  [ "${tcc_rule_count}" -ge 1 ]

  # A correlation entry under path correlation://... carries the
  # correlation:tcc_mdm_without_profile rule (R1 cross-surface pass).
  local corr_count
  corr_count=$(printf '%s' "${delta}" | jq -r \
    '[.tiers["3"].suspicious[]
        | select(.path | startswith("correlation://"))
        | select(.anomalies[]? | .rule == "correlation:tcc_mdm_without_profile")]
      | length')
  [ "${corr_count}" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 16.21 — persistence ↔ codesign correlation (R3)
# ---------------------------------------------------------------------------
# A LaunchAgent that points at an unsigned on-disk binary is the
# classic persistence-plus-unsigned-payload shape: the plist's Program
# resolves to a path that fails `codesign --verify --deep --strict`,
# and the R3 correlation pass emits `correlation:persistence_codesign_fail`.
#
# We drive the scenario via the tests/bin/codesign PATH-shim which
# returns RC=1 for every invocation. The shim is indiscriminate — if
# an XProtect bundle happens to be present at the real production
# path on this machine, xprotect_capture will also surface
# `xprotect_codesign_fail` — but that is fine: the assertion is
# scoped to the correlation rule, not to the total anomaly count.

@test "16.21 persistence pointing at unsigned binary fires correlation:persistence_codesign_fail and exits 3" {
  # Fixture binary the LaunchAgent points at. Must be a real file for
  # utils_codesign_verify to even run codesign against it.
  local bin="${FIXTURE_DIR}/payload.bin"
  printf '#!/bin/sh\nexit 0\n' > "${bin}"
  chmod +x "${bin}"

  # Drop a LaunchAgent plist whose Program is the fixture binary.
  # Going through plutil keeps the plist in the canonical XML shape
  # the production walker accepts.
  local seed="${FIXTURE_DIR}/seed-agent.json"
  jq -cn --arg p "${bin}" \
    '{Label:"com.example.unsigned", RunAtLoad:true, Program: $p}' > "${seed}"
  local plist="${FAKE_HOME}/Library/LaunchAgents/com.example.unsigned.plist"
  plutil -convert xml1 -o "${plist}" "${seed}"

  # Install the codesign PATH-shim. The shim is a tracked file under
  # tests/bin/ and exits with ${MACAUDIT_BATS_CODESIGN_RC} for every
  # invocation. Prepending tests/bin/ to PATH ensures the production
  # utils_codesign_verify resolves to our shim.
  local shim_dir="${BATS_TEST_DIRNAME}/../bin"
  [ -x "${shim_dir}/codesign" ] || chmod +x "${shim_dir}/codesign"

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      MACAUDIT_BATS_CODESIGN_RC=1 \
      MACAUDIT_BATS_CODESIGN_STDERR="unsigned binary" \
      PATH="${shim_dir}:${ORIG_PATH}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      MACAUDIT_BATS_CODESIGN_RC=1 \
      MACAUDIT_BATS_CODESIGN_STDERR="unsigned binary" \
      PATH="${shim_dir}:${ORIG_PATH}" \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  # The correlation entry fires under a correlation:// path carrying
  # the correlation:persistence_codesign_fail rule. We scope the
  # assertion narrowly so any incidental xprotect_codesign_fail
  # anomaly that fires on a real Mac's XProtect bundle does not
  # perturb the result.
  local corr_count
  corr_count=$(printf '%s' "${delta}" | jq -r \
    '[.tiers["3"].suspicious[]
        | select(.path | startswith("correlation://"))
        | select(.anomalies[]? | .rule == "correlation:persistence_codesign_fail")]
      | length')
  [ "${corr_count}" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 16.22 — Determinism across two sequential baselines (P17)
# ---------------------------------------------------------------------------
# The determinism invariant asserts that two baselines taken
# back-to-back against a stable environment produce identical
# `(path, sha256_checkpointed, content_hash)` triples for every
# Tier 3 entry. This guarantees the SQLite snapshot pipeline is
# content-addressed rather than time-addressed — a prerequisite for
# audit's drift detection to surface real attacker mutations rather
# than false positives from capture-time jitter.
#
# We seed a mix of Tier 3 surfaces (system TCC.db with two rows,
# a KextPolicy DB with both its tables populated, a per-user
# quarantine DB, and a SystemPolicy stub) so the comparison covers
# both single-table and multi-table snapshots.

@test "16.22 two sequential baselines preserve every (path, sha256_checkpointed, content_hash) triple" {
  local tcc_sys="${FIXTURE_DIR}/TCC.db"
  _make_tcc_db "${tcc_sys}" 1 7

  local kp="${FIXTURE_DIR}/KextPolicy"
  _make_kextpolicy_db "${kp}" 2 1

  local sp="${FIXTURE_DIR}/SystemPolicy"
  sqlite3 "${sp}" "CREATE TABLE authority (id INTEGER PRIMARY KEY);"

  # Per-user quarantine DB under the fake home — the standard
  # production path is ${HOME}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2.
  local qe="${FAKE_HOME}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
  _make_quarantine_db "${qe}"

  # Fixture XProtect bundle so the `(file_path, sha256_raw)` set in
  # files[] can be compared across runs. Seeded with CFBundleShortVersionString
  # plus one extra regular file under Contents/ so the files[] map is
  # non-empty (same shape as scenario 16.16).
  local bundle="${FIXTURE_DIR}/XProtect.bundle"
  mkdir -p -- "${bundle}/Contents/Resources"
  cat > "${bundle}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>2173</string>
</dict>
</plist>
PLIST
  printf 'xprotect-signature-fixture\n' > "${bundle}/Contents/Resources/sig.bin"

  local b1="${FIXTURE_DIR}/B1.jsonl"
  local b2="${FIXTURE_DIR}/B2.jsonl"

  # First run.
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      KEXTPOLICY_PATH_OVERRIDE="${kp}" \
      SYSTEMPOLICY_PATH_OVERRIDE="${sp}" \
      XPROTECT_BUNDLE_OVERRIDE="${bundle}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${b1}"
  [ "${status}" -eq 0 ]

  # Second run — no state change between calls.
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      KEXTPOLICY_PATH_OVERRIDE="${kp}" \
      SYSTEMPOLICY_PATH_OVERRIDE="${sp}" \
      XPROTECT_BUNDLE_OVERRIDE="${bundle}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${b2}"
  [ "${status}" -eq 0 ]

  # --- SQLite determinism ------------------------------------------------
  # Extract the (path, sha256_checkpointed, per-table content-hash
  # map) triple for every Tier 3 entry that carries SQLite snapshot
  # data. We deliberately filter out non-SQLite entries (launchctl://
  # injected-label rows, plist-only surfaces) because the host OS's
  # launchctl can spin transient mdworker instances up and down
  # between invocations — a live-system artefact the determinism
  # invariant does not cover.
  local set1 set2
  set1=$(tail -n +2 -- "${b1}" \
    | jq -c 'select(.tier == 3
                    and ((.sha256_checkpointed // "") != ""
                         or ((.table_snapshots // {}) | length) > 0))
             | {
                path: .path,
                ck: (.sha256_checkpointed // null),
                snaps: (
                  (.table_snapshots // {})
                  | to_entries
                  | map({k: .key, h: (.value.content_hash // null)})
                  | sort_by(.k)
                )
              }' \
    | sort)
  set2=$(tail -n +2 -- "${b2}" \
    | jq -c 'select(.tier == 3
                    and ((.sha256_checkpointed // "") != ""
                         or ((.table_snapshots // {}) | length) > 0))
             | {
                path: .path,
                ck: (.sha256_checkpointed // null),
                snaps: (
                  (.table_snapshots // {})
                  | to_entries
                  | map({k: .key, h: (.value.content_hash // null)})
                  | sort_by(.k)
                )
              }' \
    | sort)

  [ "${set1}" = "${set2}" ]

  # --- XProtect files[] determinism -------------------------------------
  # For the XProtect entry, the (relative_file_path, sha256_raw) pair
  # set in files[] must be identical across the two runs. The files
  # map has the shape {"<rel-path>": {"sha256_raw","size_bytes"}, ...}
  # so we canonicalise it as a sorted array of [path, sha] tuples.
  local xp_set1 xp_set2
  xp_set1=$(tail -n +2 -- "${b1}" \
    | jq -c --arg p "${bundle}" \
        'select(.surface == "xprotect" and .path == $p)
         | (.files // {})
         | to_entries
         | map([.key, (.value.sha256_raw // null)])
         | sort')
  xp_set2=$(tail -n +2 -- "${b2}" \
    | jq -c --arg p "${bundle}" \
        'select(.surface == "xprotect" and .path == $p)
         | (.files // {})
         | to_entries
         | map([.key, (.value.sha256_raw // null)])
         | sort')
  [ -n "${xp_set1}" ]
  [ -n "${xp_set2}" ]
  [ "${xp_set1}" = "${xp_set2}" ]
}
