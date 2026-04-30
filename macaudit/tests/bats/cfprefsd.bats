#!/usr/bin/env bats
# tests/bats/cfprefsd.bats — unit tests for lib/cfprefsd.sh.
#
# Strategy: the real `defaults` binary is not safe to drive in a unit
# test (it would touch the tester's live cfprefsd state), so every test
# that needs `defaults` output goes through a PATH-shim. `setup`
# prepends a per-test `${FIXTURE_DIR}/bin` to PATH; `_install_defaults_shim`
# writes a throwaway `defaults` script there and teaches it what to emit.
# `teardown` tears the whole fixture directory down so no shim leaks
# between tests.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/cfprefsd.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-cfprefsd.XXXXXX")"
  mkdir -p "${FIXTURE_DIR}/bin"
  ORIG_PATH="${PATH}"
  PATH="${FIXTURE_DIR}/bin:${PATH}"
  export PATH
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
}

# _install_defaults_shim <exit_code> <stdout_body>
#   Write ${FIXTURE_DIR}/bin/defaults as a tiny bash script that prints
#   ${stdout_body} (verbatim, no trailing newline added beyond what the
#   body itself contains) and then exits with ${exit_code}. Any prior
#   shim is overwritten.
_install_defaults_shim() {
  local rc="$1"
  local body="$2"
  local shim="${FIXTURE_DIR}/bin/defaults"
  # Heredoc writes the script; we embed ${body} via a sibling file so
  # special characters inside don't have to be escaped through the
  # heredoc.
  local body_file="${FIXTURE_DIR}/shim_body.txt"
  printf '%s' "$body" > "$body_file"
  cat > "$shim" <<SHIM
#!/bin/bash
cat "${body_file}"
exit ${rc}
SHIM
  chmod +x "$shim"
}

# _xml_plist_from_seed <seed_json> <out_path>
#   Build an XML plist at <out_path> from a one-line JSON seed. Uses
#   the real plutil (no shim for this — we want the actual conversion).
_xml_plist_from_seed() {
  local seed_json="$1"
  local out="$2"
  local seed_file="${FIXTURE_DIR}/seed.$(basename "$out").json"
  printf '%s' "$seed_json" > "$seed_file"
  plutil -convert xml1 -o "$out" "$seed_file"
}

# -----------------------------------------------------------------------------
# cfprefsd_domain_from_path
# -----------------------------------------------------------------------------

@test "cfprefsd_domain_from_path: /Library/Preferences/com.apple.alf.plist" {
  [ "$(cfprefsd_domain_from_path /Library/Preferences/com.apple.alf.plist)" = "com.apple.alf" ]
}

@test "cfprefsd_domain_from_path: user Library/Preferences" {
  [ "$(cfprefsd_domain_from_path "${HOME}/Library/Preferences/com.apple.alf.plist")" = "com.apple.alf" ]
}

@test "cfprefsd_domain_from_path: /Library/Managed Preferences/com.apple.alf.plist" {
  [ "$(cfprefsd_domain_from_path "/Library/Managed Preferences/com.apple.alf.plist")" = "com.apple.alf" ]
}

@test "cfprefsd_domain_from_path: /Library/Managed Preferences/<user>/com.apple.alf.plist" {
  [ "$(cfprefsd_domain_from_path "/Library/Managed Preferences/tester/com.apple.alf.plist")" = "com.apple.alf" ]
}

@test "cfprefsd_domain_from_path: .GlobalPreferences maps to NSGlobalDomain (system)" {
  [ "$(cfprefsd_domain_from_path /Library/Preferences/.GlobalPreferences.plist)" = "NSGlobalDomain" ]
}

@test "cfprefsd_domain_from_path: .GlobalPreferences maps to NSGlobalDomain (user)" {
  [ "$(cfprefsd_domain_from_path "${HOME}/Library/Preferences/.GlobalPreferences.plist")" = "NSGlobalDomain" ]
}

