#!/usr/bin/env bats
# tests/bats/baseline.bats — unit tests for lib/baseline.sh.
#
# Strategy: every test runs against a per-test fixture HOME and a
# per-test PATH-shim directory so we can stub `launchctl`, `defaults`,
# `sfltool`, and `sudo` without touching the tester's real state.
# `teardown` tears the whole fixture directory down so no shim or
# fixture file leaks between tests. The real `plutil`, `jq`, `shasum`,
# `xattr`, `stat`, `date`, and `hostname` binaries are always used —
# they are read-only and have stable enough output to make fixture
# assertions reliable.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/surfaces.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"
  # shellcheck source=/dev/null
  source "${LIB}/cfprefsd.sh"
  # shellcheck source=/dev/null
  source "${LIB}/baseline.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-baseline.XXXXXX")"
  FIXTURE_HOME="${FIXTURE_DIR}/home"
  mkdir -p "${FIXTURE_HOME}/Library/LaunchAgents"
  mkdir -p "${FIXTURE_HOME}/Library/Preferences"
  mkdir -p "${FIXTURE_DIR}/bin"

  ORIG_HOME="${HOME}"
  ORIG_PATH="${PATH}"
  HOME="${FIXTURE_HOME}"
  PATH="${FIXTURE_DIR}/bin:${PATH}"
  export HOME PATH

  # Install default no-op shims for every external tool the orchestrator
  # would otherwise fork against the real system. Without these, tests
  # that expect "clean baseline" semantics would pick up the tester's
  # real launchctl labels / defaults state, and every real launchctl
  # job would be reported as an "injection" because the fixture HOME
  # has no matching on-disk plist. Individual tests may override any
  # shim by re-writing the file under ${FIXTURE_DIR}/bin.
  _install_launchctl_shim ""
  _install_defaults_shim ""
  _install_sfltool_shim ""

  # Every test runs as a non-root user (BATS is never run as root on a
  # developer machine), so utils_has_sudo naturally returns 1 and the
  # sudo-gated system-path walks take the "no-sudo" / skip branch. The
  # individual tests that need to exercise a different branch
  # re-override `utils_has_sudo` locally.
}

teardown() {
  HOME="${ORIG_HOME}"
  PATH="${ORIG_PATH:-$PATH}"
  export HOME PATH
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    chmod -R u+rwX "${FIXTURE_DIR}" 2>/dev/null || true
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  unset MACAUDIT_TMPDIR OS_MAJOR_OVERRIDE
}

# ---------------------------------------------------------------------------
# Shim helpers
# ---------------------------------------------------------------------------

# _install_launchctl_shim <body>
#   Write a PATH-shimmed `launchctl` that emits <body> on stdout and
#   exits 0. Used to stub `launchctl list` output without touching the
#   real launchd.
_install_launchctl_shim() {
  local body="$1"
  local body_file="${FIXTURE_DIR}/launchctl_body.txt"
  printf '%s' "$body" > "$body_file"
  cat > "${FIXTURE_DIR}/bin/launchctl" <<SHIM
#!/bin/bash
cat "${body_file}"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/launchctl"
}

# _install_defaults_shim <stdout_body>
#   Write a PATH-shimmed `defaults` that emits <stdout_body> on stdout
#   and exits 0. Used to drive cfprefsd_live_canonical's shim in Tier 2
#   tests.
_install_defaults_shim() {
  local body="$1"
  local body_file="${FIXTURE_DIR}/defaults_body.bin"
  printf '%s' "$body" > "$body_file"
  cat > "${FIXTURE_DIR}/bin/defaults" <<SHIM
#!/bin/bash
cat "${body_file}"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/defaults"
}

# _install_sfltool_shim <body>
#   Write a PATH-shimmed `sfltool` that emits <body> on stdout and
#   exits 0. Used to stub BTM snapshots. Installed in setup with an
#   empty body so the real /usr/bin/sfltool never runs from a BATS
#   test.
_install_sfltool_shim() {
  local body="$1"
  local body_file="${FIXTURE_DIR}/sfltool_body.txt"
  printf '%s' "$body" > "$body_file"
  cat > "${FIXTURE_DIR}/bin/sfltool" <<SHIM
#!/bin/bash
cat "${body_file}"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/bin/sfltool"
}

