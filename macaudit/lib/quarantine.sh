#!/bin/bash
# lib/quarantine.sh — per-user LSQuarantineEvent SQLite capture +
# `com.apple.quarantine` xattr decoding and lookup.
#
# The per-user LSQuarantineEvent database
# (`$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`)
# records a row for every file downloaded through a quarantine-aware agent
# (Safari, Chrome, Firefox, Mail, etc.). Each row carries a UUID that also
# lands on the downloaded file's `com.apple.quarantine` extended attribute,
# giving us a cryptographically-unique provenance edge from a persistence
# plist back to the browser/agent that wrote it.
#
# This module provides:
#
#   1. `quarantine_capture_user` — Tier 3 capture of LSQuarantineEvent via
#      the sqlite_safe_copy / sqlite_snapshot_table pipeline. Emits a
#      single manifest entry with `surface: "quarantine_events"`.
#
#   2. `quarantine_xattr_uuid` / `quarantine_lookup_uuid` — the two
#      helpers the R2 cross-surface correlation rule (task 15F) uses to
#      tie a Tier 1 plist's quarantine xattr to the LSQuarantineEvent row.
#
# No anomaly rules live in this module — R2 fires from the correlation
# pass, not from this file. `anomalies` is always `[]` on the emitted
# entry.
#
# Missing DB is NOT an error: on a fresh install, or for a user who has
# never downloaded anything through a quarantine-aware agent, the file
# does not exist. We log a single info line and return 0 so the caller
# can optionally record the skip in `header.skipped_paths`.
#
# Style constraints (shared across lib/):
#   - `#!/bin/bash` only — bash 3.2 compatible.
#   - `printf '%s\n'` — never `echo -e`.
#   - No `set -euo pipefail`; every function returns an explicit status.
#   - Errors via `utils_log_err`, informational skips via `utils_log_info`.

# =============================================================================
# Section 1 — LSQuarantineEvent capture
# =============================================================================
# Follows the same five-step pipeline as `tcc_capture_user` in lib/tcc.sh:
#   1. Resolve the database path (honouring QUARANTINE_PATH_OVERRIDE).
#   2. Safe-copy via `sqlite_safe_copy` from lib/sqlite.sh.
#   3. Snapshot the LSQuarantineEvent table with the forensic column
#      subset, sorted by LSQuarantineEventIdentifier (the UUID primary
#      key, guaranteed unique and therefore stable).
#   4. Gather WAL sidecar info + checkpointed hash.
#   5. Build a Tier 3 manifest entry and append to the scratch JSONL.

# quarantine_user_path <home>
#   stdout: <home>/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2
#           — unless QUARANTINE_PATH_OVERRIDE is set, in which case its
#           value is echoed verbatim (tests only).
quarantine_user_path() {
  local home="$1"
  if [ -n "${QUARANTINE_PATH_OVERRIDE:-}" ]; then
    printf '%s\n' "$QUARANTINE_PATH_OVERRIDE"
    return 0
  fi
  if [ -z "$home" ]; then
    utils_log_err "quarantine_user_path: home directory is required"
    return 1
  fi
  printf '%s\n' "${home}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
}

# _quarantine_event_columns_csv
#   stdout: the SELECT column list for the LSQuarantineEvent snapshot.
#           The seven forensic fields called out in task 15D.1, plus no
#           extras — we do NOT need indirect columns for sort stability
#           here because LSQuarantineEventIdentifier is a UUID and thus
#           globally unique on its own.
_quarantine_event_columns_csv() {
  printf '%s\n' \
    "LSQuarantineEventIdentifier,LSQuarantineTimeStamp,LSQuarantineAgentBundleIdentifier,LSQuarantineAgentName,LSQuarantineDataURLString,LSQuarantineOriginURLString,LSQuarantineTypeNumber"
}

# _quarantine_event_primary_key_csv
#   stdout: the sort key used when producing the canonical row order.
#           UUID — unique, stable, deterministic. Callers that want
#           most-recent-first ordering for a human-facing report can
#           re-sort by LSQuarantineTimeStamp on their own.
_quarantine_event_primary_key_csv() {
  printf '%s\n' "LSQuarantineEventIdentifier"
}

