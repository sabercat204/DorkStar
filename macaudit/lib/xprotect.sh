#!/bin/bash
# lib/xprotect.sh — XProtect bundle capture: version extraction,
# per-file SHA-256, codesign verification, and the
# `xprotect_codesign_fail` anomaly rule (Requirements 22.6, 28.4, 28.6).
#
# XProtect is Apple's built-in signature-based malware blocker. The
# canonical bundle sits at
#   /Library/Apple/System/Library/CoreServices/XProtect.bundle
# and bundles four assets the tool captures for forensic baseline
# purposes:
#   - Contents/Info.plist                 — CFBundleShortVersionString
#                                            (the YARA rule version)
#   - Contents/Resources/XProtect.yara    — YARA rules
#   - Contents/Resources/XProtect.meta.plist — blocklist metadata
#   - Contents/Resources/gk.db            — Gatekeeper blocked-team-id db
#
# We hash every regular file under the bundle (not just the four above)
# so that any file Apple adds or removes in a future release is still
# captured; this is what drives design.md's P14 surface-partitioning
# invariant for Tier 3.
#
# Codesign: `utils_codesign_verify` (lib/utils.sh) is the single source
# of truth for codesign introspection. We call it on the bundle root
# and fire `xprotect_codesign_fail` (severity: high) whenever its
# `valid` field is false.
#
# Test hook: `XPROTECT_BUNDLE_OVERRIDE` when set replaces the default
# bundle path. Bats fixtures materialise a miniature bundle tree under
# a scratch dir and point the override at it so we never depend on
# Apple's real bundle being present or signed.
#
# bash 3.2 compatible: no associative arrays, no mapfile/readarray.
# No `set -euo pipefail` per house style. All errors routed through
# `utils_log_err`. Every stdout-producing function uses `printf '%s\n'`.

# =============================================================================
# Section 1 — Bundle path + version
# =============================================================================
# Thin helpers so callers (baseline.sh, tests) don't hardcode the bundle
# path and so the CFBundleShortVersionString extraction lives in one
# place with a documented empty-string-on-failure semantics.

# xprotect_bundle_path
#   stdout: absolute path to the XProtect bundle.
#
#   When XPROTECT_BUNDLE_OVERRIDE is set (test-only) its value takes
#   precedence so fixtures can stand in for the real bundle.
xprotect_bundle_path() {
  if [ -n "${XPROTECT_BUNDLE_OVERRIDE:-}" ]; then
    printf '%s\n' "$XPROTECT_BUNDLE_OVERRIDE"
    return 0
  fi
  printf '%s\n' "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
}

# xprotect_version <bundle>
#   stdout: CFBundleShortVersionString from <bundle>/Contents/Info.plist.
#           Empty when Info.plist is missing, unreadable, or doesn't have
#           the key. Never fails non-zero — the empty-string sentinel is
#           what callers splice into a manifest entry via `jq --arg`.
#
#   Implementation: `plutil -extract CFBundleShortVersionString raw
#   -o - -- <path>`. `raw` emits the scalar value with no surrounding
#   quotes, and `-o -` routes to stdout so we avoid a scratch file.
xprotect_version() {
  local bundle="$1"
  if [ -z "$bundle" ]; then
    return 0
  fi
  local info="${bundle}/Contents/Info.plist"
  if [ ! -r "$info" ]; then
    return 0
  fi
  local ver
  ver=$(plutil -extract CFBundleShortVersionString raw -o - -- "$info" 2>/dev/null) || return 0
  [ -n "$ver" ] || return 0
  # `plutil -extract ... raw` emits the value followed by a newline; strip
  # any trailing CR to stay robust if the source plist was mis-encoded.
  ver=$(printf '%s' "$ver" | tr -d '\r')
  printf '%s\n' "$ver"
}

# =============================================================================
# Section 2 — Bundle capture
# =============================================================================
# `xprotect_capture` walks every regular file under the bundle and
# emits ONE manifest entry summarising the whole bundle:
#   surface       = "xprotect"
#   format        = "bundle"
#   bundle_version = CFBundleShortVersionString
#   files         = {"<rel-path>": {"sha256_raw", "size_bytes"}, ...}
#   codesign      = utils_codesign_verify(bundle)
#   anomalies     = [xprotect_codesign_fail] when codesign.valid == false
#
# Bundle-level sha256_raw / sha256_canonical are empty strings — the
# bundle is a directory, not a file, so there is no canonical byte
# stream to hash. Per-file hashes live in the `files` map.
#
# Size caveat: `stat -f %z` on a directory returns the inode's own
# size (typically a small constant), NOT the sum of contents. The
# emitted `size_bytes` field is therefore informational only. Callers
# interested in aggregate size should sum `files[*].size_bytes`.

