#!/usr/bin/env bats
# tests/bats/tcc.bats — unit tests for lib/tcc.sh path helpers, capture
# pipeline, FDA gating, and anomaly detection.
#
# Fixture TCC databases are materialised via `sqlite3` into a per-test
# FIXTURE_DIR; the capture flow is redirected at the fixture via the
# `TCC_SYSTEM_PATH_OVERRIDE` env var so the tests never need actual
# FDA or the operator's real TCC.db.

bats_require_minimum_version 1.5.0

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/sqlite.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  # shellcheck source=/dev/null
  source "${LIB}/tcc.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-tcc.XXXXXX")"
  utils_tmpdir_init >/dev/null
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "${MACAUDIT_TMPDIR}" ]; then
    rm -rf -- "${MACAUDIT_TMPDIR}" || true
  fi
  unset MACAUDIT_TMPDIR
  unset MACAUDIT_FDA_AVAILABLE
  unset TCC_SYSTEM_PATH_OVERRIDE
}

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# _make_empty_tcc_db <path>
#   Build a TCC.db with the real `access` schema but no rows.
_make_empty_tcc_db() {
  local p="$1"
  sqlite3 "${p}" <<'SQL'
CREATE TABLE access (
  service TEXT NOT NULL,
  client TEXT NOT NULL,
  client_type INTEGER NOT NULL,
  auth_value INTEGER NOT NULL,
  auth_reason INTEGER NOT NULL,
  auth_version INTEGER NOT NULL,
  csreq BLOB,
  policy_id INTEGER,
  indirect_object_identifier_type INTEGER,
  indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
  indirect_object_code_identity BLOB,
  flags INTEGER,
  last_modified INTEGER NOT NULL,
  PRIMARY KEY (service, client, client_type, indirect_object_identifier)
);
SQL
}

# _insert_access_row <db> <service> <client> <client_type> <auth_reason>
_insert_access_row() {
  local db="$1" service="$2" client="$3" ctype="$4" reason="$5"
  sqlite3 "${db}" \
    "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified)
     VALUES ('${service}', '${client}', ${ctype}, 2, ${reason}, 1, 1700000000);"
}

# -----------------------------------------------------------------------------
# Path helpers
# -----------------------------------------------------------------------------

@test "tcc_system_path: returns the canonical system path" {
  unset TCC_SYSTEM_PATH_OVERRIDE
  got=$(tcc_system_path)
  [ "${got}" = "/Library/Application Support/com.apple.TCC/TCC.db" ]
}

@test "tcc_system_path: honours TCC_SYSTEM_PATH_OVERRIDE" {
  TCC_SYSTEM_PATH_OVERRIDE="${FIXTURE_DIR}/fake.db"
  got=$(tcc_system_path)
  [ "${got}" = "${FIXTURE_DIR}/fake.db" ]
}

@test "tcc_user_path: expands under the supplied home" {
  got=$(tcc_user_path "/Users/alice")
  [ "${got}" = "/Users/alice/Library/Application Support/com.apple.TCC/TCC.db" ]
}

@test "tcc_user_path: errors when home is empty" {
  run tcc_user_path ""
  [ "${status}" -ne 0 ]
}

# -----------------------------------------------------------------------------
# Anomaly detection — all four rules fire
# -----------------------------------------------------------------------------

@test "tcc_detect_anomalies: every rule fires for a fixture with one hit per rule" {
  # Four rows, one per rule:
  #   r1 — override_policy        : auth_reason=7
  #   r2 — av_unusual_reason      : camera + auth_reason=3
  #   r3 — fda_unsigned           : FDA + client_type=1 + unsigned client
  #   r4 — mdm_without_profile    : auth_reason=6 (photos), client not in pppc
  rows='[
    {"service":"kTCCServiceAppleEvents","client":"com.x.overr","client_type":0,"auth_value":2,"auth_reason":7,"auth_version":1,"last_modified":1},
    {"service":"kTCCServiceCamera","client":"com.x.cam","client_type":0,"auth_value":2,"auth_reason":3,"auth_version":1,"last_modified":2},
    {"service":"kTCCServiceSystemPolicyAllFiles","client":"/nonexistent/binary","client_type":1,"auth_value":2,"auth_reason":2,"auth_version":1,"last_modified":3},
    {"service":"kTCCServicePhotos","client":"com.x.mdm","client_type":0,"auth_value":2,"auth_reason":6,"auth_version":1,"last_modified":4}
  ]'

  out=$(tcc_detect_anomalies "${rows}" "[]")
  [ -n "${out}" ]
  echo "${out}" | jq -e . >/dev/null

  count=$(echo "${out}" | jq 'length')
  [ "${count}" = "4" ]

  # Check each rule id is present exactly once.
  for rule in tcc_override_policy tcc_av_unusual_reason tcc_fda_unsigned tcc_mdm_without_profile; do
    n=$(echo "${out}" | jq -r --arg r "${rule}" '[.[] | select(.rule == $r)] | length')
    [ "${n}" = "1" ]
  done

  # Severity sanity.
  sev=$(echo "${out}" | jq -r '.[] | select(.rule == "tcc_override_policy") | .severity')
  [ "${sev}" = "high" ]
  sev=$(echo "${out}" | jq -r '.[] | select(.rule == "tcc_av_unusual_reason") | .severity')
  [ "${sev}" = "warn" ]
  sev=$(echo "${out}" | jq -r '.[] | select(.rule == "tcc_fda_unsigned") | .severity')
  [ "${sev}" = "high" ]
  sev=$(echo "${out}" | jq -r '.[] | select(.rule == "tcc_mdm_without_profile") | .severity')
  [ "${sev}" = "high" ]
}

