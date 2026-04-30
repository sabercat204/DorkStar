#!/bin/bash
# lib/audit.sh — audit delta computation. Loads a stored baseline, re-captures
# current state, computes added/removed/modified/stale/injection/suspicious
# categories, and emits a single JSON delta document for the reporter to
# render.
#
# Task 10 introduced Tier 1 + Tier 2 classification. Task 15G extends this
# module with the `suspicious` category (current-state entries whose
# `anomalies` array is non-empty), a per-tier Tier 3 delta block, and the
# three-way exit-code rule documented under Section 1.
#
# Public entry points:
#   audit_run <baseline_path> [--output <path>] [--json]
#
# Invariants enforced here:
#
#   1. The re-capture NEVER writes to the user's manifests/ directory.
#      Everything happens under ${MACAUDIT_TMPDIR}/current.jsonl and is
#      cleaned up by the EXIT trap utils_tmpdir_init installs.
#
#   2. Re-capture uses the same `tier` and `user_only` flags the baseline
#      header records, so the comparison is apples-to-apples.
#
#   3. The delta JSON is built in a single jq pass via --slurpfile so bash
#      never enumerates entries directly. This keeps memory bounded for
#      large manifests and lets jq handle deep JSON equality (especially
#      for the `content` object) correctly.
#
#   4. Within a tier the categories {added, removed, modified} are
#      pairwise disjoint by construction (Property P5 — see design.md).
#
#   5. Every path in B ∪ C lands in exactly one of {added, removed,
#      modified, unchanged} per tier (Property P6). `unchanged` is not
#      emitted; its absence is implicit.
#
# bash 3.2 compatible. No `set -euo pipefail` — this file is sourced.
# `echo` is banned; every stdout write uses `printf '%s\n'`.

# =============================================================================
# Section 1: Entry point, flag parsing, validation
# =============================================================================
# `audit_run` is the only public function. It validates the baseline path
# and version header (Requirement 18), re-captures current state using the
# baseline's tier/user_only flags, invokes the delta compute helper, and
# emits the resulting JSON document to stdout (or to --output).
#
# Exit codes:
#   0   — delta is empty, no drift detected.
#   1   — delta has at least one non-empty category AND no suspicious entries.
#   2   — unrecoverable error before the comparison runs.
#   3   — delta has at least one non-empty category AND at least one
#         suspicious entry (i.e. a current-state entry with a non-empty
#         `anomalies` array).
#   130 — SIGINT (via the EXIT/INT trap installed by utils_tmpdir_init).

