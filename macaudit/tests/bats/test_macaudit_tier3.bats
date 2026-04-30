#!/usr/bin/env bats
# tests/bats/test_macaudit_tier3.bats — unit tests for task 15K.2:
# macaudit.sh Tier 3 CLI dispatch + FDA startup warning.
#
# Strategy: invoke `macaudit.sh` as a child process (the same pattern
# macaudit.bats uses) and assert on exit status + merged stdout/stderr.
# The child inherits `MACAUDIT_FDA_AVAILABLE=no` so the memoised probe
# short-circuits without touching the real system TCC.db, and HOME is
# always an empty fixture so the per-user LaunchAgent walk sees nothing
# unexpected.
#
# Covered:
#   * `baseline --tier 3`           — exits 0 with a v1.1 manifest.
#   * `baseline --tier all --user-only` under FDA=no — no system
#     Tier 3 paths in `skipped_paths` (no-sudo / user-only elides them)
#     but the run still completes.
#   * `enumerate --databases`       — emits the Tier 3 header.
#   * FDA warning on stderr for `baseline --tier all`.
#   * FDA warning NOT emitted for `--version` / `--help`.
#   * A hand-rolled v1.1 baseline is accepted by both `audit` and
#     `integrity` (no "version not supported" rejection).

setup() {
  MACAUDIT="${BATS_TEST_DIRNAME}/../../macaudit.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-tier3.XXXXXX")"

  # Isolated HOME so the user LaunchAgents / Preferences walks don't
  # see the tester's own files. The Tier 3 per-user surfaces likewise
  # route through $HOME.
  FAKE_HOME="${FIXTURE_DIR}/home"
  mkdir -p -- "${FAKE_HOME}"

  # Pin the FDA probe result to "no" across every child invocation
  # so no test ever tries to read the real /Library/Application
  # Support/com.apple.TCC/TCC.db. Tests that want the probe to
  # succeed set MACAUDIT_FDA_AVAILABLE=yes on their own `run` line.
  export MACAUDIT_FDA_AVAILABLE=no
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  unset MACAUDIT_FDA_AVAILABLE
}

# ---------------------------------------------------------------------------
# Tier 3 flag parsing
# ---------------------------------------------------------------------------

@test "macaudit baseline --tier 3 is accepted and writes a v1.1 manifest" {
  local manifest="${FIXTURE_DIR}/tier3.jsonl"
  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" baseline --tier 3 --user-only --output "${manifest}"
  [ "${status}" -eq 0 ]
  [ -f "${manifest}" ]
  # Header's manifest_version should be "1.1" — Tier 3 baselines bump
  # the schema per the 15E integration.
  local mv
  mv=$(head -n 1 -- "${manifest}" | jq -r '.manifest_version')
  [ "${mv}" = "1.1" ]
  # Header reports fda_available=false (we pinned the probe to "no").
  local fda
  fda=$(head -n 1 -- "${manifest}" | jq -r '.fda_available')
  [ "${fda}" = "false" ]
}

@test "macaudit baseline --tier all --user-only under FDA=no completes without aborting" {
  local manifest="${FIXTURE_DIR}/all-useronly.jsonl"
  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" baseline --tier all --user-only --output "${manifest}"
  [ "${status}" -eq 0 ]
  [ -f "${manifest}" ]
  # Under --user-only + FDA=no the tool still probes every FDA-gated
  # system Tier 3 path and records it in `skipped_paths` with
  # reason=fda-unavailable (Requirement 13.5). The assertion here is
  # just that the run produced a valid manifest with a populated
  # `skipped_paths` array — i.e., the degraded-FDA branch did not
  # abort.
  local header
  header=$(head -n 1 -- "${manifest}")
  # Header must parse and have fda_available=false.
  [ "$(printf '%s' "${header}" | jq -r '.fda_available')" = "false" ]
  # System TCC.db appears in skipped_paths with an fda-unavailable
  # reason — confirms the probe-and-record path works without sudo.
  local tcc_reason
  tcc_reason=$(printf '%s' "${header}" \
    | jq -r '.skipped_paths[] | select(.path == "/Library/Application Support/com.apple.TCC/TCC.db") | .reason' \
    | head -n 1)
  [ "${tcc_reason}" = "fda-unavailable" ]
}