# _write_launch_agent <name> <label>
#   Helper: create a LaunchAgent plist with a given Label, RunAtLoad,
#   and ProgramArguments under the fixture user's LaunchAgents dir.
_write_launch_agent() {
  local name="$1" label="$2"
  local seed="${FIXTURE_DIR}/${name}.json"
  printf '%s' "{\"Label\":\"${label}\",\"RunAtLoad\":true,\"ProgramArguments\":[\"/usr/bin/true\"]}" \
    > "${seed}"
  plutil -convert xml1 -o "${FIXTURE_HOME}/Library/LaunchAgents/${name}.plist" "${seed}"
}

# ---------------------------------------------------------------------------
# 1. Clean baseline — no fixtures, header-only manifest
# ---------------------------------------------------------------------------

@test "baseline_run: empty fixture HOME produces header-only manifest" {
  out="${FIXTURE_DIR}/clean.jsonl"
  run baseline_run --tier all --user-only --output "${out}"
  [ "${status}" -eq 0 ]
  # stdout must be the path we passed.
  printed=$(printf '%s' "${output}" | tail -n 1)
  [ "${printed}" = "${out}" ]
  # First line is the header, no entries.
  line_count=$(wc -l < "${out}" | tr -d ' ')
  [ "${line_count}" -eq 1 ]
  head -n 1 "${out}" | jq -e . >/dev/null
  header=$(head -n 1 "${out}")
  [ "$(printf '%s' "${header}" | jq -r '.manifest_version')" = "1.0" ]
  [ "$(printf '%s' "${header}" | jq -r '.tier')" = "all" ]
  [ "$(printf '%s' "${header}" | jq -r '.user_only')" = "true" ]
  # skipped_paths is always present, even when empty.
  [ "$(printf '%s' "${header}" | jq -c '.skipped_paths')" = "[]" ]
}

# ---------------------------------------------------------------------------
# 2. Tier 1 — user LaunchAgent fixture
# ---------------------------------------------------------------------------

@test "baseline_run: tier 1 --user-only picks up fixture LaunchAgent" {
  _write_launch_agent example "com.example.test"

  out="${FIXTURE_DIR}/tier1.jsonl"
  run baseline_run --tier 1 --user-only --output "${out}"
  [ "${status}" -eq 0 ]

  # Header + at least one entry.
  entries_count=$(tail -n +2 "${out}" | wc -l | tr -d ' ')
  [ "${entries_count}" -ge 1 ]

  # The fixture LaunchAgent must appear as a launchd_user entry with
  # the correct label in the content object.
  entry=$(tail -n +2 "${out}" | jq -c \
    --arg p "${FIXTURE_HOME}/Library/LaunchAgents/example.plist" \
    'select(.path == $p)')
  [ -n "${entry}" ]
  [ "$(printf '%s' "${entry}" | jq -r '.tier')" = "1" ]
  [ "$(printf '%s' "${entry}" | jq -r '.surface')" = "launchd_user" ]
  [ "$(printf '%s' "${entry}" | jq -r '.content.Label')" = "com.example.test" ]
  [ "$(printf '%s' "${entry}" | jq -r '.content.RunAtLoad')" = "true" ]
  [ "$(printf '%s' "${entry}" | jq -c '.content.ProgramArguments')" = '["/usr/bin/true"]' ]
  # cfprefsd_match must be null for Tier 1.
  [ "$(printf '%s' "${entry}" | jq -r '.cfprefsd_match | type')" = "null" ]
  # The dual hash must both be populated and 64 hex chars.
  raw=$(printf '%s' "${entry}" | jq -r '.sha256_raw')
  can=$(printf '%s' "${entry}" | jq -r '.sha256_canonical')
  [ "${#raw}" -eq 64 ]
  [ "${#can}" -eq 64 ]
}

