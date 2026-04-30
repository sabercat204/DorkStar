#!/bin/bash
# lib/persistence.sh — three-view correlation across on-disk plists,
# `launchctl list`, and `sfltool dumpbtm`. Produces launchctl_loaded and
# btm_registered flags and detects in-memory-only persistence injections.
#
# Three views, three signals:
#   1. On-disk       — a plist with a given Label exists under a Tier 1
#                      surface.
#   2. launchctl     — the Label is loaded (or at least registered) in
#                      `launchctl list`. Covers both user and root scope.
#   3. BTM (≥ 13)    — the Label appears in `sfltool dumpbtm`'s Background
#                      Task Management database.
#
# Full agreement across all three = normal. Disagreements flag tampering:
#   • launchctl ∧ ¬on_disk            → injection (in-memory-only persistence)
#   • on_disk ∧ ¬launchctl            → staged (disabled or queued)
#   • on_disk ∧ launchctl ∧ ¬BTM      → potential BTM evasion (macOS 13+)
#
# All functions are side-effect free apart from the collectors, which
# fork `launchctl` / `sfltool`. Every collector SUCCEEDS SILENTLY (empty
# output, exit 0) when the underlying tool is unavailable, the macOS
# version is too old for the view, or the caller lacks sudo. The caller
# — typically lib/baseline.sh — is the layer that decides whether to
# record a `skipped_paths` entry for the missing view.
#
# Bash 3.2 compatibility: no associative arrays, no `mapfile`/`readarray`,
# no `<<<` here-strings. Set operations are implemented via
# `sort -u | comm -23`, feeding the sorted streams through the
# `<(...)` process-substitution form (which bash 3.2 supports via
# /dev/fd).

# =============================================================================
# Section 1: Snapshot collectors
# =============================================================================
# Each collector forks the underlying command exactly once and emits a
# structured representation of its output on stdout. Collectors are
# designed to be called once per baseline run; their output is cached to
# a scratch file and the path threaded through `persistence_correlate`
# for each label the baseline encounters.
#
# The TSV schema for launchctl is deliberately minimal — `label`, `pid`,
# `status` — because those are the only fields baseline.sh consumes. A
# job's PID column in `launchctl list` is a hyphen when the job is
# registered but not running; we normalise that to `0` so the TSV schema
# is uniform and every row parses as `<string>\t<int>\t<int>` without a
# special-case check for hyphens. The Status column undergoes the same
# normalisation.
#
# The BTM collector emits JSONL (one record per Background Task
# Management entry) rather than TSV because BTM entries carry several
# free-text fields (Developer Name, URL, Disposition) that may contain
# whitespace or tabs — JSON encodes them unambiguously where TSV would
# need ad-hoc escaping.

# persistence_collect_launchctl_user
#   stdout: TSV lines of the form `<label>\t<pid>\t<status>`, one per
#           loaded job. The header row (`PID\tStatus\tLabel`) is
#           filtered out. `-` in the PID or Status columns is
#           normalised to `0`. Empty output is valid and means
#           `launchctl list` produced no data (or the binary is
#           missing).
#   exit:   always 0.
persistence_collect_launchctl_user() {
  # `launchctl list` output columns are "PID", "Status", "Label",
  # separated by whitespace. The first row is a header. Using awk lets
  # us filter the header, normalise hyphens, and emit TSV in one pass
  # without reopening the stream.
  launchctl list 2>/dev/null | awk '
    NR == 1 && $1 == "PID" && $2 == "Status" && $3 == "Label" { next }
    NF >= 3 {
      pid = $1
      status = $2
      # The label is the remainder of the line from column 3 onward,
      # preserving any embedded whitespace (launchctl itself never
      # emits whitespace in a Label, but we are defensive).
      label = $3
      for (i = 4; i <= NF; i++) label = label " " $i
      if (pid == "-")    pid = "0"
      if (status == "-") status = "0"
      printf "%s\t%s\t%s\n", label, pid, status
    }
  '
  return 0
}

