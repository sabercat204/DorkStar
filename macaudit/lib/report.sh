#!/bin/bash
# lib/report.sh — terminal formatting. Category symbols, colors, delta
# rendering, enumeration rendering, and summary. Supports human and --json
# output modes.
#
# The module is purely presentational: it reads an audit delta JSON
# document (produced by `audit_run` in lib/audit.sh) and an enumerate
# text report (produced by `enumerate_run` in lib/enumerate.sh) and
# emits a human-readable report or a JSON document on stdout. It never
# re-hashes, never walks filesystems, never mutates state.
#
# Category coverage (Phase 1 / Task 13 scope):
#   added, removed, modified, injection, stale
# The Tier 3 `suspicious` category and its `[⚑]` symbol / magenta color
# land in Task 15H, which extends this same module without rewriting
# it. The symbol and color helpers fall through to the empty string on
# unknown categories so 15H only has to add two case arms.
#
# bash 3.2 compatible. `echo` is banned — every stdout write uses
# `printf '%s\n'` (or a richer printf format). No `set -euo pipefail`
# because this file is sourced from the dispatcher.

# =============================================================================
# Section 1: Symbols and colors
# =============================================================================
# Two small lookups. `report_symbol` maps a delta category name to its
# fixed-width three-character marker (e.g. `[+]`). `report_color` maps
# a category to the `tput` escape sequence that introduces it — or an
# empty string when the current stdout is not a color-capable TTY. Both
# functions are tolerant of unknown categories (empty stdout), which
# keeps task 15H's `suspicious` extension additive.

# report_symbol <category>
#   stdout: the fixed-width 3-char marker for the given category:
#     added      → [+]
#     removed    → [-]
#     modified   → [~]
#     injection  → [!]
#     stale      → [?]
#     suspicious → [⚑]   (U+2691 BLACK FLAG, 3-byte UTF-8)
#   Unknown categories produce empty stdout. The `[⚑]` glyph is
#   emitted as a literal UTF-8 sequence so that the 3-column visual
#   width matches the `[X]` ASCII markers on UTF-8-aware terminals;
#   surrounding `printf` format strings do not pad on byte count so
#   the extra UTF-8 bytes do not disturb alignment.
report_symbol() {
  case "$1" in
    added)      printf '%s' '[+]' ;;
    removed)    printf '%s' '[-]' ;;
    modified)   printf '%s' '[~]' ;;
    injection)  printf '%s' '[!]' ;;
    stale)      printf '%s' '[?]' ;;
    suspicious) printf '%s' '[⚑]' ;;
    *)          : ;;
  esac
}

# report_color <category>
#   stdout: the `tput` escape sequence introducing the color used for
#   the given category, or empty when the tty does not support color.
#   Mapping (from design.md §Audit Report Rendering):
#     added      → green
#     removed    → red
#     injection  → red
#     modified   → yellow
#     stale      → yellow
#     suspicious → magenta
#   Unknown categories produce empty stdout. The `suspicious → magenta`
#   arm routes through `utils_color magenta` (added in the same task);
#   `utils_color` returns empty when the tty is color-incapable so
#   this helper inherits graceful degradation.
#
# We delegate gating to `utils_tty_supports_color` so this module never
# duplicates the `[ -t 1 ]` / `tput colors` probe. `utils_color` itself
# already emits empty output when the tty is incapable, so a second
# guard here is belt-and-braces but keeps unknown categories cheap.
report_color() {
  if ! utils_tty_supports_color; then
    return 0
  fi
  case "$1" in
    added)      utils_color green   ;;
    removed)    utils_color red     ;;
    injection)  utils_color red     ;;
    modified)   utils_color yellow  ;;
    stale)      utils_color yellow  ;;
    suspicious) utils_color magenta ;;
    *)          : ;;
  esac
}

