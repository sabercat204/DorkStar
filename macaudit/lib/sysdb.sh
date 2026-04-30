#!/bin/bash
# lib/sysdb.sh — KextPolicy / ExecPolicy / SystemPolicy / AuthorizationDB
# capture + Gatekeeper status + authorization mechanism classification.
#
# This module covers the five Tier 3 security-database surfaces that are
# NOT TCC.db (that surface lives in lib/tcc.sh). All SQLite surfaces
# route through `sqlite_safe_copy` / `sqlite_snapshot_table` from
# lib/sqlite.sh so the originals stay byte-identical across the tool
# run. The authorization database is read via `security authorizationdb
# read <name>`, piped through `plutil -convert json` and then through
# `utils_canonical_json_stdin` so the resulting `sha256_canonical`
# participates in the same canonical-hash domain as every other plist
# surface.
#
# Mechanism classification is factored out of the authdb capture path
# because the cross-surface correlation pass (R5) needs to run the same
# classifier against the set of mechanisms discovered during Tier 3,
# and because P21 validates it as a pure function of its inputs.
#
# Every function is read-only with respect to the operating system.
# The only side effects are writes into `MACAUDIT_TMPDIR` (via the
# SQLite helpers) and the append to the scratch entries file (via the
# manifest helpers). `profiles` is invoked via `utils_mdm_managed`;
# `spctl` is invoked here; `security` is invoked here. All three can
# be shimmed via override env vars for tests.
#
# bash 3.2 compatible: no associative arrays, no `mapfile`/`readarray`.

# =============================================================================
# Section 1 — KextPolicy capture
# =============================================================================
# KextPolicy tracks kernel extension approvals at two scopes:
#   * kext_policy       — user-approved kexts
#   * kext_policy_mdm   — MDM-authorised kexts
# Both tables have the same columns: team_id, bundle_id, allowed,
# developer_name, flags. Primary key is (team_id, bundle_id) in both.
#
# Anomaly `kext_user_approved_on_mdm` (severity high) fires for every
# row in kext_policy that has NO matching (team_id, bundle_id) in
# kext_policy_mdm AND the device is MDM-managed. On a non-MDM device
# user approvals are expected and the rule never fires.

# _sysdb_kextpolicy_columns_csv
#   stdout: canonical SELECT column list for both kext_policy tables.
_sysdb_kextpolicy_columns_csv() {
  printf '%s\n' "team_id,bundle_id,allowed,developer_name,flags"
}

# _sysdb_kextpolicy_pk_csv
#   stdout: (team_id, bundle_id) primary key used for sort stability.
_sysdb_kextpolicy_pk_csv() {
  printf '%s\n' "team_id,bundle_id"
}

