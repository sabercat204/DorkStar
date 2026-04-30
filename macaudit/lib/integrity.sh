#!/bin/bash
# lib/integrity.sh — integrity re-hash loop. Re-hashes every file referenced
# in a baseline and classifies each as PASS / FAIL / MISSING / NEW, reporting
# which hash channel (raw vs canonical) changed.
#
# Phase 1 Task 11 covered Tier 1 + Tier 2 plist re-hashing with
# raw/canonical channels. Task 15J extends this same module with Tier 3
# hash channels per surface:
#   - SQLite surfaces (tcc_system, tcc_user, kextpolicy, execpolicy,
#     systempolicy, quarantine_events): compare `sha256_checkpointed`
#     and every per-table `content_hash` from baseline against a fresh
#     re-capture of the same surface.
#   - `authdb`: compare `sha256_canonical` (authdb entries are JSON
#     blobs from `security authorizationdb read`, not SQLite).
#   - `xprotect`: compare every per-file `sha256_raw` in the baseline's
#     `files` map plus the `codesign.valid` field.
#   - `correlation`: synthesised entries; skipped both in re-hash and
#     in NEW-detection because they are not stable artefacts.
#
# Public entry point:
#   integrity_run <baseline_path>
#
# Exit codes:
#   0   — every entry PASSed (no FAIL, no MISSING, no NEW).
#   1   — any FAIL / MISSING / NEW entry present.
#   2   — unrecoverable error before the check ran (bad flag, missing
#         baseline, unsupported manifest version, re-capture failure).
#   130 — SIGINT (inherited from utils_tmpdir_init's EXIT/INT trap).
#
# Invariants enforced here:
#
#   1. The re-capture NEVER writes to the user's manifests/ directory.
#      All scratch lives under ${MACAUDIT_TMPDIR}/current.jsonl and is
#      cleaned up by the EXIT trap utils_tmpdir_init installs. SIGINT
#      leaves no partial manifest behind.
#
#   2. Re-capture uses the same `tier` and `user_only` flags the baseline
#      header records, so the NEW-detection set is apples-to-apples.
#
#   3. Classification output is deterministic: within a run, the PASS
#      block is emitted first (sorted by path), then FAIL, then MISSING,
#      then NEW. This makes two runs against identical state produce
#      byte-identical stdout (Property P11 applied to integrity).
#
#   4. Baseline entries with `.surface == "injection"` are skipped — they
#      describe in-memory launchctl state, not an on-disk artefact, and
#      re-hashing a `launchctl://<label>` pseudo-path is meaningless.
#
#   5. Baseline entries with `.surface == "correlation"` are skipped —
#      these are synthesised by `baseline_correlate` from Tier 1 + Tier 3
#      data rather than hashed from disk, and the underlying surfaces
#      are already re-captured. Correlation paths are also excluded
#      from the NEW-detection diff because they are not stable across
#      runs (ordering of anomaly rows, changes in environment probes
#      etc. can shift the correlation set without any real drift).
#
#   6. Re-hashing uses the SAME pipeline baseline.sh uses:
#        utils_sha256_file            for sha256_raw
#        utils_plist_to_canonical_json | utils_sha256_stdin
#                                     for sha256_canonical (Tier 1/2)
#        sqlite_safe_copy + sqlite_checkpointed_hash
#                                     for sha256_checkpointed (Tier 3)
#        sqlite_snapshot_table        for per-table content_hash (Tier 3)
#      so a PASS result is genuinely byte-identical in every channel.
#
# bash 3.2 compatible. No `set -euo pipefail`. `echo` is banned.

