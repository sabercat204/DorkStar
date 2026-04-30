#!/bin/bash
# lib/manifest.sh — JSONL read/write helpers, header serialization, and
# per-entry path-keyed lookup via streaming jq over a scratch entries file.
#
# The manifest is a JSONL file:
#   Line 1        = header JSON object (schema: design.md §Manifest Header).
#   Lines 2..N    = entry JSON objects, one per audited artefact.
#
# Every serializer here composes JSON via `jq -cn` with `--arg` / `--argjson`
# so that caller-supplied strings, numbers, booleans, arrays, and objects are
# escaped safely. No function interpolates user input directly into a jq
# filter string. Output is always a single compact line terminated by `\n`.
#
# Streaming is mandatory: callers must never slurp the entries portion of a
# manifest into a bash variable. `manifest_entries` and `manifest_entry_by_path`
# both read the manifest via `tail -n +2 | jq` so memory stays bounded
# regardless of manifest size.
#
# bash 3.2 compatibility: no associative arrays, no `mapfile`/`readarray`.
# All per-line iteration uses `while IFS= read -r line; do ... done` loops.
# All error messages go to stderr via `utils_log_err` (defined in lib/utils.sh).

# =============================================================================
# Section 1: Header construction
# =============================================================================
# `manifest_build_header` composes the single-line header JSON from flag-style
# arguments. Defaults are populated from lib/utils.sh helpers so callers that
# only need the standard shape can pass no flags apart from the required
# --tier / --user-only pair. The --has-tier3 toggle upgrades the version
# fields to the 1.1 / tier3 variants described in design.md §Amended Manifest
# Header.

