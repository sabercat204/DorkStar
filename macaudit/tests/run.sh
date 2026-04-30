#!/bin/bash
# tests/run.sh — run the bats and hypothesis test suites.
#
# Tolerates missing bats / pytest so scaffolding tasks don't fail CI before
# those tools are installed. Any test failure from an installed runner is
# surfaced via the `set -e` exit semantics below.
#
# Flags:
#   --perf   After the bats + pytest suites pass, also run the
#            performance harness at tests/perf/run.sh. Not part of the
#            default loop because it takes multiple seconds; invoke it
#            explicitly or out of CI on demand.

set -euo pipefail

# Resolve paths relative to the project root (parent of this script).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"

bats_dir="${project_root}/tests/bats"
pbt_dir="${project_root}/tests/pbt"
perf_script="${project_root}/tests/perf/run.sh"

# --- flag parsing -------------------------------------------------------------
run_perf=0
while [ $# -gt 0 ]; do
  case "$1" in
    --perf)
      run_perf=1; shift 1
      ;;
    -h|--help)
      printf '%s\n' 'Usage: tests/run.sh [--perf]'
      exit 0
      ;;
    *)
      printf 'tests/run.sh: unexpected argument: %s\n' "$1" >&2
      printf '%s\n' 'Usage: tests/run.sh [--perf]' >&2
      exit 2
      ;;
  esac
done

status=0

# --- bats suite ---------------------------------------------------------------
bats_files=()
if [ -d "${bats_dir}" ]; then
  # Collect .bats files (null-safe, handles zero matches).
  while IFS= read -r -d '' f; do
    bats_files+=("$f")
  done < <(find "${bats_dir}" -type f -name '*.bats' -print0 2>/dev/null || true)
fi

if [ "${#bats_files[@]}" -eq 0 ]; then
  printf '[i] no .bats files in %s — skipping bats suite\n' "${bats_dir}"
elif ! command -v bats >/dev/null 2>&1; then
  printf '[!] bats not installed — skipping bats suite (install with: brew install bats-core)\n'
else
  printf '[i] running bats %s\n' "${bats_dir}"
  if ! bats "${bats_dir}"; then
    status=1
  fi
fi

# --- hypothesis / pytest suite ------------------------------------------------
pbt_files=()
if [ -d "${pbt_dir}" ]; then
  while IFS= read -r -d '' f; do
    pbt_files+=("$f")
  done < <(find "${pbt_dir}" -type f -name 'test_*.py' -print0 2>/dev/null || true)
fi

if [ "${#pbt_files[@]}" -eq 0 ]; then
  printf '[i] no test_*.py files in %s — skipping pytest suite\n' "${pbt_dir}"
elif ! command -v python3 >/dev/null 2>&1; then
  printf '[!] python3 not installed — skipping pytest suite\n'
else
  if ! python3 -c 'import pytest' >/dev/null 2>&1; then
    printf '[!] pytest not installed — skipping pytest suite (install with: pip install pytest hypothesis)\n'
  else
    printf '[i] running python3 -m pytest %s\n' "${pbt_dir}"
    if ! python3 -m pytest "${pbt_dir}"; then
      status=1
    fi
  fi
fi

# --- optional perf harness ----------------------------------------------------
# Opt-in via `--perf`. Only executed if the bats + pytest suites
# passed, so a perf regression doesn't mask a functional regression in
# the output.

if [ "${run_perf}" -eq 1 ]; then
  if [ "${status}" -ne 0 ]; then
    printf '[!] skipping perf harness — prior suites failed (status=%s)\n' "${status}"
  elif [ ! -f "${perf_script}" ]; then
    printf '[!] perf harness not found at %s — skipping\n' "${perf_script}"
  else
    printf '[i] running perf harness %s\n' "${perf_script}"
    if ! bash "${perf_script}"; then
      status=1
    fi
  fi
fi

exit "${status}"
