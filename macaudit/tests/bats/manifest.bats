#!/usr/bin/env bats
# tests/bats/manifest.bats — unit tests for lib/manifest.sh header + entry
# serialisation, read-back, path-keyed lookup, and input validation.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-manifest.XXXXXX")"
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
# manifest_build_header — JSON validity and version selection
# -----------------------------------------------------------------------------

@test "manifest_build_header: emits valid JSON with defaults and skipped_paths []" {
  run manifest_build_header --tier all --user-only false
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
  echo "${output}" | jq -e . >/dev/null
  [ "$(echo "${output}" | jq -r '.manifest_version')" = "1.0" ]
  [ "$(echo "${output}" | jq -r '.tool_version')" = "0.1.0-phase1" ]
  [ "$(echo "${output}" | jq -c '.skipped_paths')" = "[]" ]
  [ "$(echo "${output}" | jq -r '.tool')" = "macaudit" ]
  [ "$(echo "${output}" | jq -r '.tier')" = "all" ]
  [ "$(echo "${output}" | jq -r '.user_only')" = "false" ]
  # user_only must be a JSON boolean, not a string
  [ "$(echo "${output}" | jq -r '.user_only | type')" = "boolean" ]
}

@test "manifest_build_header: --has-tier3 upgrades version fields to 1.1 / phase1-tier3" {
  run manifest_build_header --tier all --user-only false --has-tier3
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | jq -r '.manifest_version')" = "1.1" ]
  [ "$(echo "${output}" | jq -r '.tool_version')" = "0.1.0-phase1-tier3" ]
}

@test "manifest_build_header: rejects invalid --tier" {
  run manifest_build_header --tier 4 --user-only false
  [ "${status}" -ne 0 ]
}

@test "manifest_build_header: rejects invalid --user-only" {
  run manifest_build_header --tier 1 --user-only maybe
  [ "${status}" -ne 0 ]
}

@test "manifest_build_header: accepts --skipped-json [] and preserves as JSON array" {
  run manifest_build_header --tier 1 --user-only true --skipped-json '[{"path":"/x","reason":"no-sudo"}]'
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | jq -r '.skipped_paths | type')" = "array" ]
  [ "$(echo "${output}" | jq -r '.skipped_paths[0].reason')" = "no-sudo" ]
}

# -----------------------------------------------------------------------------
# manifest_build_entry — tri-bool fields emit literal JSON booleans / null
# -----------------------------------------------------------------------------

@test "manifest_build_entry: tier is a JSON number" {
  run manifest_build_entry \
    --path /Library/LaunchDaemons/com.foo.plist \
    --tier 1 \
    --surface launchd_system \
    --format xml \
    --sha256-raw aa --sha256-canonical bb \
    --size 42 --mtime 2026-04-27T10:00:00Z
  [ "${status}" -eq 0 ]
  echo "${output}" | jq -e '.tier | type == "number"' >/dev/null
  [ "$(echo "${output}" | jq -r '.tier')" = "1" ]
}

@test "manifest_build_entry: --cfprefsd-match null emits literal JSON null, not a string" {
  run manifest_build_entry \
    --path /Library/Preferences/com.foo.plist --tier 2 --surface preferences_system \
    --format xml --sha256-raw a --sha256-canonical b \
    --cfprefsd-match null
  [ "${status}" -eq 0 ]
  echo "${output}" | jq -e '.cfprefsd_match == null' >/dev/null
  # `jq '.cfprefsd_match'` on a null should print `null` unquoted; on a string "null" it would be `"null"`.
  raw=$(echo "${output}" | jq -c '.cfprefsd_match')
  [ "${raw}" = "null" ]
}

@test "manifest_build_entry: --launchctl-loaded / --btm-registered booleans are literal JSON booleans" {
  run manifest_build_entry \
    --path /Library/LaunchDaemons/com.foo.plist --tier 1 --surface launchd_system \
    --format xml --sha256-raw a --sha256-canonical b \
    --launchctl-loaded true --btm-registered false
  [ "${status}" -eq 0 ]
  echo "${output}" | jq -e '.launchctl_loaded == true' >/dev/null
  echo "${output}" | jq -e '.btm_registered == false' >/dev/null
  [ "$(echo "${output}" | jq -r '.launchctl_loaded | type')" = "boolean" ]
  [ "$(echo "${output}" | jq -r '.btm_registered | type')" = "boolean" ]
}

