#!/bin/bash
# macaudit — macOS Forensic System Configuration Auditor (Phase 1)
#
# CLI entry point. Sources every lib/*.sh exactly once, runs startup
# preconditions (bash version, jq on PATH, macOS version warning),
# parses global flags, and dispatches to one of four subcommand handlers
# (baseline / audit / enumerate / integrity). Installs a global
# EXIT/INT trap so SIGINT during startup (before any library initialises
# its own tmpdir) still exits 130 cleanly.
#
# This file is intentionally a thin shell: every subcommand's real
# work lives in the corresponding lib/*.sh module. The cmd_* helpers
# below exist only to parse subcommand flags and forward them to the
# corresponding *_run function.
#
# Tier 3 (task 15K): `cmd_baseline` probes FDA once via `utils_fda_probe`
# when the resolved tier is 3 or all, and emits the FDA warning from
# Requirement 15.7 on probe failure. `MACAUDIT_FDA_AVAILABLE` is
# populated by that probe so the downstream `baseline_run` consumption
# is free (no extra sqlite3 forks). `cmd_enumerate` accepts
# `--databases` and forwards it to `enumerate_run`.

set -euo pipefail

# -----------------------------------------------------------------------------
# Path resolution + library sourcing
# -----------------------------------------------------------------------------
# We resolve lib/ relative to this script rather than $PWD so the tool
# works regardless of where it is invoked from. `readlink -f` is GNU-only
# on macOS, so we do the resolution in portable bash: one `cd` into
# dirname(BASH_SOURCE) gives us the absolute script directory.

_MACAUDIT_SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${_MACAUDIT_SCRIPT_DIR}/lib"

# Source dependency order — utils first, then surfaces + manifest +
# cfprefsd + persistence (building blocks), then report (used by both
# the CLI and audit), then the four subcommand modules. The order
# matters because each later file may reference helpers defined in an
# earlier one at source time.
for _lib in utils surfaces manifest cfprefsd persistence sqlite tcc sysdb quarantine xprotect report baseline audit integrity enumerate; do
  _lib_path="${LIB_DIR}/${_lib}.sh"
  if [ ! -f "${_lib_path}" ]; then
    # utils_log_err isn't available yet — fall back to a plain printf.
    printf '[x] macaudit: missing library file: %s\n' "${_lib_path}" >&2
    exit 2
  fi
  # shellcheck source=/dev/null
  . "${_lib_path}"
done
unset _lib _lib_path

# -----------------------------------------------------------------------------
# Traps
# -----------------------------------------------------------------------------
# utils_tmpdir_init installs its own EXIT/INT traps when a module calls
# it, and those traps supplant ours. That's fine — both drive the same
# utils_tmpdir_cleanup helper. The reason we install a pair here
# anyway is so that a SIGINT during startup (after the libraries load
# but before any module has called utils_tmpdir_init) still triggers an
# exit 130 cleanly, rather than an unclean bash default.

_macaudit_on_interrupt() {
  utils_tmpdir_cleanup 2>/dev/null || true
  exit 130
}

_macaudit_on_exit() {
  utils_tmpdir_cleanup 2>/dev/null || true
}

trap '_macaudit_on_interrupt' INT
trap '_macaudit_on_exit' EXIT

# -----------------------------------------------------------------------------
# Help / version
# -----------------------------------------------------------------------------

print_version() {
  printf '%s\n' 'macaudit 0.1.0-phase1'
}

