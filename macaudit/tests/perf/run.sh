#!/bin/bash
# tests/perf/run.sh — performance harness for task 18.1.
#
# Times a single invocation of:
#
#     macaudit.sh baseline --tier all --user-only --output <manifest>
#
# against a synthetic fixture tree of ~3000 Tier 1 + Tier 2 entries
# (built by tests/perf/gen_fixture.sh). Asserts the wall-clock time is
# under the design's 30-second non-functional target.
#
# This harness is deliberately NOT wired into the default tests/run.sh
# path — a real perf run is multi-second and would drag the CI loop
# over a minute. Wire it in with `tests/run.sh --perf` to run it after
# the bats + pytest suites.
#
# Invoke directly:
#   bash tests/perf/run.sh [--count N] [--target-seconds N] [--keep-fixture]
#
# Defaults:
#   --count 3000
#   --target-seconds 30
#
# Exit codes:
#   0 — wall-clock below the target
#   1 — wall-clock at or above the target (regression)
#   2 — harness setup error
#
# Hard constraints:
#   * bash 3.2 compatible: no associative arrays, no mapfile, no `echo`.
#   * `printf '%s\n'` only.
#   * The harness MUST clean up its tmpdir on exit via EXIT trap unless
#     --keep-fixture is set.
#   * MACAUDIT_FDA_AVAILABLE=no in the env so Tier 3 FDA-gated surfaces
#     do not pad the runtime.

set -euo pipefail

# -----------------------------------------------------------------------------
# Flag parsing
# -----------------------------------------------------------------------------

count="3000"
target_seconds="30"
keep_fixture=0

_usage() {
  printf '%s\n' \
    'Usage: run.sh [--count N] [--target-seconds N] [--keep-fixture]' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --count)
      if [ $# -lt 2 ]; then _usage; exit 2; fi
      count="$2"; shift 2
      ;;
    --target-seconds)
      if [ $# -lt 2 ]; then _usage; exit 2; fi
      target_seconds="$2"; shift 2
      ;;
    --keep-fixture)
      keep_fixture=1; shift 1
      ;;
    -h|--help)
      _usage; exit 0
      ;;
    *)
      printf 'run.sh: unexpected argument: %s\n' "$1" >&2
      _usage; exit 2
      ;;
  esac
done

case "${count}" in
  ''|*[!0-9]*)
    printf 'run.sh: --count must be a positive integer (got %s)\n' "${count}" >&2
    exit 2
    ;;
esac
case "${target_seconds}" in
  ''|*[!0-9]*)
    printf 'run.sh: --target-seconds must be a positive integer (got %s)\n' \
      "${target_seconds}" >&2
    exit 2
    ;;
esac

# -----------------------------------------------------------------------------
# Path resolution + preflight
# -----------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
macaudit_sh="${project_root}/macaudit.sh"
gen_fixture_sh="${script_dir}/gen_fixture.sh"
perf_log="${script_dir}/perf.md"

if [ ! -f "${macaudit_sh}" ]; then
  printf 'run.sh: macaudit.sh not found at %s\n' "${macaudit_sh}" >&2
  exit 2
fi
if [ ! -f "${gen_fixture_sh}" ]; then
  printf 'run.sh: gen_fixture.sh not found at %s\n' "${gen_fixture_sh}" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'run.sh: jq not found on PATH\n' >&2
  exit 2
fi
if ! command -v plutil >/dev/null 2>&1; then
  printf 'run.sh: plutil not found on PATH\n' >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# Scratch dir + cleanup trap
# -----------------------------------------------------------------------------

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-perf.XXXXXX")"

_perf_cleanup() {
  if [ "${keep_fixture}" -eq 1 ]; then
    printf 'run.sh: --keep-fixture set, leaving %s in place\n' "${fixture_dir}" >&2
    return 0
  fi
  if [ -n "${fixture_dir:-}" ] && [ -d "${fixture_dir}" ]; then
    chmod -R u+rwX "${fixture_dir}" 2>/dev/null || true
    rm -rf -- "${fixture_dir}" || true
  fi
}
trap '_perf_cleanup' EXIT
trap '_perf_cleanup; exit 130' INT

fake_home="${fixture_dir}/home"
mkdir -p -- "${fake_home}"

# -----------------------------------------------------------------------------
# launchctl + sfltool shim
# -----------------------------------------------------------------------------
# The Tier 1 walk forks `launchctl list` and `sfltool dumpbtm` once per
# run and correlates every on-disk label against the result. On a real
# developer machine the user's live session registers hundreds of
# launchctl jobs — none of which match the synthetic fixture's labels,
# so every real label lands as an "injection" entry and every
# injection fires a per-entry `persistence_correlate` fork. That's
# hundreds of forks of unmeasured ambient cost that have nothing to
# do with the fixture.
#
# The design's 30-second target is about the walker's scalability in
# the fixture size, not about the size of the operator's current
# launchctl session. We shim both commands to emit empty output so
# the timing reflects the walker's per-fixture-entry cost alone.

