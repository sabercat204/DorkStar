#!/bin/bash
# lib/tcc.sh — TCC.db capture + anomaly detection.
#
# Captures macOS's TCC (Transparency, Consent, and Control) database — the
# system-wide and per-user authorization grant store — at Tier 3. Both
# scopes route through `sqlite_safe_copy` / `sqlite_snapshot_table` from
# lib/sqlite.sh so the originals stay byte-identical across the tool run.
#
# The `access` table is snapshotted deterministically (sorted by a compound
# primary key including indirect_object_identifier for stability) and then
# handed to `tcc_detect_anomalies`, which emits a JSON array of
# `{rule, severity, detail}` objects for every row that matches one of
# the four TCC abuse indicators (Requirement 25): override policy,
# AV with unusual reason, FDA granted to an unsigned binary, and
# MDM-labelled grants without a matching PPPC profile.
#
# Every function is read-only with respect to the source database. The
# only side effects are writes into `MACAUDIT_TMPDIR` (via the SQLite
# helpers) and the append to the scratch entries file (via the manifest
# helpers).
#
# bash 3.2 compatible: no associative arrays, no mapfile/readarray.

# =============================================================================
# Section 1 — Path helpers
# =============================================================================
# Thin wrappers so callers (baseline.sh, tests) don't hard-code the
# TCC.db paths. Both emit an absolute path on stdout and never fail.

# tcc_system_path
#   stdout: /Library/Application Support/com.apple.TCC/TCC.db
#
#   When TCC_SYSTEM_PATH_OVERRIDE is set (test-only), its value takes
#   precedence so fixtures can stand in for the real system database.
tcc_system_path() {
  if [ -n "${TCC_SYSTEM_PATH_OVERRIDE:-}" ]; then
    printf '%s\n' "$TCC_SYSTEM_PATH_OVERRIDE"
    return 0
  fi
  printf '%s\n' "/Library/Application Support/com.apple.TCC/TCC.db"
}

# tcc_user_path <home>
#   stdout: <home>/Library/Application Support/com.apple.TCC/TCC.db
tcc_user_path() {
  local home="$1"
  if [ -z "$home" ]; then
    utils_log_err "tcc_user_path: home directory is required"
    return 1
  fi
  printf '%s\n' "${home}/Library/Application Support/com.apple.TCC/TCC.db"
}

# =============================================================================
# Section 2 — access table capture
# =============================================================================
# Both `tcc_capture_system` and `tcc_capture_user` follow the same
# pipeline:
#   1. Resolve the source TCC.db path (with optional test-override).
#   2. For the system path, require FDA via utils_fda_probe; return 1
#      when unavailable so the caller can record the skip in the header.
#   3. Safe-copy the database via sqlite_safe_copy (task 15A).
#   4. Snapshot the `access` table with the canonical sort order
#      described in Requirement 22.3.
#   5. Run the four anomaly rules over the snapshot's rows.
#   6. Compose a manifest entry via manifest_build_entry and append it
#      to the scratch entries file via manifest_write_entry.
#
# The SELECT column list INCLUDES `indirect_object_identifier` even
# though it is not part of the seven forensic fields in the design.md
# pseudocode, because sqlite_snapshot_table requires every primary-key
# column to appear in the column list so `.rows[$pk[]]` can dereference
# each sort key during the jq sort pass. Anomaly detection only reads
# the forensic fields; the indirect_object_identifier is purely a
# sort-stability column.
#
# The PPPC payloads list comes from the caller (baseline_run_tier3 in
# task 15F fetches it via `profiles show -type configuration` and hands
# it in as a JSON array). Tests pass a synthetic array.

# _tcc_access_columns_csv
#   stdout: the SELECT column list for the `access` table snapshot,
#           comma-separated. Kept as a helper so tests and internal
#           call sites stay in lock-step.
_tcc_access_columns_csv() {
  printf '%s\n' \
    "service,client,client_type,auth_value,auth_reason,auth_version,last_modified,indirect_object_identifier"
}