# persistence_collect_launchctl_system
#   stdout: TSV lines in the same schema as persistence_collect_launchctl_user.
#           Emits empty output when the caller is not root (we never
#           prompt for sudo — the caller is expected to re-invoke
#           macaudit under sudo when the system scope is required).
#   exit:   always 0.
persistence_collect_launchctl_system() {
  if ! utils_has_sudo; then
    return 0
  fi
  # Even when we are root we still go through `sudo launchctl list` so
  # the call path is identical under `sudo ./macaudit.sh` and under a
  # genuine root shell. When euid is already 0, sudo is a no-op.
  sudo launchctl list 2>/dev/null | awk '
    NR == 1 && $1 == "PID" && $2 == "Status" && $3 == "Label" { next }
    NF >= 3 {
      pid = $1
      status = $2
      label = $3
      for (i = 4; i <= NF; i++) label = label " " $i
      if (pid == "-")    pid = "0"
      if (status == "-") status = "0"
      printf "%s\t%s\t%s\n", label, pid, status
    }
  '
  return 0
}

# persistence_collect_btm
#   stdout: JSONL, one record per BTM entry:
#             {"label": "...", "type": "...", "developer": "...",
#              "team_identifier": "...", "parent": "...", "url": "...",
#              "disposition": "..."}
#           Empty output when any of the gating conditions fails:
#             • macOS major version < 13 (BTM did not exist)
#             • caller is not root (sfltool dumpbtm needs sudo)
#             • sfltool binary is absent
#             • sfltool dumpbtm exits non-zero
#   exit:   always 0.
#
# Parsing strategy: `sfltool dumpbtm` emits plain-text blocks separated
# by blank lines. Within a block, each field is a single line of the
# form `<Key>: <Value>`. We accumulate field values into awk state
# across lines of a block, and emit one JSON record per block. Unknown
# keys are ignored — we only extract the fields macaudit's three-view
# correlation actually needs.
#
# Rationale for forking `jq` per-record instead of building a jq
# streaming filter: BTM outputs are bounded (typically a few dozen to a
# few hundred records on a healthy system), each record has ~7 fields,
# and jq `-n --arg` composition gives us correct JSON escaping for free.
# Building a streaming parser would add maintenance burden without a
# measurable runtime benefit.
persistence_collect_btm() {
  # Gate on macOS version: BTM was added in macOS 13 (Ventura). Older
  # releases have no such database and sfltool does not know the
  # `dumpbtm` subcommand.
  local os_major
  os_major=$(utils_os_major)
  if [ -z "$os_major" ] || [ "$os_major" -lt 13 ] 2>/dev/null; then
    return 0
  fi

  # Gate on sudo. sfltool dumpbtm requires root privileges; a non-root
  # invocation would emit an error to stderr and a misleading exit
  # code. We short-circuit before forking.
  if ! utils_has_sudo; then
    return 0
  fi

  # Gate on command availability. On systems where sfltool is missing
  # or masked by an incomplete Command Line Tools install we return
  # empty rather than aborting.
  if ! command -v sfltool >/dev/null 2>&1; then
    return 0
  fi

  local raw
  raw=$(sudo sfltool dumpbtm 2>/dev/null) || return 0
  if [ -z "$raw" ]; then
    return 0
  fi

  # Walk the text output block-by-block, extracting the six fields we
  # care about plus the Identifier (which is what macaudit calls the
  # Label for BTM records). Each block ends at a blank line or EOF; at
  # that point we emit the accumulated record via jq and reset.
  #
  # The awk program below forks jq once per record via a pipe opened on
  # demand. Bash 3.2-compatible awks (BSD awk on macOS, plus gawk)
  # support the pipe-to-command syntax we use here.
  printf '%s\n' "$raw" | awk '
    function emit(   cmd) {
      if (have_record == 0) return
      cmd = "jq -cn --arg label \"" label "\"" \
            " --arg type \"" type "\"" \
            " --arg developer \"" developer "\"" \
            " --arg team_identifier \"" team_identifier "\"" \
            " --arg parent \"" parent "\"" \
            " --arg url \"" url "\"" \
            " --arg disposition \"" disposition "\"" \
            " '"'"'{label:$label,type:$type,developer:$developer,team_identifier:$team_identifier,parent:$parent,url:$url,disposition:$disposition}'"'"'"
      system(cmd)
      # Reset state for the next block.
      label = ""; type = ""; developer = ""; team_identifier = ""
      parent = ""; url = ""; disposition = ""
      have_record = 0
    }

    function esc(s) {
      # Escape backslashes and double-quotes for safe inclusion in the
      # --arg payload we hand jq. jq itself rewraps each value as a
      # JSON string, but the intermediate shell-level quoting still
      # needs these two characters escaped.
      gsub(/\\/, "\\\\", s)
      gsub(/"/,  "\\\"",  s)
      return s
    }

    # Blank line terminates a block.
    /^[[:space:]]*$/ { emit(); next }

    # Otherwise parse a `Key: Value` line. We match on a fixed set of
    # keys; anything else is ignored.
    {
      # Split on the first colon-space pair.
      idx = index($0, ": ")
      if (idx == 0) next
      key = substr($0, 1, idx - 1)
      # Strip leading whitespace from the key so indented sub-fields
      # still key correctly.
      sub(/^[[:space:]]+/, "", key)
      val = substr($0, idx + 2)
      # Strip trailing whitespace.
      sub(/[[:space:]]+$/, "", val)

      if (key == "Identifier") { label = esc(val); have_record = 1 }
      else if (key == "Type") { type = esc(val); have_record = 1 }
      else if (key == "Developer Name") { developer = esc(val); have_record = 1 }
      else if (key == "Team Identifier") { team_identifier = esc(val); have_record = 1 }
      else if (key == "Parent Identifier") { parent = esc(val); have_record = 1 }
      else if (key == "URL") { url = esc(val); have_record = 1 }
      else if (key == "Disposition") { disposition = esc(val); have_record = 1 }
    }

    END { emit() }
  '
  return 0
}