# manifest_build_header [flags]
#   See file banner for the full flag list. Emits a compact one-line JSON
#   object on stdout. Returns 1 on any validation failure.
manifest_build_header() {
  local manifest_version=""
  local tool_version=""
  local timestamp=""
  local hostname=""
  local os_version=""
  local os_major=""
  local sip_status=""
  local ssv_status=""
  local tier=""
  local user_only=""
  local fda_available="null"
  local environment_json="null"
  local skipped_json="[]"
  local has_tier3=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest-version) manifest_version="$2"; shift 2 ;;
      --tool-version)     tool_version="$2";     shift 2 ;;
      --timestamp)        timestamp="$2";        shift 2 ;;
      --hostname)         hostname="$2";         shift 2 ;;
      --os-version)       os_version="$2";       shift 2 ;;
      --os-major)         os_major="$2";         shift 2 ;;
      --sip-status)       sip_status="$2";       shift 2 ;;
      --ssv-status)       ssv_status="$2";       shift 2 ;;
      --tier)             tier="$2";             shift 2 ;;
      --user-only)        user_only="$2";        shift 2 ;;
      --fda-available)    fda_available="$2";    shift 2 ;;
      --environment-json) environment_json="$2"; shift 2 ;;
      --skipped-json)     skipped_json="$2";     shift 2 ;;
      --has-tier3)        has_tier3=1;           shift 1 ;;
      *)
        utils_log_err "manifest_build_header: unknown flag '$1'"
        return 1
        ;;
    esac
  done

  # Required fields.
  if [ -z "$tier" ]; then
    utils_log_err "manifest_build_header: --tier is required"
    return 1
  fi
  case "$tier" in
    1|2|3|all) : ;;
    *)
      utils_log_err "manifest_build_header: invalid --tier '$tier' (expected 1, 2, 3, or all)"
      return 1
      ;;
  esac

  if [ -z "$user_only" ]; then
    utils_log_err "manifest_build_header: --user-only is required"
    return 1
  fi
  case "$user_only" in
    true|false) : ;;
    *)
      utils_log_err "manifest_build_header: invalid --user-only '$user_only' (expected true or false)"
      return 1
      ;;
  esac

  # Version defaults — auto-upgrade when Tier 3 ran.
  if [ -z "$manifest_version" ]; then
    if [ "$has_tier3" -eq 1 ]; then
      manifest_version="1.1"
    else
      manifest_version="1.0"
    fi
  fi
  if [ -z "$tool_version" ]; then
    if [ "$has_tier3" -eq 1 ]; then
      tool_version="0.1.0-phase1-tier3"
    else
      tool_version="0.1.0-phase1"
    fi
  fi

  # Environment defaults populated from utils.sh.
  [ -n "$timestamp" ]  || timestamp=$(utils_iso_now)
  [ -n "$hostname" ]   || hostname=$(utils_hostname)
  [ -n "$os_version" ] || os_version=$(utils_os_version)
  [ -n "$os_major" ]   || os_major=$(utils_os_major)
  [ -n "$sip_status" ] || sip_status=$(utils_sip_status)
  [ -n "$ssv_status" ] || ssv_status=$(utils_ssv_status)

  # Validate typed literals.
  case "$fda_available" in
    true|false|null) : ;;
    *)
      utils_log_err "manifest_build_header: invalid --fda-available '$fda_available' (expected true, false, or null)"
      return 1
      ;;
  esac

  # os_major is a JSON number when non-empty, null when empty. We coerce
  # empty / non-numeric values to `null` so --argjson stays happy.
  local os_major_json
  if [ -z "$os_major" ]; then
    os_major_json="null"
  else
    case "$os_major" in
      *[!0-9]*) os_major_json="null" ;;
      *)        os_major_json="$os_major" ;;
    esac
  fi

  # Structural JSON blobs are passed through --argjson; validate them up-front
  # so a malformed blob is surfaced here rather than inside the final jq call.
  # Use `jq .` (no -e) because `null` is valid JSON but falsy under -e.
  if ! printf '%s' "$environment_json" | jq . >/dev/null 2>&1; then
    utils_log_err "manifest_build_header: --environment-json is not valid JSON"
    return 1
  fi
  if ! printf '%s' "$skipped_json" | jq . >/dev/null 2>&1; then
    utils_log_err "manifest_build_header: --skipped-json is not valid JSON"
    return 1
  fi

  jq -cn \
    --arg    manifest_version "$manifest_version" \
    --arg    tool             "macaudit" \
    --arg    tool_version     "$tool_version" \
    --arg    timestamp        "$timestamp" \
    --arg    hostname         "$hostname" \
    --arg    os_version       "$os_version" \
    --argjson os_major        "$os_major_json" \
    --arg    sip_status       "$sip_status" \
    --arg    ssv_status       "$ssv_status" \
    --arg    tier             "$tier" \
    --argjson user_only       "$user_only" \
    --argjson fda_available   "$fda_available" \
    --argjson environment     "$environment_json" \
    --argjson skipped_paths   "$skipped_json" \
    '{
       manifest_version: $manifest_version,
       tool:             $tool,
       tool_version:     $tool_version,
       timestamp:        $timestamp,
       hostname:         $hostname,
       os_version:       $os_version,
       os_major:         $os_major,
       sip_status:       $sip_status,
       ssv_status:       $ssv_status,
       tier:             $tier,
       user_only:        $user_only,
       fda_available:    $fda_available,
       environment:      $environment,
       skipped_paths:    $skipped_paths
     }'
}

# manifest_write_header <out_path> <header_json>
#   Writes $2 as the FIRST line of $1. Fails when $1 already exists and is
#   non-empty — the header must appear before any entry.
manifest_write_header() {
  local out_path="$1"
  local header_json="$2"

  if [ -z "$out_path" ]; then
    utils_log_err "manifest_write_header: output path required"
    return 1
  fi
  if [ -z "$header_json" ]; then
    utils_log_err "manifest_write_header: header JSON required"
    return 1
  fi

  # The header must parse as a single JSON value.
  if ! printf '%s' "$header_json" | jq -e . >/dev/null 2>&1; then
    utils_log_err "manifest_write_header: header JSON does not parse"
    return 1
  fi

  if [ -e "$out_path" ] && [ -s "$out_path" ]; then
    utils_log_err "manifest_write_header: '$out_path' already has content; header must be the first line"
    return 1
  fi

  printf '%s\n' "$header_json" > "$out_path"
}

