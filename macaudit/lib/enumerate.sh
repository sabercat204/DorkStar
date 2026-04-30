#!/bin/bash
# lib/enumerate.sh — one-shot, baseline-free dump of current persistence
# and/or preference state for reconnaissance.
#
# Unlike baseline/audit, this module never writes a manifest and never
# compares against a prior snapshot. It emits a human-readable summary
# of *live* state — what exists on the box right now — and skips lines
# the current privilege / OS context cannot answer. Skipped lines are
# rendered as `--- (skipped: <reason>)` so the operator immediately
# sees which data points would need sudo, FDA, or a newer macOS to
# populate.
#
# Output semantics:
#   - Every numeric count is a plain integer (no commas, no units).
#   - Unavailable sources render as the literal string `---` followed
#     by a parenthetical skip reason.
#   - Everything goes to stdout, never stderr. There are no `[i]` /
#     `[!]` prefixes — this is user-facing tabular data, not logging.
#   - Exit status is always 0 on a successful run. Enumerate is a
#     reconnaissance tool, we always want the best available picture
#     and never short-circuit on a partial answer.
#
# Structure:
#   - enumerate_run               — public entry point; parses flags,
#                                   calls one or more section helpers.
#   - _enumerate_tier1_summary    — prints the TIER 1 block.
#   - _enumerate_tier2_summary    — prints the TIER 2 block.
#   - _enumerate_tier3_summary    — prints the TIER 3 block (security
#                                   databases).
#   - _enumerate_count_plists     — helper: count *.plist files under a
#                                   directory, empty string on missing
#                                   directory or enumeration error.
#   - _enumerate_emit             — helper: format one label line with
#                                   either a numeric count or a skip
#                                   marker.
#   - _enumerate_sqlite_row_count — helper: open a SQLite database via
#                                   sqlite_safe_copy and return the
#                                   `SELECT COUNT(*)` for a table.
#
# Bash 3.2 compatibility: no associative arrays, no mapfile/readarray,
# no `<<<` here-strings. Counts go through `find ... | wc -l | tr -d`
# so a missing directory becomes an empty count cleanly — globbing
# with `shopt -s nullglob` would work too but is fiddlier across bash
# versions.

# -----------------------------------------------------------------------------
# Formatting constants
# -----------------------------------------------------------------------------
# Column width used for the label portion of every summary line. The
# value is chosen to accommodate the longest label in either tier with
# a visually consistent gap between label and value. Keep this in sync
# with the design.md example block.
_ENUMERATE_LABEL_WIDTH=33

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

# _enumerate_emit <label> <value>
#   stdout: `  <label-padded-to-width>  <value>`
#
# <value> is emitted verbatim — callers pass either a decimal count or
# the pre-formatted skip marker (`--- (skipped: <reason>)`). The label
# has a trailing colon appended inside this helper so call sites stay
# terse.
_enumerate_emit() {
  local label="$1"
  local value="$2"
  printf '  %-'"$_ENUMERATE_LABEL_WIDTH"'s %s\n' "${label}:" "$value"
}

# _enumerate_count_plists <dir>
#   stdout: integer count of `*.plist` files directly under <dir>, or
#           empty string when <dir> is missing / unreadable.
#   exit:   always 0.
#
# Uses `find -maxdepth 1` to avoid recursing into sub-bundles. A
# missing directory yields a `find` error on stderr (suppressed) and
# an empty stdout, which we normalise to the empty string — callers
# treat empty as "no count available" rather than "zero".
_enumerate_count_plists() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf '%s' ''
    return 0
  fi
  find "$dir" -maxdepth 1 -name '*.plist' -type f 2>/dev/null \
    | wc -l \
    | tr -d ' '
}

# _enumerate_count_entries <dir>
#   stdout: integer count of regular files directly under <dir>, or
#           empty string when <dir> is missing / unreadable.
#   exit:   always 0.
#
# Used for directories whose members are not *.plist (periodic scripts,
# cron tabs, emond rules directory when checking for a bundle rather
# than a plist). Same missing-directory semantics as
# _enumerate_count_plists.
_enumerate_count_entries() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf '%s' ''
    return 0
  fi
  find "$dir" -maxdepth 1 -type f 2>/dev/null \
    | wc -l \
    | tr -d ' '
}