# quarantine_capture_user <home> <scratch_entries_file>
#   Capture the per-user LSQuarantineEvent database for <home> and append
#   one Tier 3 manifest entry (surface: "quarantine_events") to
#   <scratch_entries_file>.
#
#   Return codes:
#     0 — one entry was written, OR the DB is missing (info line logged,
#         nothing written; caller decides whether to record the skip).
#     1 — invalid input or `sqlite_safe_copy` failed.
#
#   The "missing DB ⇒ exit 0 with nothing written" case is intentional:
#   a fresh-install user with no browser downloads has no LSQuarantineEvent
#   database on disk, and that is not a tool failure. Callers (15F) can
#   still record the path in `header.skipped_paths` with `reason: "missing"`.
quarantine_capture_user() {
  local home="$1"
  local scratch="$2"

  if [ -z "$home" ] && [ -z "${QUARANTINE_PATH_OVERRIDE:-}" ]; then
    utils_log_err "quarantine_capture_user: home directory is required"
    return 1
  fi
  if [ -z "$scratch" ]; then
    utils_log_err "quarantine_capture_user: scratch entries file is required"
    return 1
  fi

  local db_path
  db_path=$(quarantine_user_path "$home") || return 1

  # Missing DB is an informational skip, not an error.
  if [ ! -e "$db_path" ]; then
    utils_log_info "quarantine_capture_user: '${db_path}' not present; skipping"
    return 0
  fi

  if [ ! -r "$db_path" ]; then
    utils_log_err "quarantine_capture_user: '${db_path}' is not readable"
    return 1
  fi

  local copy
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    utils_log_err "quarantine_capture_user: sqlite_safe_copy failed for '${db_path}'"
    return 1
  fi

  local ck_hash size mtime wal_info wal_present wal_hash
  ck_hash=$(sqlite_checkpointed_hash "$copy")
  size=$(utils_file_size "$db_path")
  mtime=$(utils_file_mtime_iso "$db_path")
  wal_info=$(sqlite_wal_sidecar_info "$db_path")
  if [ -z "$wal_info" ]; then
    wal_info='{"wal_present": false, "wal_sha256": ""}'
  fi
  wal_present=$(printf '%s' "$wal_info" | jq -r '.wal_present' 2>/dev/null)
  wal_hash=$(printf '%s' "$wal_info" | jq -r '.wal_sha256' 2>/dev/null)
  case "$wal_present" in
    true|false) : ;;
    *) wal_present=false ;;
  esac

  local cols pk snapshot
  cols=$(_quarantine_event_columns_csv)
  pk=$(_quarantine_event_primary_key_csv)
  snapshot=$(sqlite_snapshot_table "$copy" "LSQuarantineEvent" "$pk" "$cols")

  # Fall back to a well-formed empty snapshot so the entry always has
  # a valid table_snapshots.LSQuarantineEvent object.
  if [ -z "$snapshot" ]; then
    local empty_hash
    empty_hash=$(printf '[]\n' | utils_sha256_stdin)
    snapshot=$(jq -cn \
      --arg content_hash "$empty_hash" \
      '{row_count: 0, primary_key: ["LSQuarantineEventIdentifier"], content_hash: $content_hash, rows: []}')
  fi

  local table_snapshots
  table_snapshots=$(jq -cn --argjson s "$snapshot" '{LSQuarantineEvent: $s}')

  # No dedicated anomaly rules on this surface — R2 fires from the
  # cross-surface correlation pass.
  local anomalies='[]'

  local entry
  entry=$(manifest_build_entry \
    --path "$db_path" \
    --tier 3 \
    --surface "quarantine_events" \
    --format sqlite \
    --sha256-raw "" \
    --sha256-canonical "" \
    --size "${size:-}" \
    --mtime "${mtime:-}" \
    --xattrs-json '{}' \
    --content-json '{}' \
    --sha256-checkpointed "$ck_hash" \
    --wal-present "$wal_present" \
    --wal-sha256 "$wal_hash" \
    --table-snapshots-json "$table_snapshots" \
    --anomalies-json "$anomalies")
  if [ -z "$entry" ]; then
    utils_log_err "quarantine_capture_user: manifest_build_entry failed for '${db_path}'"
    return 1
  fi

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# =============================================================================
# Section 2 — Quarantine xattr UUID helpers
# =============================================================================
# The `com.apple.quarantine` xattr value is a semicolon-separated string
# with four fields:
#
#   <flag>;<epoch_hex>;<agent_name>;<uuid>
#
# Example (Safari download):
#   0083;5991b778;Safari.app;D1192986-42A3-41DB-AF71-E1A4F28F6D21
#
# `quarantine_xattr_uuid` decodes the fourth field; `quarantine_lookup_uuid`
# confirms that UUID is recorded in LSQuarantineEvent on a checkpointed
# copy. Both are pure functions with no filesystem side effects outside
# of reading the xattr / reading the copy.

