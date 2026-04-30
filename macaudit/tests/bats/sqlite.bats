#!/usr/bin/env bats
# tests/bats/sqlite.bats — unit tests for lib/sqlite.sh WAL safe-copy
# protocol, read-only queries, and per-table snapshotting.
#
# Every test spins up a fixture database in a per-test tmpdir so the
# library's `MACAUDIT_TMPDIR` stays internal to the tool and the
# fixtures stay under our own cleanup control.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/sqlite.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-sqlite.XXXXXX")"
  # sqlite_safe_copy writes into MACAUDIT_TMPDIR, which must exist.
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
}

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# _make_fixture_db <path>
#   Build a small rollback-journal database with a primary-key table and
#   three rows. This is the "no WAL" baseline fixture.
_make_fixture_db() {
  local p="$1"
  sqlite3 "${p}" \
    "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT);
     INSERT INTO foo (id, name) VALUES (1, 'one'), (2, 'two'), (3, 'three');"
}

# _make_wal_fixture_db <path>
#   Build a fixture in WAL mode. SQLite's default checkpoint policy can
#   collapse the WAL between the two statements, but the `-wal` / `-shm`
#   sidecars survive on disk regardless. The test suite only depends on
#   the presence of the sidecars, not on a non-empty WAL.
_make_wal_fixture_db() {
  local p="$1"
  sqlite3 "${p}" \
    "PRAGMA journal_mode=WAL;
     CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT);
     INSERT INTO foo (id, name) VALUES (1, 'one');"
  sqlite3 "${p}" "INSERT INTO foo (id, name) VALUES (2, 'two'), (3, 'three');"
}

# -----------------------------------------------------------------------------
# sqlite_safe_copy — preserves originals (no WAL)
# -----------------------------------------------------------------------------

@test "sqlite_safe_copy: original .db is byte-identical before/after (no WAL)" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_fixture_db "${fix}"
  pre=$(utils_sha256_file "${fix}")
  [ -n "${pre}" ]

  copy=$(sqlite_safe_copy "${fix}")
  [ -n "${copy}" ]
  [ -r "${copy}" ]
  [ "${copy}" != "${fix}" ]

  post=$(utils_sha256_file "${fix}")
  [ "${pre}" = "${post}" ]
}

# -----------------------------------------------------------------------------
# sqlite_safe_copy — preserves originals (db + wal + shm)
# -----------------------------------------------------------------------------

@test "sqlite_safe_copy: originals .db/.db-wal/.db-shm byte-identical before/after" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_wal_fixture_db "${fix}"
  # At least -shm should be present; -wal may be auto-truncated to 0
  # bytes but must still exist on disk.
  [ -e "${fix}" ]
  [ -e "${fix}-shm" ]
  [ -e "${fix}-wal" ]

  pre_db=$(utils_sha256_file "${fix}")
  pre_wal=$(utils_sha256_file "${fix}-wal")
  pre_shm=$(utils_sha256_file "${fix}-shm")

  copy=$(sqlite_safe_copy "${fix}")
  [ -n "${copy}" ]
  [ -r "${copy}" ]

  post_db=$(utils_sha256_file "${fix}")
  post_wal=$(utils_sha256_file "${fix}-wal")
  post_shm=$(utils_sha256_file "${fix}-shm")

  [ "${pre_db}" = "${post_db}" ]
  [ "${pre_wal}" = "${post_wal}" ]
  [ "${pre_shm}" = "${post_shm}" ]
}

# -----------------------------------------------------------------------------
# sqlite_safe_copy — checkpointed copy has no WAL sidecars
# -----------------------------------------------------------------------------

@test "sqlite_safe_copy: scratch dir contains only the main copy, no -wal/-shm" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_wal_fixture_db "${fix}"
  copy=$(sqlite_safe_copy "${fix}")
  [ -n "${copy}" ]
  [ -r "${copy}" ]
  [ ! -e "${copy}-wal" ]
  [ ! -e "${copy}-shm" ]
}

# -----------------------------------------------------------------------------
# sqlite_safe_copy — deterministic checkpointed hash across back-to-back calls
# -----------------------------------------------------------------------------

@test "sqlite_safe_copy: two back-to-back calls produce equal sha256_checkpointed" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_fixture_db "${fix}"

  copy1=$(sqlite_safe_copy "${fix}")
  h1=$(sqlite_checkpointed_hash "${copy1}")
  copy2=$(sqlite_safe_copy "${fix}")
  h2=$(sqlite_checkpointed_hash "${copy2}")

  [ -n "${h1}" ]
  [ "${h1}" = "${h2}" ]
}

# -----------------------------------------------------------------------------
# sqlite_query_tsv — read-only URI, header row first
# -----------------------------------------------------------------------------

@test "sqlite_query_tsv: emits header row followed by tab-separated data" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_fixture_db "${fix}"
  copy=$(sqlite_safe_copy "${fix}")
  out=$(sqlite_query_tsv "${copy}" "SELECT id, name FROM foo ORDER BY id;")
  # Line 1: header.
  header=$(printf '%s\n' "${out}" | head -n 1)
  [ "${header}" = $'id\tname' ]
  # Line 2: first row.
  row1=$(printf '%s\n' "${out}" | sed -n '2p')
  [ "${row1}" = $'1\tone' ]
}

# -----------------------------------------------------------------------------
# sqlite_assert_readonly — succeeds on a safe-copied DB
# -----------------------------------------------------------------------------