# _enumerate_count_bundles <dir>
#   stdout: integer count of directory entries (of any type other than
#           the parent itself) directly under <dir>, or empty string
#           when <dir> is missing. Used for the SecurityAgentPlugins
#           surface whose members are `.bundle` directories.
#   exit:   always 0.
_enumerate_count_bundles() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf '%s' ''
    return 0
  fi
  find "$dir" -maxdepth 1 -mindepth 1 2>/dev/null \
    | wc -l \
    | tr -d ' '
}

# _enumerate_count_cron_lines <dir>
#   stdout: integer count of non-empty lines across every file under
#           <dir>, or empty string when <dir> is missing. One cron
#           tab per user, one line per scheduled entry.
#   exit:   always 0.
_enumerate_count_cron_lines() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf '%s' ''
    return 0
  fi
  # awk sums non-empty lines across every file find prints. The
  # `-print0 | xargs -0` dance avoids problems with whitespace in tab
  # filenames; in practice cron tabs are usernames so whitespace is
  # extremely unlikely, but we stay defensive.
  local total
  total=$(find "$dir" -maxdepth 1 -type f 2>/dev/null -print0 \
    | xargs -0 awk 'NF { c++ } END { print c + 0 }' 2>/dev/null)
  # xargs with no input still runs awk once on /dev/null-equivalent
  # input; awk prints "0". If the find itself failed or emitted
  # nothing, xargs produces empty stdout and total stays empty.
  if [ -z "$total" ]; then
    total=0
  fi
  printf '%s' "$total"
}

# _enumerate_login_hooks_count
#   stdout: `1` if either the LoginHook or LogoutHook key is set in
#           com.apple.loginwindow; `0` otherwise. Empty string if
#           `defaults` is unavailable.
#   exit:   always 0.
_enumerate_login_hooks_count() {
  if ! command -v defaults >/dev/null 2>&1; then
    printf '%s' ''
    return 0
  fi
  local hit=0
  local val
  val=$(defaults read com.apple.loginwindow LoginHook 2>/dev/null)
  if [ -n "$val" ]; then
    hit=1
  fi
  val=$(defaults read com.apple.loginwindow LogoutHook 2>/dev/null)
  if [ -n "$val" ]; then
    hit=1
  fi
  printf '%s' "$hit"
}

# _enumerate_btm_skip_reason
#   stdout: one of:
#             - empty string              — BTM is available; caller
#                                           should count records.
#             - `macOS < 13`              — BTM did not exist before
#                                           Ventura.
#             - `no sudo`                 — caller is not root and
#                                           sfltool dumpbtm requires
#                                           root.
#             - `sfltool unavailable`     — sfltool binary missing on
#                                           PATH (typically indicates
#                                           an incomplete Command Line
#                                           Tools install).
#   exit:   always 0.
#
# Probe order matches the design: version first, then privilege, then
# binary availability. Every subsequent reason implies the previous
# ones did not trip.
_enumerate_btm_skip_reason() {
  local os_major
  os_major=$(utils_os_major 2>/dev/null)
  if [ -z "$os_major" ] || [ "$os_major" -lt 13 ] 2>/dev/null; then
    printf '%s' 'macOS < 13'
    return 0
  fi
  if ! utils_has_sudo; then
    printf '%s' 'no sudo'
    return 0
  fi
  if ! command -v sfltool >/dev/null 2>&1; then
    printf '%s' 'sfltool unavailable'
    return 0
  fi
  printf '%s' ''
}

# -----------------------------------------------------------------------------
# Tier 1 — persistence
# -----------------------------------------------------------------------------