# =============================================================================
# Section 2: Header renderer
# =============================================================================
# The top five lines of every human report: two rule lines framing a
# title, a Baseline line with an elapsed "ago" annotation, a Current
# line, and a Host / OS / SIP / SSV summary. Every field is read from
# the delta JSON's `baseline_header` and `current_header` sub-objects
# via `jq -r`, so nothing is eval'd or word-split.

# _report_format_elapsed <baseline_iso> [<now_iso>]
#   stdout: compact human-readable elapsed-time string (`7d 6h`,
#           `2h 15m`, `45s`, `1m 30s`, `just now`) between the two
#           timestamps. Empty stdout when baseline_iso is empty or
#           cannot be parsed.
#
# `now_iso` defaults to the MACAUDIT_NOW override when set (enables
# deterministic test output), falling back to `utils_iso_now`. Both
# inputs accept the `YYYY-MM-DDTHH:MM:SS±HH:MM` form utils_iso_now
# produces; the colon in the offset is stripped before passing to
# BSD `date -j -f` so we don't depend on GNU/coreutils.
_report_format_elapsed() {
  local baseline="$1"
  local now="${2:-}"
  if [ -z "$baseline" ]; then
    return 0
  fi
  if [ -z "$now" ]; then
    now="${MACAUDIT_NOW:-$(utils_iso_now 2>/dev/null)}"
  fi
  if [ -z "$now" ]; then
    return 0
  fi

  # BSD date can't consume `-05:00`; it wants `-0500`. Strip the
  # colon out of a trailing ±HH:MM if present. We do this in pure
  # bash 3.2 parameter expansion so we don't need sed.
  local b_clean n_clean
  b_clean="$baseline"
  n_clean="$now"
  # Only strip if the last 6 chars match ±HH:MM.
  local last6=""
  if [ ${#b_clean} -ge 6 ]; then
    last6=${b_clean:${#b_clean}-6}
    case "$last6" in
      [+-][0-9][0-9]:[0-9][0-9])
        b_clean="${b_clean:0:${#b_clean}-6}${last6:0:3}${last6:4:2}"
        ;;
    esac
  fi
  if [ ${#n_clean} -ge 6 ]; then
    last6=${n_clean:${#n_clean}-6}
    case "$last6" in
      [+-][0-9][0-9]:[0-9][0-9])
        n_clean="${n_clean:0:${#n_clean}-6}${last6:0:3}${last6:4:2}"
        ;;
    esac
  fi

  local b_epoch n_epoch
  b_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$b_clean" +%s 2>/dev/null)
  n_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$n_clean" +%s 2>/dev/null)
  if [ -z "$b_epoch" ] || [ -z "$n_epoch" ]; then
    return 0
  fi

  local diff=$((n_epoch - b_epoch))
  if [ "$diff" -lt 0 ]; then
    diff=$((-diff))
  fi

  local days hours minutes seconds
  days=$((diff / 86400))
  hours=$(((diff % 86400) / 3600))
  minutes=$(((diff % 3600) / 60))
  seconds=$((diff % 60))

  # Two-component compact form — the largest unit plus the next one
  # down. Seconds-only for sub-minute gaps.
  if [ "$days" -gt 0 ]; then
    printf '%dd %dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh %dm' "$hours" "$minutes"
  elif [ "$minutes" -gt 0 ]; then
    printf '%dm %ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

# _report_status_display <enabled|disabled|unknown>
#   stdout: `ON` / `OFF` / `UNKNOWN` (upper-cased form the header line
#   uses for SIP and SSV status). Empty string for anything else.
_report_status_display() {
  case "$1" in
    enabled)  printf '%s' 'ON' ;;
    disabled) printf '%s' 'OFF' ;;
    unknown)  printf '%s' 'UNKNOWN' ;;
    *)        printf '%s' 'UNKNOWN' ;;
  esac
}

# _report_render_header <delta_json>
#   stdout: the five-line header block plus the enclosing ═ rulers.
#
# Every value is pulled from the delta JSON via `jq -r`, so the only
# interpolation into the printf format strings is shell-safe text.
_report_render_header() {
  local delta="$1"
  local baseline_ts current_ts hostname os_version sip ssv elapsed
  baseline_ts=$(printf '%s' "$delta" | jq -r '.baseline_timestamp // ""' 2>/dev/null)
  current_ts=$(printf '%s'  "$delta" | jq -r '.current_header.timestamp // ""' 2>/dev/null)
  hostname=$(printf '%s'    "$delta" | jq -r '.current_header.hostname // ""' 2>/dev/null)
  os_version=$(printf '%s'  "$delta" | jq -r '.current_header.os_version // ""' 2>/dev/null)
  sip=$(printf '%s'         "$delta" | jq -r '.current_header.sip_status // "unknown"' 2>/dev/null)
  ssv=$(printf '%s'         "$delta" | jq -r '.current_header.ssv_status // "unknown"' 2>/dev/null)

  local sip_disp ssv_disp
  sip_disp=$(_report_status_display "$sip")
  ssv_disp=$(_report_status_display "$ssv")

  elapsed=$(_report_format_elapsed "$baseline_ts")

  printf '%s\n' '═══════════════════════════════════════════════════════════'
  printf '%s\n' '  macaudit Δ REPORT'
  if [ -n "$elapsed" ]; then
    printf '  Baseline: %s (%s ago)\n' "$baseline_ts" "$elapsed"
  else
    printf '  Baseline: %s\n' "$baseline_ts"
  fi
  printf '  Current:  %s\n' "$current_ts"
  printf '  Host: %s | macOS %s | SIP: %s | SSV: %s\n' \
    "$hostname" "$os_version" "$sip_disp" "$ssv_disp"
  printf '%s\n' '═══════════════════════════════════════════════════════════'
}

# =============================================================================
# Section 3: Entry renderer
# =============================================================================
# `_report_render_entry` takes a category name and a single entry JSON
# object (as produced by audit.sh) and emits the rendered block on
# stdout. The block starts with a colored `  [SYM] LABEL path` line
# and is followed by four-space-indented detail lines specific to the
# category.
#
# Long values (> the truncation cap) are cut with an ellipsis so a
# single entry never wraps a terminal line. The truncation width is
# intentionally generous (~60 chars) so typical strings stay intact.

# Truncation cap for before/after change values. Chosen to leave room
# for the `      Δ <field>: ` prefix on an 80-column terminal.
_REPORT_TRUNC=60

# _report_truncate <text>
#   stdout: <text> as-is if shorter than _REPORT_TRUNC, otherwise the
#   first (_REPORT_TRUNC - 1) characters followed by `…`.
_report_truncate() {
  local s="$1"
  if [ ${#s} -le "$_REPORT_TRUNC" ]; then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:$((_REPORT_TRUNC - 1))}"
  fi
}

# _report_render_entry <category> <entry_json>
#   stdout: one rendered entry block, terminated by a trailing blank
#   line. The category-driven dispatch in the case statement keeps
#   per-category rendering cohesive without threading format flags.
_report_render_entry() {
  local category="$1"
  local entry="$2"

  local sym color reset
  sym=$(report_symbol "$category")
  color=$(report_color "$category")
  reset=$(utils_color reset)

  local path label
  case "$category" in
    added)
      path=$(printf '%s' "$entry" | jq -r '.path // ""' 2>/dev/null)
      label='ADDED'
      printf '  %s%s %s%s %s\n' "$color" "$sym" "$label" "$reset" "$path"
      # Dump each content key as `      <key>: <value>` — compact JSON
      # serialisation via `jq -r` keeps strings unquoted and objects/
      # arrays intact.
      printf '%s' "$entry" | jq -r '
        (.entry // {}) as $e
        | ($e.content // {})
        | to_entries[]
        | "      \(.key): \(.value | if type=="string" then . else tojson end)"
      ' 2>/dev/null
      ;;
    removed)
      path=$(printf '%s' "$entry" | jq -r '.path // ""' 2>/dev/null)
      label='REMOVED'
      printf '  %s%s %s%s %s\n' "$color" "$sym" "$label" "$reset" "$path"
      printf '%s' "$entry" | jq -r '
        (.entry // {}) as $e
        | ($e.content // {})
        | to_entries[]
        | "      \(.key): \(.value | if type=="string" then . else tojson end)"
      ' 2>/dev/null
      ;;
    modified)
      path=$(printf '%s' "$entry" | jq -r '.path // ""' 2>/dev/null)
      label='MODIFIED'
      printf '  %s%s %s%s %s\n' "$color" "$sym" "$label" "$reset" "$path"
      # Emit one `Δ field: before → after` per change. We render
      # before/after as compact JSON (strings stay bare, objects get
      # `tojson`ed), then truncate to _REPORT_TRUNC chars.
      local change_lines
      change_lines=$(printf '%s' "$entry" | jq -r '
        (.changes // [])[]
        | .field as $f
        | (.before | if type=="string" then . elif . == null then "null" else tojson end) as $b
        | (.after  | if type=="string" then . elif . == null then "null" else tojson end) as $a
        | "\($f)\t\($b)\t\($a)"
      ' 2>/dev/null)
      if [ -n "$change_lines" ]; then
        # Process line-by-line so bash can truncate each value in
        # isolation. The three TAB-separated fields are safe because
        # TAB is not a valid character inside a jq-compact string.
        local oldifs f b a b_tr a_tr
        oldifs="$IFS"
        while IFS=$'\t' read -r f b a; do
          [ -n "$f" ] || continue
          b_tr=$(_report_truncate "$b")
          a_tr=$(_report_truncate "$a")
          printf '      Δ %s: %s → %s\n' "$f" "$b_tr" "$a_tr"
        done <<EOF
$change_lines
EOF
        IFS="$oldifs"
      fi
      ;;
    injection)
      # Injection entries are reported by launchctl label, with no
      # disk path. The top line uses the "launchctl shows … — no
      # matching plist on disk" phrasing from design.md.
      label=$(printf '%s' "$entry" | jq -r '.label // ""' 2>/dev/null)
      local pid status
      pid=$(printf '%s' "$entry" | jq -r '.pid // "?"' 2>/dev/null)
      status=$(printf '%s' "$entry" | jq -r '.status // "?"' 2>/dev/null)
      printf '  %s%s INJECTION%s  launchctl shows "%s" — no matching plist on disk\n' \
        "$color" "$sym" "$reset" "$label"
      printf '      PID: %s | Status: %s\n' "$pid" "$status"
      ;;
    stale)
      path=$(printf '%s' "$entry" | jq -r '.path // ""' 2>/dev/null)
      label='STALE'
      printf '  %s%s %s%s %s\n' "$color" "$sym" "$label" "$reset" "$path"
      local disk_hash live_hash
      disk_hash=$(printf '%s' "$entry" | jq -r '.disk // ""' 2>/dev/null)
      live_hash=$(printf '%s' "$entry" | jq -r '.live // ""' 2>/dev/null)
      printf '      Disk hash: %s\n' "$disk_hash"
      printf '      Live hash: %s\n' "$live_hash"
      printf '%s\n' '      cfprefsd and disk disagree — investigate'
      ;;
    suspicious)
      # A suspicious entry carries the current manifest entry copy
      # with its `anomalies` array preserved (see 15G). Each anomaly
      # object yields its own rendered block so findings never pile
      # up behind a single path header and detail strings stay legible.
      path=$(printf '%s' "$entry" | jq -r '.path // ""' 2>/dev/null)
      label='SUSPICIOUS'
      # Stream one TAB-separated `rule<TAB>severity<TAB>detail` line
      # per anomaly. `detail` is free-form, so non-string values are
      # serialised via `tojson` before truncation. Literal tabs inside
      # string values would be escaped by jq as `\t`, so the TAB
      # delimiter is unambiguous here.
      local anom_lines
      anom_lines=$(printf '%s' "$entry" | jq -r '
        (.anomalies // [])[]
        | (.rule     // "")                                  as $r
        | (.severity // "")                                  as $s
        | (.detail | if type=="string" then . elif . == null then "" else tojson end) as $d
        | "\($r)\t\($s)\t\($d)"
      ' 2>/dev/null)
      if [ -n "$anom_lines" ]; then
        local oldifs rule sev detail detail_tr
        oldifs="$IFS"
        # One rendered block per anomaly: a colored header line
        # followed by three detail lines. A trailing blank line is
        # emitted by the shared tail at the bottom of this function
        # — so we output one blank line AFTER each inner block here
        # to separate successive anomalies that share the same path.
        local first=1
        while IFS=$'\t' read -r rule sev detail; do
          [ -n "$rule" ] || [ -n "$sev" ] || [ -n "$detail" ] || continue
          if [ "$first" -eq 0 ]; then
            printf '\n'
          fi
          first=0
          detail_tr=$(_report_truncate "$detail")
          printf '  %s%s %s%s %s%s%s\n' \
            "$color" "$sym" "$label" "$reset" "$color" "$path" "$reset"
          printf '      rule:     %s\n' "$rule"
          printf '      severity: %s\n' "$sev"
          printf '      detail:   %s\n' "$detail_tr"
        done <<EOF
$anom_lines
EOF
        IFS="$oldifs"
      fi
      ;;
    *)
      # Unknown categories fall through silently so the report does
      # not trap on unexpected input. All known arms above are
      # exhaustive against the current audit delta schema; a new
      # category must be added here explicitly before it will render.
      return 0
      ;;
  esac

  # Blank line after every rendered entry.
  printf '\n'
}

# =============================================================================
# Section 4: Tier renderer
# =============================================================================
# `_report_render_tier` prints the per-tier block: a `TIER N — NAME`
# header, one blank line, then every entry in the documented category
# order (added, injections, modified, stale, removed).

# _report_render_tier <delta_json> <tier_number> <tier_name>
_report_render_tier() {
  local delta="$1" tier="$2" name="$3"

  printf '  TIER %s — %s\n' "$tier" "$name"
  printf '\n'

  # jq emits one compact-JSON entry per line per category. Iteration
  # order (added, injections, modified, stale, removed) matches the
  # design example. The `[⚑] SUSPICIOUS` subsection follows the
  # category loop so all drift is reported before anomaly findings.
  local cat cat_key entries line
  for cat in added injections modified stale removed; do
    # Only `injections` needs a plural→singular mapping for the
    # `_report_render_entry` dispatcher; the rest already match.
    case "$cat" in
      injections) cat_key='injection' ;;
      *)          cat_key="$cat" ;;
    esac

    entries=$(printf '%s' "$delta" \
      | jq -c --arg tier "$tier" --arg cat "$cat" \
          '.tiers[$tier][$cat][]' 2>/dev/null)
    [ -n "$entries" ] || continue

    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _report_render_entry "$cat_key" "$line"
    done <<EOF
$entries
EOF
  done

  # Per-tier [⚑] SUSPICIOUS subsection. Only rendered when at least
  # one suspicious entry exists for this tier — otherwise the header
  # would dangle. For Tier 3, cross-surface correlation findings are
  # excluded here (they render in the top-level
  # [⚑] CROSS-SURFACE CORRELATION block emitted by
  # `_report_render_correlation`). We identify correlation entries
  # by `surface == "correlation"` on the preserved current-entry
  # object; as a fallback, any anomaly whose `rule` id begins with
  # `correlation:` also marks the entry as a correlation finding,
  # which keeps the filter robust against audit-side schema shifts.
  local susp
  if [ "$tier" = "3" ]; then
    susp=$(printf '%s' "$delta" \
      | jq -c --arg tier "$tier" '
          .tiers[$tier].suspicious // []
          | .[]
          | select(
              ((.surface // .entry.surface // "") != "correlation")
              and ((.anomalies // []) | map(.rule // "" | startswith("correlation:")) | any | not)
            )
        ' 2>/dev/null)
  else
    susp=$(printf '%s' "$delta" \
      | jq -c --arg tier "$tier" \
          '.tiers[$tier].suspicious // [] | .[]' 2>/dev/null)
  fi
  if [ -n "$susp" ]; then
    local susp_color susp_sym susp_reset
    susp_color=$(report_color suspicious)
    susp_sym=$(report_symbol suspicious)
    susp_reset=$(utils_color reset)
    printf '  %s%s SUSPICIOUS%s\n' "$susp_color" "$susp_sym" "$susp_reset"
    printf '\n'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      _report_render_entry suspicious "$line"
    done <<EOF
$susp
EOF
  fi
}

# _report_render_correlation <delta_json>
#   stdout: a top-level `[⚑] CROSS-SURFACE CORRELATION` block listing
#   every Tier 3 suspicious entry that represents a cross-surface
#   correlation finding. Nothing is printed when no correlation
#   entries exist so the report layout stays tight.
#
# Correlation entries are identified using the same filter as the
# per-Tier-3 suspicious subsection (see `_report_render_tier`): either
# the preserved current-entry's `surface` field equals `"correlation"`,
# or at least one anomaly carries a `rule` id beginning with
# `correlation:`. Each entry is rendered through the shared
# `suspicious` case in `_report_render_entry`.
_report_render_correlation() {
  local delta="$1"

  local corr
  corr=$(printf '%s' "$delta" | jq -c '
    .tiers["3"].suspicious // []
    | .[]
    | select(
        ((.surface // .entry.surface // "") == "correlation")
        or ((.anomalies // []) | map(.rule // "" | startswith("correlation:")) | any)
      )
  ' 2>/dev/null)
  [ -n "$corr" ] || return 0

  local corr_color corr_sym corr_reset line
  corr_color=$(report_color suspicious)
  corr_sym=$(report_symbol suspicious)
  corr_reset=$(utils_color reset)
  printf '  %s%s CROSS-SURFACE CORRELATION%s\n' \
    "$corr_color" "$corr_sym" "$corr_reset"
  printf '\n'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _report_render_entry suspicious "$line"
  done <<EOF
$corr
EOF
}

# =============================================================================
# Section 5: Summary renderer
# =============================================================================
# `_report_render_summary` prints the trailing summary block wrapped
# between a `─` ruler and the closing `═` ruler. Every category count
# is rendered unconditionally (even zero) so the layout stays stable
# between runs.

# _report_render_summary <delta_json>
_report_render_summary() {
  local delta="$1"
  local t1_added t1_removed t1_modified t1_injections t1_suspicious
  local t2_added t2_removed t2_modified t2_stale t2_suspicious
  local t3_added t3_removed t3_modified t3_suspicious
  local tot_added tot_removed tot_modified tot_stale tot_injections tot_suspicious

  t1_added=$(printf      '%s' "$delta" | jq -r '.summary.tier1.added      // 0' 2>/dev/null)
  t1_removed=$(printf    '%s' "$delta" | jq -r '.summary.tier1.removed    // 0' 2>/dev/null)
  t1_modified=$(printf   '%s' "$delta" | jq -r '.summary.tier1.modified   // 0' 2>/dev/null)
  t1_injections=$(printf '%s' "$delta" | jq -r '.summary.tier1.injections // 0' 2>/dev/null)
  t1_suspicious=$(printf '%s' "$delta" | jq -r '.summary.tier1.suspicious // 0' 2>/dev/null)

  t2_added=$(printf      '%s' "$delta" | jq -r '.summary.tier2.added      // 0' 2>/dev/null)
  t2_removed=$(printf    '%s' "$delta" | jq -r '.summary.tier2.removed    // 0' 2>/dev/null)
  t2_modified=$(printf   '%s' "$delta" | jq -r '.summary.tier2.modified   // 0' 2>/dev/null)
  t2_stale=$(printf      '%s' "$delta" | jq -r '.summary.tier2.stale      // 0' 2>/dev/null)
  t2_suspicious=$(printf '%s' "$delta" | jq -r '.summary.tier2.suspicious // 0' 2>/dev/null)

  t3_added=$(printf      '%s' "$delta" | jq -r '.summary.tier3.added      // 0' 2>/dev/null)
  t3_removed=$(printf    '%s' "$delta" | jq -r '.summary.tier3.removed    // 0' 2>/dev/null)
  t3_modified=$(printf   '%s' "$delta" | jq -r '.summary.tier3.modified   // 0' 2>/dev/null)
  t3_suspicious=$(printf '%s' "$delta" | jq -r '.summary.tier3.suspicious // 0' 2>/dev/null)

  tot_added=$(printf      '%s' "$delta" | jq -r '.summary.total.added      // 0' 2>/dev/null)
  tot_removed=$(printf    '%s' "$delta" | jq -r '.summary.total.removed    // 0' 2>/dev/null)
  tot_modified=$(printf   '%s' "$delta" | jq -r '.summary.total.modified   // 0' 2>/dev/null)
  tot_stale=$(printf      '%s' "$delta" | jq -r '.summary.total.stale      // 0' 2>/dev/null)
  tot_injections=$(printf '%s' "$delta" | jq -r '.summary.total.injections // 0' 2>/dev/null)
  tot_suspicious=$(printf '%s' "$delta" | jq -r '.summary.total.suspicious // 0' 2>/dev/null)

  printf '%s\n' '  ───────────────────────────────────────────────────────────'
  printf '%s\n' '  SUMMARY'
  printf '  Tier 1: %s added | %s removed | %s modified | %s injection | %s suspicious\n' \
    "$t1_added" "$t1_removed" "$t1_modified" "$t1_injections" "$t1_suspicious"
  printf '  Tier 2: %s added | %s removed | %s modified | %s stale | %s suspicious\n' \
    "$t2_added" "$t2_removed" "$t2_modified" "$t2_stale" "$t2_suspicious"
  printf '  Tier 3: %s added | %s removed | %s modified | %s suspicious\n' \
    "$t3_added" "$t3_removed" "$t3_modified" "$t3_suspicious"
  printf '  Total:  %s added | %s removed | %s modified | %s injection | %s stale | %s suspicious\n' \
    "$tot_added" "$tot_removed" "$tot_modified" "$tot_injections" "$tot_stale" "$tot_suspicious"
  printf '%s\n' '═══════════════════════════════════════════════════════════'
}

# =============================================================================
# Section 6: Public entry points
# =============================================================================
# `report_render_delta` is the one-and-only public function for delta
# rendering. It dispatches between human and json modes; human mode
# sequences the four private renderers above, json mode validates the
# input and echoes it compacted. `report_render_enumeration` wraps
# `enumerate_run` with a post-processor that promotes the tabular
# output to a JSON document for pipeline consumers.

# report_render_delta <delta_json> [mode]
#   mode defaults to `human`. Writes the rendered report to stdout.
#   Returns 0 on success; 1 when the input JSON does not parse (json
#   mode) or is unusable (human mode).
report_render_delta() {
  local delta="$1"
  local mode="${2:-human}"

  if [ -z "$delta" ]; then
    utils_log_err "report_render_delta: empty delta JSON"
    return 1
  fi
  # Validate once up-front — a malformed delta should fail loudly
  # rather than silently render an empty report.
  if ! printf '%s' "$delta" | jq -e . >/dev/null 2>&1; then
    utils_log_err "report_render_delta: delta JSON did not parse"
    return 1
  fi

  case "$mode" in
    json)
      # Emit compact JSON for pipelines. `jq -c .` normalises
      # whitespace but preserves keys and types.
      printf '%s' "$delta" | jq -c . || {
        utils_log_err "report_render_delta: jq failed to canonicalise delta"
        return 1
      }
      printf '\n'
      return 0
      ;;
    human|'')
      _report_render_header "$delta"
      printf '\n'
      _report_render_tier "$delta" 1 'PERSISTENCE'
      _report_render_tier "$delta" 2 'PREFERENCES'
      _report_render_tier "$delta" 3 'SECURITY DATABASES'
      _report_render_correlation "$delta"
      _report_render_summary "$delta"
      return 0
      ;;
    *)
      utils_log_err "report_render_delta: unknown mode '$mode' (expected human or json)"
      return 1
      ;;
  esac
}

# report_render_enumeration <mode>
#   mode ∈ {human, json}. Runs `enumerate_run` (no flags — i.e. --all)
#   and either emits its output verbatim (human) or post-processes it
#   into a JSON document (json).
#
# The JSON conversion is an awk-style parse of enumerate's tabular
# output. Teaching enumerate_run to emit JSON natively would be a
# cleaner long-term design, but that is a larger change to
# lib/enumerate.sh than task 13 permits, so we post-process here.
# Every label is mapped to a stable JSON key; counts become integers,
# and `--- (skipped: …)` lines become JSON nulls. Any line that does
# not match a known label is ignored.
report_render_enumeration() {
  local mode="${1:-human}"

  case "$mode" in
    human|'')
      enumerate_run
      return 0
      ;;
    json)
      local raw
      raw=$(enumerate_run 2>/dev/null)
      # Feed the raw tabular output through jq's raw-input mode. The
      # filter splits on the first `:`, trims whitespace, maps labels
      # to canonical keys, and classifies each value as either an
      # integer or null. Unknown labels are silently skipped so future
      # additions to enumerate_run do not break this filter.
      printf '%s' "$raw" | jq -Rsc '
        def trim: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
        def label_to_key($tier; $label):
          if $tier == 1 then
            {
              "LaunchAgents (user)":       "launch_agents_user",
              "LaunchAgents (system)":     "launch_agents_system",
              "LaunchDaemons":             "launch_daemons",
              "launchctl jobs (user)":     "launchctl_jobs_user",
              "launchctl jobs (system)":   "launchctl_jobs_system",
              "BTM records":               "btm_records",
              "cron entries":              "cron_entries",
              "periodic (non-Apple)":      "periodic_non_apple",
              "login hooks":               "login_hooks",
              "auth plugins (non-Apple)":  "auth_plugins_non_apple",
              "emond rules":               "emond_rules"
            }[$label] // null
          elif $tier == 2 then
            {
              "/Library/Preferences":          "library_preferences",
              "/Library/Managed Preferences":  "library_managed_preferences",
              "~/Library/Preferences":         "user_preferences"
            }[$label] // null
          else null end;
        def parse_value($s):
          if ($s | test("^---")) then null
          elif ($s | test("^[0-9]+$")) then ($s | tonumber)
          else null end;
        # Split raw input into lines; fold over them tracking the
        # current tier and accumulating {tier1:{}, tier2:{}}.
        split("\n") as $lines
        | reduce $lines[] as $line (
            {tier: 0, tier1: {}, tier2: {}};
            ($line | trim) as $t
            | if   ($t | test("^TIER 1")) then .tier = 1
              elif ($t | test("^TIER 2")) then .tier = 2
              elif ($t | contains(":")) then
                ($t | index(":")) as $i
                | ($t[0:$i] | trim) as $label
                | ($t[$i+1:] | trim) as $value
                | label_to_key(.tier; $label) as $k
                | if $k == null then .
                  else
                    if   .tier == 1 then .tier1[$k] = parse_value($value)
                    elif .tier == 2 then .tier2[$k] = parse_value($value)
                    else . end
                  end
              else . end
          )
        | del(.tier)
      '
      printf '\n'
      return 0
      ;;
    *)
      utils_log_err "report_render_enumeration: unknown mode '$mode' (expected human or json)"
      return 1
      ;;
  esac
}