@test "sqlite_assert_readonly: returns 0 on a checkpointed copy" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_fixture_db "${fix}"
  copy=$(sqlite_safe_copy "${fix}")
  run sqlite_assert_readonly "${copy}"
  [ "${status}" -eq 0 ]
}

# -----------------------------------------------------------------------------
# sqlite_snapshot_table — rows sorted by primary key
# -----------------------------------------------------------------------------

@test "sqlite_snapshot_table: rows sorted by declared primary key" {
  fix="${FIXTURE_DIR}/fixture.db"
  # Insert rows in REVERSE PK order to exercise the sort.
  sqlite3 "${fix}" \
    "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT);
     INSERT INTO foo (id, name) VALUES (3, 'three'), (1, 'one'), (2, 'two');"

  copy=$(sqlite_safe_copy "${fix}")
  snap=$(sqlite_snapshot_table "${copy}" "foo" "id" "id,name")
  [ -n "${snap}" ]
  echo "${snap}" | jq -e . >/dev/null

  id0=$(printf '%s' "${snap}" | jq -r '.rows[0].id')
  id1=$(printf '%s' "${snap}" | jq -r '.rows[1].id')
  id2=$(printf '%s' "${snap}" | jq -r '.rows[2].id')
  [ "${id0}" = "1" ]
  [ "${id1}" = "2" ]
  [ "${id2}" = "3" ]

  rc=$(printf '%s' "${snap}" | jq -r '.row_count')
  [ "${rc}" = "3" ]
  pk=$(printf '%s' "${snap}" | jq -c '.primary_key')
  [ "${pk}" = '["id"]' ]
}

# -----------------------------------------------------------------------------
# sqlite_snapshot_table — content_hash stable across back-to-back runs
# -----------------------------------------------------------------------------

@test "sqlite_snapshot_table: content_hash is stable across two runs" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_fixture_db "${fix}"

  copy1=$(sqlite_safe_copy "${fix}")
  ch1=$(sqlite_content_hash "${copy1}" "foo" "id" "id,name")
  copy2=$(sqlite_safe_copy "${fix}")
  ch2=$(sqlite_content_hash "${copy2}" "foo" "id" "id,name")

  [ -n "${ch1}" ]
  # 64-char lowercase hex.
  echo "${ch1}" | grep -Eq '^[0-9a-f]{64}$'
  [ "${ch1}" = "${ch2}" ]
}

# -----------------------------------------------------------------------------
# sqlite_snapshot_table — empty table edge case
# -----------------------------------------------------------------------------

@test "sqlite_snapshot_table: empty table yields row_count=0, rows=[], 64-hex content_hash" {
  fix="${FIXTURE_DIR}/fixture.db"
  sqlite3 "${fix}" "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT);"

  copy=$(sqlite_safe_copy "${fix}")
  snap=$(sqlite_snapshot_table "${copy}" "foo" "id" "id,name")
  [ -n "${snap}" ]
  echo "${snap}" | jq -e . >/dev/null

  rc=$(printf '%s' "${snap}" | jq -r '.row_count')
  [ "${rc}" = "0" ]
  rows=$(printf '%s' "${snap}" | jq -c '.rows')
  [ "${rows}" = "[]" ]
  ch=$(printf '%s' "${snap}" | jq -r '.content_hash')
  echo "${ch}" | grep -Eq '^[0-9a-f]{64}$'
}

# -----------------------------------------------------------------------------
# sqlite_wal_sidecar_info — reports absence
# -----------------------------------------------------------------------------

@test "sqlite_wal_sidecar_info: reports wal_present=false when no sidecar exists" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_fixture_db "${fix}"
  # No WAL mode ⇒ no -wal sidecar.
  [ ! -e "${fix}-wal" ]
  info=$(sqlite_wal_sidecar_info "${fix}")
  [ -n "${info}" ]
  echo "${info}" | jq -e . >/dev/null
  [ "$(echo "${info}" | jq -r '.wal_present')" = "false" ]
  [ "$(echo "${info}" | jq -r '.wal_present | type')" = "boolean" ]
  [ "$(echo "${info}" | jq -r '.wal_sha256')" = "" ]
}

# -----------------------------------------------------------------------------
# sqlite_wal_sidecar_info — reports presence + 64-hex sha256
# -----------------------------------------------------------------------------

@test "sqlite_wal_sidecar_info: reports wal_present=true and 64-hex hash when sidecar exists" {
  fix="${FIXTURE_DIR}/fixture.db"
  _make_wal_fixture_db "${fix}"
  [ -e "${fix}-wal" ]
  info=$(sqlite_wal_sidecar_info "${fix}")
  [ -n "${info}" ]
  [ "$(echo "${info}" | jq -r '.wal_present')" = "true" ]
  [ "$(echo "${info}" | jq -r '.wal_present | type')" = "boolean" ]
  wal_hash=$(echo "${info}" | jq -r '.wal_sha256')
  echo "${wal_hash}" | grep -Eq '^[0-9a-f]{64}$'
  # Cross-check: must match utils_sha256_file of the source sidecar.
  expected=$(utils_sha256_file "${fix}-wal")
  [ "${wal_hash}" = "${expected}" ]
}

# -----------------------------------------------------------------------------
# sqlite_safe_copy — missing source returns empty
# -----------------------------------------------------------------------------

@test "sqlite_safe_copy: missing source yields empty stdout" {
  got=$(sqlite_safe_copy "${FIXTURE_DIR}/nope.db")
  [ -z "${got}" ]
}