# _enumerate_tier1_summary
#   stdout: the Tier 1 block — a `TIER 1 — PERSISTENCE (live)` header
#           line followed by one line per persistence surface counter.
#   exit:   always 0.
#
# System-scoped surfaces (LaunchAgents system, LaunchDaemons, cron,
# auth plugins, emond rules) are gated on sudo. A non-root caller
# sees `--- (skipped: no sudo)` on those lines. User-scoped and
# ambient surfaces (LaunchAgents user, user launchctl, periodic,
# login hooks) are always counted.
_enumerate_tier1_summary() {
  printf '%s\n' 'TIER 1 — PERSISTENCE (live)'

  local count reason
  local has_sudo=1
  utils_has_sudo || has_sudo=0

  # LaunchAgents (user): directly under $HOME/Library/LaunchAgents.
  # Always available — no sudo required for the caller's own home.
  count=$(_enumerate_count_plists "${HOME}/Library/LaunchAgents")
  [ -n "$count" ] || count=0
  _enumerate_emit 'LaunchAgents (user)' "$count"

  # LaunchAgents (system): /Library/LaunchAgents. Sudo-gated for
  # consistency with baseline even though the directory is typically
  # world-readable.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_plists /Library/LaunchAgents)
    [ -n "$count" ] || count=0
    _enumerate_emit 'LaunchAgents (system)' "$count"
  else
    _enumerate_emit 'LaunchAgents (system)' '--- (skipped: no sudo)'
  fi

  # LaunchDaemons: /Library/LaunchDaemons. Same sudo gating.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_plists /Library/LaunchDaemons)
    [ -n "$count" ] || count=0
    _enumerate_emit 'LaunchDaemons' "$count"
  else
    _enumerate_emit 'LaunchDaemons' '--- (skipped: no sudo)'
  fi

  # launchctl jobs (user): count of label rows from the user collector.
  # Always available; empty when launchctl is missing.
  local rows
  rows=$(persistence_collect_launchctl_user 2>/dev/null)
  if [ -z "$rows" ]; then
    count=0
  else
    count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  fi
  _enumerate_emit 'launchctl jobs (user)' "$count"

  # launchctl jobs (system): sudo-gated.
  if [ "$has_sudo" -eq 1 ]; then
    rows=$(persistence_collect_launchctl_system 2>/dev/null)
    if [ -z "$rows" ]; then
      count=0
    else
      count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    fi
    _enumerate_emit 'launchctl jobs (system)' "$count"
  else
    _enumerate_emit 'launchctl jobs (system)' '--- (skipped: no sudo)'
  fi

  # BTM records: triply gated — macOS < 13, no sudo, or no sfltool.
  reason=$(_enumerate_btm_skip_reason)
  if [ -n "$reason" ]; then
    _enumerate_emit 'BTM records' "--- (skipped: ${reason})"
  else
    rows=$(persistence_collect_btm 2>/dev/null)
    if [ -z "$rows" ]; then
      count=0
    else
      count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    fi
    _enumerate_emit 'BTM records' "$count"
  fi

  # cron entries: every non-empty line across /var/at/tabs/*.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_cron_lines /var/at/tabs)
    [ -n "$count" ] || count=0
    _enumerate_emit 'cron entries' "$count"
  else
    _enumerate_emit 'cron entries' '--- (skipped: no sudo)'
  fi

  # periodic (non-Apple): files under /etc/periodic/{daily,weekly,monthly}.
  # The "(non-Apple)" label is forward-looking — the filter will land
  # in a later phase. For now we count everything that exists.
  local periodic_total=0
  local d
  for d in /etc/periodic/daily /etc/periodic/weekly /etc/periodic/monthly; do
    local c
    c=$(_enumerate_count_entries "$d")
    if [ -n "$c" ]; then
      periodic_total=$((periodic_total + c))
    fi
  done
  _enumerate_emit 'periodic (non-Apple)' "$periodic_total"

  # Login hooks: 1 if LoginHook or LogoutHook is set, else 0.
  count=$(_enumerate_login_hooks_count)
  [ -n "$count" ] || count=0
  _enumerate_emit 'login hooks' "$count"

  # Authorization plugins (non-Apple): bundles under
  # /Library/Security/SecurityAgentPlugins.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_bundles /Library/Security/SecurityAgentPlugins)
    [ -n "$count" ] || count=0
    _enumerate_emit 'auth plugins (non-Apple)' "$count"
  else
    _enumerate_emit 'auth plugins (non-Apple)' '--- (skipped: no sudo)'
  fi

  # emond rules: *.plist under /etc/emond.d/rules.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_plists /etc/emond.d/rules)
    [ -n "$count" ] || count=0
    _enumerate_emit 'emond rules' "$count"
  else
    _enumerate_emit 'emond rules' '--- (skipped: no sudo)'
  fi
}