# _tcc_access_primary_key_csv
#   stdout: the compound primary key used to sort the access snapshot,
#           comma-separated. Requirement 22.3.
_tcc_access_primary_key_csv() {
  printf '%s\n' "service,client,client_type,indirect_object_identifier"
}

# _tcc_capture_common <db_path> <surface> <scratch_entries_file> <pppc_json>
#   Internal: builds and writes one manifest entry for the TCC.db at
#   <db_path>. The <surface> parameter is either `tcc_system` or
#   `tcc_user` and is carried verbatim into the entry. <pppc_json> is
#   a JSON array of PPPC client identifiers (empty array when the
#   caller has no profiles data).
#
#   Returns 0 on success, 1 when safe-copy fails or inputs are invalid.
_tcc_capture_common() {
  local db_path="$1"
  local surface="$2"
  local scratch="$3"
  local pppc_json="$4"

  if [ -z "$db_path" ]; then
    utils_log_err "tcc_capture: db path is required"
    return 1
  fi
  if [ -z "$surface" ]; then
    utils_log_err "tcc_capture: surface is required"
    return 1
  fi
  if [ -z "$scratch" ]; then
    utils_log_err "tcc_capture: scratch entries file is required"
    return 1
  fi
  if [ -z "$pppc_json" ]; then
    pppc_json='[]'
  fi
  if ! printf '%s' "$pppc_json" | jq -e . >/dev/null 2>&1; then
    utils_log_err "tcc_capture: pppc payloads is not valid JSON"
    return 1
  fi

  if [ ! -r "$db_path" ]; then
    utils_log_err "tcc_capture: '${db_path}' is not readable"
    return 1
  fi

  local copy
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    utils_log_err "tcc_capture: sqlite_safe_copy failed for '${db_path}'"
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
  cols=$(_tcc_access_columns_csv)
  pk=$(_tcc_access_primary_key_csv)
  snapshot=$(sqlite_snapshot_table "$copy" "access" "$pk" "$cols")
  if [ -z "$snapshot" ]; then
    # Fall back to a well-formed empty snapshot so the entry still has
    # a valid table_snapshots.access value. The sort-order PK is still
    # recorded for downstream consumers.
    local empty_hash
    empty_hash=$(printf '[]\n' | utils_sha256_stdin)
    snapshot=$(jq -cn \
      --arg content_hash "$empty_hash" \
      '{row_count: 0, primary_key: ["service","client","client_type","indirect_object_identifier"], content_hash: $content_hash, rows: []}')
  fi

  local rows_json
  rows_json=$(printf '%s' "$snapshot" | jq -c '.rows' 2>/dev/null)
  [ -n "$rows_json" ] || rows_json='[]'

  local anomalies
  anomalies=$(tcc_detect_anomalies "$rows_json" "$pppc_json")
  if [ -z "$anomalies" ]; then
    anomalies='[]'
  fi

  local table_snapshots
  table_snapshots=$(jq -cn --argjson s "$snapshot" '{access: $s}')

  local entry
  entry=$(manifest_build_entry \
    --path "$db_path" \
    --tier 3 \
    --surface "$surface" \
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
    utils_log_err "tcc_capture: manifest_build_entry failed for '${db_path}'"
    return 1
  fi

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# tcc_capture_system <scratch_entries_file> [pppc_json]
#   Capture the system TCC.db, gated on FDA. Returns 1 (with empty
#   stdout, a log-err line on stderr) when FDA is unavailable so the
#   caller can route the path into the manifest header's skipped_paths
#   array. Returns 1 with a log-err line when the safe-copy fails.
#   Returns 0 and appends one JSONL entry to <scratch_entries_file>
#   on success.
tcc_capture_system() {
  local scratch="$1"
  local pppc_json="${2:-[]}"

  if [ -z "$scratch" ]; then
    utils_log_err "tcc_capture_system: scratch entries file is required"
    return 1
  fi

  if ! utils_fda_probe; then
    utils_log_err "tcc_capture_system: FDA unavailable; skipping system TCC.db"
    return 1
  fi

  local db_path
  db_path=$(tcc_system_path)
  _tcc_capture_common "$db_path" "tcc_system" "$scratch" "$pppc_json"
}

# tcc_capture_user <home> <scratch_entries_file> [pppc_json]
#   Capture the per-user TCC.db for <home>. The per-user database is
#   readable by the owning user without FDA when the calling process
#   lives under that same $HOME. When we cannot read it we log and
#   return 1 rather than emit a zombie entry.
tcc_capture_user() {
  local home="$1"
  local scratch="$2"
  local pppc_json="${3:-[]}"

  if [ -z "$home" ]; then
    utils_log_err "tcc_capture_user: home directory is required"
    return 1
  fi
  if [ -z "$scratch" ]; then
    utils_log_err "tcc_capture_user: scratch entries file is required"
    return 1
  fi

  local db_path
  db_path=$(tcc_user_path "$home") || return 1

  if [ ! -r "$db_path" ]; then
    utils_log_err "tcc_capture_user: '${db_path}' is not readable"
    return 1
  fi

  _tcc_capture_common "$db_path" "tcc_user" "$scratch" "$pppc_json"
}

# =============================================================================
# Section 3 — Anomaly detection
# =============================================================================
# `tcc_detect_anomalies` is the single entry point for the four TCC
# abuse rules (Requirement 25). It is a pure function of
#   (rows_json, pppc_payloads_json)
# and the codesign status of every candidate FDA client — the rule
# set is small and the logic is all in one jq pass so soundness and
# completeness (P19 / P20) are easy to reason about.
#
# Rule definitions (Requirement 25):
#   1. tcc_override_policy   — auth_reason == 7                        (severity: high)
#   2. tcc_av_unusual_reason — service ∈ {camera, mic} && auth_reason != 2 (severity: warn)
#   3. tcc_fda_unsigned      — FDA + client_type=1 + codesign invalid   (severity: high)
#   4. tcc_mdm_without_profile — auth_reason == 6 && client ∉ pppc      (severity: high)
#
# Each anomaly is `{rule, severity, detail}`. The detail string formats
# are fixed by Requirement 25's acceptance criteria.

_TCC_FDA_SERVICE="kTCCServiceSystemPolicyAllFiles"
_TCC_CAMERA_SERVICE="kTCCServiceCamera"
_TCC_MIC_SERVICE="kTCCServiceMicrophone"

# _tcc_codesign_map <rows_json>
#   stdout: one-line JSON object mapping every candidate FDA client
#           path (service == FDA, client_type == 1) to its
#           `utils_codesign_verify(client).valid` boolean. Unresolvable
#           paths map to false so the anomaly rule treats them as
#           unsigned (the safer default for a grant that exists in
#           TCC.db but whose on-disk binary is missing or unreadable).
#
#   The map is keyed by the raw client string so the downstream jq
#   pass can do a direct `$sigs[.client]` lookup.
_tcc_codesign_map() {
  local rows_json="$1"
  [ -n "$rows_json" ] || { printf '%s\n' '{}'; return 0; }

  # Collect unique candidate client paths. jq prints one per line.
  local candidates
  candidates=$(printf '%s' "$rows_json" | jq -r --arg fda "$_TCC_FDA_SERVICE" '
    .[]
    | select(.service == $fda and .client_type == 1)
    | .client
  ' 2>/dev/null | awk 'NF' | sort -u)

  local sigs='{}'
  if [ -z "$candidates" ]; then
    printf '%s\n' "$sigs"
    return 0
  fi

  local client cs valid_json
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    cs=$(utils_codesign_verify "$client" 2>/dev/null)
    if [ -z "$cs" ]; then
      valid_json=false
    else
      valid_json=$(printf '%s' "$cs" | jq -r '.valid // false' 2>/dev/null)
      case "$valid_json" in
        true|false) : ;;
        *) valid_json=false ;;
      esac
    fi
    sigs=$(printf '%s' "$sigs" | jq -c \
      --arg c "$client" \
      --argjson v "$valid_json" \
      '. + {($c): $v}' 2>/dev/null)
  done <<EOF
$candidates
EOF

  [ -n "$sigs" ] || sigs='{}'
  printf '%s\n' "$sigs"
}

# tcc_detect_anomalies <rows_json> <pppc_json>
#   stdout: one-line JSON array of anomaly objects, or `[]` for clean
#           state. Each anomaly has shape {rule, severity, detail}.
#
#   <rows_json> — the `rows` array from sqlite_snapshot_table (or any
#                 equivalent array of access-row objects).
#   <pppc_json> — JSON array of PPPC client identifiers installed via
#                 configuration profiles.
tcc_detect_anomalies() {
  local rows_json="$1"
  local pppc_json="$2"

  if [ -z "$rows_json" ]; then
    rows_json='[]'
  fi
  if [ -z "$pppc_json" ]; then
    pppc_json='[]'
  fi
  if ! printf '%s' "$rows_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    utils_log_err "tcc_detect_anomalies: rows input is not a JSON array"
    printf '%s\n' '[]'
    return 0
  fi
  if ! printf '%s' "$pppc_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    utils_log_err "tcc_detect_anomalies: pppc input is not a JSON array"
    printf '%s\n' '[]'
    return 0
  fi

  local sigs
  sigs=$(_tcc_codesign_map "$rows_json")

  local result
  result=$(printf '%s' "$rows_json" | jq -c \
    --argjson pppc "$pppc_json" \
    --argjson sigs "$sigs" \
    --arg fda "$_TCC_FDA_SERVICE" \
    --arg cam "$_TCC_CAMERA_SERVICE" \
    --arg mic "$_TCC_MIC_SERVICE" \
    '
    . as $rows
    | [
        # Rule 1 — tcc_override_policy
        ( $rows[]
          | select(.auth_reason == 7)
          | {rule: "tcc_override_policy",
             severity: "high",
             detail: (.service + " granted to " + .client + " via Override Policy")}
        ),
        # Rule 2 — tcc_av_unusual_reason
        ( $rows[]
          | select((.service == $cam or .service == $mic) and .auth_reason != 2)
          | {rule: "tcc_av_unusual_reason",
             severity: "warn",
             detail: (.service + " for " + .client + ": auth_reason=" + (.auth_reason | tostring) + ", not user consent")}
        ),
        # Rule 3 — tcc_fda_unsigned
        ( $rows[]
          | select(.service == $fda and .client_type == 1 and (($sigs[.client] // false) == false))
          | {rule: "tcc_fda_unsigned",
             severity: "high",
             detail: ("Full Disk Access granted to unsigned binary at " + .client)}
        ),
        # Rule 4 — tcc_mdm_without_profile
        # NOTE: `index()` evaluates its argument filter against the ARRAY
        # ($pppc) rather than the row, so we must bind the row into $r
        # before calling $pppc | index($r.client). Without the binding,
        # jq errors with "Cannot index array with string \"client\"".
        ( $rows[]
          | . as $r
          | select($r.auth_reason == 6 and ($pppc | index($r.client)) == null)
          | {rule: "tcc_mdm_without_profile",
             severity: "high",
             detail: ($r.service + "/" + $r.client + " claims MDM provenance but no matching PPPC profile installed")}
        )
      ]
    ' 2>/dev/null)

  if [ -z "$result" ]; then
    printf '%s\n' '[]'
    return 0
  fi

  printf '%s\n' "$result"
}