# audit_run <baseline_path> [--output <path>] [--json]
audit_run() {
  local baseline_path=""
  local output=""
  local json_flag=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        if [ $# -lt 2 ]; then
          utils_log_err "audit_run: --output requires a value"
          return 2
        fi
        output="$2"; shift 2
        ;;
      --json)
        json_flag=1; shift 1
        ;;
      --)
        shift 1
        if [ -n "$1" ] && [ -z "$baseline_path" ]; then
          baseline_path="$1"; shift 1
        fi
        ;;
      -*)
        utils_log_err "audit_run: unknown flag '$1'"
        return 2
        ;;
      *)
        if [ -z "$baseline_path" ]; then
          baseline_path="$1"
        else
          utils_log_err "audit_run: unexpected positional argument '$1'"
          return 2
        fi
        shift 1
        ;;
    esac
  done

  # The --json flag is accepted so callers can force JSON output; task 10
  # always emits JSON (report rendering lands in task 13), so the flag is
  # currently a no-op beyond parsing. Reference it to silence shellcheck
  # and future-proof the surface.
  : "$json_flag"

  if [ -z "$baseline_path" ]; then
    utils_log_err "audit_run: baseline path is required"
    return 2
  fi

  # Requirement 18.1: baseline must exist.
  if [ ! -f "$baseline_path" ]; then
    utils_log_err "baseline not found: ${baseline_path}"
    return 2
  fi

  # Requirement 18.2: manifest_version must be 1.0 or 1.1. Anything else
  # is either a future schema we do not understand or a malformed header.
  local version_raw version
  version_raw=$(manifest_header_value "$baseline_path" manifest_version)
  # manifest_header_value returns a JSON value — strings come out quoted.
  # Strip the quotes for the version check.
  version=$(printf '%s' "$version_raw" | jq -r '.' 2>/dev/null)
  case "$version" in
    1.0|1.1) : ;;
    *)
      utils_log_err "baseline version ${version} not supported by this tool (expected 1.0 or 1.1)"
      return 2
      ;;
  esac

  # Initialise the scratch tmpdir. The EXIT / INT traps this installs are
  # what drive the "SIGINT exits 130 and leaves no partial output" invariant
  # (Requirement 19) for the current.jsonl scratch file.
  if ! utils_tmpdir_init >/dev/null; then
    utils_log_err "audit_run: unable to initialise scratch tmpdir"
    return 2
  fi

  # Pull the baseline's tier + user_only so the re-capture matches.
  local tier_raw tier user_only_raw user_only
  tier_raw=$(manifest_header_value "$baseline_path" tier)
  tier=$(printf '%s' "$tier_raw" | jq -r '.' 2>/dev/null)
  if [ -z "$tier" ]; then
    utils_log_err "audit_run: baseline header missing 'tier'"
    return 2
  fi
  user_only_raw=$(manifest_header_value "$baseline_path" user_only)
  user_only=$(printf '%s' "$user_only_raw" | jq -r '.' 2>/dev/null)
  case "$user_only" in
    true|false) : ;;
    *)
      utils_log_err "audit_run: baseline header 'user_only' is not a boolean"
      return 2
      ;;
  esac

  # Re-capture into a tmpdir-scoped file. Never touches manifests/.
  local current_path="${MACAUDIT_TMPDIR}/current.jsonl"
  # Make sure any stale scratch from a previous invocation is gone.
  rm -f -- "$current_path" 2>/dev/null || true

  local recapture_args=( --output "$current_path" --tier "$tier" )
  if [ "$user_only" = "true" ]; then
    recapture_args+=( --user-only )
  fi

  # baseline_run prints the output path on stdout; we don't care about it
  # here because we already know where we told it to write. Redirect its
  # stdout to /dev/null so nothing leaks into our own stdout.
  if ! baseline_run "${recapture_args[@]}" >/dev/null; then
    utils_log_err "audit_run: re-capture failed"
    return 2
  fi
  if [ ! -f "$current_path" ]; then
    utils_log_err "audit_run: re-capture produced no manifest at '$current_path'"
    return 2
  fi

  # Compute the delta. The helper writes a single JSON document on stdout.
  local delta_json
  delta_json=$(_audit_compute_delta "$baseline_path" "$current_path") || {
    utils_log_err "audit_run: delta computation failed"
    return 2
  }
  if [ -z "$delta_json" ]; then
    utils_log_err "audit_run: delta computation produced empty output"
    return 2
  fi

  # --output: write to the file, otherwise to stdout. When --output is
  # given stdout stays silent — operators use --output precisely so they
  # can suppress tty output and still inspect the file separately.
  if [ -n "$output" ]; then
    printf '%s\n' "$delta_json" > "$output" || {
      utils_log_err "audit_run: unable to write delta to '$output'"
      return 2
    }
    utils_log_info "audit_run: delta written to ${output}"
  else
    printf '%s\n' "$delta_json"
  fi

  # Requirements 7.10 / 7.11 / 7.12, 14.1 / 14.2 / 14.5 — three-way rule:
  #   exit 0 ⟺ every category (across all tiers) empty, including suspicious;
  #   exit 1 ⟺ some category non-empty AND suspicious == 0;
  #   exit 3 ⟺ some category non-empty AND suspicious >  0.
  # We compute the two integers separately via jq so the bash side is a
  # simple branch rather than a multi-field conditional.
  local total suspicious
  total=$(printf '%s' "$delta_json" \
    | jq -r '.summary.total
             | (.added + .removed + .modified + .stale + .injections + .suspicious)' \
        2>/dev/null)
  suspicious=$(printf '%s' "$delta_json" \
    | jq -r '.summary.total.suspicious' \
        2>/dev/null)
  case "$total" in
    ''|*[!0-9]*)
      # jq gave us something we cannot interpret — treat as unrecoverable.
      utils_log_err "audit_run: summary totals malformed"
      return 2
      ;;
  esac
  case "$suspicious" in
    ''|*[!0-9]*)
      utils_log_err "audit_run: summary totals malformed"
      return 2
      ;;
  esac
  if [ "$total" -eq 0 ]; then
    return 0
  fi
  if [ "$suspicious" -gt 0 ]; then
    return 3
  fi
  return 1
}