# _sysdb_kext_anomalies <user_rows_json> <mdm_rows_json>
#   stdout: JSON array of kext_user_approved_on_mdm anomaly objects, one
#           per user-approved row without a matching MDM entry.
#
# The rule fires only when the device is MDM-managed. We call
# `utils_mdm_managed` inline rather than short-circuiting in the caller
# so the memoised result is honoured regardless of call order.
_sysdb_kext_anomalies() {
  local user_rows="$1"
  local mdm_rows="$2"

  [ -n "$user_rows" ] || user_rows='[]'
  [ -n "$mdm_rows" ]  || mdm_rows='[]'

  if ! utils_mdm_managed; then
    printf '%s\n' '[]'
    return 0
  fi

  # Build a key set from kext_policy_mdm rows. We use the unit-
  # separator (U+001F) to join team_id and bundle_id because neither
  # field can legitimately contain it — it is the SQL-identifier-
  # unfriendly byte that macOS TeamIDs and bundle identifiers never
  # use.
  local mdm_keys
  mdm_keys=$(printf '%s' "$mdm_rows" | jq -c '
    [ .[] | ((.team_id // "") + "\u001f" + (.bundle_id // "")) ]
  ' 2>/dev/null)
  [ -n "$mdm_keys" ] || mdm_keys='[]'

  local result
  result=$(printf '%s' "$user_rows" | jq -c --argjson keys "$mdm_keys" '
    [ .[]
      | . as $r
      | (($r.team_id // "") + "\u001f" + ($r.bundle_id // "")) as $k
      | select(($keys | index($k)) == null)
      | {rule: "kext_user_approved_on_mdm",
         severity: "high",
         detail: ((($r.developer_name // $r.team_id // "unknown")
                   + " kext "
                   + ($r.bundle_id // "")
                   + " approved by user without MDM authorisation"))}
    ]
  ' 2>/dev/null)

  if [ -z "$result" ]; then
    printf '%s\n' '[]'
    return 0
  fi
  printf '%s\n' "$result"
}

# sysdb_capture_kextpolicy <scratch_entries_file>
#   Safe-copy /var/db/SystemPolicyConfiguration/KextPolicy (or the
#   KEXTPOLICY_PATH_OVERRIDE path for tests), snapshot both
#   kext_policy and kext_policy_mdm, emit one manifest entry with
#   surface: "kextpolicy". Append anomaly entries for every
#   user-approved kext that lacks an MDM-authorised counterpart on
#   MDM-managed devices.
#
#   FDA-gated: when utils_fda_probe returns non-zero and no override
#   is set we log an error and return 1 with no entry written. The
#   caller records the path in the manifest header's skipped_paths
#   array.
sysdb_capture_kextpolicy() {
  local scratch="$1"

  if [ -z "$scratch" ]; then
    utils_log_err "sysdb_capture_kextpolicy: scratch entries file is required"
    return 1
  fi

  local db_path="/var/db/SystemPolicyConfiguration/KextPolicy"
  if [ -n "${KEXTPOLICY_PATH_OVERRIDE:-}" ]; then
    db_path="$KEXTPOLICY_PATH_OVERRIDE"
  else
    # FDA gate only applies to the real system path. Tests that supply
    # their own fixture via the override never exercise FDA.
    if ! utils_fda_probe; then
      utils_log_err "sysdb_capture_kextpolicy: FDA unavailable; skipping $db_path"
      return 1
    fi
  fi

  if [ ! -r "$db_path" ]; then
    utils_log_err "sysdb_capture_kextpolicy: '${db_path}' is not readable"
    return 1
  fi

  local copy
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    utils_log_err "sysdb_capture_kextpolicy: sqlite_safe_copy failed for '${db_path}'"
    return 1
  fi

  local ck_hash size mtime wal_info wal_present wal_hash
  ck_hash=$(sqlite_checkpointed_hash "$copy")
  size=$(utils_file_size "$db_path")
  mtime=$(utils_file_mtime_iso "$db_path")
  wal_info=$(sqlite_wal_sidecar_info "$db_path")
  [ -n "$wal_info" ] || wal_info='{"wal_present": false, "wal_sha256": ""}'
  wal_present=$(printf '%s' "$wal_info" | jq -r '.wal_present' 2>/dev/null)
  wal_hash=$(printf '%s' "$wal_info" | jq -r '.wal_sha256' 2>/dev/null)
  case "$wal_present" in true|false) : ;; *) wal_present=false ;; esac

  local cols pk user_snap mdm_snap
  cols=$(_sysdb_kextpolicy_columns_csv)
  pk=$(_sysdb_kextpolicy_pk_csv)
  user_snap=$(sqlite_snapshot_table "$copy" "kext_policy"     "$pk" "$cols")
  mdm_snap=$(sqlite_snapshot_table  "$copy" "kext_policy_mdm" "$pk" "$cols")

  # Missing tables collapse to an empty-snapshot placeholder so the
  # entry shape stays constant across schema variants.
  if [ -z "$user_snap" ]; then
    local empty_hash
    empty_hash=$(printf '[]\n' | utils_sha256_stdin)
    user_snap=$(jq -cn --arg h "$empty_hash" '{row_count:0, primary_key:["team_id","bundle_id"], content_hash:$h, rows:[]}')
  fi
  if [ -z "$mdm_snap" ]; then
    local empty_hash
    empty_hash=$(printf '[]\n' | utils_sha256_stdin)
    mdm_snap=$(jq -cn --arg h "$empty_hash" '{row_count:0, primary_key:["team_id","bundle_id"], content_hash:$h, rows:[]}')
  fi

  local user_rows mdm_rows
  user_rows=$(printf '%s' "$user_snap" | jq -c '.rows' 2>/dev/null)
  mdm_rows=$(printf '%s'  "$mdm_snap"  | jq -c '.rows' 2>/dev/null)
  [ -n "$user_rows" ] || user_rows='[]'
  [ -n "$mdm_rows" ]  || mdm_rows='[]'

  local anomalies
  anomalies=$(_sysdb_kext_anomalies "$user_rows" "$mdm_rows")
  [ -n "$anomalies" ] || anomalies='[]'

  local table_snapshots
  table_snapshots=$(jq -cn \
    --argjson kp  "$user_snap" \
    --argjson mdm "$mdm_snap" \
    '{kext_policy: $kp, kext_policy_mdm: $mdm}')

  local entry
  entry=$(manifest_build_entry \
    --path "$db_path" \
    --tier 3 \
    --surface "kextpolicy" \
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
    utils_log_err "sysdb_capture_kextpolicy: manifest_build_entry failed for '${db_path}'"
    return 1
  fi

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# =============================================================================
# Section 2 — ExecPolicy capture
# =============================================================================
# ExecPolicy is Gatekeeper's execution-policy cache. The schema has
# shifted across macOS releases; not every install ships every table.
# We introspect `sqlite_master` on the checkpointed copy to find the
# intersection with the well-known table set
# {legacy_exec_history_v4, policy_scan_cache, provisional_policy} and
# snapshot only those that are present.
#
# The tables' primary keys are not uniform across versions either, so
# for each present table we derive the column list via PRAGMA
# table_info and use THAT list as both the SELECT column set and the
# sort-stability key. This is safe because sqlite_snapshot_table sorts
# by `.[$pk[]]` — as long as every column name in the sort key also
# appears in the selected row object, the sort is well-defined.
#
# ExecPolicy has no dedicated anomaly rules in Phase 1; the entry's
# anomalies array is always [].

# _sysdb_columns_of <copy_path> <table>
#   stdout: comma-separated list of column names from PRAGMA table_info
#           for the given table on the checkpointed copy. Empty when
#           the table is missing or the query fails.
_sysdb_columns_of() {
  local copy="$1"
  local table="$2"
  [ -n "$copy" ] || return 0
  [ -n "$table" ] || return 0
  [ -r "$copy" ] || return 0
  # PRAGMA table_info emits one row per column: `cid|name|type|notnull|dflt_value|pk`.
  # We want the name (second field) as a CSV.
  local names
  names=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
    "PRAGMA table_info(${table});" 2>/dev/null \
    | awk -F'|' '{print $2}' \
    | awk 'NF' \
    | paste -sd, -)
  [ -n "$names" ] || return 0
  printf '%s\n' "$names"
}

# _sysdb_execpolicy_table_names <copy_path>
#   stdout: newline-separated list of the intersection between the
#           well-known ExecPolicy tables and the tables actually
#           present in the copy.
_sysdb_execpolicy_table_names() {
  local copy="$1"
  [ -n "$copy" ] || return 0
  [ -r "$copy" ] || return 0
  sqlite3 -batch -readonly "file:${copy}?mode=ro" \
    "SELECT name FROM sqlite_master
       WHERE type='table'
         AND name IN ('legacy_exec_history_v4','policy_scan_cache','provisional_policy')
       ORDER BY name;" 2>/dev/null
}

# sysdb_capture_execpolicy <scratch_entries_file>
#   Safe-copy /var/db/SystemPolicyConfiguration/ExecPolicy (or the
#   EXECPOLICY_PATH_OVERRIDE path for tests), snapshot whichever
#   subset of {legacy_exec_history_v4, policy_scan_cache,
#   provisional_policy} is present, emit one manifest entry with
#   surface: "execpolicy". FDA-gated.
sysdb_capture_execpolicy() {
  local scratch="$1"

  if [ -z "$scratch" ]; then
    utils_log_err "sysdb_capture_execpolicy: scratch entries file is required"
    return 1
  fi

  local db_path="/var/db/SystemPolicyConfiguration/ExecPolicy"
  if [ -n "${EXECPOLICY_PATH_OVERRIDE:-}" ]; then
    db_path="$EXECPOLICY_PATH_OVERRIDE"
  else
    if ! utils_fda_probe; then
      utils_log_err "sysdb_capture_execpolicy: FDA unavailable; skipping $db_path"
      return 1
    fi
  fi

  if [ ! -r "$db_path" ]; then
    utils_log_err "sysdb_capture_execpolicy: '${db_path}' is not readable"
    return 1
  fi

  local copy
  copy=$(sqlite_safe_copy "$db_path")
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    utils_log_err "sysdb_capture_execpolicy: sqlite_safe_copy failed for '${db_path}'"
    return 1
  fi

  local ck_hash size mtime wal_info wal_present wal_hash
  ck_hash=$(sqlite_checkpointed_hash "$copy")
  size=$(utils_file_size "$db_path")
  mtime=$(utils_file_mtime_iso "$db_path")
  wal_info=$(sqlite_wal_sidecar_info "$db_path")
  [ -n "$wal_info" ] || wal_info='{"wal_present": false, "wal_sha256": ""}'
  wal_present=$(printf '%s' "$wal_info" | jq -r '.wal_present' 2>/dev/null)
  wal_hash=$(printf '%s' "$wal_info" | jq -r '.wal_sha256' 2>/dev/null)
  case "$wal_present" in true|false) : ;; *) wal_present=false ;; esac

  local present_tables
  present_tables=$(_sysdb_execpolicy_table_names "$copy")

  # Build table_snapshots one object at a time.
  local table_snapshots='{}'
  if [ -n "$present_tables" ]; then
    local table cols snap
    while IFS= read -r table; do
      [ -n "$table" ] || continue
      cols=$(_sysdb_columns_of "$copy" "$table")
      [ -n "$cols" ] || continue
      # Use the full column list as both the PK (for sort stability)
      # and the SELECT list. This produces a deterministic row order
      # regardless of the table's real primary key.
      snap=$(sqlite_snapshot_table "$copy" "$table" "$cols" "$cols")
      [ -n "$snap" ] || continue
      table_snapshots=$(printf '%s' "$table_snapshots" | jq -c \
        --arg t "$table" \
        --argjson s "$snap" \
        '. + {($t): $s}' 2>/dev/null)
      [ -n "$table_snapshots" ] || table_snapshots='{}'
    done <<EOF
$present_tables
EOF
  fi

  local entry
  entry=$(manifest_build_entry \
    --path "$db_path" \
    --tier 3 \
    --surface "execpolicy" \
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
    --anomalies-json '[]')
  if [ -z "$entry" ]; then
    utils_log_err "sysdb_capture_execpolicy: manifest_build_entry failed for '${db_path}'"
    return 1
  fi

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# =============================================================================
# Section 3 — SystemPolicy + Gatekeeper capture
# =============================================================================
# SystemPolicy is Gatekeeper's authority table. We snapshot the
# `authority` table (PK: id) and `bookmarkhints` table. In addition we
# invoke `spctl --status` and `spctl --test-devid-status` and capture
# both outputs into a `gatekeeper` sub-object on the entry's content.
#
# The SystemPolicy.db itself requires root to read (SIP-protected
# directory permissions), but `spctl` works without FDA and without
# sudo on most macOS installs. We therefore split the capture:
#   * The SQLite work runs under utils_has_sudo.
#   * spctl runs unconditionally.
#
# When sudo is unavailable we still emit the entry — it carries the
# gatekeeper field and the skip reason, but empty sha256_checkpointed
# and empty table_snapshots. This keeps the surface's presence in the
# manifest invariant regardless of privilege level.
#
# Anomaly: `gatekeeper_disabled` (severity high) fires when
# `spctl --status` reports `assessments disabled`.

# _sysdb_spctl_run <arg>
#   stdout: verbatim combined stdout+stderr of `spctl <arg>`. Empty
#           when the binary is absent.
#
#   Honours SPCTL_STATUS_OVERRIDE (for --status) and
#   SPCTL_DEVID_OVERRIDE (for --test-devid-status). When the override
#   env var is set the override value is emitted in place of a real
#   fork, so tests never need to ship an spctl shim on PATH.
_sysdb_spctl_run() {
  local arg="$1"
  case "$arg" in
    --status)
      if [ -n "${SPCTL_STATUS_OVERRIDE+x}" ]; then
        printf '%s\n' "$SPCTL_STATUS_OVERRIDE"
        return 0
      fi
      ;;
    --test-devid-status)
      if [ -n "${SPCTL_DEVID_OVERRIDE+x}" ]; then
        printf '%s\n' "$SPCTL_DEVID_OVERRIDE"
        return 0
      fi
      ;;
  esac
  if ! command -v spctl >/dev/null 2>&1; then
    return 0
  fi
  spctl "$arg" 2>&1
}

# _sysdb_spctl_status_value <raw_output>
#   stdout: "enabled" | "disabled" | "unknown" based on the output.
_sysdb_spctl_status_value() {
  local raw="$1"
  [ -n "$raw" ] || { printf '%s\n' unknown; return 0; }
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"assessments enabled"*)  printf '%s\n' enabled ;;
    *"assessments disabled"*) printf '%s\n' disabled ;;
    *"enabled"*)              printf '%s\n' enabled ;;
    *"disabled"*)             printf '%s\n' disabled ;;
    *)                        printf '%s\n' unknown ;;
  esac
}