@test "manifest_build_entry: --size empty yields JSON null, numeric string yields number" {
  run manifest_build_entry \
    --path /a --tier 1 --surface launchd_system \
    --format xml --sha256-raw a --sha256-canonical b
  [ "${status}" -eq 0 ]
  echo "${output}" | jq -e '.size_bytes == null' >/dev/null

  run manifest_build_entry \
    --path /a --tier 1 --surface launchd_system \
    --format xml --sha256-raw a --sha256-canonical b --size 1234
  [ "${status}" -eq 0 ]
  echo "${output}" | jq -e '.size_bytes == 1234' >/dev/null
}

@test "manifest_build_entry: rejects invalid tri-bool, tier, format, size" {
  run manifest_build_entry --path /a --tier 1 --surface s --format xml \
    --sha256-raw a --sha256-canonical b --cfprefsd-match maybe
  [ "${status}" -ne 0 ]

  run manifest_build_entry --path /a --tier 4 --surface s --format xml \
    --sha256-raw a --sha256-canonical b
  [ "${status}" -ne 0 ]

  run manifest_build_entry --path /a --tier 1 --surface s --format exe \
    --sha256-raw a --sha256-canonical b
  [ "${status}" -ne 0 ]

  run manifest_build_entry --path /a --tier 1 --surface s --format xml \
    --sha256-raw a --sha256-canonical b --size notanum
  [ "${status}" -ne 0 ]
}

@test "manifest_build_entry: rejects missing --path / --tier / --surface" {
  run manifest_build_entry --tier 1 --surface s --format xml --sha256-raw a --sha256-canonical b
  [ "${status}" -ne 0 ]
  run manifest_build_entry --path /a --surface s --format xml --sha256-raw a --sha256-canonical b
  [ "${status}" -ne 0 ]
  run manifest_build_entry --path /a --tier 1 --format xml --sha256-raw a --sha256-canonical b
  [ "${status}" -ne 0 ]
}

@test "manifest_build_entry: rejects unknown flag" {
  run manifest_build_entry --path /a --tier 1 --surface s --format xml \
    --sha256-raw a --sha256-canonical b --not-a-real-flag 1
  [ "${status}" -ne 0 ]
}

# -----------------------------------------------------------------------------
# Tier 3 SQLite extension — every extended field preserved
# -----------------------------------------------------------------------------

@test "manifest_build_entry: Tier 3 SQLite entry preserves every extended field" {
  run manifest_build_entry \
    --path '/Library/Application Support/com.apple.TCC/TCC.db' \
    --tier 3 --surface tcc_system \
    --sha256-raw raw1 --sha256-canonical can1 \
    --size 16384 --mtime 2026-04-27T10:00:00Z \
    --sha256-checkpointed ckpt1 \
    --wal-present true --wal-sha256 walhash \
    --table-snapshots-json '{"access":{"rows":3}}' \
    --anomalies-json '[{"rule_id":"tcc_override_policy","severity":"high"}]'
  [ "${status}" -eq 0 ]
  echo "${output}" | jq -e . >/dev/null
  [ "$(echo "${output}" | jq -r '.format')" = "sqlite" ]
  [ "$(echo "${output}" | jq -r '.sha256_checkpointed')" = "ckpt1" ]
  [ "$(echo "${output}" | jq -r '.wal_present')" = "true" ]
  [ "$(echo "${output}" | jq -r '.wal_present | type')" = "boolean" ]
  [ "$(echo "${output}" | jq -r '.wal_sha256')" = "walhash" ]
  [ "$(echo "${output}" | jq -c '.table_snapshots')" = '{"access":{"rows":3}}' ]
  [ "$(echo "${output}" | jq -r '.anomalies[0].rule_id')" = "tcc_override_policy" ]
}

# -----------------------------------------------------------------------------
# manifest_write_header / _write_entry / manifest_header / _entries / _load /
# manifest_entry_by_path / manifest_header_value — end-to-end round trip
# -----------------------------------------------------------------------------

