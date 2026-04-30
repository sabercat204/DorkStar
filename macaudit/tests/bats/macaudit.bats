#!/usr/bin/env bats
# tests/bats/macaudit.bats — unit tests for the macaudit.sh CLI entry point.
#
# Unlike the per-library bats files (which source a single lib/*.sh into
# the test shell), macaudit.sh is a script that calls `set -euo pipefail`
# and `main "$@"` at the bottom — sourcing it would execute main
# immediately. So every test here invokes the script as a child process
# via `run bash "${MACAUDIT}" ...` and asserts on exit status + captured
# output.
#
# Each test controls any environment it needs via exported variables
# passed on the command line (HOME override, PATH shim for the jq-missing
# case). We never mutate the host's real $PATH, $HOME, or the project
# manifests/ directory.

setup() {
  MACAUDIT="${BATS_TEST_DIRNAME}/../../macaudit.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-cli.XXXXXX")"
  # Real libraries need real $PATH for jq, date, etc. Tests that need
  # a restricted PATH set it on the `run` line.
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
}

# ---------------------------------------------------------------------------
# Global flags: --version / -V / --help / -h
# ---------------------------------------------------------------------------

@test "macaudit --version prints the version string and exits 0" {
  run bash "${MACAUDIT}" --version
  [ "${status}" -eq 0 ]
  [ "${output}" = "macaudit 0.1.0-phase1" ]
}

@test "macaudit -V is an alias for --version" {
  run bash "${MACAUDIT}" -V
  [ "${status}" -eq 0 ]
  [ "${output}" = "macaudit 0.1.0-phase1" ]
}

@test "macaudit --help prints the usage block and exits 0" {
  run bash "${MACAUDIT}" --help
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -q "Usage: macaudit"
  echo "${output}" | grep -q "Subcommands:"
  echo "${output}" | grep -q "baseline "
  echo "${output}" | grep -q "audit "
  echo "${output}" | grep -q "enumerate "
  echo "${output}" | grep -q "integrity "
}

@test "macaudit -h is an alias for --help" {
  run bash "${MACAUDIT}" -h
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -q "Subcommands:"
}

# ---------------------------------------------------------------------------
# No subcommand / unknown subcommand
# ---------------------------------------------------------------------------

@test "macaudit with no arguments prints usage and exits 2" {
  run bash "${MACAUDIT}"
  [ "${status}" -eq 2 ]
  # bats merges stdout+stderr into $output.
  echo "${output}" | grep -q "Usage:"
}

@test "macaudit with an unknown subcommand prints usage and exits 2" {
  run bash "${MACAUDIT}" nonsense-command
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "unknown subcommand"
  echo "${output}" | grep -q "Usage:"
}

# ---------------------------------------------------------------------------
# audit: missing baseline + version mismatch
# ---------------------------------------------------------------------------

@test "macaudit audit with a missing baseline path prints 'baseline not found' and exits 2" {
  run bash "${MACAUDIT}" audit "${FIXTURE_DIR}/does-not-exist.jsonl"
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "baseline not found"
}

@test "macaudit audit with an unsupported manifest_version prints the version-mismatch error and exits 2" {
  # Hand-roll a header with manifest_version 0.9. The audit_run
  # library-level check rejects it before any re-capture happens.
  local bad="${FIXTURE_DIR}/old.jsonl"
  printf '{"manifest_version":"0.9","tool":"macaudit","tier":"all","user_only":false,"skipped_paths":[]}\n' > "${bad}"

  run bash "${MACAUDIT}" audit "${bad}"
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "not supported by this tool"
  echo "${output}" | grep -q "0.9"
}

# ---------------------------------------------------------------------------
# jq missing — the jq precondition error
# ---------------------------------------------------------------------------

@test "macaudit with jq missing from PATH prints the jq error and exits 2" {
  # We cannot rely on an "empty" PATH — the script's own sourcing
  # needs dirname, pwd, test, etc., all of which live under /usr/bin
  # on macOS, alongside /usr/bin/jq. We also cannot shadow `command`
  # (it's a bash built-in). The reliable trick is to build a shim
  # directory containing symlinks to EVERY binary under /bin and
  # /usr/bin EXCEPT jq, then run the CLI with PATH pointing at that
  # shim. The script then gets its usual tools but `command -v jq`
  # legitimately fails.
  local shim="${FIXTURE_DIR}/bin-no-jq"
  mkdir -p -- "${shim}"
  local d f
  for d in /bin /usr/bin; do
    [ -d "${d}" ] || continue
    for f in "${d}"/*; do
      ln -s -- "${f}" "${shim}/$(basename -- "${f}")" 2>/dev/null || true
    done
  done
  rm -f -- "${shim}/jq"

  run env PATH="${shim}" HOME="${FIXTURE_DIR}" bash "${MACAUDIT}" baseline
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "macaudit requires jq"
  echo "${output}" | grep -q "brew install jq"
}

# ---------------------------------------------------------------------------
# baseline flag parsing
# ---------------------------------------------------------------------------

@test "macaudit baseline --tier 7 is rejected with exit 2" {
  run bash "${MACAUDIT}" baseline --tier 7
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "invalid --tier"
}

@test "macaudit baseline --frobnicate is rejected as an unknown flag with exit 2" {
  run bash "${MACAUDIT}" baseline --frobnicate
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "unknown flag"
}

@test "macaudit baseline --user-only writes a manifest and exits 0" {
  # Isolated HOME so the walk does not see the tester's own LaunchAgents.
  # The manifest lands at a known path under FIXTURE_DIR so we can
  # inspect it afterwards without depending on the project's manifests/
  # directory.
  local manifest="${FIXTURE_DIR}/out.jsonl"
  run env HOME="${FIXTURE_DIR}" bash "${MACAUDIT}" baseline --user-only --output "${manifest}"
  [ "${status}" -eq 0 ]
  [ -f "${manifest}" ]
  # First line of the manifest is the header.
  head -n 1 -- "${manifest}" | jq -e '.manifest_version' >/dev/null
  # stdout advertises the written path.
  echo "${output}" | grep -q "${manifest}"
}

# ---------------------------------------------------------------------------
# enumerate
# ---------------------------------------------------------------------------

@test "macaudit enumerate --persistence prints the TIER 1 header and exits 0" {
  run env HOME="${FIXTURE_DIR}" bash "${MACAUDIT}" enumerate --persistence
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -q "TIER 1 — PERSISTENCE"
  # --persistence-only output must NOT contain the TIER 2 header.
  if echo "${output}" | grep -q "TIER 2 — PREFERENCES"; then
    false
  fi
}

@test "macaudit enumerate --frobnicate is rejected with exit 2" {
  run bash "${MACAUDIT}" enumerate --frobnicate
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "unknown flag"
}

# ---------------------------------------------------------------------------
# integrity
# ---------------------------------------------------------------------------

@test "macaudit integrity with no positional argument prints usage and exits 2" {
  run bash "${MACAUDIT}" integrity
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "required"
  echo "${output}" | grep -q "Usage: macaudit integrity"
}

@test "macaudit integrity with a missing baseline path prints 'baseline not found' and exits 2" {
  run bash "${MACAUDIT}" integrity "${FIXTURE_DIR}/does-not-exist.jsonl"
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "baseline not found"
}