@test "cfprefsd_domain_from_path: non-preference path yields empty" {
  # Tier 1 launchd plist — must return empty.
  got=$(cfprefsd_domain_from_path "/Library/LaunchDaemons/x.plist")
  [ -z "${got}" ]
  # Random non-plist path — also empty.
  got2=$(cfprefsd_domain_from_path "/etc/hosts")
  [ -z "${got2}" ]
  # Nested under /Library/Preferences — not a flat domain file, so empty.
  got3=$(cfprefsd_domain_from_path "/Library/Preferences/subdir/foo.plist")
  [ -z "${got3}" ]
}

@test "cfprefsd_domain_from_path: empty input returns empty" {
  got=$(cfprefsd_domain_from_path "")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# cfprefsd_live_canonical — PATH-shim driven
# -----------------------------------------------------------------------------

@test "cfprefsd_live_canonical: shim exits non-zero → empty output" {
  _install_defaults_shim 1 ""
  got=$(cfprefsd_live_canonical com.example.test)
  [ -z "${got}" ]
}

@test "cfprefsd_live_canonical: shim emits empty stdout → empty output" {
  _install_defaults_shim 0 ""
  got=$(cfprefsd_live_canonical com.example.test)
  [ -z "${got}" ]
}

@test "cfprefsd_live_canonical: shim emits whitespace-only → empty output" {
  _install_defaults_shim 0 "   "$'\n'"  "$'\n'
  got=$(cfprefsd_live_canonical com.example.test)
  [ -z "${got}" ]
}

@test "cfprefsd_live_canonical: shim emits {} → empty output" {
  _install_defaults_shim 0 "{}"
  got=$(cfprefsd_live_canonical com.example.test)
  [ -z "${got}" ]
}

@test "cfprefsd_live_canonical: empty domain → empty output" {
  _install_defaults_shim 0 "whatever"
  got=$(cfprefsd_live_canonical "")
  [ -z "${got}" ]
}

@test "cfprefsd_live_canonical: XML plist from shim matches disk-side canonical hash" {
  # Build an XML plist and compute its disk-side canonical hash via the
  # utils.sh pipeline. Then install a shim that emits the exact same XML
  # bytes. The live canonical hash MUST equal the disk canonical hash —
  # this is the whole point of routing both halves through
  # utils_canonical_json_stdin.
  #
  # Critical: both sides are computed via direct pipes (no command
  # substitution) so jq's trailing newline is preserved end-to-end.
  # Using `$(...)` + `printf '%s'` would strip the newline on one side
  # and re-introduce the disk/live drift this whole module exists to
  # prevent.
  plist="${FIXTURE_DIR}/com.example.test.plist"
  _xml_plist_from_seed '{"z":1,"a":"hello","nested":{"c":3,"b":[1,2,3]}}' "${plist}"

  disk_hash=$(utils_plist_to_canonical_json "${plist}" | utils_sha256_stdin)
  [ -n "${disk_hash}" ]
  [ ${#disk_hash} -eq 64 ]

  # Feed the shim the raw XML bytes of the plist.
  cp "${plist}" "${FIXTURE_DIR}/bin/shim_body.bin"
  cat > "${FIXTURE_DIR}/bin/defaults" <<'SHIM'
#!/bin/bash
cat "$(dirname "$0")/shim_body.bin"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/defaults"

  live_hash=$(cfprefsd_live_canonical com.example.test)
  [ -n "${live_hash}" ]
  [ ${#live_hash} -eq 64 ]
  [ "${live_hash}" = "${disk_hash}" ]
}

@test "cfprefsd_live_canonical: binary↔XML disk format does not affect match" {
  # The disk file is binary; the shim returns XML; both encode the same
  # semantic plist. The canonical pipeline must still produce matching
  # hashes (this validates that cfprefsd cross-reference is immune to
  # disk-side binary/XML format drift — per the dual-hash contract).
  seed_file="${FIXTURE_DIR}/seed.json"
  printf '%s' '{"alpha":"one","beta":2,"flag":true}' > "${seed_file}"

  bin_plist="${FIXTURE_DIR}/com.example.test.bin.plist"
  xml_plist="${FIXTURE_DIR}/com.example.test.xml.plist"
  plutil -convert binary1 -o "${bin_plist}" "${seed_file}"
  plutil -convert xml1    -o "${xml_plist}" "${seed_file}"

  disk_hash=$(utils_plist_to_canonical_json "${bin_plist}" | utils_sha256_stdin)

  cp "${xml_plist}" "${FIXTURE_DIR}/bin/shim_body.bin"
  cat > "${FIXTURE_DIR}/bin/defaults" <<'SHIM'
#!/bin/bash
cat "$(dirname "$0")/shim_body.bin"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/defaults"

  live_hash=$(cfprefsd_live_canonical com.example.test)
  [ "${live_hash}" = "${disk_hash}" ]
}

# -----------------------------------------------------------------------------
# cfprefsd_compare — full 3×3 truth table
# -----------------------------------------------------------------------------

@test "cfprefsd_compare: both empty → null (empty stdout)" {
  got=$(cfprefsd_compare "" "")
  [ -z "${got}" ]
}

@test "cfprefsd_compare: disk empty, live set → null" {
  got=$(cfprefsd_compare "" "abcdef")
  [ -z "${got}" ]
}

@test "cfprefsd_compare: disk set, live empty → null" {
  got=$(cfprefsd_compare "abcdef" "")
  [ -z "${got}" ]
}

@test "cfprefsd_compare: both set and equal → true" {
  got=$(cfprefsd_compare "abc123" "abc123")
  [ "${got}" = "true" ]
}

@test "cfprefsd_compare: both set and differ → false" {
  got=$(cfprefsd_compare "abc123" "def456")
  [ "${got}" = "false" ]
}

@test "cfprefsd_compare: long-hex matching and non-matching" {
  h1="$(printf 'hello' | shasum -a 256 | awk '{print $1}')"
  h2="$(printf 'world' | shasum -a 256 | awk '{print $1}')"
  [ "$(cfprefsd_compare "${h1}" "${h1}")" = "true" ]
  [ "$(cfprefsd_compare "${h1}" "${h2}")" = "false" ]
  [ -z "$(cfprefsd_compare ""      "${h2}")" ]
  [ -z "$(cfprefsd_compare "${h1}" ""     )" ]
  [ -z "$(cfprefsd_compare ""      ""     )" ]
}

# -----------------------------------------------------------------------------
# cfprefsd_cross_reference — end-to-end JSON shape
# -----------------------------------------------------------------------------

@test "cfprefsd_cross_reference: unknown domain emits {match:null, live:\"\"}" {
  # Any path cfprefsd_domain_from_path rejects should short-circuit
  # before the shim is even consulted. Install an obviously-wrong shim
  # so any leak would be detectable.
  _install_defaults_shim 0 "leaked"
  out=$(cfprefsd_cross_reference "/Library/LaunchDaemons/foo.plist" "deadbeef")
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.match | type')" = "null" ]
  [ "$(echo "${out}" | jq -r '.live')" = "" ]
}

@test "cfprefsd_cross_reference: shim returns identical XML → match:true" {
  plist="${FIXTURE_DIR}/com.example.test.plist"
  _xml_plist_from_seed '{"z":1,"a":"hello"}' "${plist}"

  # Disk hash via direct pipe (preserves jq trailing newline, matching
  # what cfprefsd_live_canonical computes internally).
  disk_hash=$(utils_plist_to_canonical_json "${plist}" | utils_sha256_stdin)

  cp "${plist}" "${FIXTURE_DIR}/bin/shim_body.bin"
  cat > "${FIXTURE_DIR}/bin/defaults" <<'SHIM'
#!/bin/bash
cat "$(dirname "$0")/shim_body.bin"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/defaults"

  # The cross-reference resolves the domain from the filename. Point
  # the input path into /Library/Preferences so domain resolution
  # picks up `com.example.test` (not the fixture-dir path).
  pref_path="/Library/Preferences/com.example.test.plist"
  out=$(cfprefsd_cross_reference "${pref_path}" "${disk_hash}")
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.match')" = "true" ]
  [ "$(echo "${out}" | jq -r '.match | type')" = "boolean" ]
  [ "$(echo "${out}" | jq -r '.live')" = "${disk_hash}" ]
}

@test "cfprefsd_cross_reference: shim returns different XML → match:false" {
  disk_plist="${FIXTURE_DIR}/disk.plist"
  live_plist="${FIXTURE_DIR}/live.plist"
  _xml_plist_from_seed '{"z":1,"a":"hello"}' "${disk_plist}"
  _xml_plist_from_seed '{"z":1,"a":"HELLO"}' "${live_plist}"

  disk_hash=$(utils_plist_to_canonical_json "${disk_plist}" | utils_sha256_stdin)

  cp "${live_plist}" "${FIXTURE_DIR}/bin/shim_body.bin"
  cat > "${FIXTURE_DIR}/bin/defaults" <<'SHIM'
#!/bin/bash
cat "$(dirname "$0")/shim_body.bin"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/defaults"

  pref_path="/Library/Preferences/com.example.test.plist"
  out=$(cfprefsd_cross_reference "${pref_path}" "${disk_hash}")
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.match')" = "false" ]
  [ "$(echo "${out}" | jq -r '.match | type')" = "boolean" ]
  # live hash is still reported, and must differ from disk.
  live_hash=$(echo "${out}" | jq -r '.live')
  [ -n "${live_hash}" ]
  [ "${live_hash}" != "${disk_hash}" ]
}

@test "cfprefsd_cross_reference: shim emits empty → match:null" {
  _install_defaults_shim 0 ""
  pref_path="/Library/Preferences/com.example.test.plist"
  out=$(cfprefsd_cross_reference "${pref_path}" "deadbeefdeadbeef")
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.match | type')" = "null" ]
  [ "$(echo "${out}" | jq -r '.live')" = "" ]
}

@test "cfprefsd_cross_reference: shim emits {} → match:null" {
  _install_defaults_shim 0 "{}"
  pref_path="/Library/Preferences/com.example.test.plist"
  out=$(cfprefsd_cross_reference "${pref_path}" "deadbeefdeadbeef")
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "${out}" | jq -r '.match | type')" = "null" ]
}

@test "cfprefsd_cross_reference: empty disk hash + non-empty live → match:null, live:<hash>" {
  plist="${FIXTURE_DIR}/com.example.test.plist"
  _xml_plist_from_seed '{"x":1}' "${plist}"
  xml_bytes=$(cat "${plist}")
  _install_defaults_shim 0 "${xml_bytes}"

  pref_path="/Library/Preferences/com.example.test.plist"
  out=$(cfprefsd_cross_reference "${pref_path}" "")
  echo "${out}" | jq -e . >/dev/null
  # match must be null because disk side was empty, even though live
  # succeeded. live hash is still reported so callers can record it.
  [ "$(echo "${out}" | jq -r '.match | type')" = "null" ]
  live_hash=$(echo "${out}" | jq -r '.live')
  [ ${#live_hash} -eq 64 ]
}

# -----------------------------------------------------------------------------
# cfprefsd_available
# -----------------------------------------------------------------------------

@test "cfprefsd_available: succeeds when defaults is on PATH" {
  # The real /usr/bin/defaults is always present on macOS. Our per-test
  # PATH prepends ${FIXTURE_DIR}/bin to the original PATH, so we still
  # fall through to the real defaults when no shim is installed.
  run cfprefsd_available
  [ "${status}" -eq 0 ]
}