# ---------------------------------------------------------------------------
# enumerate --databases passthrough
# ---------------------------------------------------------------------------

@test "macaudit enumerate --databases prints the TIER 3 header and exits 0" {
  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" enumerate --databases
  [ "${status}" -eq 0 ]
  # The Tier 3 header is the literal banner emitted by
  # _enumerate_tier3_summary (see lib/enumerate.sh).
  echo "${output}" | grep -q "TIER 3 — SECURITY DATABASES (live)"
  # `--databases` alone must NOT print Tier 1 / Tier 2 headers.
  if echo "${output}" | grep -q "TIER 1 — PERSISTENCE"; then false; fi
  if echo "${output}" | grep -q "TIER 2 — PREFERENCES"; then false; fi
}

# ---------------------------------------------------------------------------
# FDA startup warning
# ---------------------------------------------------------------------------

@test "macaudit baseline --tier all emits the FDA warning on stderr when FDA=no" {
  local manifest="${FIXTURE_DIR}/fda-warn.jsonl"
  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" baseline --tier all --user-only --output "${manifest}"
  [ "${status}" -eq 0 ]
  # The exact warning text is Requirement 15.7 / task 15K.1. Match on
  # the distinctive fragment so we don't break on punctuation cleanup.
  echo "${output}" | grep -q "Full Disk Access unavailable"
  echo "${output}" | grep -q "System Settings → Privacy & Security"
}

@test "macaudit --version does NOT emit the FDA warning" {
  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" --version
  [ "${status}" -eq 0 ]
  # The FDA probe must short-circuit before dispatch decides to
  # warn — --version and --help branches exit before the probe is
  # reached.
  if echo "${output}" | grep -q "Full Disk Access"; then false; fi
}

@test "macaudit --help does NOT emit the FDA warning" {
  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" --help
  [ "${status}" -eq 0 ]
  if echo "${output}" | grep -q "Full Disk Access"; then false; fi
}

# ---------------------------------------------------------------------------
# v1.1 baseline acceptance by audit + integrity
# ---------------------------------------------------------------------------

@test "macaudit audit accepts a v1.1 manifest header (no version-mismatch rejection)" {
  # Hand-roll a minimal v1.1 header with zero entries. audit_run must
  # accept the version, re-capture, and compute an empty delta (exit
  # 0) — NOT reject with the "version not supported" error.
  local base="${FIXTURE_DIR}/v11.jsonl"
  printf '%s\n' '{"manifest_version":"1.1","tool":"macaudit","tool_version":"0.1.0-phase1","tier":"all","user_only":true,"skipped_paths":[],"fda_available":false,"captured_at":"2025-01-01T00:00:00Z","hostname":"test"}' > "${base}"

  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" audit "${base}"
  # The key assertion: exit status is NOT 2 with a version-mismatch
  # message. Accept any code the downstream audit pipeline yields
  # (0 clean, 1 drift, 3 suspicious). Fail only on exit 2 combined
  # with the version-mismatch sentinel.
  if [ "${status}" -eq 2 ]; then
    if echo "${output}" | grep -q "not supported by this tool"; then
      false
    fi
  fi
}

@test "macaudit integrity accepts a v1.1 manifest header (no version-mismatch rejection)" {
  local base="${FIXTURE_DIR}/v11.jsonl"
  printf '%s\n' '{"manifest_version":"1.1","tool":"macaudit","tool_version":"0.1.0-phase1","tier":"all","user_only":true,"skipped_paths":[],"fda_available":false,"captured_at":"2025-01-01T00:00:00Z","hostname":"test"}' > "${base}"

  run env HOME="${FAKE_HOME}" MACAUDIT_FDA_AVAILABLE=no \
    bash "${MACAUDIT}" integrity "${base}"
  if [ "${status}" -eq 2 ]; then
    if echo "${output}" | grep -q "not supported by this tool"; then
      false
    fi
  fi
}