# integrity_run <baseline_path>
integrity_run() {
  local baseline_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift 1
        if [ -n "${1:-}" ] && [ -z "$baseline_path" ]; then
          baseline_path="$1"; shift 1
        fi
        ;;
      -*)
        utils_log_err "integrity_run: unknown flag '$1'"
        return 2
        ;;
      *)
        if [ -z "$baseline_path" ]; then
          baseline_path="$1"
        else
          utils_log_err "integrity_run: unexpected positional argument '$1'"
          return 2
        fi
        shift 1
        ;;
    esac
  done

  if [ -z "$baseline_path" ]; then
    utils_log_err "integrity_run: baseline path is required"
    return 2
  fi

  # Requirement 18.1 — baseline file must exist. The error format here
  # is intentionally identical to audit_run's so downstream tooling that
  # greps stderr sees one stable message across subcommands.
  if [ ! -f "$baseline_path" ]; then
    utils_log_err "baseline not found: ${baseline_path}"
    return 2
  fi

  # Requirement 18.2 — manifest_version must be 1.0 or 1.1. manifest_header_value
  # emits a JSON-encoded scalar (quoted strings), so we unwrap via `jq -r`
  # before comparing. An empty header field still trips the default branch
  # because the empty string is not a supported version.
  local version_raw version
  version_raw=$(manifest_header_value "$baseline_path" manifest_version)
  version=$(printf '%s' "$version_raw" | jq -r '.' 2>/dev/null)
  case "$version" in
    1.0|1.1) : ;;
    *)
      utils_log_err "baseline version ${version} not supported by this tool (expected 1.0 or 1.1)"
      return 2
      ;;
  esac

  # Scratch tmpdir. The EXIT / INT trap installed here is what delivers
  # the "SIGINT exits 130 and leaves no partial output" invariant for
  # the current.jsonl scratch file.
  if ! utils_tmpdir_init >/dev/null; then
    utils_log_err "integrity_run: unable to initialise scratch tmpdir"
    return 2
  fi

  # Pull tier + user_only from the baseline header so the re-capture
  # matches the original scope. Without this, a `--tier 1` baseline
  # re-captured under the default `all` would report every Tier 2 path
  # as NEW on a clean system.
  local tier_raw tier user_only_raw user_only
  tier_raw=$(manifest_header_value "$baseline_path" tier)
  tier=$(printf '%s' "$tier_raw" | jq -r '.' 2>/dev/null)
  if [ -z "$tier" ]; then
    utils_log_err "integrity_run: baseline header missing 'tier'"
    return 2
  fi
  user_only_raw=$(manifest_header_value "$baseline_path" user_only)
  user_only=$(printf '%s' "$user_only_raw" | jq -r '.' 2>/dev/null)
  case "$user_only" in
    true|false) : ;;
    *)
      utils_log_err "integrity_run: baseline header 'user_only' is not a boolean"
      return 2
      ;;
  esac

  # Scratch output files. These live under MACAUDIT_TMPDIR so cleanup is
  # handled automatically on normal exit and SIGINT.
  local current_path="${MACAUDIT_TMPDIR}/current.jsonl"
  local pass_file="${MACAUDIT_TMPDIR}/integrity.pass.txt"
  local fail_file="${MACAUDIT_TMPDIR}/integrity.fail.txt"
  local missing_file="${MACAUDIT_TMPDIR}/integrity.missing.txt"
  local skip_file="${MACAUDIT_TMPDIR}/integrity.skip.txt"
  local new_file="${MACAUDIT_TMPDIR}/integrity.new.txt"
  local baseline_paths_file="${MACAUDIT_TMPDIR}/integrity.baseline_paths.txt"
  local current_skipped_file="${MACAUDIT_TMPDIR}/integrity.current_skipped.txt"

  # Start empty — a previous invocation inside the same shell must not
  # leak state into this one.
  : > "$current_path"
  : > "$pass_file"
  : > "$fail_file"
  : > "$missing_file"
  : > "$skip_file"
  : > "$new_file"
  : > "$baseline_paths_file"
  : > "$current_skipped_file"

  # ---------------------------------------------------------------------
  # Phase 1 — re-capture current state.
  # ---------------------------------------------------------------------
  #
  # We invoke baseline_run with the baseline's tier + user_only flags so
  # the current manifest covers exactly the same surfaces the baseline
  # did. The re-capture MUST run before classification because Tier 3
  # entries need the matching current entry looked up by path
  # (`manifest_entry_by_path`) to compare `sha256_checkpointed` +
  # per-table `content_hash`. Tier 1/2 plist re-hashing does not need
  # the re-capture for classification — it re-hashes the on-disk file
  # directly — but it still needs the current manifest for NEW detection.
  local recapture_args=( --output "$current_path" --tier "$tier" )
  if [ "$user_only" = "true" ]; then
    recapture_args+=( --user-only )
  fi
  if ! baseline_run "${recapture_args[@]}" >/dev/null; then
    utils_log_err "integrity_run: re-capture failed"
    return 2
  fi
  if [ ! -f "$current_path" ]; then
    utils_log_err "integrity_run: re-capture produced no manifest at '$current_path'"
    return 2
  fi

  # Extract paths from the current manifest's header.skipped_paths so
  # Tier 3 classification can distinguish between `[skip]` (the surface
  # could not be re-captured — FDA lost, sudo lost, DB became
  # unreadable) and `MISSING` (the path was re-captured successfully
  # but the underlying file has genuinely gone away). A `[skip]` is
  # informational — the integrity check could not be performed, so
  # classifying as FAIL or MISSING would misrepresent the truth.
  # One path per line, empty file when skipped_paths is absent or
  # empty. `manifest_header_value` emits a JSON-encoded array; we
  # unwrap via `jq -r '.[].path'`.
  local skipped_raw
  skipped_raw=$(manifest_header_value "$current_path" skipped_paths)
  if [ -n "$skipped_raw" ]; then
    printf '%s' "$skipped_raw" \
      | jq -r '.[] | .path // empty' 2>/dev/null \
      > "$current_skipped_file" || :
  fi

  # ---------------------------------------------------------------------
  # Phase 2 — classify every baseline entry.
  # ---------------------------------------------------------------------
  #
  # We stream the baseline via `manifest_entries` (a `tail -n +2` pipe)
  # and pipe the stream through a `while read` loop so memory stays
  # bounded regardless of manifest size. Per-entry, `jq -r` extracts
  # the fields we need as a tab-separated tuple so bash's IFS= read can
  # parse them without a second jq fork.

  # Collect baseline entry paths as we go so the NEW-detection phase
  # can diff against the current manifest without re-reading the baseline.
  # Injection pseudo-paths (launchctl://<label>) never appear in a
  # current-state manifest and so never trigger NEW; correlation paths
  # are omitted entirely from the diff pool (see phase 3 below).
  while IFS= read -r entry_line; do
    [ -n "$entry_line" ] || continue

    # One jq pass per entry. Emits: path \t tier \t surface \t sha_raw \t sha_canon
    # Missing fields fall back to empty strings / 0 so the `read` below
    # never splits on trailing unset columns.
    local fields path tier_s surface sha_raw_b sha_canon_b
    fields=$(printf '%s' "$entry_line" | jq -r '
      [
        (.path             // ""),
        ((.tier            // 0) | tostring),
        (.surface          // ""),
        (.sha256_raw       // ""),
        (.sha256_canonical // "")
      ] | @tsv
    ' 2>/dev/null)
    [ -n "$fields" ] || continue

    IFS=$'\t' read -r path tier_s surface sha_raw_b sha_canon_b <<EOF
${fields}
EOF
    [ -n "$path" ] || continue

    # Record every baseline path (except correlation) for NEW-detection.
    # Correlation paths are synthesised per-run and vary across captures
    # without real drift, so the diff treats them as absent in both
    # manifests.
    if [ "$surface" != "correlation" ]; then
      printf '%s\n' "$path" >> "$baseline_paths_file"
    fi

    # Skip injection entries — they describe live launchctl state, not
    # an on-disk artefact, and the path field is a launchctl://<label>
    # pseudo-path.
    if [ "$surface" = "injection" ]; then
      continue
    fi

    # Skip correlation entries — synthesised by baseline_correlate, not
    # hashed from disk. The underlying surfaces (Tier 1 launch plists +
    # Tier 3 security databases) are re-captured directly in their own
    # entries, so a drift in the correlated state surfaces there.
    if [ "$surface" = "correlation" ]; then
      continue
    fi

    # Tier 3 entries dispatch on surface. The helper appends exactly
    # one line to one of the scratch files (PASS / FAIL / MISSING /
    # SKIP) and returns 0. We never let a Tier 3 dispatch failure
    # short-circuit the outer loop — every entry must classify so the
    # totals line up.
    if [ "$tier_s" = "3" ]; then
      _integrity_classify_tier3 \
        "$entry_line" "$path" "$surface" \
        "$current_path" "$current_skipped_file" \
        "$pass_file" "$fail_file" "$missing_file" "$skip_file" || true
      continue
    fi

    # Tier 1/2 — MISSING when the baselined path no longer exists. `-e`
    # is the right primitive here: a symlink to a deleted target should
    # also classify as MISSING (the re-hash cannot produce a real
    # value), and directories are never baselined so the type check is
    # unnecessary.
    if [ ! -e "$path" ]; then
      printf '%s\n' "$path" >> "$missing_file"
      continue
    fi

    # PASS / FAIL — re-hash both channels and compare field-by-field.
    local sha_raw_now sha_canon_now
    sha_raw_now=$(utils_sha256_file "$path")
    sha_canon_now=$(utils_plist_to_canonical_json "$path" | utils_sha256_stdin)

    if [ "$sha_raw_now" = "$sha_raw_b" ] && [ "$sha_canon_now" = "$sha_canon_b" ]; then
      printf '%s\n' "$path" >> "$pass_file"
      continue
    fi

    # FAIL — report EXACTLY the channels that changed. Both channels can
    # legitimately differ (semantic content drift) or only raw (a binary
    # plist re-saved as XML with identical content) or only canonical
    # (an unlikely but possible jq canonicalisation edge case).
    local channels=""
    if [ "$sha_raw_now" != "$sha_raw_b" ]; then
      channels="raw"
    fi
    if [ "$sha_canon_now" != "$sha_canon_b" ]; then
      if [ -n "$channels" ]; then
        channels="${channels},canonical"
      else
        channels="canonical"
      fi
    fi
    # Store as "channels<TAB>path" so the sort+emit phase can recover the
    # two halves without re-computing the diff.
    printf 'FAIL[%s]\t%s\n' "$channels" "$path" >> "$fail_file"
  done < <(manifest_entries "$baseline_path")

  # ---------------------------------------------------------------------
  # Phase 3 — detect NEW paths.
  # ---------------------------------------------------------------------
  #
  # Any path in the current manifest that is not in baseline_paths_file
  # is classified NEW. We drive the diff through sort + comm which is
  # O((N+M) log N) and stays streaming-friendly. We deliberately sort
  # into per-phase scratch files rather than attempting `comm <(...)`
  # process substitution, which is bash-4+ only and would break 3.2
  # compatibility.
  #
  # Correlation entries are excluded on both sides: the current manifest
  # stream filters them out, and the baseline_paths_file already omitted
  # them in phase 2. Correlation row counts depend on environment probes
  # (MDM state, plugin directory listings, etc.) that can flip between
  # runs without any real drift, so treating them as stable NEW/MISSING
  # candidates would produce spurious drift reports.
  local current_paths_file="${MACAUDIT_TMPDIR}/integrity.current_paths.txt"
  local baseline_paths_sorted="${MACAUDIT_TMPDIR}/integrity.baseline_paths.sorted.txt"
  local current_paths_sorted="${MACAUDIT_TMPDIR}/integrity.current_paths.sorted.txt"

  manifest_entries "$current_path" \
    | jq -r 'select(.surface != "correlation") | (.path // empty)' 2>/dev/null \
    > "$current_paths_file"

  LC_ALL=C sort -u -- "$baseline_paths_file" > "$baseline_paths_sorted" 2>/dev/null || :
  LC_ALL=C sort -u -- "$current_paths_file"  > "$current_paths_sorted"  2>/dev/null || :

  # comm -23 A B — lines only in A. Present in current but not baseline → NEW.
  LC_ALL=C comm -23 "$current_paths_sorted" "$baseline_paths_sorted" > "$new_file" 2>/dev/null || :

  # ---------------------------------------------------------------------
  # Phase 4 — emit classification lines + summary.
  # ---------------------------------------------------------------------
  #
  # Output ordering (documented in the banner, Invariant 3):
  #   PASS rows first   (sorted by path)
  #   FAIL rows next    (sorted by path)
  #   SKIP rows next    (sorted by path)
  #   MISSING rows next (sorted by path)
  #   NEW rows last     (sorted by path)
  #
  # Each row is printed with a fixed-width classification column so the
  # output is easy to eyeball in a terminal. We use `printf` rather than
  # `column` or `awk`-based alignment to keep the dependency surface
  # minimal and the output byte-stable.
  #
  # The column width (32) fits every Tier 1/2 label (longest is
  # `FAIL[raw,canonical]` at 19) and the Tier 3 FAIL channel labels
  # which carry table names and per-file relative paths. The channel
  # list itself is unbounded in principle (an XProtect bundle could
  # mutate many files) — on overflow the label simply runs past the
  # column and the path shifts right, which is acceptable since these
  # cases are already visibly anomalous.

  local p_count f_count m_count s_count n_count
  p_count=$(_integrity_count_lines "$pass_file")
  f_count=$(_integrity_count_lines "$fail_file")
  m_count=$(_integrity_count_lines "$missing_file")
  s_count=$(_integrity_count_lines "$skip_file")
  n_count=$(_integrity_count_lines "$new_file")

  # PASS block.
  if [ "$p_count" -gt 0 ]; then
    LC_ALL=C sort -- "$pass_file" 2>/dev/null \
      | while IFS= read -r p; do
          [ -n "$p" ] || continue
          printf '%-32s %s\n' "PASS" "$p"
        done
  fi

  # FAIL block — sort by path (column 2) so the user sees them in the
  # same order as PASS rows. Column 1 already carries the channel list.
  if [ "$f_count" -gt 0 ]; then
    LC_ALL=C sort -t $'\t' -k2,2 -- "$fail_file" 2>/dev/null \
      | while IFS=$'\t' read -r label p; do
          [ -n "$p" ] || continue
          printf '%-32s %s\n' "$label" "$p"
        done
  fi

  # SKIP block. Informational — the integrity check could not be
  # performed (FDA or sudo lost between runs, etc.). Does NOT
  # contribute to a non-zero exit code.
  if [ "$s_count" -gt 0 ]; then
    LC_ALL=C sort -- "$skip_file" 2>/dev/null \
      | while IFS= read -r p; do
          [ -n "$p" ] || continue
          printf '%-32s %s\n' "[skip]" "$p"
        done
  fi

  # MISSING block.
  if [ "$m_count" -gt 0 ]; then
    LC_ALL=C sort -- "$missing_file" 2>/dev/null \
      | while IFS= read -r p; do
          [ -n "$p" ] || continue
          printf '%-32s %s\n' "MISSING" "$p"
        done
  fi

  # NEW block. `new_file` is already sorted (comm requires sorted input).
  if [ "$n_count" -gt 0 ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '%-32s %s\n' "NEW" "$p"
    done < "$new_file"
  fi

  local total=$(( p_count + f_count + m_count + s_count + n_count ))

  # Summary block. The leading `---` separator mirrors the convention
  # used by other macaudit report renderers (task 13) so operators who
  # pipe integrity output into less or grep see a recognisable boundary.
  printf '%s\n' '---'
  printf '%s\n' 'SUMMARY'
  printf '  PASS:      %d\n' "$p_count"
  printf '  FAIL:      %d\n' "$f_count"
  printf '  SKIP:      %d\n' "$s_count"
  printf '  MISSING:   %d\n' "$m_count"
  printf '  NEW:       %d\n' "$n_count"
  printf '  TOTAL:     %d\n' "$total"

  # Exit code — Requirement 10.8 / 10.9 / 14.3. SKIP does NOT contribute
  # to a non-zero exit: the integrity check could not be performed, not
  # FAILED, so surfacing it as drift would be wrong.
  if [ "$f_count" -eq 0 ] && [ "$m_count" -eq 0 ] && [ "$n_count" -eq 0 ]; then
    return 0
  fi
  return 1
}

# _integrity_count_lines <file>
#   stdout: decimal line count (0 when file is missing or empty). We
#   deliberately avoid `wc -l` here — BSD `wc` pads its output with
#   leading spaces which then break the %-d format specifiers in the
#   summary block. Counting via a streaming awk keeps the output clean.
_integrity_count_lines() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || { printf '%s\n' 0; return 0; }
  awk 'END { print NR+0 }' "$f" 2>/dev/null
}

# _integrity_classify_tier3 <baseline_entry_json> <path> <surface>
#                           <current_manifest_path> <current_skipped_file>
#                           <pass_file> <fail_file> <missing_file>
#                           <skip_file>
#   Append exactly one classification line to one of the four scratch
#   files and return 0. Dispatches on <surface>:
#
#     sqlite surfaces (tcc_system, tcc_user, kextpolicy, execpolicy,
#                      systempolicy, quarantine_events)
#                   → compare sha256_checkpointed + every per-table
#                     content_hash. Emits PASS when all channels match;
#                     FAIL[checkpointed,content:<t1>,content:<t2>]
#                     listing every mismatching channel; MISSING when
#                     the current manifest has no entry at <path> AND
#                     the path is not in skipped_paths; SKIP when the
#                     current manifest's header.skipped_paths lists the
#                     path (FDA/sudo lost between runs, DB became
#                     unreadable — the integrity check cannot be
#                     performed, so it is not a FAIL).
#
#     authdb        → compare sha256_canonical. Emits PASS / FAIL[canonical]
#                     / MISSING / SKIP.
#
#     xprotect      → compare every per-file sha256_raw in the baseline's
#                     files map plus the codesign.valid field. Emits
#                     PASS when every file matches AND codesign stays
#                     valid; FAIL[file:<path>,...,codesign] otherwise;
#                     MISSING / SKIP as above.
#
#     unknown Tier 3 surface → record as MISSING so the total stays
#                     consistent; the caller's banner sort/emit phase
#                     handles the rest.
#
# Implementation notes:
#   - The current entry is fetched via `manifest_entry_by_path` which
#     streams the current manifest via `tail -n +2 | jq` and emits the
#     first matching line. For the common Tier 3 path this is one entry
#     at most per baseline row.
#   - A missing current entry COULD mean the underlying surface was
#     skipped on re-capture (usually FDA loss between runs, or the
#     database file was deleted). We disambiguate by consulting the
#     current manifest's `header.skipped_paths` — presence there ⇒ SKIP
#     (integrity cannot be performed, not a FAIL), absence there ⇒
#     MISSING (the file is genuinely gone on disk).
#   - FAIL lines use the same `<label><TAB><path>` scratch-file format
#     as Tier 1/2 so the phase-4 sort/emit loop can emit them through
#     the existing `sort -t <TAB> -k2,2` pipeline without change.
_integrity_classify_tier3() {
  local entry_line="$1"
  local path="$2"
  local surface="$3"
  local current_path="$4"
  local current_skipped_file="$5"
  local pass_file="$6"
  local fail_file="$7"
  local missing_file="$8"
  local skip_file="$9"

  # Fetch the matching current entry by path.
  local current_entry
  current_entry=$(manifest_entry_by_path "$current_path" "$path")
  if [ -z "$current_entry" ]; then
    # No body entry. If the re-capture recorded the path in
    # skipped_paths, emit SKIP (informational — the integrity check
    # could not run). Otherwise the path is genuinely missing on disk.
    if [ -n "$current_skipped_file" ] && [ -s "$current_skipped_file" ] \
        && LC_ALL=C grep -qxF -- "$path" "$current_skipped_file" 2>/dev/null; then
      printf '%s\n' "$path" >> "$skip_file"
    else
      printf '%s\n' "$path" >> "$missing_file"
    fi
    return 0
  fi

  case "$surface" in
    tcc_system|tcc_user|kextpolicy|execpolicy|systempolicy|quarantine_events)
      _integrity_compare_sqlite \
        "$entry_line" "$current_entry" "$path" \
        "$pass_file" "$fail_file"
      ;;
    authdb)
      _integrity_compare_authdb \
        "$entry_line" "$current_entry" "$path" \
        "$pass_file" "$fail_file"
      ;;
    xprotect)
      _integrity_compare_xprotect \
        "$entry_line" "$current_entry" "$path" \
        "$pass_file" "$fail_file"
      ;;
    *)
      # Unknown Tier 3 surface — classify as MISSING to keep totals
      # consistent. A future surface will either slot in above or
      # ship with its own comparator.
      printf '%s\n' "$path" >> "$missing_file"
      ;;
  esac
  return 0
}

# _integrity_compare_sqlite <baseline_entry> <current_entry> <path>
#                           <pass_file> <fail_file>
#   Compare sha256_checkpointed + every table's content_hash. Tables
#   snapshotted in the baseline are the set of keys under
#   `.table_snapshots`; each gets compared against
#   `.table_snapshots.<table>.content_hash` on the current entry.
#
#   PASS iff every channel matches. FAIL records every mismatching
#   channel in the form:
#     FAIL[checkpointed]
#     FAIL[content:<table1>]
#     FAIL[checkpointed,content:<t1>,content:<t2>]
#   so the operator can see exactly which channels flipped.
_integrity_compare_sqlite() {
  local baseline_entry="$1"
  local current_entry="$2"
  local path="$3"
  local pass_file="$4"
  local fail_file="$5"

  local ck_b ck_c
  ck_b=$(printf '%s' "$baseline_entry" | jq -r '.sha256_checkpointed // ""' 2>/dev/null)
  ck_c=$(printf '%s' "$current_entry"  | jq -r '.sha256_checkpointed // ""' 2>/dev/null)

  local channels=""
  if [ "$ck_b" != "$ck_c" ]; then
    channels="checkpointed"
  fi

  # Iterate the baseline's table keys and compare each content_hash.
  # A table present in baseline but missing in current maps to the empty
  # string on the current side, which will never equal a real hash so
  # it naturally shows up as a mismatching channel.
  local tables table bh ch
  tables=$(printf '%s' "$baseline_entry" \
    | jq -r '.table_snapshots // {} | keys[]' 2>/dev/null)
  if [ -n "$tables" ]; then
    while IFS= read -r table; do
      [ -n "$table" ] || continue
      bh=$(printf '%s' "$baseline_entry" | jq -r \
        --arg t "$table" '.table_snapshots[$t].content_hash // ""' 2>/dev/null)
      ch=$(printf '%s' "$current_entry" | jq -r \
        --arg t "$table" '.table_snapshots[$t].content_hash // ""' 2>/dev/null)
      if [ "$bh" != "$ch" ]; then
        if [ -n "$channels" ]; then
          channels="${channels},content:${table}"
        else
          channels="content:${table}"
        fi
      fi
    done <<EOF
$tables
EOF
  fi

  if [ -z "$channels" ]; then
    printf '%s\n' "$path" >> "$pass_file"
  else
    printf 'FAIL[%s]\t%s\n' "$channels" "$path" >> "$fail_file"
  fi
}

# _integrity_compare_authdb <baseline_entry> <current_entry> <path>
#                           <pass_file> <fail_file>
#   Compare sha256_canonical. authdb entries are JSON blobs (not SQLite)
#   so there is no checkpointed hash and no per-table snapshot.
_integrity_compare_authdb() {
  local baseline_entry="$1"
  local current_entry="$2"
  local path="$3"
  local pass_file="$4"
  local fail_file="$5"

  local b c
  b=$(printf '%s' "$baseline_entry" | jq -r '.sha256_canonical // ""' 2>/dev/null)
  c=$(printf '%s' "$current_entry"  | jq -r '.sha256_canonical // ""' 2>/dev/null)

  if [ "$b" = "$c" ]; then
    printf '%s\n' "$path" >> "$pass_file"
  else
    printf 'FAIL[%s]\t%s\n' "canonical" "$path" >> "$fail_file"
  fi
}

# _integrity_compare_xprotect <baseline_entry> <current_entry> <path>
#                             <pass_file> <fail_file>
#   Compare every per-file sha256_raw under `.files.<rel>.sha256_raw`
#   against the current bundle AND compare `.codesign.valid`. Emits:
#     PASS                                   — every file matches
#                                              and codesign valid
#                                              unchanged.
#     FAIL[file:<rel>,...,codesign]          — one channel per
#                                              mismatching file
#                                              (relative bundle path)
#                                              plus the literal token
#                                              "codesign" when
#                                              `.codesign.valid`
#                                              flipped from true to
#                                              false.
#
#   A file present in baseline.files but absent in current.files counts
#   as a mismatch (empty != non-empty hash). Extra files on the current
#   side are surfaced through the NEW block at the bundle-root path
#   scope — XProtect emits ONE entry for the whole bundle, so per-file
#   NEW tracking does not apply here.
_integrity_compare_xprotect() {
  local baseline_entry="$1"
  local current_entry="$2"
  local path="$3"
  local pass_file="$4"
  local fail_file="$5"

  local files tokens=""
  files=$(printf '%s' "$baseline_entry" \
    | jq -r '.files // {} | keys[]' 2>/dev/null)
  if [ -n "$files" ]; then
    local rel bh ch
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      bh=$(printf '%s' "$baseline_entry" | jq -r \
        --arg r "$rel" '.files[$r].sha256_raw // ""' 2>/dev/null)
      ch=$(printf '%s' "$current_entry"  | jq -r \
        --arg r "$rel" '.files[$r].sha256_raw // ""' 2>/dev/null)
      if [ "$bh" != "$ch" ]; then
        if [ -n "$tokens" ]; then
          tokens="${tokens},file:${rel}"
        else
          tokens="file:${rel}"
        fi
      fi
    done <<EOF
$files
EOF
  fi

  # codesign flip — only flag when baseline was valid (true) and
  # current is no longer valid. A codesign that was already invalid
  # in the baseline and stays invalid should not drive a FAIL[codesign]
  # channel; the original anomaly (xprotect_codesign_fail) already
  # surfaces that state via the suspicious category.
  local cs_b cs_c
  cs_b=$(printf '%s' "$baseline_entry" | jq -r '.codesign.valid // false' 2>/dev/null)
  cs_c=$(printf '%s' "$current_entry"  | jq -r '.codesign.valid // false' 2>/dev/null)
  if [ "$cs_b" = "true" ] && [ "$cs_c" != "true" ]; then
    if [ -n "$tokens" ]; then
      tokens="${tokens},codesign"
    else
      tokens="codesign"
    fi
  fi

  if [ -z "$tokens" ]; then
    printf '%s\n' "$path" >> "$pass_file"
  else
    printf 'FAIL[%s]\t%s\n' "$tokens" "$path" >> "$fail_file"
  fi
}
