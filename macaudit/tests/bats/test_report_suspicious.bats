#!/usr/bin/env bats
# tests/bats/test_report_suspicious.bats — unit tests for the Tier-3
# [⚑] SUSPICIOUS rendering extension added by task 15H.
#
# These tests build a synthetic delta carrying at least one suspicious
# finding per tier plus one cross-surface correlation entry, drive
# `report_render_delta` in human mode with color disabled, and inspect
# the captured stdout. The fixture data never touches the filesystem
# outside `FIXTURE_DIR`.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/report.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-susp.XXXXXX")"
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  unset MACAUDIT_NOW
}

# _build_suspicious_delta
#   stdout: a compact JSON delta carrying one suspicious finding in
#   each of tiers 1, 2, and 3, plus one cross-surface correlation
#   finding at Tier 3. Every non-suspicious category is empty so the
#   rendered output is dominated by [⚑] blocks.
_build_suspicious_delta() {
  jq -cn '
  {
    baseline_path: "/tmp/b.jsonl",
    baseline_timestamp: "2026-04-20T14:00:00-05:00",
    baseline_header: {},
    current_header: {
      timestamp: "2026-04-27T20:00:00-05:00",
      hostname: "macbook.local",
      os_version: "15.4",
      sip_status: "enabled",
      ssv_status: "enabled"
    },
    tiers: {
      "1": {
        added: [], removed: [], modified: [], stale: [], injections: [],
        suspicious: [{
          path: "/Library/LaunchAgents/com.suspect.tier1.plist",
          anomalies: [{
            rule: "no_quarantine",
            severity: "warn",
            detail: "newly added agent lacks com.apple.quarantine xattr"
          }]
        }]
      },
      "2": {
        added: [], removed: [], modified: [], stale: [], injections: [],
        suspicious: [{
          path: "/Library/Preferences/com.suspect.tier2.plist",
          anomalies: [{
            rule: "pref_cfprefsd_disagreement",
            severity: "warn",
            detail: "cfprefsd-visible content differs from on-disk plist"
          }]
        }]
      },
      "3": {
        added: [], removed: [], modified: [], stale: [], injections: [],
        suspicious: [
          {
            path: "/Library/Application Support/com.apple.TCC/TCC.db",
            anomalies: [{
              rule: "tcc_override_policy",
              severity: "high",
              detail: "kTCCServiceCamera granted to com.unknown.app via Override Policy"
            }]
          },
          {
            path: "correlation:tcc_mdm_without_profile",
            surface: "correlation",
            anomalies: [{
              rule: "correlation:tcc_mdm_without_profile",
              severity: "high",
              detail: "com.x.app declares auth_reason=6 but no matching PPPC profile is installed"
            }]
          }
        ]
      }
    },
    summary: {
      tier1: {added:0, removed:0, modified:0, stale:0, injections:0, suspicious:1},
      tier2: {added:0, removed:0, modified:0, stale:0, injections:0, suspicious:1},
      tier3: {added:0, removed:0, modified:0, stale:0, injections:0, suspicious:2},
      total: {added:0, removed:0, modified:0, stale:0, injections:0, suspicious:3}
    }
  }
  '
}

# ---------------------------------------------------------------------------
# 1. Section rendering — [⚑] SUSPICIOUS appears per tier with findings
# ---------------------------------------------------------------------------