# print_usage
#   Emit the usage block. Callers that want the help flag (--help / -h)
#   route this to stdout and exit 0; the "no subcommand" and "unknown
#   subcommand" paths route it to stderr and exit 2. We keep the body
#   in a single heredoc so both sinks see byte-identical copy.
print_usage() {
  local sink="${1:-stderr}"
  local block
  block=$(cat <<'EOF'
Usage: macaudit <subcommand> [options]

Subcommands:
  baseline [--output PATH] [--tier 1|2|3|all] [--user-only]
      Capture a JSONL manifest of current persistence and preference state.

  audit <baseline> [--output PATH] [--json]
      Compare current state against a stored baseline and report drift.
      Exit codes: 0 clean | 1 drift | 2 error | 3 drift + suspicious.

  enumerate [--persistence] [--preferences] [--databases] [--all]
      One-shot live summary of persistence, preference, and/or
      security-database state.

  integrity <baseline>
      Re-hash every file in a baseline and classify PASS/FAIL/MISSING/NEW.

Global options:
  --version, -V    Print the tool version and exit.
  --help, -h       Print this usage block and exit.
EOF
)
  if [ "${sink}" = "stdout" ]; then
    printf '%s\n' "${block}"
  else
    printf '%s\n' "${block}" >&2
  fi
}

# -----------------------------------------------------------------------------
# Subcommand handlers
# -----------------------------------------------------------------------------
# Every cmd_* function parses its own flags via a `while $# -gt 0; case`
# loop (the same pattern baseline_run / audit_run use internally) and
# forwards to the corresponding *_run function. Unknown flags are
# rejected with exit 2 — the downstream *_run functions also do their
# own validation, but catching flag errors here produces a more precise
# error message ("macaudit baseline: unknown flag 'X'" vs the generic
# "baseline_run: unknown flag 'X'").

# cmd_baseline [--output PATH] [--tier 1|2|3|all] [--user-only]
#   Wraps baseline_run. `--tier 3` captures only the Tier 3 security
#   databases; `--tier all` (the default) captures Tier 1, 2, and 3.
cmd_baseline() {
  local tier="all"
  local user_only=0
  local output=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        if [ $# -lt 2 ]; then
          utils_log_err "macaudit baseline: --output requires a value"
          return 2
        fi
        output="$2"; shift 2
        ;;
      --tier)
        if [ $# -lt 2 ]; then
          utils_log_err "macaudit baseline: --tier requires a value"
          return 2
        fi
        tier="$2"; shift 2
        ;;
      --user-only)
        user_only=1; shift 1
        ;;
      -h|--help)
        printf '%s\n' 'Usage: macaudit baseline [--output PATH] [--tier 1|2|3|all] [--user-only]'
        return 0
        ;;
      -*)
        utils_log_err "macaudit baseline: unknown flag '$1'"
        printf '%s\n' 'Usage: macaudit baseline [--output PATH] [--tier 1|2|3|all] [--user-only]' >&2
        return 2
        ;;
      *)
        utils_log_err "macaudit baseline: unexpected positional argument '$1'"
        return 2
        ;;
    esac
  done

  # Tier validation — accept 1, 2, 3, all.
  case "$tier" in
    1|2|3|all) : ;;
    *)
      utils_log_err "macaudit baseline: invalid --tier '$tier' (expected 1, 2, 3, or all)"
      return 2
      ;;
  esac

  # Note: the startup FDA probe + warning run from main() before
  # dispatch (see task 15K.1). MACAUDIT_FDA_AVAILABLE is already
  # populated by the time we reach baseline_run, so neither this
  # handler nor baseline_run / sysdb_capture re-probes.

  local args=( --tier "$tier" )
  if [ -n "$output" ]; then
    args+=( --output "$output" )
  fi
  if [ "$user_only" -eq 1 ]; then
    args+=( --user-only )
  fi

  baseline_run "${args[@]}"
}