shim_dir="${fixture_dir}/bin"
mkdir -p -- "${shim_dir}"

cat > "${shim_dir}/launchctl" <<'SHIM'
#!/bin/bash
# Empty launchctl list — no live jobs to correlate against.
printf 'PID\tStatus\tLabel\n'
exit 0
SHIM
chmod +x "${shim_dir}/launchctl"

cat > "${shim_dir}/sfltool" <<'SHIM'
#!/bin/bash
# Empty BTM dump — no Background Task Management records.
exit 0
SHIM
chmod +x "${shim_dir}/sfltool"

# -----------------------------------------------------------------------------
# Timer helpers
# -----------------------------------------------------------------------------
# macOS's BSD `date` does not support %N. Prefer gdate if available
# (coreutils from brew), otherwise fall back to perl's Time::HiRes for
# sub-second resolution — perl ships with macOS by default. As a final
# fallback, use whole-second `date +%s`.

_now_cmd=""
if command -v gdate >/dev/null 2>&1; then
  _now_cmd="gdate"
elif command -v perl >/dev/null 2>&1; then
  _now_cmd="perl"
else
  _now_cmd="date"
fi

_now() {
  case "${_now_cmd}" in
    gdate) gdate +%s.%N ;;
    perl)  perl -MTime::HiRes=time -e 'printf "%.6f\n", time' ;;
    *)     date +%s ;;
  esac
}

_elapsed() {
  # awk for portable float math — bash itself has no float arithmetic.
  awk -v s="$1" -v e="$2" 'BEGIN { printf "%.3f\n", e - s }'
}

# -----------------------------------------------------------------------------
# Fixture build
# -----------------------------------------------------------------------------

printf 'run.sh: generating fixture (count=%s) under %s\n' \
  "${count}" "${fake_home}" >&2

bash "${gen_fixture_sh}" --home "${fake_home}" --count "${count}" >/dev/null

# Count the actual on-disk regular files under the two surface roots —
# this is what the walker traverses, so it's the honest "fixture
# entry count" we report in the summary.
fixture_entries=$(
  find "${fake_home}/Library/LaunchAgents" "${fake_home}/Library/Preferences" \
    -type f 2>/dev/null | wc -l | tr -d ' '
)
printf 'run.sh: fixture on-disk file count = %s\n' "${fixture_entries}" >&2

# -----------------------------------------------------------------------------
# Timed baseline
# -----------------------------------------------------------------------------

manifest="${fixture_dir}/baseline.jsonl"

printf 'run.sh: running baseline --tier all --user-only...\n' >&2
start=$(_now)
env HOME="${fake_home}" MACAUDIT_FDA_AVAILABLE=no \
  PATH="${shim_dir}:${PATH}" \
  bash "${macaudit_sh}" baseline --tier all --user-only \
    --output "${manifest}" \
  >/dev/null 2>&1
end=$(_now)
elapsed=$(_elapsed "${start}" "${end}")

# Count manifest entries (one JSON object per line).
if [ -f "${manifest}" ]; then
  manifest_entries=$(wc -l < "${manifest}" | tr -d ' ')
else
  manifest_entries=0
fi

# -----------------------------------------------------------------------------
# Verdict
# -----------------------------------------------------------------------------

verdict=$(awk -v t="${elapsed}" -v tgt="${target_seconds}" \
  'BEGIN { if (t + 0.0 < tgt + 0.0) print "pass"; else print "fail" }')

# -----------------------------------------------------------------------------
# perf.md log append
# -----------------------------------------------------------------------------
# Columns (tab-separated): ISO timestamp, bash version, fixture entry
# count, manifest entry count, wall-clock seconds, verdict.

if [ ! -f "${perf_log}" ]; then
  {
    printf '%s\n' '# macaudit perf runs — appended by tests/perf/run.sh, do not hand-edit'
    printf '%s\n' ''
    printf '%s\n' 'This log is produced by `bash tests/perf/run.sh`. It is NOT wired into'
    printf '%s\n' 'the default tests/run.sh; use `tests/run.sh --perf` to run it as part'
    printf '%s\n' 'of a full suite.'
    printf '%s\n' ''
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      'timestamp' 'bash' 'fixture_entries' 'manifest_entries' 'seconds' 'verdict'
  } > "${perf_log}"
fi

iso_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# BASH_VERSION is always set by bash itself.
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "${iso_ts}" "${BASH_VERSION}" "${fixture_entries}" \
  "${manifest_entries}" "${elapsed}" "${verdict}" \
  >> "${perf_log}"

# -----------------------------------------------------------------------------
# Summary + exit
# -----------------------------------------------------------------------------

printf 'perf: count=%s entries=%s seconds=%s target=%s verdict=%s\n' \
  "${count}" "${manifest_entries}" "${elapsed}" "${target_seconds}" "${verdict}"

if [ "${verdict}" = "pass" ]; then
  exit 0
fi
exit 1