# -----------------------------------------------------------------------------
# Anomaly detection — clean fixture produces no anomalies
# -----------------------------------------------------------------------------

@test "tcc_detect_anomalies: clean rows produce empty anomaly array" {
  # Rows that do NOT match any rule:
  #   - auth_reason=2 (user consent), not 7
  #   - non-camera / non-mic service
  #   - no FDA + client_type=1 entry
  #   - no auth_reason=6 entries
  rows='[
    {"service":"kTCCServiceAddressBook","client":"com.y.one","client_type":0,"auth_value":2,"auth_reason":2,"auth_version":1,"last_modified":1},
    {"service":"kTCCServiceCamera","client":"com.y.cam","client_type":0,"auth_value":2,"auth_reason":2,"auth_version":1,"last_modified":2}
  ]'

  out=$(tcc_detect_anomalies "${rows}" "[]")
  [ "${out}" = "[]" ]
}

# -----------------------------------------------------------------------------
# Anomaly detection — MDM rule suppressed when client is in PPPC list
# -----------------------------------------------------------------------------

@test "tcc_detect_anomalies: tcc_mdm_without_profile is suppressed when client is in PPPC list" {
  rows='[
    {"service":"kTCCServicePhotos","client":"com.y.mdm","client_type":0,"auth_value":2,"auth_reason":6,"auth_version":1,"last_modified":1}
  ]'

  # With client in PPPC list, rule must NOT fire.
  out=$(tcc_detect_anomalies "${rows}" '["com.y.mdm"]')
  [ "${out}" = "[]" ]

  # With client NOT in PPPC list, rule DOES fire.
  out=$(tcc_detect_anomalies "${rows}" '["com.other.thing"]')
  n=$(echo "${out}" | jq -r '[.[] | select(.rule == "tcc_mdm_without_profile")] | length')
  [ "${n}" = "1" ]
}

# -----------------------------------------------------------------------------
# Capture pipeline — FDA gate returns 1 when probe fails
# -----------------------------------------------------------------------------

@test "tcc_capture_system: returns 1 and writes nothing when FDA probe fails" {
  # Point the override at a non-existent path so the FDA probe cannot succeed.
  export TCC_SYSTEM_PATH_OVERRIDE="${FIXTURE_DIR}/never.db"
  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  # Use `run --separate-stderr` to keep the diagnostic log out of `${output}`.
  run --separate-stderr tcc_capture_system "${scratch}"
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
  # Nothing appended to the scratch file either.
  [ ! -s "${scratch}" ]
}

# -----------------------------------------------------------------------------
# Capture pipeline — well-formed entry on successful capture
# -----------------------------------------------------------------------------