# sysdb_capture_systempolicy <scratch_entries_file>
#   Capture SystemPolicy + Gatekeeper state. Emits exactly one entry
#   regardless of sudo availability.
sysdb_capture_systempolicy() {
  local scratch="$1"

  if [ -z "$scratch" ]; then
    utils_log_err "sysdb_capture_systempolicy: scratch entries file is required"
    return 1
  fi

  local db_path="/var/db/SystemPolicyConfiguration/SystemPolicy"
  if [ -n "${SYSTEMPOLICY_PATH_OVERRIDE:-}" ]; then
    db_path="$SYSTEMPOLICY_PATH_OVERRIDE"
  fi

  # Always run spctl first — it does not require sudo or FDA.
  local status_raw devid_raw assessments test_devid
  status_raw=$(_sysdb_spctl_run --status)
  devid_raw=$(_sysdb_spctl_run --test-devid-status)
  assessments=$(_sysdb_spctl_status_value "$status_raw")
  test_devid=$(_sysdb_spctl_status_value "$devid_raw")

  # Build the gatekeeper content sub-object.
  local gatekeeper
  gatekeeper=$(jq -cn \
    --arg assessments "$assessments" \
    --arg test_devid  "$test_devid" \
    --arg status_raw  "$status_raw" \
    --arg devid_raw   "$devid_raw" \
    '{assessments: $assessments,
      test_devid:  $test_devid,
      spctl_status_raw: $status_raw,
      spctl_devid_raw:  $devid_raw}')
  [ -n "$gatekeeper" ] || gatekeeper='{}'

  # Anomaly: gatekeeper_disabled when assessments are disabled.
  local anomalies='[]'
  if [ "$assessments" = "disabled" ]; then
    anomalies=$(jq -cn '[{
      rule: "gatekeeper_disabled",
      severity: "high",
      detail: "Gatekeeper assessments are disabled — unsigned code will run without prompt"
    }]')
  fi

  # Database portion — only attempt when we can actually read it.
  # The override path bypasses the sudo check because tests supply
  # fixtures readable by the current user.
  local ck_hash="" wal_present=false wal_hash="" table_snapshots='{}'
  local size="" mtime=""
  local db_readable=0
  if [ -n "${SYSTEMPOLICY_PATH_OVERRIDE:-}" ]; then
    if [ -r "$db_path" ]; then db_readable=1; fi
  elif utils_has_sudo; then
    if [ -r "$db_path" ]; then db_readable=1; fi
  fi

  local content
  if [ "$db_readable" -eq 1 ]; then
    local copy
    copy=$(sqlite_safe_copy "$db_path")
    if [ -n "$copy" ] && [ -r "$copy" ]; then
      ck_hash=$(sqlite_checkpointed_hash "$copy")
      size=$(utils_file_size "$db_path")
      mtime=$(utils_file_mtime_iso "$db_path")
      local wal_info wp wh
      wal_info=$(sqlite_wal_sidecar_info "$db_path")
      [ -n "$wal_info" ] || wal_info='{"wal_present": false, "wal_sha256": ""}'
      wp=$(printf '%s' "$wal_info" | jq -r '.wal_present' 2>/dev/null)
      wh=$(printf '%s' "$wal_info" | jq -r '.wal_sha256' 2>/dev/null)
      case "$wp" in true|false) wal_present="$wp" ;; *) wal_present=false ;; esac
      wal_hash="$wh"

      # authority — PK is id (INTEGER). Use columns via PRAGMA.
      local auth_cols auth_snap
      auth_cols=$(_sysdb_columns_of "$copy" "authority")
      if [ -n "$auth_cols" ]; then
        auth_snap=$(sqlite_snapshot_table "$copy" "authority" "id" "$auth_cols")
        if [ -n "$auth_snap" ]; then
          table_snapshots=$(printf '%s' "$table_snapshots" | jq -c \
            --argjson s "$auth_snap" '. + {authority: $s}' 2>/dev/null)
          [ -n "$table_snapshots" ] || table_snapshots='{}'
        fi
      fi
      # bookmarkhints — no guaranteed PK; use full column set.
      local bh_cols bh_snap
      bh_cols=$(_sysdb_columns_of "$copy" "bookmarkhints")
      if [ -n "$bh_cols" ]; then
        bh_snap=$(sqlite_snapshot_table "$copy" "bookmarkhints" "$bh_cols" "$bh_cols")
        if [ -n "$bh_snap" ]; then
          table_snapshots=$(printf '%s' "$table_snapshots" | jq -c \
            --argjson s "$bh_snap" '. + {bookmarkhints: $s}' 2>/dev/null)
          [ -n "$table_snapshots" ] || table_snapshots='{}'
        fi
      fi
    else
      utils_log_err "sysdb_capture_systempolicy: sqlite_safe_copy failed for '${db_path}'"
    fi
    content=$(jq -cn --argjson gk "$gatekeeper" '{gatekeeper: $gk}')
  else
    # No privilege: still emit the entry with spctl output but flag
    # the skipped DB read. The manifest consumer can see the skip
    # via content.skipped_db.
    content=$(jq -cn --argjson gk "$gatekeeper" \
      '{gatekeeper: $gk, skipped_db: "no-sudo"}')
  fi

  [ -n "$content" ] || content='{}'

  local entry
  entry=$(manifest_build_entry \
    --path "$db_path" \
    --tier 3 \
    --surface "systempolicy" \
    --format sqlite \
    --sha256-raw "" \
    --sha256-canonical "" \
    --size "${size:-}" \
    --mtime "${mtime:-}" \
    --xattrs-json '{}' \
    --content-json "$content" \
    --sha256-checkpointed "$ck_hash" \
    --wal-present "$wal_present" \
    --wal-sha256 "$wal_hash" \
    --table-snapshots-json "$table_snapshots" \
    --anomalies-json "$anomalies")
  if [ -z "$entry" ]; then
    utils_log_err "sysdb_capture_systempolicy: manifest_build_entry failed for '${db_path}'"
    return 1
  fi

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# =============================================================================
# Section 4 — Authorization DB capture
# =============================================================================
# The authorization database is macOS's policy layer for privileged
# operations (login, Preferences unlock, install). Rules and rights
# are exposed via `security authorizationdb read <name>`, which emits
# an XML plist on stdout. We pipe that XML through
# `plutil -convert json -o - -` and then through
# `utils_canonical_json_stdin` to produce canonical JSON; the
# canonical bytes' SHA-256 becomes `sha256_canonical`.
#
# The `content` field on each emitted entry carries the subset of
# fields macaudit cares about:
#   * mechanisms — array of "<prefix>:<name>" strings
#   * class      — "evaluate-mechanisms", "rule", etc
#   * shared     — bool
#   * timeout    — int
#   * tries      — int
# Only fields that exist in the source plist are included.
#
# For every mechanism we call sysdb_classify_mechanism and emit
# anomalies:
#   * authdb_third_party_plugin (warn) per third-party-plugin mech
#   * authdb_missing_plugin     (high) per missing mech
#
# FDA is not required. Some rights may fail to read (system-restricted);
# those are logged and skipped (no zombie entry in the manifest).