# =============================================================================
# Section 2: Entry construction
# =============================================================================
# `manifest_build_entry` composes one entry line. Tier 1 / Tier 2 fields are
# always emitted; Tier 3 fields (SQLite snapshots, XProtect bundle files,
# anomaly arrays) are only emitted when the caller passes the corresponding
# flags. Boolean-or-null fields (`cfprefsd_match`, `launchctl_loaded`,
# `btm_registered`, `wal_present`) accept exactly `true`, `false`, or `null`
# and are emitted via `--argjson` so they land as literal JSON values, not
# strings.

# __manifest_validate_tri_bool <flag-name> <value>
#   Helper: accept `true` | `false` | `null` only. Emits an error to stderr
#   and returns 1 for anything else.
__manifest_validate_tri_bool() {
  local flag="$1"
  local val="$2"
  case "$val" in
    true|false|null) return 0 ;;
    *)
      utils_log_err "manifest_build_entry: invalid $flag '$val' (expected true, false, or null)"
      return 1
      ;;
  esac
}

# __manifest_default_format_for <tier> <surface>
#   Helper: produce a default --format value for a (tier, surface) pair when
#   the caller did not supply one. Tier 3 surfaces have well-known defaults
#   documented in design.md; all other combinations return empty so the
#   caller's explicit --format remains required.
__manifest_default_format_for() {
  local tier="$1"
  local surface="$2"
  if [ "$tier" != "3" ]; then
    return 0
  fi
  case "$surface" in
    tcc_system|tcc_user|kextpolicy|execpolicy|systempolicy|quarantine_events)
      printf '%s\n' sqlite ;;
    xprotect)
      printf '%s\n' bundle ;;
    authdb)
      printf '%s\n' authdb ;;
    correlation)
      printf '%s\n' n/a ;;
    *)
      : ;;
  esac
}