# quarantine_xattr_uuid <path>
#   stdout: the UUID component of `com.apple.quarantine` on <path>, or
#           the empty string when:
#             - <path> is empty
#             - <path> does not exist
#             - the xattr is not present on <path>
#             - the decoded string has fewer than 4 semicolon-separated
#               fields
#
#   The parse is strict on field count (4) but permissive on field
#   content — we do NOT validate that the UUID field looks like a UUID
#   (a `.` or empty string is returned verbatim). The R2 correlation
#   rule makes the determinism call via `quarantine_lookup_uuid`.
quarantine_xattr_uuid() {
  local path="$1"
  [ -n "$path" ] || return 0
  [ -e "$path" ] || return 0

  local raw
  raw=$(xattr -p com.apple.quarantine "$path" 2>/dev/null) || return 0
  [ -n "$raw" ] || return 0

  # Strip any trailing newline or CR so field 4 is clean when it is
  # the last component.
  raw=$(printf '%s' "$raw" | tr -d '\r\n')

  # Field count: awk over `;` separator. Refuse anything with fewer
  # than 4 fields. awk returns the NF count on stdout.
  local nf
  nf=$(printf '%s' "$raw" | awk -F';' '{print NF}')
  [ -n "$nf" ] || return 0
  if [ "$nf" -lt 4 ] 2>/dev/null; then
    return 0
  fi

  # Extract field 4. Preserve any semicolons in later fields by using
  # `cut -d ';' -f 4-` — the quarantine format only defines four
  # fields, but in theory an agent could embed a semicolon in its
  # name/UUID. Strict-four was the task's requirement; preserving
  # field 4+ matches the "everything after the third `;`" intent.
  local uuid
  uuid=$(printf '%s' "$raw" | cut -d ';' -f 4-)
  printf '%s\n' "$uuid"
}

# quarantine_lookup_uuid <checkpointed_copy> <uuid>
#   exit 0 iff the <uuid> appears in LSQuarantineEvent on the
#   checkpointed SQLite copy. exit 1 otherwise.
#
#   Failure modes (all → exit 1):
#     - empty <checkpointed_copy> or <uuid>
#     - <checkpointed_copy> unreadable
#     - UUID not found in LSQuarantineEvent
#     - underlying sqlite3 error (missing table, malformed DB)
#
#   Implementation: route through `sqlite_query_tsv` so the query
#   stays inside the read-only envelope enforced by lib/sqlite.sh.
#   For a matching row the query emits header + row ("1\n1"); for no
#   match it emits header only ("1"). We look for a line that is
#   exactly "1" AFTER the header — equivalent to "row count > 0".
quarantine_lookup_uuid() {
  local copy="$1"
  local uuid="$2"
  [ -n "$copy" ] || return 1
  [ -n "$uuid" ] || return 1
  [ -r "$copy" ] || return 1

  # The UUID is an opaque string; we escape any embedded single quotes
  # by doubling them per SQL convention so an adversarial xattr cannot
  # inject SQL through this lookup.
  local escaped
  escaped=$(printf '%s' "$uuid" | sed "s/'/''/g")

  local sql
  sql="SELECT 1 FROM LSQuarantineEvent WHERE LSQuarantineEventIdentifier = '${escaped}' LIMIT 1;"

  local out
  out=$(sqlite_query_tsv "$copy" "$sql")
  [ -n "$out" ] || return 1

  # `sqlite_query_tsv` uses -header -separator '\t'; for a match the
  # output is two lines (header "1" + row "1"). We count data lines by
  # stripping the header line via `tail -n +2`. A non-empty tail ⇒
  # match; empty tail ⇒ no match.
  local tail
  tail=$(printf '%s\n' "$out" | tail -n +2)
  [ -n "$tail" ] || return 1
  return 0
}
