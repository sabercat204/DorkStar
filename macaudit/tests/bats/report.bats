#!/usr/bin/env bats
# tests/bats/report.bats — unit tests for lib/report.sh.
#
# The report module is purely presentational — it consumes a delta
# JSON document and renders stdout — so every test here builds a
# synthetic delta by hand via jq and asserts the rendered output.
# Nothing touches the filesystem beyond a scratch tmpdir.
#
# TTY gating: bats runs tests with stdout captured into a pipe, so
# `utils_tty_supports_color` naturally returns non-zero and
# `report_color` emits the empty string. The "color when tty supports
# it" test redefines `utils_tty_supports_color` explicitly.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/report.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-report.XXXXXX")"
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  unset MACAUDIT_NOW
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# _build_full_delta
#   stdout: a compact JSON delta containing one entry in every
#   category documented in task 13 (added/removed/modified/stale/
#   injection across Tier 1 and Tier 2).
_build_full_delta() {
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
        added: [{
          path: "/Library/LaunchDaemons/com.suspicious.agent.plist",
          entry: {
            content: {
              Label: "com.suspicious.agent",
              ProgramArguments: ["/tmp/.hidden/payload"],
              RunAtLoad: true
            }
          }
        }],
        removed: [{
          path: "/Library/LaunchDaemons/com.gone-tier1.plist",
          entry: {content: {Label: "com.gone.tier1"}}
        }],
        modified: [{
          path: "/Library/LaunchAgents/com.vendor.updater.plist",
          before: {}, after: {},
          changes: [
            {field: "ProgramArguments",
             before: ["/usr/local/bin/updater"],
             after:  ["/tmp/updater"]},
            {field: "sha256_raw", before: "a1b2", after: "c3d4"}
          ]
        }],
        stale: [],
        injections: [{
          label: "com.stealth.job",
          pid: 1234,
          status: 0
        }]
      },
      "2": {
        added: [{
          path: "/Library/Preferences/com.added-tier2.plist",
          entry: {content: {Key: "value"}}
        }],
        removed: [{
          path: "/Library/Preferences/com.gone-tier2.plist",
          entry: {content: {Key: "bye"}}
        }],
        modified: [{
          path: "/Library/Preferences/com.mod.plist",
          before: {}, after: {},
          changes: [{field: "content", before: {a:1}, after: {a:2}}]
        }],
        stale: [{
          path: "/Library/Preferences/com.stale.plist",
          disk: "d1deadbeef",
          live: "l1deadbeef"
        }],
        injections: []
      }
    },
    summary: {
      tier1: {added:1, removed:1, modified:1, stale:0, injections:1},
      tier2: {added:1, removed:1, modified:1, stale:1, injections:0},
      total: {added:2, removed:2, modified:2, stale:1, injections:1}
    }
  }
  '
}

# _build_empty_delta
#   stdout: a compact JSON delta with every category empty and every
#   summary count zero. Headers are populated so the report still has
#   a meaningful top block.
_build_empty_delta() {
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
      "1": {added:[], removed:[], modified:[], stale:[], injections:[]},
      "2": {added:[], removed:[], modified:[], stale:[], injections:[]}
    },
    summary: {
      tier1: {added:0, removed:0, modified:0, stale:0, injections:0},
      tier2: {added:0, removed:0, modified:0, stale:0, injections:0},
      total: {added:0, removed:0, modified:0, stale:0, injections:0}
    }
  }
  '
}

# ---------------------------------------------------------------------------
# 1. Symbol table — every known category, plus unknown→empty
# ---------------------------------------------------------------------------

@test "report_symbol: maps every known category to its documented marker" {
  [ "$(report_symbol added)"     = '[+]' ]
  [ "$(report_symbol removed)"   = '[-]' ]
  [ "$(report_symbol modified)"  = '[~]' ]
  [ "$(report_symbol injection)" = '[!]' ]
  [ "$(report_symbol stale)"     = '[?]' ]
}

@test "report_symbol: unknown category yields empty stdout" {
  out=$(report_symbol bogus)
  [ -z "$out" ]
  out=$(report_symbol '')
  [ -z "$out" ]
}

# ---------------------------------------------------------------------------
# 2. Color when the tty reports colors
# ---------------------------------------------------------------------------

@test "report_color: returns an ESC sequence when the tty supports color" {
  # Force tty-support to true so the helper emits tput output.
  utils_tty_supports_color() { return 0; }
  # tput needs a real TERM; ensure one is present.
  export TERM="${TERM:-xterm-256color}"

  out=$(report_color added)
  # ESC is \x1b. The output must start with ESC when color is on.
  [ -n "$out" ]
  first=${out:0:1}
  [ "$first" = $'\x1b' ]
}

# ---------------------------------------------------------------------------
# 3. Color when the tty does NOT support color
# ---------------------------------------------------------------------------

@test "report_color: returns empty when the tty does not support color" {
  utils_tty_supports_color() { return 1; }
  out=$(report_color added)
  [ -z "$out" ]
  out=$(report_color removed)
  [ -z "$out" ]
  out=$(report_color modified)
  [ -z "$out" ]
  out=$(report_color injection)
  [ -z "$out" ]
  out=$(report_color stale)
  [ -z "$out" ]
}