# manifest_build_entry [flags]
#   Compose a single-line entry JSON. See file banner for the full flag list.
#   Returns 1 on any validation failure.
manifest_build_entry() {
  local path=""
  local tier=""
  local surface=""
  local format=""
  local sha256_raw=""
  local sha256_canonical=""
  local size=""
  local mtime=""
  local xattrs_json="{}"
  local content_json="{}"
  local cfprefsd_match="null"
  local launchctl_loaded="null"
  local btm_registered="null"
  # Tier 3 SQLite-specific.
  local have_sha256_checkpointed=0 sha256_checkpointed=""
  local have_wal_present=0        wal_present="false"
  local have_wal_sha256=0         wal_sha256=""
  local have_table_snapshots=0    table_snapshots_json="{}"
  local have_anomalies=0          anomalies_json="[]"
  # Tier 3 XProtect-specific.
  local have_bundle_version=0     bundle_version=""
  local have_files=0              files_json="{}"
  local have_codesign=0           codesign_json="{}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --path)              path="$2";              shift 2 ;;
      --tier)              tier="$2";              shift 2 ;;
      --surface)           surface="$2";           shift 2 ;;
      --format)            format="$2";            shift 2 ;;
      --sha256-raw)        sha256_raw="$2";        shift 2 ;;
      --sha256-canonical)  sha256_canonical="$2";  shift 2 ;;
      --size)              size="$2";              shift 2 ;;
      --mtime)             mtime="$2";             shift 2 ;;
      --xattrs-json)       xattrs_json="$2";       shift 2 ;;
      --content-json)      content_json="$2";      shift 2 ;;
      --cfprefsd-match)    cfprefsd_match="$2";    shift 2 ;;
      --launchctl-loaded)  launchctl_loaded="$2";  shift 2 ;;
      --btm-registered)    btm_registered="$2";    shift 2 ;;
      --sha256-checkpointed)
        have_sha256_checkpointed=1; sha256_checkpointed="$2"; shift 2 ;;
      --wal-present)
        have_wal_present=1;         wal_present="$2";         shift 2 ;;
      --wal-sha256)
        have_wal_sha256=1;          wal_sha256="$2";          shift 2 ;;
      --table-snapshots-json)
        have_table_snapshots=1;     table_snapshots_json="$2"; shift 2 ;;
      --anomalies-json)
        have_anomalies=1;           anomalies_json="$2";      shift 2 ;;
      --bundle-version)
        have_bundle_version=1;      bundle_version="$2";      shift 2 ;;
      --files-json)
        have_files=1;               files_json="$2";          shift 2 ;;
      --codesign-json)
        have_codesign=1;            codesign_json="$2";       shift 2 ;;
      *)
        utils_log_err "manifest_build_entry: unknown flag '$1'"
        return 1
        ;;
    esac
  done

  # Required fields.
  if [ -z "$path" ]; then
    utils_log_err "manifest_build_entry: --path is required"
    return 1
  fi
  if [ -z "$tier" ]; then
    utils_log_err "manifest_build_entry: --tier is required"
    return 1
  fi
  case "$tier" in
    1|2|3) : ;;
    *)
      utils_log_err "manifest_build_entry: invalid --tier '$tier' (expected 1, 2, or 3)"
      return 1
      ;;
  esac
  if [ -z "$surface" ]; then
    utils_log_err "manifest_build_entry: --surface is required and must be non-empty"
    return 1
  fi

  # --format: accept caller override, otherwise fall back to tier3 default,
  # otherwise require an explicit value.
  if [ -z "$format" ]; then
    format=$(__manifest_default_format_for "$tier" "$surface")
  fi
  if [ -z "$format" ]; then
    utils_log_err "manifest_build_entry: --format is required for (tier=$tier, surface=$surface)"
    return 1
  fi
  case "$format" in
    binary|xml|json|invalid|sqlite|bundle|authdb|n/a) : ;;
    *)
      utils_log_err "manifest_build_entry: invalid --format '$format'"
      return 1
      ;;
  esac

  # Tri-bool validation.
  __manifest_validate_tri_bool --cfprefsd-match   "$cfprefsd_match"   || return 1
  __manifest_validate_tri_bool --launchctl-loaded "$launchctl_loaded" || return 1
  __manifest_validate_tri_bool --btm-registered   "$btm_registered"   || return 1

  # Validate structural JSON blobs up-front. Use plain `jq .` (no -e) because
  # `{}` / `[]` are legitimate inputs that `-e` would treat as falsy.
  if ! printf '%s' "$xattrs_json" | jq . >/dev/null 2>&1; then
    utils_log_err "manifest_build_entry: --xattrs-json is not valid JSON"
    return 1
  fi
  if ! printf '%s' "$content_json" | jq . >/dev/null 2>&1; then
    utils_log_err "manifest_build_entry: --content-json is not valid JSON"
    return 1
  fi

  # Size: empty → null, otherwise must be an integer.
  local size_json
  if [ -z "$size" ]; then
    size_json="null"
  else
    case "$size" in
      *[!0-9]*)
        utils_log_err "manifest_build_entry: invalid --size '$size' (expected integer or empty)"
        return 1
        ;;
      *)
        size_json="$size"
        ;;
    esac
  fi

  # Tier: always a JSON number.
  local tier_json="$tier"

  # Compose the Tier 1/2 base object.
  local base
  base=$(jq -cn \
    --arg     path              "$path" \
    --argjson tier              "$tier_json" \
    --arg     surface           "$surface" \
    --arg     format            "$format" \
    --arg     sha256_raw        "$sha256_raw" \
    --arg     sha256_canonical  "$sha256_canonical" \
    --argjson size_bytes        "$size_json" \
    --arg     mtime             "$mtime" \
    --argjson xattrs            "$xattrs_json" \
    --argjson content           "$content_json" \
    --argjson cfprefsd_match    "$cfprefsd_match" \
    --argjson launchctl_loaded  "$launchctl_loaded" \
    --argjson btm_registered    "$btm_registered" \
    '{
       path:             $path,
       tier:             $tier,
       surface:          $surface,
       format:           $format,
       sha256_raw:       $sha256_raw,
       sha256_canonical: $sha256_canonical,
       size_bytes:       $size_bytes,
       mtime:            $mtime,
       xattrs:           $xattrs,
       content:          $content,
       cfprefsd_match:   $cfprefsd_match,
       launchctl_loaded: $launchctl_loaded,
       btm_registered:   $btm_registered
     }')
  if [ -z "$base" ]; then
    utils_log_err "manifest_build_entry: jq composition failed for base entry"
    return 1
  fi

  # Tier 3 SQLite extension.
  local want_sqlite_ext=0
  if [ "$have_sha256_checkpointed" -eq 1 ] \
      || [ "$have_wal_present" -eq 1 ] \
      || [ "$have_wal_sha256" -eq 1 ] \
      || [ "$have_table_snapshots" -eq 1 ] \
      || [ "$have_anomalies" -eq 1 ]; then
    want_sqlite_ext=1
  fi

  if [ "$want_sqlite_ext" -eq 1 ]; then
    case "$wal_present" in
      true|false) : ;;
      *)
        utils_log_err "manifest_build_entry: invalid --wal-present '$wal_present' (expected true or false)"
        return 1
        ;;
    esac
    if ! printf '%s' "$table_snapshots_json" | jq . >/dev/null 2>&1; then
      utils_log_err "manifest_build_entry: --table-snapshots-json is not valid JSON"
      return 1
    fi
    if ! printf '%s' "$anomalies_json" | jq . >/dev/null 2>&1; then
      utils_log_err "manifest_build_entry: --anomalies-json is not valid JSON"
      return 1
    fi
    base=$(printf '%s' "$base" | jq -c \
      --arg     sha256_checkpointed "$sha256_checkpointed" \
      --argjson wal_present         "$wal_present" \
      --arg     wal_sha256          "$wal_sha256" \
      --argjson table_snapshots     "$table_snapshots_json" \
      --argjson anomalies           "$anomalies_json" \
      '. + {
         sha256_checkpointed: $sha256_checkpointed,
         wal_present:         $wal_present,
         wal_sha256:          $wal_sha256,
         table_snapshots:     $table_snapshots,
         anomalies:           $anomalies
       }')
    if [ -z "$base" ]; then
      utils_log_err "manifest_build_entry: jq composition failed for SQLite extension"
      return 1
    fi
  fi

  # Tier 3 XProtect extension.
  local want_xprotect_ext=0
  if [ "$have_bundle_version" -eq 1 ] \
      || [ "$have_files" -eq 1 ] \
      || [ "$have_codesign" -eq 1 ]; then
    want_xprotect_ext=1
  fi

  if [ "$want_xprotect_ext" -eq 1 ]; then
    if ! printf '%s' "$files_json" | jq . >/dev/null 2>&1; then
      utils_log_err "manifest_build_entry: --files-json is not valid JSON"
      return 1
    fi
    if ! printf '%s' "$codesign_json" | jq . >/dev/null 2>&1; then
      utils_log_err "manifest_build_entry: --codesign-json is not valid JSON"
      return 1
    fi
    # XProtect entries also carry an anomalies[] array. If the caller did
    # not already supply one via --anomalies-json above, attach the default.
    if [ "$have_anomalies" -eq 0 ] && [ "$want_sqlite_ext" -eq 0 ]; then
      if ! printf '%s' "$anomalies_json" | jq . >/dev/null 2>&1; then
        utils_log_err "manifest_build_entry: --anomalies-json default is not valid JSON"
        return 1
      fi
      base=$(printf '%s' "$base" | jq -c \
        --arg     bundle_version "$bundle_version" \
        --argjson files          "$files_json" \
        --argjson codesign       "$codesign_json" \
        --argjson anomalies      "$anomalies_json" \
        '. + {
           bundle_version: $bundle_version,
           files:          $files,
           codesign:       $codesign,
           anomalies:      $anomalies
         }')
    else
      base=$(printf '%s' "$base" | jq -c \
        --arg     bundle_version "$bundle_version" \
        --argjson files          "$files_json" \
        --argjson codesign       "$codesign_json" \
        '. + {
           bundle_version: $bundle_version,
           files:          $files,
           codesign:       $codesign
         }')
    fi
    if [ -z "$base" ]; then
      utils_log_err "manifest_build_entry: jq composition failed for XProtect extension"
      return 1
    fi
  fi

  printf '%s\n' "$base"
}