# cmd_audit <baseline> [--output PATH] [--json]
#   Wraps audit_run. The nuance: audit_run emits the delta JSON on its
#   stdout. We don't want operators to see BOTH the raw JSON and the
#   formatted report, so cmd_audit captures audit_run's stdout to a
#   scratch file under MACAUDIT_TMPDIR and hands it to
#   report_render_delta. The operator sees either the human report
#   (default) or the canonicalised JSON (--json), and only one of them.
#
#   --output PATH writes the rendered report to PATH instead of stdout.
#
#   Return code: audit_run's return code is authoritative (0 clean, 1
#   drift, 2 error). Even if report rendering fails, we still return
#   audit_run's code — a rendering failure on a clean delta does not
#   retroactively turn the system into a drift finding.
cmd_audit() {
  local baseline_path=""
  local output=""
  local json_flag=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        if [ $# -lt 2 ]; then
          utils_log_err "macaudit audit: --output requires a value"
          return 2
        fi
        output="$2"; shift 2
        ;;
      --json)
        json_flag=1; shift 1
        ;;
      -h|--help)
        printf '%s\n' 'Usage: macaudit audit <baseline> [--output PATH] [--json]'
        return 0
        ;;
      -*)
        utils_log_err "macaudit audit: unknown flag '$1'"
        printf '%s\n' 'Usage: macaudit audit <baseline> [--output PATH] [--json]' >&2
        return 2
        ;;
      *)
        if [ -z "$baseline_path" ]; then
          baseline_path="$1"
        else
          utils_log_err "macaudit audit: unexpected positional argument '$1'"
          return 2
        fi
        shift 1
        ;;
    esac
  done

  if [ -z "$baseline_path" ]; then
    utils_log_err "macaudit audit: <baseline> is required"
    printf '%s\n' 'Usage: macaudit audit <baseline> [--output PATH] [--json]' >&2
    return 2
  fi

  # audit_run needs a scratch tmpdir for the re-capture anyway; we
  # also need it here to hold the captured JSON. utils_tmpdir_init is
  # idempotent, so calling it a second time is a no-op.
  if ! utils_tmpdir_init >/dev/null; then
    utils_log_err "macaudit audit: unable to initialise scratch tmpdir"
    return 2
  fi

  # audit_run emits the delta JSON on stdout. We capture it, then hand
  # it to report_render_delta so the operator sees the human-readable
  # report (or json mode) rather than the raw delta object.
  local delta_file="${MACAUDIT_TMPDIR}/delta.json"
  local audit_status=0
  audit_run "$baseline_path" > "$delta_file" || audit_status=$?

  # audit_status == 2 means audit_run bailed before producing a delta —
  # skip rendering and propagate. The error message is already on
  # stderr from audit_run itself.
  if [ "$audit_status" -eq 2 ]; then
    return 2
  fi

  # audit_run should have produced a non-empty JSON document on exit
  # 0 or 1. If the file is empty something went badly wrong — fall
  # back to returning 2 so the operator sees an error.
  if [ ! -s "$delta_file" ]; then
    utils_log_err "macaudit audit: audit_run produced no output"
    return 2
  fi

  local delta_json
  delta_json=$(cat -- "$delta_file")

  local render_mode="human"
  if [ "$json_flag" -eq 1 ]; then
    render_mode="json"
  fi

  if [ -n "$output" ]; then
    # Route the rendered report to the requested file. stderr still
    # shows any error lines report_render_delta emits.
    if ! report_render_delta "$delta_json" "$render_mode" > "$output"; then
      utils_log_err "macaudit audit: unable to render report to '$output'"
      return 2
    fi
  else
    if ! report_render_delta "$delta_json" "$render_mode"; then
      utils_log_err "macaudit audit: report rendering failed"
      return 2
    fi
  fi

  return "$audit_status"
}

# cmd_enumerate [--persistence] [--preferences] [--databases] [--all]
cmd_enumerate() {
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --persistence|--preferences|--databases|--all)
        args+=("$1"); shift 1
        ;;
      -h|--help)
        printf '%s\n' 'Usage: macaudit enumerate [--persistence] [--preferences] [--databases] [--all]'
        return 0
        ;;
      -*)
        utils_log_err "macaudit enumerate: unknown flag '$1'"
        printf '%s\n' 'Usage: macaudit enumerate [--persistence] [--preferences] [--databases] [--all]' >&2
        return 2
        ;;
      *)
        utils_log_err "macaudit enumerate: unexpected positional argument '$1'"
        return 2
        ;;
    esac
  done
  enumerate_run "${args[@]+"${args[@]}"}"
}