# sysdb_authdb_rule_names
#   stdout: one authorization rule name per line. Empty in Phase 1 —
#           rights are more useful. Kept as a function so the
#           correlation pass can union rule_names with right_names.
sysdb_authdb_rule_names() {
  : # intentionally empty in Phase 1
}

# sysdb_authdb_right_names
#   stdout: the curated list of authorization right names to snapshot.
sysdb_authdb_right_names() {
  printf '%s\n' system.login.console
  printf '%s\n' system.privilege.admin
  printf '%s\n' system.preferences
  printf '%s\n' system.install.apple-software
  printf '%s\n' com.apple.ServiceManagement
}

# _sysdb_security_read <name>
#   stdout: XML plist bytes emitted by `security authorizationdb
#           read <name>`. Returns the command's exit code so the
#           caller can distinguish "command ran, returned nothing"
#           from "command failed".
#
#   Honours SECURITY_CMD_OVERRIDE (path to a shim) so tests can
#   provide fixture output without touching the real authorization
#   database. The override shim is called with the same argv as the
#   real binary (`authorizationdb read <name>` etc).
_sysdb_security_read() {
  local name="$1"
  local cmd="${SECURITY_CMD_OVERRIDE:-security}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 127
  fi
  # security emits the plist on stdout and status lines on stderr;
  # only the plist is useful.
  "$cmd" authorizationdb read "$name" 2>/dev/null
}