# manifest_write_entry <out_path> <entry_json>
#   Append $2 as a single JSONL line to $1. Fails when $2 does not parse.
manifest_write_entry() {
  local out_path="$1"
  local entry_json="$2"

  if [ -z "$out_path" ]; then
    utils_log_err "manifest_write_entry: output path required"
    return 1
  fi
  if [ -z "$entry_json" ]; then
    utils_log_err "manifest_write_entry: entry JSON required"
    return 1
  fi

  if ! printf '%s' "$entry_json" | jq -e . >/dev/null 2>&1; then
    utils_log_err "manifest_write_entry: entry JSON does not parse"
    return 1
  fi

  printf '%s\n' "$entry_json" >> "$out_path"
}

# =============================================================================
# Section 3: Manifest loading and path-keyed lookup (streaming)
# =============================================================================
# Readers deliberately stream: the header is one line (`head -n 1`); the
# entries are piped via `tail -n +2 | jq ...` so memory stays bounded.

# manifest_header <manifest_path>
#   stdout: first line of $1 (the header). Empty when $1 is missing / empty.
manifest_header() {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    return 0
  fi
  head -n 1 -- "$path" 2>/dev/null
}

# manifest_entries <manifest_path>
#   stdout: every line after the first, streamed via `tail -n +2`.
manifest_entries() {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    return 0
  fi
  tail -n +2 -- "$path" 2>/dev/null
}

