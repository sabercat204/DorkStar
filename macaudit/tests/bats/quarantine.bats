#!/usr/bin/env bats
# tests/bats/quarantine.bats — unit tests for lib/quarantine.sh:
#   - com.apple.quarantine xattr UUID parser
#   - UUID → LSQuarantineEvent lookup on a checkpointed copy
#   - per-user LSQuarantineEvent capture (happy path, missing DB,
#     QUARANTINE_PATH_OVERRIDE)
#
# Fixture databases are materialised via `sqlite3` into a per-test
# FIXTURE_DIR so we never touch the operator's real quarantine DB.

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
  source "${LIB}/quarantine.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-quar.XXXXXX")"
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
  unset QUARANTINE_PATH_OVERRIDE
}

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# _make_quarantine_db <path>
#   Build an LSQuarantineEvent database with two rows suitable for
#   exercising the capture pipeline and the UUID lookup.
_make_quarantine_db() {
  local p="$1"
  sqlite3 "${p}" <<'SQL'
CREATE TABLE LSQuarantineEvent (
  LSQuarantineEventIdentifier TEXT PRIMARY KEY NOT NULL,
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
INSERT INTO LSQuarantineEvent (LSQuarantineEventIdentifier, LSQuarantineTimeStamp,
  LSQuarantineAgentBundleIdentifier, LSQuarantineAgentName,
  LSQuarantineDataURLString, LSQuarantineOriginURLString, LSQuarantineTypeNumber)
VALUES
  ('UUID-0001', 700000000.0, 'com.apple.Safari', 'Safari',
   'https://example.com/download.dmg', 'https://example.com/', 0),
  ('UUID-0002', 700000010.0, 'com.google.Chrome', 'Google Chrome',
   'https://example.com/file.zip', 'https://example.com/files', 0);
SQL
}

# -----------------------------------------------------------------------------
# quarantine_xattr_uuid — real xattr parse
# -----------------------------------------------------------------------------

@test "quarantine_xattr_uuid: extracts UUID from a valid quarantine xattr" {
  file="${FIXTURE_DIR}/downloaded.txt"
  printf 'hello\n' > "${file}"
  xattr -w com.apple.quarantine \
    "0083;5991b778;Safari.app;D1192986-42A3-41DB-AF71-1234" \
    "${file}"

  got=$(quarantine_xattr_uuid "${file}")
  [ "${got}" = "D1192986-42A3-41DB-AF71-1234" ]
}

# -----------------------------------------------------------------------------
# quarantine_xattr_uuid — no xattr
# -----------------------------------------------------------------------------

@test "quarantine_xattr_uuid: returns empty when the xattr is absent" {
  file="${FIXTURE_DIR}/plain.txt"
  printf 'nothing\n' > "${file}"

  got=$(quarantine_xattr_uuid "${file}")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# quarantine_xattr_uuid — malformed (fewer than 4 fields)
# -----------------------------------------------------------------------------

@test "quarantine_xattr_uuid: returns empty when the xattr has fewer than 4 fields" {
  file="${FIXTURE_DIR}/malformed.txt"
  printf 'malformed\n' > "${file}"
  # Only three fields — missing the UUID component entirely.
  xattr -w com.apple.quarantine "0083;5991b778;Safari.app" "${file}"

  got=$(quarantine_xattr_uuid "${file}")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# quarantine_xattr_uuid — missing file
# -----------------------------------------------------------------------------

@test "quarantine_xattr_uuid: returns empty when the path does not exist" {
  got=$(quarantine_xattr_uuid "${FIXTURE_DIR}/never-exists")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# quarantine_lookup_uuid — matching UUID
# -----------------------------------------------------------------------------

@test "quarantine_lookup_uuid: returns 0 for a matching UUID" {
  fixture="${FIXTURE_DIR}/q.db"
  _make_quarantine_db "${fixture}"

  copy=$(sqlite_safe_copy "${fixture}")
  [ -n "${copy}" ]
  [ -r "${copy}" ]

  run quarantine_lookup_uuid "${copy}" "UUID-0001"
  [ "${status}" -eq 0 ]
}

# -----------------------------------------------------------------------------
# quarantine_lookup_uuid — unknown UUID
# -----------------------------------------------------------------------------

@test "quarantine_lookup_uuid: returns 1 for an unknown UUID" {
  fixture="${FIXTURE_DIR}/q.db"
  _make_quarantine_db "${fixture}"

  copy=$(sqlite_safe_copy "${fixture}")
  [ -n "${copy}" ]

  run quarantine_lookup_uuid "${copy}" "NONE-XX"
  [ "${status}" -ne 0 ]
}

# -----------------------------------------------------------------------------
# quarantine_capture_user — happy path
# -----------------------------------------------------------------------------

@test "quarantine_capture_user: captures the DB under the supplied home" {
  home="${FIXTURE_DIR}/home"
  mkdir -p "${home}/Library/Preferences"
  fixture="${home}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
  _make_quarantine_db "${fixture}"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  run quarantine_capture_user "${home}" "${scratch}"
  [ "${status}" -eq 0 ]
  [ -s "${scratch}" ]

  entry=$(cat "${scratch}")
  echo "${entry}" | jq -e . >/dev/null

  # Surface / tier / format.
  [ "$(echo "${entry}" | jq -r '.surface')" = "quarantine_events" ]
  [ "$(echo "${entry}" | jq -r '.tier')" = "3" ]
  [ "$(echo "${entry}" | jq -r '.format')" = "sqlite" ]
  [ "$(echo "${entry}" | jq -r '.path')" = "${fixture}" ]

  # Tier 3 extension fields.
  ck=$(echo "${entry}" | jq -r '.sha256_checkpointed')
  echo "${ck}" | grep -Eq '^[0-9a-f]{64}$'
  [ "$(echo "${entry}" | jq -r '.wal_present | type')" = "boolean" ]
  [ "$(echo "${entry}" | jq -r '.anomalies | type')" = "array" ]
  [ "$(echo "${entry}" | jq -r '.anomalies | length')" = "0" ]

  # table_snapshots.LSQuarantineEvent structure.
  [ "$(echo "${entry}" | jq -r '.table_snapshots.LSQuarantineEvent | type')" = "object" ]
  [ "$(echo "${entry}" | jq -r '.table_snapshots.LSQuarantineEvent.row_count')" = "2" ]
  pk=$(echo "${entry}" | jq -c '.table_snapshots.LSQuarantineEvent.primary_key')
  [ "${pk}" = '["LSQuarantineEventIdentifier"]' ]

  # Both seeded UUIDs land in the rows array.
  has1=$(echo "${entry}" | jq -r '[.table_snapshots.LSQuarantineEvent.rows[] | select(.LSQuarantineEventIdentifier == "UUID-0001")] | length')
  has2=$(echo "${entry}" | jq -r '[.table_snapshots.LSQuarantineEvent.rows[] | select(.LSQuarantineEventIdentifier == "UUID-0002")] | length')
  [ "${has1}" = "1" ]
  [ "${has2}" = "1" ]
}

# -----------------------------------------------------------------------------
# quarantine_capture_user — missing DB ⇒ exit 0 with info log, no entry
# -----------------------------------------------------------------------------

@test "quarantine_capture_user: returns 0 and writes nothing when the DB is missing" {
  home="${FIXTURE_DIR}/home-empty"
  mkdir -p "${home}/Library/Preferences"
  # No DB file created.

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  run --separate-stderr quarantine_capture_user "${home}" "${scratch}"
  [ "${status}" -eq 0 ]
  [ ! -s "${scratch}" ]
  # An informational skip line should have landed on stderr.
  printf '%s\n' "${stderr}" | grep -q '^\[i\] '
}

# -----------------------------------------------------------------------------
# quarantine_capture_user — QUARANTINE_PATH_OVERRIDE respected
# -----------------------------------------------------------------------------

@test "quarantine_capture_user: QUARANTINE_PATH_OVERRIDE takes precedence over home" {
  override="${FIXTURE_DIR}/override.db"
  _make_quarantine_db "${override}"

  # Point $home somewhere else entirely; the override MUST win.
  home="${FIXTURE_DIR}/unrelated-home"
  mkdir -p "${home}/Library/Preferences"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  QUARANTINE_PATH_OVERRIDE="${override}" run quarantine_capture_user "${home}" "${scratch}"
  [ "${status}" -eq 0 ]
  [ -s "${scratch}" ]

  entry=$(cat "${scratch}")
  [ "$(echo "${entry}" | jq -r '.path')" = "${override}" ]
  [ "$(echo "${entry}" | jq -r '.surface')" = "quarantine_events" ]
}