# =============================================================================
# Section 2: Label extraction and correlation
# =============================================================================
# `persistence_extract_label` pulls the `Label` field out of a launchd
# plist. It is a thin wrapper over `plutil -extract` so the error
# handling stays in one place: any plutil failure (missing key, invalid
# plist, unreadable file) collapses to empty output, which is what
# baseline.sh already treats as "no label for this plist".
#
# `persistence_correlate` is the point-query form of the three-view
# correlation algorithm: for one label, look it up in the cached
# launchctl TSV and BTM JSONL files and emit a one-line JSON object.
# The BTM view gracefully becomes `null` when the BTM file is empty
# or absent (macOS < 13, or no sudo for the BTM collector to run).

# persistence_extract_label <plist_path>
#   stdout: the Label field from the plist, or empty string when the
#           key is absent, the file is unreadable, or plutil rejects
#           the file.
#   exit:   always 0.
persistence_extract_label() {
  local path="$1"
  if [ -z "$path" ] || [ ! -r "$path" ]; then
    return 0
  fi
  # `plutil -extract Label raw -o - --` prints the raw string value of
  # the `Label` key to stdout. Any failure (missing key, malformed
  # plist) exits non-zero and emits on stderr — we swallow both.
  plutil -extract Label raw -o - -- "$path" 2>/dev/null || return 0
}