# ---------------------------------------------------------------------------
# 3. Tier 2 — user preference, cfprefsd_match=true when shim mirrors disk
# ---------------------------------------------------------------------------

@test "baseline_run: tier 2 user preference matches identical defaults shim → cfprefsd_match=true" {
  # Build a fixture preference plist with a known security-critical key.
  seed="${FIXTURE_DIR}/alf.json"
  printf '%s' '{"globalstate":1,"loggingenabled":0}' > "${seed}"
  plist="${FIXTURE_HOME}/Library/Preferences/com.apple.alf.plist"
  plutil -convert xml1 -o "${plist}" "${seed}"

  # Install a `defaults` shim that emits the exact same XML bytes the
  # cfprefsd live-canonical pipeline would see from `defaults export`.
  xml_bytes=$(cat "${plist}")
  _install_defaults_shim "${xml_bytes}"

  out="${FIXTURE_DIR}/tier2.jsonl"
  run baseline_run --tier 2 --user-only --output "${out}"
  [ "${status}" -eq 0 ]

  entry=$(tail -n +2 "${out}" | jq -c \
    --arg p "${plist}" 'select(.path == $p)')
  [ -n "${entry}" ]
  [ "$(printf '%s' "${entry}" | jq -r '.tier')" = "2" ]
  [ "$(printf '%s' "${entry}" | jq -r '.surface')" = "preferences_user" ]
  [ "$(printf '%s' "${entry}" | jq -r '.content.globalstate')" = "1" ]
  [ "$(printf '%s' "${entry}" | jq -r '.content.loggingenabled')" = "0" ]
  [ "$(printf '%s' "${entry}" | jq -r '.cfprefsd_match')" = "true" ]
  [ "$(printf '%s' "${entry}" | jq -r '.launchctl_loaded | type')" = "null" ]
  [ "$(printf '%s' "${entry}" | jq -r '.btm_registered | type')" = "null" ]
}

# ---------------------------------------------------------------------------
# 4. Skipped paths — no sudo, system roots recorded with reason
# ---------------------------------------------------------------------------

@test "baseline_run: without sudo, Tier 1 system roots appear in skipped_paths with reason=no-sudo" {
  # Ensure utils_has_sudo returns 1 regardless of the real uid.
  utils_has_sudo() { return 1; }

  out="${FIXTURE_DIR}/nosudo.jsonl"
  run baseline_run --tier 1 --output "${out}"
  [ "${status}" -eq 0 ]

  header=$(head -n 1 "${out}")
  # The header must list every Tier 1 system root with reason=no-sudo.
  # Check a couple of representative entries rather than the exhaustive
  # list so additions to surfaces_tier1_system_paths don't force this
  # test to be updated.
  reason_daemons=$(printf '%s' "${header}" \
    | jq -r '.skipped_paths[] | select(.path == "/Library/LaunchDaemons") | .reason')
  [ "${reason_daemons}" = "no-sudo" ]

  reason_cron=$(printf '%s' "${header}" \
    | jq -r '.skipped_paths[] | select(.path == "/var/at/tabs") | .reason')
  [ "${reason_cron}" = "no-sudo" ]
}

# ---------------------------------------------------------------------------
# 5. --user-only — no system paths appear in entries or skipped_paths
# ---------------------------------------------------------------------------

@test "baseline_run: --user-only never records system paths" {
  _write_launch_agent example "com.example.useronly"
  out="${FIXTURE_DIR}/useronly.jsonl"
  run baseline_run --tier all --user-only --output "${out}"
  [ "${status}" -eq 0 ]

  header=$(head -n 1 "${out}")
  # No skipped_paths entry may point at a system root. The fixture
  # directory itself may be rooted under /var/folders/ on macOS
  # (mktemp honours TMPDIR), so we subtract anything under FIXTURE_DIR
  # from the system-path check.
  leaked=$(printf '%s' "${header}" \
    | jq -r --arg fx "${FIXTURE_DIR}" \
        '.skipped_paths[] | .path | select((startswith("/Library/") or startswith("/etc/") or startswith("/var/")) and (startswith($fx) | not))')
  [ -z "${leaked}" ]

  # Likewise, no manifest entry's path may be rooted under any system
  # prefix outside the fixture. The injection surface uses
  # "launchctl://" as its path so that does not count as a system leak
  # either.
  entries=$(tail -n +2 "${out}")
  sys_entries=""
  if [ -n "${entries}" ]; then
    sys_entries=$(printf '%s\n' "${entries}" \
      | jq -r --arg fx "${FIXTURE_DIR}" \
          'select((.path | (startswith("/Library/") or startswith("/etc/") or startswith("/var/")))
                 and ((.path | startswith($fx)) | not)) | .path')
  fi
  [ -z "${sys_entries}" ]
}