# =============================================================================
# Section 2: Re-capture scaffolding
# =============================================================================
# There's no separate re-capture helper — audit_run invokes baseline_run
# directly in Section 1. This banner is kept so the three-section layout
# documented in design.md stays visible: anybody adding new re-capture
# scaffolding (e.g. a cached-current mode) in a future task should add it
# here rather than inside _audit_compute_delta.

# =============================================================================
# Section 3: Delta computation
# =============================================================================
# `_audit_compute_delta` reads both manifests, builds a path->entry index
# per tier, and runs a single jq pass that produces the full delta JSON
# document. The filter does the classification entirely inside jq because:
#
#   - jq handles deep structural equality for the `content` object natively,
#     avoiding a fragile bash-side diff.
#   - Slurping both entry lists into jq arrays is O(N+M) memory, which is
#     acceptable for the manifest sizes Phase 1 produces (hundreds of
#     entries, not millions).
#   - Doing the work in bash would require either subshell forks per path
#     or associative arrays (bash 3.2 lacks them).
#
# The filter expects both entry files to contain one JSON object per line.
# We produce those files by piping `manifest_entries` (which is itself a
# `tail -n +2`) through a pass-through redirect — no slurping into bash
# variables.

# _audit_compute_delta <baseline_path> <current_path>
#   stdout: a single compact JSON document with the delta shape described
#   in tasks.md §10.2. Returns 1 on any jq error (the caller treats that
#   as unrecoverable).
_audit_compute_delta() {
  local baseline_path="$1"
  local current_path="$2"

  # Materialise each manifest's entries into its own scratch file. We
  # deliberately avoid manifest_load here — it uses a SINGLE fixed scratch
  # file, so two consecutive loads would clobber each other.
  local b_entries="${MACAUDIT_TMPDIR}/audit.baseline.entries.jsonl"
  local c_entries="${MACAUDIT_TMPDIR}/audit.current.entries.jsonl"
  : > "$b_entries" || return 1
  : > "$c_entries" || return 1
  manifest_entries "$baseline_path" > "$b_entries" 2>/dev/null || return 1
  manifest_entries "$current_path"  > "$c_entries" 2>/dev/null || return 1

  # Both headers are included verbatim in the delta output so the reporter
  # can render run provenance without re-reading the manifests.
  local b_header c_header
  b_header=$(manifest_header "$baseline_path")
  c_header=$(manifest_header "$current_path")
  [ -n "$b_header" ] || b_header="{}"
  [ -n "$c_header" ] || c_header="{}"

  # We read entry files with --slurpfile which produces a one-level-wrapped
  # array. If a file is empty jq still produces `[]`, which is what we
  # want — the filter handles the zero-entry case cleanly.
  #
  # jq filter outline:
  #   - Index both entry arrays by .path per tier.
  #   - For each tier t in (1, 2, 3):
  #       added      = current entries not in baseline
  #       removed    = baseline entries not in current
  #       modified   = paths in both, with a field-level diff
  #       stale      = tier-2 current entries with cfprefsd_match == false
  #       injections = tier-1 current entries with surface == "injection"
  #       suspicious = current entries with a non-empty `anomalies` array
  #                    (Requirement 29.2 — suspicious membership is a
  #                    function of the current manifest alone).
  #   - Summary = per-tier + total counts across all six categories.
  #
  # Tier 3 `stale` and `injections` are structurally present but always
  # empty: those two categories are Tier-1/Tier-2 specific. Keeping the
  # keys present keeps the output shape uniform across tiers.

  # The filter is intentionally verbose so each category is easy to audit.
  # Every jq block is a pure expression — no side effects, no eval of
  # anything derived from the manifests.
  local filter
  read -r -d '' filter <<'JQ' || true
# Inputs:
#   $b (array of baseline entries)
#   $c (array of current entries)
#   $bh (baseline header object)
#   $ch (current  header object)
#   $bp (baseline file path string)

# Helpers -------------------------------------------------------------------

# Return a map {path: entry} for entries whose tier matches $t.
def by_path(entries; $t):
  reduce (entries[] | select((.tier // null) == $t)) as $e
    ({}; .[$e.path] = $e);

# Tri-bool coalescing helper. The manifest schema allows true/false/null,
# and jq's `//` operator is falsy-coalescing (not null-coalescing), so a
# naive `x // null` collapses `false` to `null`. We use an explicit
# has()/get pattern to preserve the three-valued semantics.
def tri($o; $k):
  if ($o | has($k)) then $o[$k] else null end;

# Compute the per-field diff between baseline b and current c entries.
# Only the fields the task description enumerates are checked.
def field_diff(b; c):
  [
    (if (b.sha256_raw // "") != (c.sha256_raw // "")
       then {field:"sha256_raw", before:(b.sha256_raw // ""), after:(c.sha256_raw // "")}
       else empty end),
    (if (b.sha256_canonical // "") != (c.sha256_canonical // "")
       then {field:"sha256_canonical", before:(b.sha256_canonical // ""), after:(c.sha256_canonical // "")}
       else empty end),
    (if (b.sha256_checkpointed // "") != (c.sha256_checkpointed // "")
       then {field:"sha256_checkpointed", before:(b.sha256_checkpointed // ""), after:(c.sha256_checkpointed // "")}
       else empty end),
    (if (b.table_snapshots // null) != (c.table_snapshots // null)
       then {field:"table_snapshots", before:(b.table_snapshots // null), after:(c.table_snapshots // null)}
       else empty end),
    (if (b.content // null) != (c.content // null)
       then {field:"content", before:(b.content // null), after:(c.content // null)}
       else empty end),
    (if tri(b; "launchctl_loaded") != tri(c; "launchctl_loaded")
       then {field:"launchctl_loaded", before:tri(b; "launchctl_loaded"), after:tri(c; "launchctl_loaded")}
       else empty end),
    (if tri(b; "btm_registered") != tri(c; "btm_registered")
       then {field:"btm_registered", before:tri(b; "btm_registered"), after:tri(c; "btm_registered")}
       else empty end),
    (if tri(b; "cfprefsd_match") != tri(c; "cfprefsd_match")
       then {field:"cfprefsd_match", before:tri(b; "cfprefsd_match"), after:tri(c; "cfprefsd_match")}
       else empty end)
  ];

# A baseline/current pair is "modified" iff any of the tracked fields
# differ. The tracked-field list here must stay aligned with the list in
# field_diff above. Note: cfprefsd_match drift is surfaced via the
# `stale` category, not `modified` — so it is intentionally excluded
# from this predicate.
#
# Tier 3 channels (sha256_checkpointed, table_snapshots) are included
# because Tier 3 entries never populate sha256_canonical or the Tier
# 1/2 `content` object — their drift lives in the SQLite-specific
# extension fields (Requirement 22.4 / 22.5 / 15J).
def is_modified(b; c):
    (b.sha256_canonical // "") != (c.sha256_canonical // "")
    or (b.sha256_checkpointed // "") != (c.sha256_checkpointed // "")
    or (b.table_snapshots // null) != (c.table_snapshots // null)
    or (b.content // null) != (c.content // null)
    or tri(b; "launchctl_loaded") != tri(c; "launchctl_loaded")
    or tri(b; "btm_registered") != tri(c; "btm_registered");

# Build one tier's delta object given the per-tier baseline + current maps.
# Returns {added, removed, modified, stale, injections, suspicious} plus the
# enclosing path union so the summary can count accurately.
#
# `stale` is tier-2 specific; `injections` is tier-1 specific; both render as
# empty arrays for every other tier. `suspicious` applies uniformly to every
# tier — membership is exactly "current entry with a non-empty anomalies
# array", independent of the baseline (Requirement 29.2).
def tier_delta($bm; $cm; $t):
  ( [$cm | keys_unsorted[] ] ) as $c_paths
  | ( [$bm | keys_unsorted[] ] ) as $b_paths
  | {
      added: [
        $c_paths[]
        | . as $p
        | select(($bm | has($p)) | not)
        | {path:$p, entry: $cm[$p]}
      ],
      removed: [
        $b_paths[]
        | . as $p
        | select(($cm | has($p)) | not)
        | {path:$p, entry: $bm[$p]}
      ],
      modified: [
        $c_paths[]
        | . as $p
        | select($bm | has($p))
        | ($bm[$p]) as $bv
        | ($cm[$p]) as $cv
        | select(is_modified($bv; $cv))
        | {path:$p, before:$bv, after:$cv, changes: field_diff($bv; $cv)}
      ],
      stale: (
        if $t == 2 then
          [
            $c_paths[]
            | . as $p
            | ($cm[$p]) as $cv
            | select(($cv | has("cfprefsd_match")) and ($cv.cfprefsd_match == false))
            | {path:$p, disk:($cv.sha256_canonical // ""), live:""}
          ]
        else
          []
        end
      ),
      injections: (
        if $t == 1 then
          [
            $c_paths[]
            | . as $p
            | ($cm[$p]) as $cv
            | select(($cv.surface // "") == "injection")
            | {label:($cv.content.label // ""),
               pid:($cv.content.pid // null),
               status:($cv.content.status // null),
               btm_registered:($cv.btm_registered // null)}
          ]
        else
          []
        end
      ),
      suspicious: [
        $c_paths[]
        | . as $p
        | ($cm[$p]) as $cv
        | ($cv.anomalies // []) as $anoms
        | select(($anoms | type) == "array" and ($anoms | length) > 0)
        | {path:$p, anomalies:$anoms}
      ]
    };

# Top-level: build tier 1, tier 2, and tier 3 deltas, then summarise.
# --slurpfile produces $b / $c as arrays of entry objects — we pass the
# whole array into by_path so its `entries[]` iteration expands the
# per-entry stream.
#
# Tier 3 is included unconditionally. When both the baseline and the
# current manifest have zero Tier 3 entries (the v1.0-baseline case),
# every Tier 3 array in the output is empty but the shape is identical
# to tiers 1 and 2 — downstream renderers can iterate all three tiers
# without branching on version.
( by_path($b; 1) ) as $b1
| ( by_path($c; 1) ) as $c1
| ( by_path($b; 2) ) as $b2
| ( by_path($c; 2) ) as $c2
| ( by_path($b; 3) ) as $b3
| ( by_path($c; 3) ) as $c3
| ( tier_delta($b1; $c1; 1) ) as $t1
| ( tier_delta($b2; $c2; 2) ) as $t2
| ( tier_delta($b3; $c3; 3) ) as $t3
| {
    baseline_path: $bp,
    baseline_timestamp: ($bh.timestamp // ""),
    baseline_header: $bh,
    current_header:  $ch,
    tiers: { "1": $t1, "2": $t2, "3": $t3 },
    summary: {
      tier1: {
        added:      ($t1.added      | length),
        removed:    ($t1.removed    | length),
        modified:   ($t1.modified   | length),
        stale:      ($t1.stale      | length),
        injections: ($t1.injections | length),
        suspicious: ($t1.suspicious | length)
      },
      tier2: {
        added:      ($t2.added      | length),
        removed:    ($t2.removed    | length),
        modified:   ($t2.modified   | length),
        stale:      ($t2.stale      | length),
        injections: ($t2.injections | length),
        suspicious: ($t2.suspicious | length)
      },
      tier3: {
        added:      ($t3.added      | length),
        removed:    ($t3.removed    | length),
        modified:   ($t3.modified   | length),
        stale:      ($t3.stale      | length),
        injections: ($t3.injections | length),
        suspicious: ($t3.suspicious | length)
      },
      total: {
        added:      (($t1.added      | length) + ($t2.added      | length) + ($t3.added      | length)),
        removed:    (($t1.removed    | length) + ($t2.removed    | length) + ($t3.removed    | length)),
        modified:   (($t1.modified   | length) + ($t2.modified   | length) + ($t3.modified   | length)),
        stale:      (($t1.stale      | length) + ($t2.stale      | length) + ($t3.stale      | length)),
        injections: (($t1.injections | length) + ($t2.injections | length) + ($t3.injections | length)),
        suspicious: (($t1.suspicious | length) + ($t2.suspicious | length) + ($t3.suspicious | length))
      }
    }
  }
JQ

  # --slurpfile reads a newline-delimited JSON file into a single array.
  # Empty files produce `[]`, which is exactly what we want for the
  # "baseline or current had no entries" case.
  local delta_json
  delta_json=$(jq -cn \
    --slurpfile b "$b_entries" \
    --slurpfile c "$c_entries" \
    --argjson   bh "$b_header" \
    --argjson   ch "$c_header" \
    --arg       bp "$baseline_path" \
    "$filter" 2>/dev/null)

  if [ -z "$delta_json" ]; then
    return 1
  fi
  # Sanity check — the filter must produce a single top-level JSON object.
  if ! printf '%s' "$delta_json" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$delta_json"
  return 0
}