# ---------------------------------------------------------------------------
# 4. Full delta render — every symbol/label appears
# ---------------------------------------------------------------------------

@test "report_render_delta human: renders every category symbol and label" {
  delta=$(_build_full_delta)
  # Force no-color so we can assert plaintext.
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # Tier headers
  echo "${output}" | grep -qF 'TIER 1 — PERSISTENCE'
  echo "${output}" | grep -qF 'TIER 2 — PREFERENCES'

  # Category lines. Each must appear at least once.
  echo "${output}" | grep -qF '[+] ADDED'
  echo "${output}" | grep -qF '[-] REMOVED'
  echo "${output}" | grep -qF '[~] MODIFIED'
  echo "${output}" | grep -qF '[?] STALE'
  echo "${output}" | grep -qF '[!] INJECTION'

  # Paths render intact.
  echo "${output}" | grep -qF '/Library/LaunchDaemons/com.suspicious.agent.plist'
  echo "${output}" | grep -qF '/Library/LaunchAgents/com.vendor.updater.plist'
  echo "${output}" | grep -qF '/Library/Preferences/com.stale.plist'

  # Injection has its distinctive phrasing.
  echo "${output}" | grep -qF 'launchctl shows "com.stealth.job" — no matching plist on disk'

  # No ANSI escapes (ESC = 0x1b) when color is off.
  ! printf '%s' "${output}" | grep -q $'\x1b'
}

# ---------------------------------------------------------------------------
# 5. Empty delta renders cleanly
# ---------------------------------------------------------------------------