# -----------------------------------------------------------------------------
# Tier 2 — preferences
# -----------------------------------------------------------------------------

# _enumerate_tier2_summary
#   stdout: the Tier 2 block — a `TIER 2 — PREFERENCES (live)` header
#           line followed by one line per preference surface counter.
#   exit:   always 0.
_enumerate_tier2_summary() {
  printf '%s\n' 'TIER 2 — PREFERENCES (live)'

  local count
  local has_sudo=1
  utils_has_sudo || has_sudo=0

  # /Library/Preferences: system-wide plists.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_plists /Library/Preferences)
    [ -n "$count" ] || count=0
    _enumerate_emit '/Library/Preferences' "$count"
  else
    _enumerate_emit '/Library/Preferences' '--- (skipped: no sudo)'
  fi

  # /Library/Managed Preferences: MDM-delivered plists. Non-recursive —
  # per-user subdirectories are not enumerated at this level.
  if [ "$has_sudo" -eq 1 ]; then
    count=$(_enumerate_count_plists '/Library/Managed Preferences')
    [ -n "$count" ] || count=0
    _enumerate_emit '/Library/Managed Preferences' "$count"
  else
    _enumerate_emit '/Library/Managed Preferences' '--- (skipped: no sudo)'
  fi

  # ~/Library/Preferences: always available.
  count=$(_enumerate_count_plists "${HOME}/Library/Preferences")
  [ -n "$count" ] || count=0
  _enumerate_emit '~/Library/Preferences' "$count"
}

# -----------------------------------------------------------------------------
# Tier 3 — security databases
# -----------------------------------------------------------------------------

# _enumerate_sqlite_row_count <db_path> <sql>
#   stdout: integer returned by `<sql>` (which must be a
#           SELECT COUNT(*)-shaped query) executed read-only against
#           a safe-copy of <db_path>. Empty string when the copy or
#           query fails.
#   exit:   always 0.
#
# Uses `sqlite_safe_copy` to fold the WAL into a scratch copy (cleaned
# up by the EXIT trap) and then queries the COPY in read-only mode
# via a URI. The source database is never opened for writing.
_enumerate_sqlite_row_count() {
  local db_path="$1"
  local sql="$2"
  if [ -z "$db_path" ] || [ -z "$sql" ]; then
    printf '%s' ''
    return 0
  fi
  if [ ! -r "$db_path" ]; then
    printf '%s' ''
    return 0
  fi
  local copy
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    printf '%s' ''
    return 0
  fi
  local out
  out=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" "$sql" 2>/dev/null)
  if [ -z "$out" ]; then
    printf '%s' ''
    return 0
  fi
  # Trim any whitespace / CR that sqlite3 may append on some builds.
  printf '%s' "$out" | tr -d '[:space:]'
}

# _enumerate_sqlite_sum_rows <db_path> <table1> [<table2> ...]
#   stdout: integer sum of row counts across every table in the list
#           that actually exists on the checkpointed copy of <db_path>.
#           Tables that do not exist contribute 0. Empty string when
#           the safe-copy fails entirely.
#   exit:   always 0.
_enumerate_sqlite_sum_rows() {
  local db_path="$1"; shift
  if [ -z "$db_path" ] || [ $# -eq 0 ]; then
    printf '%s' ''
    return 0
  fi
  if [ ! -r "$db_path" ]; then
    printf '%s' ''
    return 0
  fi
  local copy
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    printf '%s' ''
    return 0
  fi

  local total=0 table exists rows
  for table in "$@"; do
    [ -n "$table" ] || continue
    exists=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
      "SELECT name FROM sqlite_master WHERE type='table' AND name='${table}' LIMIT 1;" \
      2>/dev/null)
    [ -n "$exists" ] || continue
    rows=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
      "SELECT COUNT(*) FROM ${table};" 2>/dev/null | tr -d '[:space:]')
    [ -n "$rows" ] || rows=0
    total=$((total + rows))
  done
  printf '%s' "$total"
}