# _xprotect_build_files_map <bundle>
#   stdout: one-line JSON object mapping every regular file's
#           bundle-relative path to `{sha256_raw, size_bytes}`. Empty
#           object `{}` when the walk yields nothing.
#
#   Uses `find -L` so symlinks inside the bundle (rare but legal) are
#   followed; a broken symlink is skipped silently. The per-file jq
#   fragments are accumulated line-by-line and merged via
#   `jq -s 'add // {}'` so a jq error anywhere in the pipeline
#   degrades to the empty map rather than crashing the caller.
_xprotect_build_files_map() {
  local bundle="$1"
  [ -n "$bundle" ] || { printf '%s\n' '{}'; return 0; }
  if [ ! -d "$bundle" ]; then
    printf '%s\n' '{}'
    return 0
  fi

  # Strip a trailing slash so the `${path#$prefix/}` relativisation
  # below always leaves a clean relative path with no leading slash.
  local root="${bundle%/}"

  local fragments
  fragments=$(
    find -L "$root" -type f 2>/dev/null | while IFS= read -r path; do
      [ -n "$path" ] || continue
      # Compute bundle-relative path. `${path#$root/}` trims the
      # "bundle/" prefix; when `path == root` (can't happen for -type f
      # under a directory, but defensive anyway) fall back to basename.
      local rel
      if [ "$path" = "$root" ]; then
        rel=$(basename -- "$path")
      else
        rel="${path#${root}/}"
      fi
      local sha size
      sha=$(utils_sha256_file "$path")
      size=$(utils_file_size "$path")
      # size is empty when stat failed — coerce to an empty string so
      # jq --arg accepts it. We intentionally emit the literal empty
      # string rather than null because the manifest schema for the
      # files map uses string / number values and we need a uniform
      # shape across all files (per P14 stability).
      if [ -z "$size" ]; then
        size="0"
      fi
      # Build a {rel: {sha256_raw, size_bytes}} fragment.
      jq -cn \
        --arg rel "$rel" \
        --arg sha "$sha" \
        --argjson size "$size" \
        '{($rel): {sha256_raw: $sha, size_bytes: $size}}' 2>/dev/null || true
    done
  )

  if [ -z "$fragments" ]; then
    printf '%s\n' '{}'
    return 0
  fi

  local merged
  merged=$(printf '%s\n' "$fragments" | jq -cs 'add // {}' 2>/dev/null)
  if [ -z "$merged" ]; then
    printf '%s\n' '{}'
  else
    printf '%s\n' "$merged"
  fi
}

# _xprotect_codesign_anomalies <codesign_json>
#   stdout: JSON array of anomaly objects. When codesign.valid == false
#           we emit one `xprotect_codesign_fail` entry (severity: high);
#           otherwise we emit an empty array. The detail string pins
#           the exact phrasing required by design.md so downstream
#           consumers can match on prefix.
_xprotect_codesign_anomalies() {
  local codesign_json="$1"
  [ -n "$codesign_json" ] || { printf '%s\n' '[]'; return 0; }

  local valid
  valid=$(printf '%s' "$codesign_json" | jq -r '.valid // false' 2>/dev/null)
  case "$valid" in
    true)
      printf '%s\n' '[]'
      return 0
      ;;
    false) : ;;
    *)
      # Unexpected shape — treat as "not verified", fire the rule.
      valid=false
      ;;
  esac

  local first_line
  first_line=$(printf '%s' "$codesign_json" | jq -r '.stderr_first_line // ""' 2>/dev/null)

  jq -cn \
    --arg detail "XProtect bundle failed codesign --verify --deep --strict: ${first_line}" \
    '[{rule: "xprotect_codesign_fail", severity: "high", detail: $detail}]' 2>/dev/null
}

# xprotect_capture <bundle> <scratch_entries_file>
#   Walk <bundle>, hash every file, run codesign, compose one manifest
#   entry, and append it to <scratch_entries_file>.
#
#   Returns 0 on success. Returns 1 when <bundle> does not exist or is
#   not a directory (the caller routes the path into the manifest
#   header's skipped_paths array).
xprotect_capture() {
  local bundle="$1"
  local scratch="$2"

  if [ -z "$bundle" ]; then
    utils_log_err "xprotect_capture: bundle path is required"
    return 1
  fi
  if [ -z "$scratch" ]; then
    utils_log_err "xprotect_capture: scratch entries file is required"
    return 1
  fi
  if [ ! -d "$bundle" ]; then
    utils_log_err "xprotect_capture: '${bundle}' does not exist or is not a directory"
    return 1
  fi

  local version
  version=$(xprotect_version "$bundle")

  local files_json
  files_json=$(_xprotect_build_files_map "$bundle")
  [ -n "$files_json" ] || files_json='{}'

  local codesign_json
  codesign_json=$(utils_codesign_verify "$bundle")
  if [ -z "$codesign_json" ] || ! printf '%s' "$codesign_json" | jq -e . >/dev/null 2>&1; then
    codesign_json='{}'
  fi

  local anomalies_json
  anomalies_json=$(_xprotect_codesign_anomalies "$codesign_json")
  [ -n "$anomalies_json" ] || anomalies_json='[]'

  # content.bundle_version is the user-facing version surface. We keep
  # it inside .content as well as promoting it to a top-level
  # bundle_version field (via --bundle-version) because the schema
  # established in task 4.1 emits bundle_version alongside files /
  # codesign and downstream consumers (report.sh, the integrity
  # delta) dereference it directly.
  local content_json
  content_json=$(jq -cn --arg v "$version" '{bundle_version: $v}' 2>/dev/null)
  [ -n "$content_json" ] || content_json='{}'

  local size mtime
  # stat -f %z on a directory returns the inode's own size — NOT the
  # sum of contents. The field is informational; aggregate size lives
  # in the per-file `files` map.
  size=$(utils_file_size "$bundle")
  mtime=$(utils_file_mtime_iso "$bundle")

  local entry
  entry=$(manifest_build_entry \
    --path "$bundle" \
    --tier 3 \
    --surface xprotect \
    --format bundle \
    --sha256-raw "" \
    --sha256-canonical "" \
    --size "${size:-}" \
    --mtime "${mtime:-}" \
    --xattrs-json '{}' \
    --content-json "$content_json" \
    --bundle-version "$version" \
    --files-json "$files_json" \
    --codesign-json "$codesign_json" \
    --anomalies-json "$anomalies_json")
  if [ -z "$entry" ]; then
    utils_log_err "xprotect_capture: manifest_build_entry failed for '${bundle}'"
    return 1
  fi

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}