# _sysdb_authdb_anomalies <mechanisms_json>
#   stdout: JSON array of anomaly objects — one per non-builtin
#           mechanism whose classification is third-party-plugin or
#           missing. Empty array when every mechanism resolves to
#           builtin or system-plugin.
_sysdb_authdb_anomalies() {
  local mechanisms="$1"
  [ -n "$mechanisms" ] || mechanisms='[]'

  # Extract one mechanism per line so we can classify each one via
  # the shell function (jq has no direct access to the classifier).
  local mechs
  mechs=$(printf '%s' "$mechanisms" | jq -r 'if type == "array" then .[] else empty end' 2>/dev/null)
  if [ -z "$mechs" ]; then
    printf '%s\n' '[]'
    return 0
  fi

  local anomalies='[]'
  local m cls anom
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    cls=$(sysdb_classify_mechanism "$m")
    case "$cls" in
      third-party-plugin)
        anom=$(jq -cn --arg m "$m" '{
          rule: "authdb_third_party_plugin",
          severity: "warn",
          detail: ($m + " resolves to /Library/Security/SecurityAgentPlugins/")
        }')
        anomalies=$(printf '%s' "$anomalies" | jq -c --argjson a "$anom" '. + [$a]' 2>/dev/null)
        ;;
      missing)
        anom=$(jq -cn --arg m "$m" '{
          rule: "authdb_missing_plugin",
          severity: "high",
          detail: ($m + " does not resolve to any plugin bundle")
        }')
        anomalies=$(printf '%s' "$anomalies" | jq -c --argjson a "$anom" '. + [$a]' 2>/dev/null)
        ;;
    esac
    [ -n "$anomalies" ] || anomalies='[]'
  done <<EOF