# _enumerate_tier3_homes
#   stdout: newline-separated list of home directories to walk for
#           per-user Tier 3 surfaces (TCC user DB, LSQuarantineEvent).
#           `$HOME` is always emitted first when non-empty; readable
#           entries under `/Users/*` (or `MACAUDIT_USERS_DIR_OVERRIDE`)
#           are appended, skipping `Shared`, `Guest`, and dotfile-
#           prefixed names, and skipping a second emission of `$HOME`.
#   exit:   always 0.
#
# Mirrors the `_baseline_enumerable_homes` walk in lib/baseline.sh so
# enumerate and baseline agree on which homes count as "user homes"
# for the same surfaces. The override lets tests drive the walk from
# a fixture tree.
_enumerate_tier3_homes() {
  if [ -n "${HOME:-}" ]; then
    printf '%s\n' "$HOME"
  fi

  local users_root="${MACAUDIT_USERS_DIR_OVERRIDE:-/Users}"
  [ -d "$users_root" ] || return 0
  [ -r "$users_root" ] || return 0

  local candidate base
  for candidate in "$users_root"/*; do
    [ -e "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    [ -r "$candidate" ] || continue
    base=$(basename -- "$candidate")
    case "$base" in
      Shared|Guest) continue ;;
      .*)           continue ;;
    esac
    if [ -n "${HOME:-}" ] && [ "$candidate" = "$HOME" ]; then
      continue
    fi
    printf '%s\n' "$candidate"
  done
}

# _enumerate_tier3_summary
#   stdout: the Tier 3 block — a `TIER 3 — SECURITY DATABASES (live)`
#           header line followed by one line per security-database
#           counter. Skip markers follow the standard
#           `--- (skipped: <reason>)` convention.
#   exit:   always 0.
#
# Line inventory (in emission order):
#   - `System TCC rows`                   SELECT COUNT(*) FROM access on
#                                         the system TCC.db. FDA-gated;
#                                         skip reason `fda-unavailable`.
#   - `~<user>/Library/...TCC.db`         SELECT COUNT(*) FROM access on
#     (one line per enumerable home)      each readable per-user TCC.db.
#                                         Unreadable / missing DBs are
#                                         skipped silently — a fresh
#                                         install genuinely has no DB,
#                                         and "no line" is the cleanest
#                                         representation of that baseline
#                                         state (same convention baseline
#                                         uses when recording skipped
#                                         paths).
#   - `KextPolicy (kext_policy)`          SELECT COUNT(*) FROM kext_policy.
#                                         FDA-gated.
#   - `KextPolicy (kext_policy_mdm)`      SELECT COUNT(*) FROM
#                                         kext_policy_mdm. FDA-gated.
#                                         Rendered as a sibling line to
#                                         kext_policy so MDM-delivered
#                                         vs user-approved counts are
#                                         visually distinct at a glance.
#   - `ExecPolicy (<table>)`              One line per table in
#                                         {legacy_exec_history_v4,
#                                         policy_scan_cache,
#                                         provisional_policy} that
#                                         actually exists on the live DB.
#                                         Missing tables are omitted
#                                         silently. FDA-gated.
#   - `SystemPolicy authority rows`       SELECT COUNT(*) FROM authority.
#                                         Sudo-gated; skip reason
#                                         `no-sudo`.
#   - `~<user>/...QuarantineEventsV2`     SELECT COUNT(*) FROM
#     (one line per enumerable home)      LSQuarantineEvent on each
#                                         readable per-user quarantine
#                                         DB. Unreadable / missing DBs
#                                         skipped silently.
#   - `Auth rules captured`               `sysdb_authdb_rule_names | wc -l`.
#                                         Curated static set, always
#                                         available.
#   - `Auth rights captured`              `sysdb_authdb_right_names | wc -l`.
#                                         Curated static set, always
#                                         available.
#   - `XProtect bundle version`           `xprotect_version <bundle>`.
#                                         `--- (skipped: missing)` when
#                                         the bundle is absent or the
#                                         version probe returns nothing.
#
# Environment overrides honoured (all test-only):
#   - `TCC_SYSTEM_PATH_OVERRIDE`          system TCC.db path
#   - `KEXTPOLICY_PATH_OVERRIDE`          KextPolicy path
#   - `EXECPOLICY_PATH_OVERRIDE`          ExecPolicy path
#   - `SYSTEMPOLICY_PATH_OVERRIDE`        SystemPolicy path
#   - `XPROTECT_BUNDLE_OVERRIDE`          XProtect bundle path
#   - `MACAUDIT_USERS_DIR_OVERRIDE`       per-user homes walk root
#   - `MACAUDIT_FDA_AVAILABLE`            memoised by `utils_fda_probe`
_enumerate_tier3_summary() {
  printf '%s\n' 'TIER 3 — SECURITY DATABASES (live)'

  local has_sudo=1
  utils_has_sudo || has_sudo=0

  local fda_ok=1
  utils_fda_probe || fda_ok=0

  local count db_path home base label

  # --- System TCC rows -------------------------------------------------
  # FDA-gated. When no override is set and the probe failed, emit the
  # `fda-unavailable` skip line and move on. The override (test-only)
  # bypasses the gate so fixtures can drive the line deterministically.
  db_path=$(tcc_system_path)
  if [ -z "${TCC_SYSTEM_PATH_OVERRIDE:-}" ] && [ "$fda_ok" -eq 0 ]; then
    _enumerate_emit 'System TCC rows' '--- (skipped: fda-unavailable)'
  elif [ ! -r "$db_path" ]; then
    _enumerate_emit 'System TCC rows' '--- (skipped: fda-unavailable)'
  else
    count=$(_enumerate_sqlite_row_count "$db_path" 'SELECT COUNT(*) FROM access;')
    if [ -z "$count" ]; then
      _enumerate_emit 'System TCC rows' '--- (skipped: fda-unavailable)'
    else
      _enumerate_emit 'System TCC rows' "$count"
    fi
  fi

  # --- Per-user TCC.db row counts --------------------------------------
  # Walk every home `_enumerate_tier3_homes` returns. For each home,
  # resolve the per-user TCC.db via `tcc_user_path` so any future path
  # change lands in one place, then emit a line labelled
  # `~<username>/Library/...TCC.db`. Unreadable / missing DBs are
  # skipped silently — a fresh-install user legitimately has no DB.
  local homes
  homes=$(_enumerate_tier3_homes)
  if [ -n "$homes" ]; then
    while IFS= read -r home; do
      [ -n "$home" ] || continue
      db_path=$(tcc_user_path "$home" 2>/dev/null)
      [ -n "$db_path" ] || continue
      [ -r "$db_path" ] || continue
      base=$(basename -- "$home")
      label="~${base}/Library/...TCC.db"
      count=$(_enumerate_sqlite_row_count "$db_path" 'SELECT COUNT(*) FROM access;')
      [ -n "$count" ] || continue
      _enumerate_emit "$label" "$count"
    done <<EOF
$homes
EOF
  fi

  # --- KextPolicy (kext_policy / kext_policy_mdm) ----------------------
  # Two sibling lines so operators can tell MDM-delivered approvals
  # from locally-user-approved ones at a glance. Both are FDA-gated.
  if [ -n "${KEXTPOLICY_PATH_OVERRIDE:-}" ]; then
    db_path="$KEXTPOLICY_PATH_OVERRIDE"
  else
    db_path="/var/db/SystemPolicyConfiguration/KextPolicy"
  fi
  if [ -z "${KEXTPOLICY_PATH_OVERRIDE:-}" ] && [ "$fda_ok" -eq 0 ]; then
    _enumerate_emit 'KextPolicy (kext_policy)' '--- (skipped: fda-unavailable)'
    _enumerate_emit 'KextPolicy (kext_policy_mdm)' '--- (skipped: fda-unavailable)'
  elif [ ! -r "$db_path" ]; then
    _enumerate_emit 'KextPolicy (kext_policy)' '--- (skipped: fda-unavailable)'
    _enumerate_emit 'KextPolicy (kext_policy_mdm)' '--- (skipped: fda-unavailable)'
  else
    count=$(_enumerate_sqlite_row_count "$db_path" 'SELECT COUNT(*) FROM kext_policy;')
    if [ -z "$count" ]; then
      _enumerate_emit 'KextPolicy (kext_policy)' '--- (skipped: fda-unavailable)'
    else
      _enumerate_emit 'KextPolicy (kext_policy)' "$count"
    fi
    count=$(_enumerate_sqlite_row_count "$db_path" 'SELECT COUNT(*) FROM kext_policy_mdm;')
    if [ -z "$count" ]; then
      _enumerate_emit 'KextPolicy (kext_policy_mdm)' '--- (skipped: fda-unavailable)'
    else
      _enumerate_emit 'KextPolicy (kext_policy_mdm)' "$count"
    fi
  fi

  # --- ExecPolicy per captured table ----------------------------------
  # Enumerate the three tables we snapshot; emit a count line for each
  # that actually exists on the live DB. Missing tables are omitted
  # silently so older macOS releases (which ship a subset) stay clean.
  if [ -n "${EXECPOLICY_PATH_OVERRIDE:-}" ]; then
    db_path="$EXECPOLICY_PATH_OVERRIDE"
  else
    db_path="/var/db/SystemPolicyConfiguration/ExecPolicy"
  fi
  if [ -z "${EXECPOLICY_PATH_OVERRIDE:-}" ] && [ "$fda_ok" -eq 0 ]; then
    _enumerate_emit 'ExecPolicy' '--- (skipped: fda-unavailable)'
  elif [ ! -r "$db_path" ]; then
    _enumerate_emit 'ExecPolicy' '--- (skipped: fda-unavailable)'
  else
    _enumerate_emit_execpolicy_tables "$db_path"
  fi

  # --- SystemPolicy authority rows ------------------------------------
  # Sudo-gated (/var/db/SystemPolicyConfiguration is mode 0700 on real
  # installs). An override bypasses the privilege gate so fixtures can
  # pin the line deterministically.
  if [ -n "${SYSTEMPOLICY_PATH_OVERRIDE:-}" ]; then
    db_path="$SYSTEMPOLICY_PATH_OVERRIDE"
  else
    db_path="/var/db/SystemPolicyConfiguration/SystemPolicy"
  fi
  if [ -z "${SYSTEMPOLICY_PATH_OVERRIDE:-}" ] && [ "$has_sudo" -eq 0 ]; then
    _enumerate_emit 'SystemPolicy authority rows' '--- (skipped: no-sudo)'
  elif [ ! -r "$db_path" ]; then
    _enumerate_emit 'SystemPolicy authority rows' '--- (skipped: no-sudo)'
  else
    count=$(_enumerate_sqlite_row_count "$db_path" 'SELECT COUNT(*) FROM authority;')
    if [ -z "$count" ]; then
      _enumerate_emit 'SystemPolicy authority rows' '--- (skipped: no-sudo)'
    else
      _enumerate_emit 'SystemPolicy authority rows' "$count"
    fi
  fi

  # --- Quarantine event count per home --------------------------------
  # Same home-walk as the per-user TCC block. Emit one line per home
  # with a readable LSQuarantineEvent DB; skip silently otherwise.
  if [ -n "$homes" ]; then
    while IFS= read -r home; do
      [ -n "$home" ] || continue
      db_path="${home}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
      [ -r "$db_path" ] || continue
      base=$(basename -- "$home")
      label="~${base}/...QuarantineEventsV2"
      count=$(_enumerate_sqlite_row_count "$db_path" 'SELECT COUNT(*) FROM LSQuarantineEvent;')
      [ -n "$count" ] || continue
      _enumerate_emit "$label" "$count"
    done <<EOF
$homes
EOF
  fi

  # --- Authorization rule + right counts -------------------------------
  # Curated static name sets — sourced from lib/sysdb.sh — so the
  # counts reflect what the tool WOULD capture, not the result of any
  # runtime probe. Always available; no skip branch needed.
  local n
  n=$(sysdb_authdb_rule_names 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')
  [ -n "$n" ] || n=0
  _enumerate_emit 'Auth rules captured' "$n"
  n=$(sysdb_authdb_right_names 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')
  [ -n "$n" ] || n=0
  _enumerate_emit 'Auth rights captured' "$n"

  # --- XProtect bundle version ----------------------------------------
  # String, not a count. Rendered verbatim in place of the integer.
  # The common test-harness case is the missing-bundle branch — no
  # XPROTECT_BUNDLE_OVERRIDE set and no real bundle on disk.
  local bundle ver
  bundle=$(xprotect_bundle_path)
  if [ -z "$bundle" ] || [ ! -d "$bundle" ]; then
    _enumerate_emit 'XProtect bundle version' '--- (skipped: missing)'
  else
    ver=$(xprotect_version "$bundle")
    if [ -z "$ver" ]; then
      _enumerate_emit 'XProtect bundle version' '--- (skipped: missing)'
    else
      _enumerate_emit 'XProtect bundle version' "$ver"
    fi
  fi
}

# _enumerate_emit_execpolicy_tables <db_path>
#   Helper for the ExecPolicy block. Runs `sqlite_safe_copy` once, then
#   probes each candidate table for existence on the copy. Each existing
#   table produces one `ExecPolicy (<table>)` line with its COUNT(*).
#   Tables that do not exist on this macOS version are silently omitted.
#   Empty stdout from sqlite3 falls back to `--- (skipped: fda-unavailable)`
#   so an operator sees the reason rather than a false zero.
_enumerate_emit_execpolicy_tables() {
  local db_path="$1"
  local copy table exists rows label
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    _enumerate_emit 'ExecPolicy' '--- (skipped: fda-unavailable)'
    return 0
  fi
  for table in legacy_exec_history_v4 policy_scan_cache provisional_policy; do
    exists=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
      "SELECT name FROM sqlite_master WHERE type='table' AND name='${table}' LIMIT 1;" \
      2>/dev/null)
    [ -n "$exists" ] || continue
    rows=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
      "SELECT COUNT(*) FROM ${table};" 2>/dev/null | tr -d '[:space:]')
    [ -n "$rows" ] || rows=0
    label="ExecPolicy (${table})"
    _enumerate_emit "$label" "$rows"
  done
}

# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------

# enumerate_run [--persistence] [--preferences] [--databases] [--all]
#   Dispatch to one or more section helpers based on the flags the
#   operator passed. The default (no flag) matches `--all`. When
#   multiple flags are passed simultaneously the union of their
#   sections is printed — e.g. `--persistence --databases` emits
#   Tier 1 and Tier 3 but skips Tier 2.
#
#   Output: the selected section blocks, with one blank line between
#   consecutive blocks (but no leading or trailing blank lines).
#
#   Exit: always 0.
enumerate_run() {
  local want_persistence=0
  local want_preferences=0
  local want_databases=0
  local any_flag=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --persistence)
        want_persistence=1
        any_flag=1
        shift
        ;;
      --preferences)
        want_preferences=1
        any_flag=1
        shift
        ;;
      --databases)
        want_databases=1
        any_flag=1
        shift
        ;;
      --all)
        want_persistence=1
        want_preferences=1
        want_databases=1
        any_flag=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        # Unknown flags are ignored silently so future sub-flags can
        # be layered on without a version bump here. The dispatcher
        # in macaudit.sh does strict validation when it is the call
        # site.
        shift
        ;;
    esac
  done

  # Default to --all when no recognised section flag was supplied.
  if [ "$any_flag" -eq 0 ]; then
    want_persistence=1
    want_preferences=1
    want_databases=1
  fi

  local printed=0
  if [ "$want_persistence" -eq 1 ]; then
    _enumerate_tier1_summary
    printed=1
  fi
  if [ "$want_preferences" -eq 1 ]; then
    if [ "$printed" -eq 1 ]; then
      printf '\n'
    fi
    _enumerate_tier2_summary
    printed=1
  fi
  if [ "$want_databases" -eq 1 ]; then
    if [ "$printed" -eq 1 ]; then
      printf '\n'
    fi
    _enumerate_tier3_summary
    printed=1
  fi

  return 0
}