@test "tcc_capture_system: emits a well-formed tier-3 entry with access snapshot" {
  fixture="${FIXTURE_DIR}/TCC.db"
  _make_empty_tcc_db "${fixture}"
  # Seed a couple of rows so the snapshot has row_count > 0.
  _insert_access_row "${fixture}" "kTCCServiceAddressBook" "com.z.one" 0 2
  _insert_access_row "${fixture}" "kTCCServiceCamera" "com.z.cam" 0 2

  TCC_SYSTEM_PATH_OVERRIDE="${fixture}"
  unset MACAUDIT_FDA_AVAILABLE

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  run tcc_capture_system "${scratch}" '[]'
  [ "${status}" -eq 0 ]
  [ -s "${scratch}" ]

  entry=$(cat "${scratch}")
  echo "${entry}" | jq -e . >/dev/null

  # Tier / surface / format.
  [ "$(echo "${entry}" | jq -r '.tier')" = "3" ]
  [ "$(echo "${entry}" | jq -r '.surface')" = "tcc_system" ]
  [ "$(echo "${entry}" | jq -r '.format')" = "sqlite" ]
  [ "$(echo "${entry}" | jq -r '.path')" = "${fixture}" ]

  # Tier 3 extension fields are present.
  ck=$(echo "${entry}" | jq -r '.sha256_checkpointed')
  echo "${ck}" | grep -Eq '^[0-9a-f]{64}$'

  [ "$(echo "${entry}" | jq -r '.wal_present | type')" = "boolean" ]
  [ "$(echo "${entry}" | jq -r '.anomalies | type')" = "array" ]

  # table_snapshots.access has the expected shape.
  [ "$(echo "${entry}" | jq -r '.table_snapshots.access | type')" = "object" ]
  [ "$(echo "${entry}" | jq -r '.table_snapshots.access.row_count')" = "2" ]
  pk=$(echo "${entry}" | jq -c '.table_snapshots.access.primary_key')
  [ "${pk}" = '["service","client","client_type","indirect_object_identifier"]' ]
  rows=$(echo "${entry}" | jq -r '.table_snapshots.access.rows | length')
  [ "${rows}" = "2" ]
  ch=$(echo "${entry}" | jq -r '.table_snapshots.access.content_hash')
  echo "${ch}" | grep -Eq '^[0-9a-f]{64}$'
}

# -----------------------------------------------------------------------------
# Capture pipeline — anomalies array is populated from the snapshot rows
# -----------------------------------------------------------------------------

@test "tcc_capture_system: anomalies array reflects rows that match each rule" {
  fixture="${FIXTURE_DIR}/TCC.db"
  _make_empty_tcc_db "${fixture}"
  # Override policy row.
  _insert_access_row "${fixture}" "kTCCServiceAppleEvents" "com.w.overr" 0 7
  # Camera with non-consent reason.
  _insert_access_row "${fixture}" "kTCCServiceCamera" "com.w.cam" 0 3
  # MDM row without a PPPC match.
  _insert_access_row "${fixture}" "kTCCServicePhotos" "com.w.mdm" 0 6

  TCC_SYSTEM_PATH_OVERRIDE="${fixture}"
  unset MACAUDIT_FDA_AVAILABLE
  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  run tcc_capture_system "${scratch}" '[]'
  [ "${status}" -eq 0 ]
  entry=$(cat "${scratch}")

  # Expect exactly three anomalies, one per rule seeded.
  count=$(echo "${entry}" | jq '.anomalies | length')
  [ "${count}" = "3" ]
  n=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "tcc_override_policy")] | length')
  [ "${n}" = "1" ]
  n=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "tcc_av_unusual_reason")] | length')
  [ "${n}" = "1" ]
  n=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "tcc_mdm_without_profile")] | length')
  [ "${n}" = "1" ]
}

# -----------------------------------------------------------------------------
# Capture pipeline — per-user capture reads the supplied home directory
# -----------------------------------------------------------------------------

@test "tcc_capture_user: captures per-user TCC.db from the supplied home" {
  home="${FIXTURE_DIR}/home"
  mkdir -p "${home}/Library/Application Support/com.apple.TCC"
  fixture="${home}/Library/Application Support/com.apple.TCC/TCC.db"
  _make_empty_tcc_db "${fixture}"
  _insert_access_row "${fixture}" "kTCCServiceAddressBook" "com.v.one" 0 2

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  run tcc_capture_user "${home}" "${scratch}" '[]'
  [ "${status}" -eq 0 ]
  entry=$(cat "${scratch}")
  [ "$(echo "${entry}" | jq -r '.surface')" = "tcc_user" ]
  [ "$(echo "${entry}" | jq -r '.path')" = "${fixture}" ]
  [ "$(echo "${entry}" | jq -r '.table_snapshots.access.row_count')" = "1" ]
}

# -----------------------------------------------------------------------------
# utils_codesign_verify pull-forward — verify against a real signed binary
# -----------------------------------------------------------------------------

@test "utils_codesign_verify: reports valid=true and exit_code=0 for /bin/ls" {
  out=$(utils_codesign_verify /bin/ls)
  [ -n "${out}" ]
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.valid')" = "true" ]
  [ "$(echo "${out}" | jq -r '.exit_code')" = "0" ]
}

@test "utils_codesign_verify: reports valid=false for a missing path" {
  out=$(utils_codesign_verify "${FIXTURE_DIR}/never-exists")
  [ -n "${out}" ]
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.valid')" = "false" ]
  [ "$(echo "${out}" | jq -r '.valid | type')" = "boolean" ]
  [ "$(echo "${out}" | jq -r '.exit_code | type')" = "number" ]
}