@test "report_render_delta: renders [⚑] SUSPICIOUS per tier that has findings" {
  delta=$(_build_suspicious_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # Tier 1 / 2 / 3 headers present.
  echo "${output}" | grep -qF 'TIER 1 — PERSISTENCE'
  echo "${output}" | grep -qF 'TIER 2 — PREFERENCES'
  echo "${output}" | grep -qF 'TIER 3 — SECURITY DATABASES'

  # Per-tier suspicious subsection headers render — count should be
  # 3 (one per tier) + 1 for the CROSS-SURFACE CORRELATION header,
  # so 4 occurrences of the [⚑] flag on header lines total.
  count=$(printf '%s\n' "${output}" | grep -c '\[⚑\]' || true)
  [ "$count" -ge 4 ]

  # Each suspicious entry's rule/severity/detail block renders.
  echo "${output}" | grep -qF 'rule:     no_quarantine'
  echo "${output}" | grep -qF 'rule:     pref_cfprefsd_disagreement'
  echo "${output}" | grep -qF 'rule:     tcc_override_policy'
  echo "${output}" | grep -qE 'severity:[[:space:]]+high'
  echo "${output}" | grep -qE 'severity:[[:space:]]+warn'
}

# ---------------------------------------------------------------------------
# 2. [⚑] section renders BEFORE the summary
# ---------------------------------------------------------------------------

@test "report_render_delta: [⚑] section and correlation block render before SUMMARY" {
  delta=$(_build_suspicious_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # Compute the line numbers for the last [⚑] header, the CROSS-SURFACE
  # block, and the SUMMARY header. Every [⚑] line must precede SUMMARY.
  summary_line=$(printf '%s\n' "${output}" | awk '/^  SUMMARY$/ {print NR; exit}')
  last_flag_line=$(printf '%s\n' "${output}" | awk '/\[⚑\]/ {ln=NR} END {print ln}')
  corr_line=$(printf '%s\n' "${output}" | awk '/CROSS-SURFACE CORRELATION/ {print NR; exit}')

  [ -n "$summary_line" ]
  [ -n "$last_flag_line" ]
  [ -n "$corr_line" ]
  [ "$last_flag_line" -lt "$summary_line" ]
  [ "$corr_line"      -lt "$summary_line" ]
}

# ---------------------------------------------------------------------------
# 3. Correlation entries are NOT duplicated inside the Tier 3 block
# ---------------------------------------------------------------------------

@test "report_render_delta: correlation finding renders under CROSS-SURFACE, not inside Tier 3 SUSPICIOUS" {
  delta=$(_build_suspicious_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # The correlation rule id (on a `rule:` line) must appear exactly
  # once — rendering inside the Tier-3 SUSPICIOUS block AND under
  # CROSS-SURFACE CORRELATION would be a duplicate.
  count=$(printf '%s\n' "${output}" \
    | grep -cE 'rule:[[:space:]]+correlation:tcc_mdm_without_profile' || true)
  [ "$count" -eq 1 ]

  # And it must appear AFTER the CROSS-SURFACE header, not before.
  corr_hdr=$(printf '%s\n' "${output}" | awk '/CROSS-SURFACE CORRELATION/ {print NR; exit}')
  corr_rule=$(printf '%s\n' "${output}" | awk '/rule:[[:space:]]+correlation:tcc_mdm_without_profile/ {print NR; exit}')
  [ "$corr_rule" -gt "$corr_hdr" ]
}

# ---------------------------------------------------------------------------
# 4. No magenta escape sequences under TERM=dumb
# ---------------------------------------------------------------------------

@test "report_render_delta: no ANSI escapes under dumb terminal" {
  delta=$(_build_suspicious_delta)
  # Force TTY-color detection off — same conditions bats applies to
  # captured stdout — plus explicitly set TERM=dumb for belt-and-braces.
  utils_tty_supports_color() { return 1; }
  export TERM=dumb
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # ESC = 0x1b. Its absence proves no color codes leaked through.
  ! printf '%s' "${output}" | grep -q $'\x1b'
}

# ---------------------------------------------------------------------------
# 5. Summary line includes suspicious count per tier and in total
# ---------------------------------------------------------------------------

@test "report_render_delta: summary lines include suspicious counts" {
  delta=$(_build_suspicious_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -qE 'Tier 1:.*1 suspicious'
  echo "${output}" | grep -qE 'Tier 2:.*1 suspicious'
  echo "${output}" | grep -qE 'Tier 3:.*2 suspicious'
  echo "${output}" | grep -qE 'Total:.*3 suspicious'
}

# ---------------------------------------------------------------------------
# 6. Symbol and color lookups for the new suspicious category
# ---------------------------------------------------------------------------

@test "report_symbol: suspicious maps to the [⚑] flag" {
  [ "$(report_symbol suspicious)" = '[⚑]' ]
}

@test "report_color: suspicious returns magenta when tty supports color" {
  utils_tty_supports_color() { return 0; }
  export TERM="${TERM:-xterm-256color}"
  # Force TERM to something other than dumb so tput produces output.
  case "${TERM}" in
    dumb) export TERM=xterm-256color ;;
  esac

  out=$(report_color suspicious)
  [ -n "$out" ]
  # First char must be ESC when tput setaf 5 is active.
  first=${out:0:1}
  [ "$first" = $'\x1b' ]
}

@test "report_color: suspicious returns empty when tty does not support color" {
  utils_tty_supports_color() { return 1; }
  out=$(report_color suspicious)
  [ -z "$out" ]
}
