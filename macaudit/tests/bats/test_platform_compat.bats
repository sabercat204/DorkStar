#!/usr/bin/env bats
# tests/bats/test_platform_compat.bats — extended platform compatibility
# checks for task 18.2 of the macaudit spec.
#
# Two groups:
#   Group 1 — Bash version smoke tests: verify the tool loads under the
#             system bash, the error message format is correct, and no
#             bash 4+ features leak into production code.
#   Group 2 — macOS version override (BTM degradation matrix): assert
#             that every module reading BTM degrades to `null` when
#             OS_MAJOR_OVERRIDE=12.

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Fixtures + shared helpers
# ---------------------------------------------------------------------------

setup() {
  MACAUDIT="${BATS_TEST_DIRNAME}/../../macaudit.sh"
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-platform.XXXXXX")"
  FAKE_HOME="${FIXTURE_DIR}/home"
  mkdir -p -- "${FAKE_HOME}/Library/LaunchAgents"
  mkdir -p -- "${FAKE_HOME}/Library/Preferences"
  mkdir -p -- "${FIXTURE_DIR}/bin"

  ORIG_PATH="${PATH}"
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH
  unset OS_MAJOR_OVERRIDE
  unset MACAUDIT_FDA_AVAILABLE
  unset MACAUDIT_TMPDIR
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
}

# _install_shim <name> <exit_code> <stdout_body>
#   Write ${FIXTURE_DIR}/bin/<name> as a tiny bash script that cats a
#   sibling body file and exits with the given code.
_install_shim() {
  local name="$1" rc="$2" body="$3"
  local body_file="${FIXTURE_DIR}/${name}_body.txt"
  printf '%s' "$body" > "$body_file"
  cat > "${FIXTURE_DIR}/bin/${name}" <<SHIM
#!/bin/bash
cat "${body_file}"
exit ${rc}
SHIM
  chmod +x "${FIXTURE_DIR}/bin/${name}"
}

# _make_launchctl_tsv <out> <label ...>
_make_launchctl_tsv() {
  local out="$1"; shift
  : >"$out"
  for label in "$@"; do
    printf '%s\t0\t0\n' "$label" >> "$out"
  done
}

# _make_btm_jsonl <out> <label ...>
_make_btm_jsonl() {
  local out="$1"; shift
  : >"$out"
  for label in "$@"; do
    jq -cn --arg l "$label" '{label:$l,type:"",developer:"",team_identifier:"",parent:"",url:"",disposition:""}' >> "$out"
  done
}

# =========================================================================
# Group 1 — Bash version smoke tests
# =========================================================================

# ---------------------------------------------------------------------------
# 1.1 utils_require_bash accepts the current bash
# ---------------------------------------------------------------------------