# cmd_integrity <baseline>
cmd_integrity() {
  local baseline_path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        printf '%s\n' 'Usage: macaudit integrity <baseline>'
        return 0
        ;;
      -*)
        utils_log_err "macaudit integrity: unknown flag '$1'"
        printf '%s\n' 'Usage: macaudit integrity <baseline>' >&2
        return 2
        ;;
      *)
        if [ -z "$baseline_path" ]; then
          baseline_path="$1"
        else
          utils_log_err "macaudit integrity: unexpected positional argument '$1'"
          return 2
        fi
        shift 1
        ;;
    esac
  done
  if [ -z "$baseline_path" ]; then
    utils_log_err "macaudit integrity: <baseline> is required"
    printf '%s\n' 'Usage: macaudit integrity <baseline>' >&2
    return 2
  fi
  integrity_run "$baseline_path"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
# Preconditions, global flag parsing, subcommand dispatch.

main() {
  # Bash 3.2+ — exits 2 internally on failure.
  utils_require_bash

  # jq must be on PATH. The exact message and exit code are spec-fixed.
  if ! command -v jq >/dev/null 2>&1; then
    utils_log_err "macaudit requires jq. Install via: brew install jq"
    exit 2
  fi

  # macOS < 13 is a warning, not an error — BTM enumeration is the
  # only thing that degrades. The warning goes to stderr so it does
  # not pollute report/manifest stdout.
  local os_major
  os_major=$(utils_os_major 2>/dev/null || true)
  if [ -n "$os_major" ] && [ "$os_major" -lt 13 ] 2>/dev/null; then
    utils_log_warn "macOS < 13 — BTM enumeration skipped. Three-view correlation limited to two views."
  fi

  # Global flags first — version/help short-circuit before we look at
  # any subcommand. This means `macaudit --help baseline` prints the
  # global usage, which is consistent with most CLI tools.
  if [ $# -eq 0 ]; then
    print_usage stderr
    exit 2
  fi

  case "$1" in
    --version|-V)
      print_version
      exit 0
      ;;
    --help|-h)
      print_usage stdout
      exit 0
      ;;
  esac

  local subcommand="$1"; shift 1

  # Tier 3 startup FDA probe + warning (Requirement 15.7 / task 15K.1).
  # Gate on subcommands that can touch FDA-protected Tier 3 surfaces —
  # baseline (via --tier 3 / --tier all), audit + integrity (both
  # re-capture via baseline_run under the baseline's tier), and
  # enumerate (via --databases / --all). Skipped for unknown
  # subcommands so the "unknown subcommand" branch below still emits
  # only the usage + exit 2, with no extraneous warning preceding it.
  #
  # The probe itself is expensive (a real sqlite3 open of the system
  # TCC.db), so we only run it here when we know the subcommand will
  # reach Tier 3. `utils_fda_probe` memoises its result in
  # MACAUDIT_FDA_AVAILABLE, so downstream modules (sysdb_capture, the
  # anomaly passes, enumerate's Tier 3 summary) read the cached value
  # without re-forking sqlite3. Honouring an already-set
  # MACAUDIT_FDA_AVAILABLE also lets test harnesses pin the probe
  # result without seeding a real TCC.db.
  case "$subcommand" in
    baseline|audit|integrity|enumerate)
      if ! utils_fda_probe; then
        utils_log_warn "Full Disk Access unavailable — Tier 3 system TCC.db, KextPolicy, and ExecPolicy captures will be skipped. Grant FDA to Terminal in System Settings → Privacy & Security to enable."
      fi
      ;;
  esac

  case "$subcommand" in
    baseline)
      cmd_baseline "$@"
      ;;
    audit)
      cmd_audit "$@"
      ;;
    enumerate)
      cmd_enumerate "$@"
      ;;
    integrity)
      cmd_integrity "$@"
      ;;
    *)
      utils_log_err "macaudit: unknown subcommand '${subcommand}'"
      print_usage stderr
      exit 2
      ;;
  esac
}

main "$@"