@test "report_render_delta human: empty delta renders cleanly with zero summary" {
  delta=$(_build_empty_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # Both tier headers still present.
  echo "${output}" | grep -qF 'TIER 1 — PERSISTENCE'
  echo "${output}" | grep -qF 'TIER 2 — PREFERENCES'

  # No category symbols since every list is empty.
  ! echo "${output}" | grep -qF '[+] ADDED'
  ! echo "${output}" | grep -qF '[-] REMOVED'
  ! echo "${output}" | grep -qF '[~] MODIFIED'
  ! echo "${output}" | grep -qF '[?] STALE'
  ! echo "${output}" | grep -qF '[!] INJECTION'

  # Summary shows zeros for every category.
  echo "${output}" | grep -qE 'Tier 1:[[:space:]]+0 added \| 0 removed \| 0 modified \| 0 injection'
  echo "${output}" | grep -qE 'Tier 2:[[:space:]]+0 added \| 0 removed \| 0 modified \| 0 stale'
  echo "${output}" | grep -qE 'Total:[[:space:]]+0 added \| 0 removed \| 0 modified \| 0 injection \| 0 stale'

  # No ANSI escapes.
  ! printf '%s' "${output}" | grep -q $'\x1b'
}

# ---------------------------------------------------------------------------
# 6. JSON mode — output parses through jq
# ---------------------------------------------------------------------------

@test "report_render_delta json: echoes a jq-parseable JSON document" {
  delta=$(_build_full_delta)
  run report_render_delta "$delta" json
  [ "${status}" -eq 0 ]

  # Output must be valid JSON.
  printf '%s' "${output}" | jq -e . >/dev/null

  # Round-trip: summary totals must equal the input's summary totals.
  [ "$(printf '%s' "${output}" | jq -r '.summary.total.added')"      = '2' ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.total.removed')"    = '2' ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.total.modified')"   = '2' ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.total.stale')"      = '1' ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.total.injections')" = '1' ]
}

# ---------------------------------------------------------------------------
# 7. Enumerate JSON mode — expected schema keys, values int-or-null
# ---------------------------------------------------------------------------

@test "report_render_enumeration json: produces tier1+tier2 JSON with int/null values" {
  # Stub enumerate_run with a representative tabular output.
  enumerate_run() {
    cat <<EOF
TIER 1 — PERSISTENCE (live)
  LaunchAgents (user):               42
  LaunchAgents (system):             --- (skipped: no sudo)
  LaunchDaemons:                     --- (skipped: no sudo)
  launchctl jobs (user):             198
  launchctl jobs (system):           --- (skipped: no sudo)
  BTM records:                       --- (skipped: no sudo)
  cron entries:                      --- (skipped: no sudo)
  periodic (non-Apple):              0
  login hooks:                       0
  auth plugins (non-Apple):          --- (skipped: no sudo)
  emond rules:                       --- (skipped: no sudo)

TIER 2 — PREFERENCES (live)
  /Library/Preferences:              --- (skipped: no sudo)
  /Library/Managed Preferences:      --- (skipped: no sudo)
  ~/Library/Preferences:             127
EOF
  }

  run report_render_enumeration json
  [ "${status}" -eq 0 ]

  # Valid JSON.
  printf '%s' "${output}" | jq -e . >/dev/null

  # Tier scaffolding present.
  [ "$(printf '%s' "${output}" | jq -e 'has("tier1")')" = 'true' ]
  [ "$(printf '%s' "${output}" | jq -e 'has("tier2")')" = 'true' ]

  # Known integer values.
  [ "$(printf '%s' "${output}" | jq -r '.tier1.launch_agents_user')"  = '42'  ]
  [ "$(printf '%s' "${output}" | jq -r '.tier1.launchctl_jobs_user')" = '198' ]
  [ "$(printf '%s' "${output}" | jq -r '.tier1.periodic_non_apple')"  = '0'   ]
  [ "$(printf '%s' "${output}" | jq -r '.tier2.user_preferences')"    = '127' ]

  # Known nulls (skipped sources).
  [ "$(printf '%s' "${output}" | jq -r '.tier1.launch_agents_system')" = 'null' ]
  [ "$(printf '%s' "${output}" | jq -r '.tier1.btm_records')"          = 'null' ]
  [ "$(printf '%s' "${output}" | jq -r '.tier2.library_preferences')"  = 'null' ]

  # Every value is either an integer or null — no stray strings.
  bad=$(printf '%s' "${output}" \
    | jq -r '[.tier1,.tier2] | map(to_entries[] | .value)
              | map(select((type != "null") and (type != "number"))) | length')
  [ "${bad}" = '0' ]
}

# ---------------------------------------------------------------------------
# 8. Paths with spaces render intact
# ---------------------------------------------------------------------------

@test "report_render_delta human: paths containing spaces are preserved verbatim" {
  delta=$(jq -cn '
    {
      baseline_path: "/tmp/b.jsonl",
      baseline_timestamp: "2026-04-20T14:00:00-05:00",
      baseline_header: {},
      current_header: {timestamp:"2026-04-27T20:00:00-05:00"},
      tiers: {
        "1": {added:[], removed:[], modified:[], stale:[], injections:[]},
        "2": {
          added: [{
            path: "/Library/Managed Preferences/com.space here.plist",
            entry: {content: {Key: "value"}}
          }],
          removed: [], modified: [], stale: [], injections: []
        }
      },
      summary: {
        tier1: {added:0,removed:0,modified:0,stale:0,injections:0},
        tier2: {added:1,removed:0,modified:0,stale:0,injections:0},
        total: {added:1,removed:0,modified:0,stale:0,injections:0}
      }
    }
  ')
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -qF '/Library/Managed Preferences/com.space here.plist'
}

# ---------------------------------------------------------------------------
# 9. Long change values get truncated
# ---------------------------------------------------------------------------

@test "report_render_delta human: long modified before/after values are truncated" {
  # Construct a change.before that is 120 characters of 'A'.
  long=$(printf 'A%.0s' $(seq 1 120))

  delta=$(jq -cn --arg long "$long" '
    {
      baseline_path: "/tmp/b.jsonl",
      baseline_timestamp: "2026-04-20T14:00:00-05:00",
      baseline_header: {},
      current_header: {timestamp:"2026-04-27T20:00:00-05:00"},
      tiers: {
        "1": {added:[], removed:[],
          modified: [{
            path: "/Library/LaunchDaemons/com.long.plist",
            before: {}, after: {},
            changes: [{field:"content", before:$long, after:"short"}]
          }],
          stale: [], injections: []
        },
        "2": {added:[], removed:[], modified:[], stale:[], injections:[]}
      },
      summary: {
        tier1: {added:0,removed:0,modified:1,stale:0,injections:0},
        tier2: {added:0,removed:0,modified:0,stale:0,injections:0},
        total: {added:0,removed:0,modified:1,stale:0,injections:0}
      }
    }
  ')
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # The truncated marker '…' must appear on the change line.
  echo "${output}" | grep -qF '…'

  # And the literal 120-char payload must NOT appear in full.
  ! echo "${output}" | grep -qF "$long"
}

# ---------------------------------------------------------------------------
# 10. Summary totals match delta.summary.total
# ---------------------------------------------------------------------------

@test "report_render_delta human: summary line matches delta.summary.total" {
  delta=$(_build_full_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # _build_full_delta sets total = {added:2, removed:2, modified:2, stale:1, injections:1}.
  echo "${output}" | grep -qE 'Total:[[:space:]]+2 added \| 2 removed \| 2 modified \| 1 injection \| 1 stale'

  # Tier rollups must match too.
  echo "${output}" | grep -qE 'Tier 1:[[:space:]]+1 added \| 1 removed \| 1 modified \| 1 injection'
  echo "${output}" | grep -qE 'Tier 2:[[:space:]]+1 added \| 1 removed \| 1 modified \| 1 stale'
}

# ---------------------------------------------------------------------------
# Extra — elapsed-time formatting
# ---------------------------------------------------------------------------

@test "report_render_delta human: header includes '(…ago)' when MACAUDIT_NOW is set" {
  delta=$(_build_empty_delta)
  utils_tty_supports_color() { return 1; }
  export MACAUDIT_NOW="2026-04-27T20:00:00-05:00"

  run report_render_delta "$delta" human
  [ "${status}" -eq 0 ]

  # Baseline is exactly 7 days + 6 hours before "now" in the fixture.
  echo "${output}" | grep -qE 'Baseline:.*\(7d 6h ago\)'
}