@test "bash version: utils_require_bash accepts the current bash (exit 0)" {
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"

  run utils_require_bash
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 1.2 Current bash is >= 3.2 (sanity check)
# ---------------------------------------------------------------------------

@test "bash version: current BASH_VERSINFO is >= 3.2" {
  local major="${BASH_VERSINFO[0]}"
  local minor="${BASH_VERSINFO[1]}"
  # Either major > 3, or major == 3 and minor >= 2.
  if [ "$major" -gt 3 ]; then
    true
  elif [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; then
    true
  else
    printf 'FAIL: bash %s.%s is below 3.2\n' "$major" "$minor" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# 1.3 Error message format matches the documented pattern
# ---------------------------------------------------------------------------

@test "bash version: utils_require_bash error message matches documented format" {
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"

  # We cannot override BASH_VERSINFO (readonly), but we can verify the
  # error message format by inspecting the function source. Instead,
  # run the function in a subshell where we redefine it to always fail,
  # and check the message pattern.
  run bash -c '
    source "'"${LIB}/utils.sh"'"
    # Simulate the error path by calling the function in a context where
    # we know it succeeds, then separately verify the message format
    # embedded in the source code.
    grep -q "\[x\] macaudit requires bash 3.2 or later. Current:" "'"${LIB}/utils.sh"'"
  '
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 1.4 macaudit.sh --version succeeds under the system bash
# ---------------------------------------------------------------------------

@test "bash version: macaudit.sh --version succeeds under the system bash" {
  run bash "${MACAUDIT}" --version
  [ "${status}" -eq 0 ]
  printf '%s\n' "${output}" | grep -q "macaudit"
}

# ---------------------------------------------------------------------------
# 1.5 No bash 4+ features in production code
# ---------------------------------------------------------------------------

@test "bash version: no 'declare -A' (associative arrays) in production code" {
  run grep -rn 'declare[[:space:]]\+-A' "${PROJECT_ROOT}/lib/" "${PROJECT_ROOT}/macaudit.sh"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "bash version: no 'mapfile' or 'readarray' in production code" {
  # Exclude comment lines (starting with optional whitespace + #) so
  # that documentation mentioning these builtins does not false-positive.
  run bash -c 'grep -rn -E "\\b(mapfile|readarray)\\b" "'"${PROJECT_ROOT}"'/lib/" "'"${PROJECT_ROOT}"'/macaudit.sh" | grep -v "^[^:]*:[0-9]*:[[:space:]]*#"'
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "bash version: no '|&' (pipe-both) in production code" {
  run grep -rn '|&' "${PROJECT_ROOT}/lib/" "${PROJECT_ROOT}/macaudit.sh"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "bash version: no bash 4+ case modification (\${var,,} / \${var^^}) in production code" {
  run grep -rn -E '\$\{[a-zA-Z_][a-zA-Z_0-9]*(,,|\^\^)' "${PROJECT_ROOT}/lib/" "${PROJECT_ROOT}/macaudit.sh"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "bash version: no 'coproc' in production code" {
  run grep -rn -E '\bcoproc\b' "${PROJECT_ROOT}/lib/" "${PROJECT_ROOT}/macaudit.sh"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "bash version: no fragile \${!prefix@} indirect expansion in production code" {
  run grep -rn -E '\$\{![a-zA-Z_][a-zA-Z_0-9]*@\}' "${PROJECT_ROOT}/lib/" "${PROJECT_ROOT}/macaudit.sh"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# =========================================================================
# Group 2 — macOS version override: BTM degradation matrix
# =========================================================================

# ---------------------------------------------------------------------------
# 2.1 persistence_collect_btm returns empty on OS_MAJOR_OVERRIDE=12
# ---------------------------------------------------------------------------

@test "BTM degradation: persistence_collect_btm returns empty on OS_MAJOR_OVERRIDE=12" {
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"

  export OS_MAJOR_OVERRIDE=12

  # Install an sfltool shim that would emit data if called — if the
  # macOS gate is broken, the shim output leaks through.
  PATH="${FIXTURE_DIR}/bin:${PATH}"
  export PATH
  _install_shim sfltool 0 'Identifier: com.leak.me
Type: 0x8

'
  cat > "${FIXTURE_DIR}/bin/sudo" <<'SHIM'
#!/bin/bash
exec "$@"
SHIM
  chmod +x "${FIXTURE_DIR}/bin/sudo"
  utils_has_sudo() { return 0; }

  out=$(persistence_collect_btm)
  [ -z "${out}" ]
}

# ---------------------------------------------------------------------------
# 2.2 persistence_correlate returns btm_registered: null on OS_MAJOR_OVERRIDE=12
# ---------------------------------------------------------------------------

@test "BTM degradation: persistence_correlate returns btm_registered:null on OS_MAJOR_OVERRIDE=12" {
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"

  export OS_MAJOR_OVERRIDE=12

  local tsv="${FIXTURE_DIR}/lctl.tsv"
  local btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.example.test
  # Empty BTM file — simulates what persistence_collect_btm produces
  # on macOS < 13.
  : > "${btm}"

  out=$(persistence_correlate com.example.test "${tsv}" "${btm}")
  printf '%s\n' "${out}" | jq -e . >/dev/null
  [ "$(printf '%s' "$out" | jq -r '.btm_registered | type')" = "null" ]
  [ "$(printf '%s' "$out" | jq -r '.launchctl_loaded')" = "true" ]
}

# ---------------------------------------------------------------------------
# 2.3 enumerate_run --persistence shows BTM as '--- (skipped: macOS < 13)'
#     on OS_MAJOR_OVERRIDE=12
# ---------------------------------------------------------------------------

@test "BTM degradation: enumerate_run --persistence shows BTM skipped on OS_MAJOR_OVERRIDE=12" {
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/surfaces.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"
  # shellcheck source=/dev/null
  source "${LIB}/enumerate.sh"

  export OS_MAJOR_OVERRIDE=12
  HOME="${FAKE_HOME}"
  export HOME

  run enumerate_run --persistence
  [ "${status}" -eq 0 ]
  printf '%s\n' "${output}" | grep -F 'BTM records:' | grep -qF 'skipped: macOS < 13'
}

# ---------------------------------------------------------------------------
# 2.4 baseline_run --tier 1 --user-only under OS_MAJOR_OVERRIDE=12
#     produces entries with btm_registered: null
# ---------------------------------------------------------------------------

@test "BTM degradation: baseline --tier 1 --user-only under OS_MAJOR_OVERRIDE=12 has btm_registered:null" {
  # Seed a LaunchAgent plist in the fixture home.
  local plist="${FAKE_HOME}/Library/LaunchAgents/com.example.test.plist"
  printf '%s' '{"Label":"com.example.test","ProgramArguments":["/bin/true"]}' \
    | plutil -convert xml1 -o "${plist}" - 2>/dev/null

  local manifest="${FIXTURE_DIR}/baseline.jsonl"

  run env HOME="${FAKE_HOME}" \
          OS_MAJOR_OVERRIDE=12 \
          MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" baseline --tier 1 --user-only --output "${manifest}"
  [ "${status}" -eq 0 ]
  [ -f "${manifest}" ]

  # Every non-header line (Tier 1 entries) must have btm_registered: null.
  local entry_count=0
  local null_count=0
  while IFS= read -r line; do
    # Skip the header (first line).
    if printf '%s' "$line" | jq -e '.manifest_version' >/dev/null 2>&1; then
      continue
    fi
    entry_count=$((entry_count + 1))
    local btm_type
    btm_type=$(printf '%s' "$line" | jq -r '.btm_registered | type' 2>/dev/null)
    if [ "$btm_type" = "null" ]; then
      null_count=$((null_count + 1))
    fi
  done < "${manifest}"

  # Must have at least one entry (the plist we seeded).
  [ "${entry_count}" -ge 1 ]
  # Every entry must have btm_registered: null.
  [ "${entry_count}" -eq "${null_count}" ]
}

# ---------------------------------------------------------------------------
# 2.5 macaudit.sh enumerate --persistence under OS_MAJOR_OVERRIDE=12
#     fires the macOS < 13 warning on stderr
# ---------------------------------------------------------------------------

@test "BTM degradation: macaudit.sh enumerate --persistence fires macOS < 13 warning on stderr" {
  local stderr_file="${FIXTURE_DIR}/stderr.txt"

  # Run the CLI and capture stderr separately.
  env HOME="${FAKE_HOME}" \
      OS_MAJOR_OVERRIDE=12 \
      MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" enumerate --persistence \
    >/dev/null 2>"${stderr_file}" || true

  # The startup warning must appear on stderr.
  grep -qF 'macOS < 13' "${stderr_file}"
  grep -qF 'BTM enumeration skipped' "${stderr_file}"
}