@test "manifest: end-to-end write + read + path-keyed lookup" {
  out="${FIXTURE_DIR}/m.jsonl"
  header=$(manifest_build_header --tier all --user-only false)
  manifest_write_header "${out}" "${header}"

  entry1=$(manifest_build_entry \
    --path /Library/LaunchDaemons/com.a.plist --tier 1 --surface launchd_system \
    --format xml --sha256-raw r1 --sha256-canonical c1 --size 10 --mtime 2026-04-27T10:00:00Z)
  entry2=$(manifest_build_entry \
    --path /Library/LaunchDaemons/com.b.plist --tier 1 --surface launchd_system \
    --format xml --sha256-raw r2 --sha256-canonical c2 --size 20 --mtime 2026-04-27T10:00:01Z)

  manifest_write_entry "${out}" "${entry1}"
  manifest_write_entry "${out}" "${entry2}"

  # Header round-trip.
  got_hdr=$(manifest_header "${out}")
  [ "${got_hdr}" = "${header}" ]

  # Entry count.
  n=$(manifest_entries "${out}" | wc -l | tr -d ' ')
  [ "${n}" -eq 2 ]

  # Path-keyed lookup returns the corresponding entry.
  got_a=$(manifest_entry_by_path "${out}" /Library/LaunchDaemons/com.a.plist)
  got_b=$(manifest_entry_by_path "${out}" /Library/LaunchDaemons/com.b.plist)
  [ "${got_a}" = "${entry1}" ]
  [ "${got_b}" = "${entry2}" ]

  # Missing path returns empty.
  miss=$(manifest_entry_by_path "${out}" /nowhere)
  [ -z "${miss}" ]
}

@test "manifest_header_value: returns quoted strings, bare numbers/booleans" {
  out="${FIXTURE_DIR}/h.jsonl"
  header=$(manifest_build_header --tier all --user-only false)
  manifest_write_header "${out}" "${header}"

  got=$(manifest_header_value "${out}" tier)
  [ "${got}" = '"all"' ]

  got=$(manifest_header_value "${out}" user_only)
  [ "${got}" = "false" ]

  got=$(manifest_header_value "${out}" tool)
  [ "${got}" = '"macaudit"' ]

  # Unknown field → empty.
  got=$(manifest_header_value "${out}" nope)
  [ -z "${got}" ]
}

@test "manifest_write_header: fails when target already contains data" {
  out="${FIXTURE_DIR}/prepop.jsonl"
  printf 'already here\n' > "${out}"
  header=$(manifest_build_header --tier 1 --user-only true)
  run manifest_write_header "${out}" "${header}"
  [ "${status}" -ne 0 ]
}

@test "manifest_write_entry: rejects non-JSON input" {
  out="${FIXTURE_DIR}/bad.jsonl"
  header=$(manifest_build_header --tier 1 --user-only true)
  manifest_write_header "${out}" "${header}"
  run manifest_write_entry "${out}" 'this-is-not-json{'
  [ "${status}" -ne 0 ]
}

@test "manifest_load: populates HEADER / ENTRIES_FILE exports" {
  out="${FIXTURE_DIR}/load.jsonl"
  header=$(manifest_build_header --tier 1 --user-only true)
  manifest_write_header "${out}" "${header}"
  entry=$(manifest_build_entry \
    --path /x --tier 1 --surface launchd_system --format xml \
    --sha256-raw a --sha256-canonical b)
  manifest_write_entry "${out}" "${entry}"

  unset MACAUDIT_TMPDIR MACAUDIT_MANIFEST_HEADER MACAUDIT_MANIFEST_ENTRIES_FILE
  # manifest_load installs an EXIT trap via utils_tmpdir_init; fine for bats.
  manifest_load "${out}"
  [ "${MACAUDIT_MANIFEST_HEADER}" = "${header}" ]
  [ -n "${MACAUDIT_MANIFEST_ENTRIES_FILE}" ]
  [ -f "${MACAUDIT_MANIFEST_ENTRIES_FILE}" ]
  lines=$(wc -l <"${MACAUDIT_MANIFEST_ENTRIES_FILE}" | tr -d ' ')
  [ "${lines}" -eq 1 ]
}