# ---------------------------------------------------------------------------
# 6. Injection detection — launchctl reports a label with no on-disk plist
# ---------------------------------------------------------------------------

@test "baseline_run: launchctl label without matching on-disk plist emits injection entry" {
  # No on-disk LaunchAgent. The shim reports one loaded label, so the
  # injection detector must emit a single entry with surface=injection.
  body=$'PID\tStatus\tLabel\n999\t0\tcom.example.injected\n'
  _install_launchctl_shim "${body}"

  out="${FIXTURE_DIR}/inject.jsonl"
  run baseline_run --tier 1 --user-only --output "${out}"
  [ "${status}" -eq 0 ]

  inj=$(tail -n +2 "${out}" | jq -c 'select(.surface == "injection")')
  [ -n "${inj}" ]
  [ "$(printf '%s' "${inj}" | jq -r '.path')" = "launchctl://com.example.injected" ]
  [ "$(printf '%s' "${inj}" | jq -r '.tier')" = "1" ]
  [ "$(printf '%s' "${inj}" | jq -r '.content.label')" = "com.example.injected" ]
  [ "$(printf '%s' "${inj}" | jq -r '.content.pid')" = "999" ]
  [ "$(printf '%s' "${inj}" | jq -r '.launchctl_loaded')" = "true" ]
  # btm_registered is null because the BTM collector does not run
  # without sudo (and the fixture tests run non-root).
  [ "$(printf '%s' "${inj}" | jq -r '.btm_registered | type')" = "null" ]
}

# ---------------------------------------------------------------------------
# 7. Header shape — every required field is populated
# ---------------------------------------------------------------------------

@test "baseline_run: header has the required fields with the correct types" {
  out="${FIXTURE_DIR}/hdr.jsonl"
  run baseline_run --tier all --user-only --output "${out}"
  [ "${status}" -eq 0 ]

  header=$(head -n 1 "${out}")
  printf '%s' "${header}" | jq -e . >/dev/null

  [ "$(printf '%s' "${header}" | jq -r '.manifest_version')" = "1.0" ]
  [ "$(printf '%s' "${header}" | jq -r '.tool')" = "macaudit" ]
  [ "$(printf '%s' "${header}" | jq -r '.tier')" = "all" ]
  [ "$(printf '%s' "${header}" | jq -r '.user_only')" = "true" ]

  # Required non-empty fields.
  ts=$(printf '%s' "${header}" | jq -r '.timestamp')
  [ -n "${ts}" ]
  host=$(printf '%s' "${header}" | jq -r '.hostname')
  [ -n "${host}" ]
  osv=$(printf '%s' "${header}" | jq -r '.os_version')
  [ -n "${osv}" ]

  # skipped_paths is always a JSON array.
  [ "$(printf '%s' "${header}" | jq -r '.skipped_paths | type')" = "array" ]
}

# ---------------------------------------------------------------------------
# 8. Atomic write — no `.tmp` file is left on disk after a successful run
# ---------------------------------------------------------------------------

@test "baseline_run: leaves no .tmp file next to the output on success" {
  out="${FIXTURE_DIR}/atomic.jsonl"
  run baseline_run --tier 1 --user-only --output "${out}"
  [ "${status}" -eq 0 ]
  [ -f "${out}" ]
  [ ! -f "${out}.tmp" ]
}