# persistence_correlate <label> <launchctl_tsv_file> <btm_jsonl_file>
#   stdout: one-line JSON object of the form
#             {"launchctl_loaded": true|false, "btm_registered": true|false|null}
#   exit:   always 0.
#
# Inputs:
#   • launchctl_tsv_file — path to a TSV file produced by
#     persistence_collect_launchctl_user + persistence_collect_launchctl_system
#     (both streams concatenated by the caller, or either alone).
#     Each row's first column is the label.
#   • btm_jsonl_file — path to a JSONL file produced by
#     persistence_collect_btm. Each record has a `.label` field.
#
# btm_registered is `null` (rendered as JSON null) in two cases:
#   • The btm_jsonl_file does not exist.
#   • The btm_jsonl_file exists but is empty (the collector returned
#     empty on macOS < 13, or the caller lacked sudo).
# Callers that want a boolean `false` (e.g. "BTM was collected but this
# label was not in it") should write a sentinel record to the BTM file
# — the current design does not need that distinction because baseline
# only emits the field as `null` when BTM was not collected at all.
persistence_correlate() {
  local label="$1"
  local launchctl_tsv="$2"
  local btm_jsonl="$3"

  # -- launchctl membership ---------------------------------------------------
  local launchctl_loaded="false"
  if [ -n "$label" ] && [ -n "$launchctl_tsv" ] && [ -r "$launchctl_tsv" ]; then
    # Compare the label against the first tab-separated field. Using
    # awk with an exact equality test avoids false positives a
    # `grep -F` would produce on labels that are prefixes of other
    # labels (e.g. `com.apple.foo` matching `com.apple.foobar`).
    if awk -v L="$label" -F '\t' '$1 == L { found = 1; exit } END { exit !found }' "$launchctl_tsv"; then
      launchctl_loaded="true"
    fi
  fi

  # -- BTM membership ---------------------------------------------------------
  # btm_registered is tri-state: true, false, or null. Null when the
  # BTM view was not collected for this run.
  local btm_registered_raw="null"
  if [ -n "$btm_jsonl" ] && [ -r "$btm_jsonl" ] && [ -s "$btm_jsonl" ]; then
    if [ -n "$label" ] && jq -e --arg L "$label" -c '. | select(.label == $L)' "$btm_jsonl" >/dev/null 2>&1; then
      btm_registered_raw="true"
    else
      btm_registered_raw="false"
    fi
  fi

  # Compose the result via jq -n so the boolean / null distinction is
  # preserved correctly in the output. Passing the raw token through
  # `--argjson` lets us hand jq a literal JSON value rather than a
  # string.
  jq -cn \
    --argjson loaded "$launchctl_loaded" \
    --argjson btm "$btm_registered_raw" \
    '{launchctl_loaded: $loaded, btm_registered: $btm}'
}

# =============================================================================
# Section 3: Injection detection via set difference
# =============================================================================
# Injection = a Label that `launchctl list` reports but that no on-disk
# plist under the Tier 1 surfaces carries. In classical tamper terms,
# injection means the job is live in memory with no persistence footprint
# — either launchctl was populated directly (via `launchctl submit` or a
# crafted bootstrap) or the plist was deleted after the job loaded.
#
# The algorithm is a pure set difference. We implement it via
# `comm -23 <(sort -u launchctl) <(sort -u on_disk)` so no associative
# arrays are needed and the computation is O(n log n) on stable sort.
# Both sides are first passed through `sort -u` which handles empty
# inputs and de-duplication in one step.
#
# The callers never pass raw TSV in — by the time this function is
# invoked, baseline.sh has extracted the first column into a
# label-per-line scratch file (via `awk -F '\t' '{print $1}'`).

# persistence_detect_injections <on_disk_labels_file> <launchctl_labels_file>
#   stdout: sorted, unique list of labels present in the launchctl file
#           but absent from the on-disk file. One label per line.
#           Always disjoint from the contents of on_disk_labels_file.
#   exit:   always 0.
persistence_detect_injections() {
  local on_disk="$1"
  local launchctl="$2"

  # Defensive: if either file does not exist, fall back to /dev/null so
  # sort still produces an empty stream and comm still operates over
  # two valid arguments. Emitting nothing is the correct answer when
  # the launchctl view is missing entirely (no labels in launchctl ⇒
  # no injections), and likewise empty launchctl vs populated on_disk
  # yields empty.
  if [ -z "$on_disk" ] || [ ! -r "$on_disk" ]; then
    on_disk="/dev/null"
  fi
  if [ -z "$launchctl" ] || [ ! -r "$launchctl" ]; then
    launchctl="/dev/null"
  fi

  # `comm -23 A B` emits the lines in A not in B, when both A and B are
  # sorted and unique. Process substitution (`<(...)`) is bash 3.2
  # compatible on macOS via /dev/fd.
  #
  # We filter empty lines out of both sides first — a real label is
  # non-empty, and an empty line would cause comm to treat it as a
  # common element on both sides and thereby leak into neither output.
  # The simpler `sort -u | sed '/^$/d'` chain keeps the pipeline
  # transparent.
  comm -23 \
    <(sort -u -- "$launchctl" | sed '/^$/d') \
    <(sort -u -- "$on_disk"   | sed '/^$/d')
  return 0
}