# manifest_load <manifest_path>
#   Populate:
#     MACAUDIT_MANIFEST_HEADER       — the header JSON line (exported).
#     MACAUDIT_MANIFEST_ENTRIES_FILE — scratch file holding entry lines only
#                                      (exported). Lives under MACAUDIT_TMPDIR.
#   Returns 0 on success, 1 when the manifest is missing, 2 when the header
#   does not parse as JSON.
manifest_load() {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    utils_log_err "manifest_load: manifest '$path' does not exist"
    return 1
  fi

  local header
  header=$(head -n 1 -- "$path" 2>/dev/null)
  if [ -z "$header" ]; then
    utils_log_err "manifest_load: manifest '$path' is empty"
    return 2
  fi
  if ! printf '%s' "$header" | jq -e . >/dev/null 2>&1; then
    utils_log_err "manifest_load: header in '$path' does not parse as JSON"
    return 2
  fi

  # Ensure we have a scratch directory under MACAUDIT_TMPDIR.
  if [ -z "${MACAUDIT_TMPDIR:-}" ] || [ ! -d "${MACAUDIT_TMPDIR:-}" ]; then
    utils_tmpdir_init >/dev/null || return 1
  fi

  local scratch="${MACAUDIT_TMPDIR}/manifest.entries.$.jsonl"
  # Rewrite the scratch file for each load so sequential loads of different
  # manifests do not interfere.
  : > "$scratch" || {
    utils_log_err "manifest_load: unable to create scratch file '$scratch'"
    return 1
  }
  tail -n +2 -- "$path" >> "$scratch" 2>/dev/null || true

  MACAUDIT_MANIFEST_HEADER="$header"
  MACAUDIT_MANIFEST_ENTRIES_FILE="$scratch"
  export MACAUDIT_MANIFEST_HEADER
  export MACAUDIT_MANIFEST_ENTRIES_FILE
  return 0
}

# manifest_entry_by_path <manifest_path> <wanted_path>
#   stdout: the entry JSON line whose `.path` equals $2, or empty when no
#   match. Streams the entries via `tail -n +2 | jq -c` so large manifests
#   stay within bounded memory.
manifest_entry_by_path() {
  local path="$1"
  local wanted="$2"
  if [ -z "$path" ] || [ ! -f "$path" ] || [ -z "$wanted" ]; then
    return 0
  fi
  tail -n +2 -- "$path" 2>/dev/null | jq -c --arg p "$wanted" 'select(.path == $p)' 2>/dev/null
}

# manifest_header_value <manifest_path> <field>
#   stdout: the header field $2 rendered as a JSON value (scalars come out
#   quoted; booleans / nulls / numbers come out unquoted). Empty when the
#   manifest is missing or the field is absent.
manifest_header_value() {
  local path="$1"
  local field="$2"
  if [ -z "$path" ] || [ ! -f "$path" ] || [ -z "$field" ]; then
    return 0
  fi
  head -n 1 -- "$path" 2>/dev/null \
    | jq -c --arg f "$field" 'if has($f) then .[$f] else empty end' 2>/dev/null
}