$mechs
EOF

  printf '%s\n' "$anomalies"
}

# _sysdb_capture_authdb_one <name> <scratch>
#   Capture a single authorization rule/right <name>. Returns 0 on
#   success (one entry appended to <scratch>), 1 when the `security`
#   read fails or the plist cannot be canonicalised.
_sysdb_capture_authdb_one() {
  local name="$1"
  local scratch="$2"

  [ -n "$name" ]    || return 1
  [ -n "$scratch" ] || return 1

  local xml
  xml=$(_sysdb_security_read "$name")
  if [ -z "$xml" ]; then
    utils_log_warn "sysdb_capture_authdb: 'security authorizationdb read ${name}' returned no output; skipping"
    return 1
  fi

  # Convert XML -> JSON via plutil, then canonicalise.
  local json_raw canonical
  json_raw=$(printf '%s' "$xml" | plutil -convert json -o - -- - 2>/dev/null)
  if [ -z "$json_raw" ]; then
    utils_log_warn "sysdb_capture_authdb: plutil rejected authorizationdb output for '${name}'; skipping"
    return 1
  fi
  canonical=$(printf '%s' "$json_raw" | utils_canonical_json_stdin)
  if [ -z "$canonical" ]; then
    utils_log_warn "sysdb_capture_authdb: canonical JSON empty for '${name}'; skipping"
    return 1
  fi

  local sha_canon
  sha_canon=$(printf '%s\n' "$canonical" | utils_sha256_stdin)

  # Project the subset of fields we care about.
  local content
  content=$(printf '%s' "$canonical" | jq -c '{
    mechanisms: (.mechanisms // null),
    class:      (.class // null),
    shared:     (.shared // null),
    timeout:    (.timeout // null),
    tries:      (.tries // null)
  } | with_entries(select(.value != null))' 2>/dev/null)
  [ -n "$content" ] || content='{}'

  local mechs
  mechs=$(printf '%s' "$content" | jq -c '(.mechanisms // [])' 2>/dev/null)
  [ -n "$mechs" ] || mechs='[]'

  local anomalies
  anomalies=$(_sysdb_authdb_anomalies "$mechs")
  [ -n "$anomalies" ] || anomalies='[]'

  # authdb entries are not SQLite, so we deliberately do NOT pass any
  # --sha256-checkpointed / --table-snapshots-json flags. But
  # manifest_build_entry requires the SQLite extension when we want
  # an anomalies[] field in a non-XProtect tier3 entry — so we pass
  # --sha256-checkpointed "" / --wal-present false / empty table
  # snapshots just to coax the array into the output shape.
  local path="security://authorizationdb/${name}"
  local entry
  entry=$(manifest_build_entry \
    --path "$path" \
    --tier 3 \
    --surface "authdb" \
    --format authdb \
    --sha256-raw "" \
    --sha256-canonical "$sha_canon" \
    --size "" \
    --mtime "" \
    --xattrs-json '{}' \
    --content-json "$content" \
    --sha256-checkpointed "" \
    --wal-present false \
    --wal-sha256 "" \
    --table-snapshots-json '{}' \
    --anomalies-json "$anomalies")
  if [ -z "$entry" ]; then
    utils_log_err "sysdb_capture_authdb: manifest_build_entry failed for '${name}'"
    return 1
  fi
  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# sysdb_capture_authdb <scratch_entries_file>
#   Capture every curated rule/right name. Emits one entry per name
#   into <scratch>. Returns 0 when at least one name succeeded; 1
#   when every name failed (unusual but possible in sandboxed CI).
sysdb_capture_authdb() {
  local scratch="$1"

  if [ -z "$scratch" ]; then
    utils_log_err "sysdb_capture_authdb: scratch entries file is required"
    return 1
  fi

  local names
  names=$( { sysdb_authdb_rule_names; sysdb_authdb_right_names; } 2>/dev/null)
  if [ -z "$names" ]; then
    return 0
  fi

  local any=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if _sysdb_capture_authdb_one "$name" "$scratch"; then
      any=1
    fi
  done <<EOF
$names
EOF

  if [ "$any" -eq 0 ]; then
    return 1
  fi
  return 0
}

# =============================================================================
# Section 5 — Mechanism classification + plugin listing cache
# =============================================================================
# The classifier maps a "<prefix>:<name>" mechanism string to one of
# four categories: builtin, system-plugin, third-party-plugin,
# missing. It is the pure-function soul of the R5 correlation rule
# and of the authdb_third_party_plugin / authdb_missing_plugin
# anomalies.
#
# The classifier is deliberately a total function over non-empty
# strings with a colon; for malformed input (empty, no colon) it
# emits empty stdout. P21 validates this totality + determinism.
#
# The plugin-directory listings are cached in the single string
# variable `MACAUDIT_PLUGIN_LISTING` for the life of the process.
# First call populates the cache by enumerating both well-known
# directories (or their overrides); subsequent calls read the cache.
# The cache stores the listing in a deterministic format:
#
#   <flag><SP><bundle_name>\n
#
# where <flag> is `S` for system-bundle entries or `T` for
# third-party. A single `grep -Fxq` over the cache answers both
# classification queries in O(N) without re-reading the filesystem.

_SYSDB_PLUGIN_LISTING_FLAG_SYSTEM="S"
_SYSDB_PLUGIN_LISTING_FLAG_THIRD="T"

_SYSDB_DEFAULT_SYSTEM_PLUGIN_DIR="/System/Library/CoreServices/SecurityAgentPlugins"
_SYSDB_DEFAULT_THIRD_PLUGIN_DIR="/Library/Security/SecurityAgentPlugins"

# sysdb_plugin_listing_reset
#   Drop the memoised plugin listing. Tests call this between
#   scenarios so each example sees a freshly-populated cache derived
#   from the current override values.
sysdb_plugin_listing_reset() {
  unset MACAUDIT_PLUGIN_LISTING
}

# _sysdb_populate_plugin_listing
#   Internal: build the plugin listing cache from the system and
#   third-party directories (honouring overrides). Idempotent.
_sysdb_populate_plugin_listing() {
  if [ -n "${MACAUDIT_PLUGIN_LISTING+x}" ]; then
    return 0
  fi

  local sys_dir="${SYSTEM_PLUGIN_DIR_OVERRIDE:-$_SYSDB_DEFAULT_SYSTEM_PLUGIN_DIR}"
  local third_dir="${THIRD_PARTY_PLUGIN_DIR_OVERRIDE:-$_SYSDB_DEFAULT_THIRD_PLUGIN_DIR}"

  local listing=""

  # System plugins first so precedence is implicit via iteration order
  # (the classifier checks system lines first).
  if [ -d "$sys_dir" ]; then
    local entry name
    for entry in "$sys_dir"/*.bundle "$sys_dir"/*.plugin; do
      [ -e "$entry" ] || continue
      name=$(basename -- "$entry")
      # Strip trailing .bundle/.plugin so the listing stores the
      # prefix (the mechanism's <prefix>).
      case "$name" in
        *.bundle) name="${name%.bundle}" ;;
        *.plugin) name="${name%.plugin}" ;;
      esac
      [ -n "$name" ] || continue
      listing="${listing}${_SYSDB_PLUGIN_LISTING_FLAG_SYSTEM} ${name}
"
    done
  fi

  if [ -d "$third_dir" ]; then
    local entry name
    for entry in "$third_dir"/*.bundle "$third_dir"/*.plugin; do
      [ -e "$entry" ] || continue
      name=$(basename -- "$entry")
      case "$name" in
        *.bundle) name="${name%.bundle}" ;;
        *.plugin) name="${name%.plugin}" ;;
      esac
      [ -n "$name" ] || continue
      listing="${listing}${_SYSDB_PLUGIN_LISTING_FLAG_THIRD} ${name}
"
    done
  fi

  MACAUDIT_PLUGIN_LISTING="$listing"
  export MACAUDIT_PLUGIN_LISTING
}

# sysdb_plugin_dirs_listing
#   stdout: the cached plugin directory listing, one `<flag> <name>`
#           token per line. Empty when neither directory exists.
#           Exposed so the correlation pass (R5) can reuse the same
#           cache instead of rebuilding its own.
sysdb_plugin_dirs_listing() {
  _sysdb_populate_plugin_listing
  printf '%s' "${MACAUDIT_PLUGIN_LISTING:-}"
}

# sysdb_classify_mechanism <mechanism>
#   stdout: exactly one of {builtin, system-plugin, third-party-plugin,
#           missing}. Empty stdout when the input is empty or contains
#           no colon (malformed).
#
#   Rule (per design.md Mechanism Classification):
#     prefix starts with "builtin"               → builtin
#     else <prefix>.bundle ∈ system plugin dir   → system-plugin
#     else <prefix>.bundle ∈ third-party dir     → third-party-plugin
#     else                                       → missing
#
#   System precedence over third-party is intentional: if the same
#   prefix exists in both directories the system copy wins (a
#   defence-in-depth assumption — a legitimate system-provided plugin
#   cannot be masqueraded by a same-name third-party drop-in).
sysdb_classify_mechanism() {
  local mech="$1"

  if [ -z "$mech" ]; then
    return 0
  fi

  # Must contain a colon to be a valid "<prefix>:<name>" mechanism.
  case "$mech" in
    *:*) : ;;
    *) return 0 ;;
  esac

  local prefix="${mech%%:*}"
  if [ -z "$prefix" ]; then
    return 0
  fi

  if [ "$prefix" = "builtin" ]; then
    printf '%s\n' builtin
    return 0
  fi

  _sysdb_populate_plugin_listing
  local listing="${MACAUDIT_PLUGIN_LISTING:-}"

  # Check system precedence first.
  if [ -n "$listing" ]; then
    if printf '%s' "$listing" | grep -Fxq -- "${_SYSDB_PLUGIN_LISTING_FLAG_SYSTEM} ${prefix}"; then
      printf '%s\n' system-plugin
      return 0
    fi
    if printf '%s' "$listing" | grep -Fxq -- "${_SYSDB_PLUGIN_LISTING_FLAG_THIRD} ${prefix}"; then
      printf '%s\n' third-party-plugin
      return 0
    fi
  fi

  printf '%s\n' missing
}
