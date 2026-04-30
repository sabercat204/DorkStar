#!/bin/bash
# lib/utils.sh — shared primitives: SHA-256 hashing, plist format detection,
# canonical JSON conversion, xattr extraction, temp-dir lifecycle, color/tty
# detection, logging, sudo detection, OS version guards.

# -----------------------------------------------------------------------------
# Hashing, plist format detection, canonical JSON conversion
# -----------------------------------------------------------------------------
# These primitives underpin the dual-hash model: every plist is hashed both
# over its raw on-disk bytes (sha256_raw) and over a canonical JSON
# representation (sha256_canonical). The canonical form is produced by
# piping `plutil -convert json` through `jq -cS` so that binary, XML, and
# JSON serialisations of the same semantic plist yield identical hashes.
#
# All functions here are deterministic and have no side effects. On any
# error (missing file, unreadable file, malformed plist) they emit an
# empty string on stdout. `utils_plist_format` is the sole exception: it
# emits the literal string `invalid` for unreadable or malformed inputs.
# Callers rely on empty-string semantics to populate manifest fields.

# utils_sha256_file <path>
#   stdout: lowercase 64-hex SHA-256 of file bytes, or empty string on error.
utils_sha256_file() {
  local path="$1"
  shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
}

# utils_sha256_stdin
#   stdin:  arbitrary bytes
#   stdout: lowercase 64-hex SHA-256 of the stdin bytes, or empty string on error.
utils_sha256_stdin() {
  shasum -a 256 2>/dev/null | awk '{print $1}'
}

# utils_plist_valid <path>
#   exit 0 when `plutil -lint` accepts the file, exit 1 otherwise.
utils_plist_valid() {
  local path="$1"
  plutil -lint -s -- "$path" >/dev/null 2>&1
}

# utils_plist_format <path>
#   stdout: one of `binary`, `xml`, `json`, `invalid`.
#
# Detection strategy: `plutil -lint -s` first gates validity. For valid
# plists we peek at the leading bytes to distinguish the three on-disk
# encodings — `bplist` magic for binary, `<?xml` / `<plist` for XML,
# `{` / `[` for JSON. We avoid `file(1)` because its output is not
# stable across macOS versions.
utils_plist_format() {
  local path="$1"
  if [ ! -r "$path" ]; then
    printf '%s\n' invalid
    return 0
  fi
  if ! plutil -lint -s -- "$path" >/dev/null 2>&1; then
    printf '%s\n' invalid
    return 0
  fi
  local head
  head=$(head -c 6 -- "$path" 2>/dev/null)
  case "$head" in
    bplist*)
      printf '%s\n' binary
      ;;
    '<?xml'*|'<plist'*)
      printf '%s\n' xml
      ;;
    '{'*|'['*)
      printf '%s\n' json
      ;;
    *)
      # plutil-valid but leading bytes don't match any known on-disk
      # encoding. Defensive fallback: XML plists may start with a BOM
      # or leading whitespace — re-check with the first non-whitespace
      # byte before giving up.
      local trimmed
      trimmed=$(head -c 16 -- "$path" 2>/dev/null | tr -d '[:space:]' | head -c 6)
      case "$trimmed" in
        bplist*)  printf '%s\n' binary ;;
        '<?xml'*|'<plist'*) printf '%s\n' xml ;;
        '{'*|'['*) printf '%s\n' json ;;
        *) printf '%s\n' invalid ;;
      esac
      ;;
  esac
}

# utils_plist_to_canonical_json <path>
#   stdout: canonical JSON representation of the plist — compact form,
#           recursively sorted keys, signed-zero normalised. Empty
#           string on any error.
#
# The canonicalization pipeline is the crux of the dual-hash model:
# converting any of {binary, XML, JSON} plist to JSON and then feeding
# that through `jq -cS '.'` produces a byte-for-byte identical result
# whenever the two inputs are semantically equivalent, so
# sha256(canonical_json) is invariant under format conversion.
#
# Signed-zero normalisation: macOS `plutil -convert json` preserves the
# sign of -0.0 when the source is binary/XML but normalises it away when
# the source is JSON, producing divergent canonical output for the same
# semantic plist. We post-process via `jq 'walk(if . == 0 then 0 else . end)'`
# which rewrites every numeric 0 / -0 to a canonical positive 0, restoring
# P2 (canonical-hash format invariance) across every plist encoding.
utils_plist_to_canonical_json() {
  local path="$1"
  plutil -convert json -o - -- "$path" 2>/dev/null \
    | utils_canonical_json_stdin
}

# utils_canonical_json_stdin
#   stdin:  raw JSON bytes (typically the output of `plutil -convert json`).
#   stdout: canonical JSON — compact form, recursively sorted keys,
#           signed-zero normalised. Empty string on jq error or empty
#           input.
#
# This is the single source of truth for the canonicalization pipeline.
# Both `utils_plist_to_canonical_json` (reading from a file via plutil)
# and `cfprefsd_live_canonical` (reading `defaults export <domain> -`
# output via plutil over stdin) MUST route through this helper so the
# disk and live halves of the cfprefsd cross-reference stay byte-identical.
# Any divergence between the two pipelines (e.g. a mismatched jq flag or
# a missing numeric normalisation) would produce a systemic false-positive
# `[?] STALE` finding on every Tier 2 domain.
utils_canonical_json_stdin() {
  jq -cS '(.. | numbers) |= (if . == 0 then 0 else . end)' 2>/dev/null
}

# -----------------------------------------------------------------------------
# File metadata, xattrs, environment
# -----------------------------------------------------------------------------
# Per-file metadata helpers (size, mtime, extended attributes) and
# environment inspectors (macOS version, SIP/SSV status, hostname, ISO
# timestamp, sudo detection, bash-version guard).
#
# All of these are side-effect free. They either succeed and emit a
# value on stdout, or fail quietly and emit an empty string. The sole
# exceptions are `utils_require_bash`, which may abort with exit 2 when
# the running shell is too old, and `utils_has_sudo`, which returns an
# exit status rather than stdout.
#
# Rationale for empty-on-failure semantics: callers build JSONL entries
# by interpolating these outputs through `jq --arg`, which treats an
# empty string as the literal empty string rather than aborting. The
# manifest schema permits empty `size_bytes` / `mtime` / `xattrs` on
# files the tool could not stat, and `skipped_paths` in the header
# records the underlying reason separately.

# utils_file_size <path>
#   stdout: decimal bytes as reported by `stat -f %z`. Empty on error.
#
# BSD `stat` is the macOS default; GNU `stat -c %s` is not available
# without coreutils and we deliberately do not depend on it
# (Requirement 15.6).
utils_file_size() {
  local path="$1"
  stat -f %z -- "$path" 2>/dev/null
}

# utils_file_mtime_iso <path>
#   stdout: modification time in ISO 8601 UTC (e.g. `2026-04-20T14:30:00Z`).
#           Empty on error.
#
# We read the epoch-seconds mtime via `stat -f %m` and format it with
# `date -u -r <epoch>`. Both invocations are BSD-native on macOS.
utils_file_mtime_iso() {
  local path="$1"
  local mtime
  mtime=$(stat -f %m -- "$path" 2>/dev/null) || return 0
  [ -n "$mtime" ] || return 0
  date -u -r "$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# utils_xattrs_json <path>
#   stdout: one-line JSON object mapping xattr name to base64-encoded
#           value. Always emits at least `{}` so callers can splice
#           the result directly into a manifest entry's `xattrs` field.
#
# Strategy: `xattr -l <path>` lists attribute names (one per line). For
# each name we read the raw bytes via `xattr -px` (which prints hex
# with whitespace), strip whitespace, convert hex to binary via
# `xxd -r -p`, and base64-encode the result. Each single-key JSON
# fragment is produced by `jq -n --arg k --arg v '{($k): $v}'`, and
# the fragments are merged via `jq -s 'add'` to form the final object.
utils_xattrs_json() {
  local path="$1"
  if [ ! -e "$path" ]; then
    printf '%s\n' '{}'
    return 0
  fi

  local names
  names=$(xattr -- "$path" 2>/dev/null) || {
    printf '%s\n' '{}'
    return 0
  }

  if [ -z "$names" ]; then
    printf '%s\n' '{}'
    return 0
  fi

  # Build each {name: base64_value} object on its own line, then merge.
  local fragments
  fragments=$(
    printf '%s\n' "$names" | while IFS= read -r name; do
      [ -n "$name" ] || continue
      local hex b64
      hex=$(xattr -px -- "$name" "$path" 2>/dev/null | tr -d '[:space:]')
      if [ -z "$hex" ]; then
        b64=""
      else
        b64=$(printf '%s' "$hex" | xxd -r -p 2>/dev/null | base64 2>/dev/null | tr -d '\n')
      fi
      jq -cn --arg k "$name" --arg v "$b64" '{($k): $v}' 2>/dev/null || true
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

# utils_os_version
#   stdout: macOS product version (e.g. `15.4`). Empty on error.
utils_os_version() {
  sw_vers -productVersion 2>/dev/null
}

# utils_os_major
#   stdout: integer macOS major version (e.g. `15`). Empty on error.
#
# Honours `OS_MAJOR_OVERRIDE`: when that variable is non-empty the
# value is echoed verbatim. The override exists so the test harness
# can simulate older/newer macOS releases without actually changing
# `sw_vers` output (required by tasks 12.2 / 18.2).
utils_os_major() {
  if [ -n "${OS_MAJOR_OVERRIDE:-}" ]; then
    printf '%s\n' "$OS_MAJOR_OVERRIDE"
    return 0
  fi
  local ver
  ver=$(sw_vers -productVersion 2>/dev/null) || return 0
  [ -n "$ver" ] || return 0
  printf '%s\n' "${ver%%.*}"
}

# utils_sip_status
#   stdout: `enabled` | `disabled` | `unknown`.
#
# Parses `csrutil status` output case-insensitively. On systems where
# csrutil is unavailable or the output is unparseable we emit
# `unknown` rather than aborting.
utils_sip_status() {
  local out
  out=$(csrutil status 2>/dev/null) || {
    printf '%s\n' unknown
    return 0
  }
  local lower
  lower=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *enabled*)  printf '%s\n' enabled ;;
    *disabled*) printf '%s\n' disabled ;;
    *)          printf '%s\n' unknown ;;
  esac
}

# utils_ssv_status
#   stdout: `enabled` | `disabled` | `unknown`.
#
# `csrutil authenticated-root status` reports the Sealed System Volume
# state on macOS 11+. On older releases (or when the command errors)
# we fall back to `unknown`.
utils_ssv_status() {
  local out
  out=$(csrutil authenticated-root status 2>/dev/null) || {
    printf '%s\n' unknown
    return 0
  }
  local lower
  lower=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *enabled*)  printf '%s\n' enabled ;;
    *disabled*) printf '%s\n' disabled ;;
    *)          printf '%s\n' unknown ;;
  esac
}

# utils_hostname
#   stdout: `hostname(1)` output with any trailing newline stripped.
utils_hostname() {
  local h
  h=$(hostname 2>/dev/null) || return 0
  printf '%s' "$h"
  # trailing newline is intentionally omitted so callers can splice via --arg
  printf '\n'
}

# utils_iso_now
#   stdout: ISO 8601 timestamp with timezone offset and a colon
#           separator in the offset (e.g. `2026-04-27T20:00:00-05:00`).
#
# BSD `date` emits `-0500`; the manifest schema (Requirement 11.5)
# requires the colon-separated `-05:00` form. We splice the colon in
# manually so we do not depend on GNU `date` or `gdate`.
utils_iso_now() {
  local raw
  raw=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || return 0
  # Split into "YYYY-MM-DDTHH:MM:SS" and "+HHMM" / "-HHMM".
  # ${raw%???} drops the last three characters (the minutes portion
  # plus one digit of the hour) — too aggressive — so instead we use
  # a length-based split that works in bash 3.2.
  local len prefix offset hh mm
  len=${#raw}
  if [ "$len" -lt 5 ]; then
    printf '%s\n' "$raw"
    return 0
  fi
  prefix=${raw:0:len-5}
  offset=${raw:len-5:5}
  hh=${offset:0:3}
  mm=${offset:3:2}
  printf '%s%s:%s\n' "$prefix" "$hh" "$mm"
}

# utils_has_sudo
#   exit 0 when the effective UID is 0, exit 1 otherwise. No side
#   effects — we deliberately do NOT invoke `sudo` itself (which would
#   prompt) or probe for a cached credential (which would require a
#   side-effecting `sudo -n true`).
utils_has_sudo() {
  [ "$(id -u)" -eq 0 ]
}

# utils_require_bash
#   Abort with exit 2 and the message
#     `[x] macaudit requires bash 3.2 or later. Current: $BASH_VERSION`
#   to stderr when `BASH_VERSINFO` is unset, or when the running bash
#   is older than 3.2. Otherwise return 0 silently.
utils_require_bash() {
  local major minor
  if [ -z "${BASH_VERSINFO+x}" ]; then
    printf '[x] macaudit requires bash 3.2 or later. Current: %s\n' "${BASH_VERSION:-unknown}" >&2
    exit 2
  fi
  major=${BASH_VERSINFO[0]}
  minor=${BASH_VERSINFO[1]}
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 2 ]; }; then
    printf '[x] macaudit requires bash 3.2 or later. Current: %s\n' "${BASH_VERSION:-unknown}" >&2
    exit 2
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Logging, tty/color detection, temp-dir lifecycle
# -----------------------------------------------------------------------------
# User-facing diagnostics go to stderr so they do not pollute the
# manifest / report stdout stream. Colors are opt-in based on tty
# capability. The temp-dir helpers manage a per-run scratch directory
# under `${TMPDIR:-/tmp}` and tear it down via EXIT+INT traps so SIGINT
# leaves no half-written artefacts (Requirement 19.1).

# utils_log_info <msg>
#   stderr: `[i] <msg>`. Always returns 0.
utils_log_info() {
  printf '[i] %s\n' "$1" >&2
}

# utils_log_warn <msg>
#   stderr: `[!] <msg>`. Always returns 0.
utils_log_warn() {
  printf '[!] %s\n' "$1" >&2
}

# utils_log_err <msg>
#   stderr: `[x] <msg>`. Always returns 0 (the caller decides whether
#   to exit; this function is a pure formatter).
utils_log_err() {
  printf '[x] %s\n' "$1" >&2
}

# utils_log_skip <path> <reason>
#   stderr: `[skip] <path> (<reason>)`.
#
# Note: the design mentions accumulating skipped paths for a final
# summary, but the accumulator lives in lib/baseline.sh. This function
# only emits the line — it does not mutate any shared state.
utils_log_skip() {
  printf '[skip] %s (%s)\n' "$1" "$2" >&2
}

# utils_tty_supports_color
#   exit 0 when stdout is a tty AND `tput colors` reports at least 8
#   colors. exit 1 otherwise. `tput` failures are coerced to 0 colors
#   so a missing terminfo entry disables color rather than aborting.
utils_tty_supports_color() {
  [ -t 1 ] || return 1
  local colors
  colors=$(tput colors 2>/dev/null || echo 0)
  [ "$colors" -ge 8 ] 2>/dev/null
}

# utils_color <name>
#   stdout: the `tput` escape sequence for the named role, or the
#           empty string when the tty does not support color or the
#           name is unknown. Recognised names: red, green, yellow,
#           magenta, reset, bold.
#
# `magenta` is used by the Tier 3 `[⚑] SUSPICIOUS` section in
# lib/report.sh (task 15H). The `tput setaf 5` code is the standard
# ANSI magenta slot and degrades to empty output when the tty is
# color-incapable — same gating as every other colour here.
utils_color() {
  if ! utils_tty_supports_color; then
    return 0
  fi
  case "$1" in
    red)     tput setaf 1 2>/dev/null ;;
    green)   tput setaf 2 2>/dev/null ;;
    yellow)  tput setaf 3 2>/dev/null ;;
    magenta) tput setaf 5 2>/dev/null ;;
    reset)   tput sgr0   2>/dev/null ;;
    bold)    tput bold   2>/dev/null ;;
    *)       : ;;
  esac
}

# utils_tmpdir_init
#   Create `${TMPDIR:-/tmp}/macaudit.$$.XXXXXX` via `mktemp -d`, export
#   `MACAUDIT_TMPDIR` so callers and the cleanup trap can see it, and
#   install an EXIT+INT trap invoking `utils_tmpdir_cleanup`.
#   Idempotent: if `MACAUDIT_TMPDIR` is already set to an existing
#   directory, this function is a no-op apart from echoing the path.
#   stdout: the tmpdir path.
utils_tmpdir_init() {
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "$MACAUDIT_TMPDIR" ]; then
    printf '%s\n' "$MACAUDIT_TMPDIR"
    return 0
  fi
  local base="${TMPDIR:-/tmp}"
  # Strip trailing slash for tidy concatenation.
  base="${base%/}"
  local dir
  dir=$(mktemp -d "${base}/macaudit.$$.XXXXXX" 2>/dev/null) || {
    # mktemp should almost never fail on macOS; if it does we cannot
    # meaningfully continue. Surface the failure on stderr and return
    # non-zero so the caller can abort.
    printf '[x] utils_tmpdir_init: unable to create temp directory under %s\n' "$base" >&2
    return 1
  }
  MACAUDIT_TMPDIR="$dir"
  export MACAUDIT_TMPDIR
  # Install the cleanup trap. We chain rather than overwrite so
  # callers that have already installed their own EXIT trap do not
  # silently lose it — but we only do so when no prior trap is set,
  # since bash 3.2 has no portable way to introspect the existing
  # EXIT trap without subshell trickery. In practice macaudit owns
  # its own traps, so a plain overwrite is fine here.
  trap 'utils_tmpdir_cleanup' EXIT
  trap 'utils_tmpdir_cleanup; exit 130' INT
  printf '%s\n' "$dir"
}

# utils_tmpdir_path
#   stdout: current `MACAUDIT_TMPDIR` value, or empty when unset.
utils_tmpdir_path() {
  printf '%s\n' "${MACAUDIT_TMPDIR:-}"
}

# utils_tmpdir_cleanup
#   Remove `MACAUDIT_TMPDIR` if set and the directory exists, then
#   unset the variable. Idempotent — safe to call multiple times.
#   Defensive guards:
#     - the variable must be non-empty
#     - the path must be an absolute path starting with `/`
#     - the path must actually be a directory
#   These guards exist so a mis-set `MACAUDIT_TMPDIR` can never cause
#   this function to remove anything near the filesystem root.
utils_tmpdir_cleanup() {
  if [ -n "${MACAUDIT_TMPDIR:-}" ] \
      && [ -d "$MACAUDIT_TMPDIR" ] \
      && [ "${MACAUDIT_TMPDIR#/}" != "$MACAUDIT_TMPDIR" ]; then
    rm -rf -- "$MACAUDIT_TMPDIR" 2>/dev/null || true
  fi
  unset MACAUDIT_TMPDIR
}

# -----------------------------------------------------------------------------
# Code signing + Full Disk Access probes
# -----------------------------------------------------------------------------
# `utils_codesign_verify` wraps `codesign --verify --deep --strict` and emits a
# structured JSON summary so downstream anomaly rules (task 15B's tcc_fda_unsigned
# and task 15E's xprotect_codesign_fail) can make decisions without reparsing
# codesign's free-form output.
#
# `utils_fda_probe` is the single source of truth for "can this process read
# FDA-protected paths" across the Tier 3 surfaces. It depends on
# `sqlite_safe_copy` from lib/sqlite.sh, so the entry point (macaudit.sh) MUST
# source sqlite.sh before any call path that reaches utils_fda_probe. Result
# is memoised in MACAUDIT_FDA_AVAILABLE so the probe runs at most once per
# invocation of the tool.

# utils_codesign_verify <path>
#   stdout: one-line JSON object
#     {"valid": true|false, "exit_code": <int>, "stderr_first_line": "<str>"}
#   Empty object {} when `codesign` is not available.
#
#   `valid` is strictly `exit_code == 0`. `stderr_first_line` is the first
#   line of codesign's stderr output, stripped of trailing whitespace, useful
#   for forensic diagnostics (e.g. "code object is not signed at all").
#
#   Guards:
#     - <path> must be non-empty.
#     - `codesign` must be on PATH — missing command ⇒ empty object.
#   This function is strictly read-only: it never signs, modifies, or
#   otherwise alters the subject binary.
utils_codesign_verify() {
  local path="$1"
  if [ -z "$path" ]; then
    printf '%s\n' '{}'
    return 0
  fi
  if ! command -v codesign >/dev/null 2>&1; then
    printf '%s\n' '{}'
    return 0
  fi

  # Capture stderr into a scratch file so we can read back the first line
  # without competing with stdout. We prefer MACAUDIT_TMPDIR when present;
  # otherwise fall back to TMPDIR / /tmp since utils_tmpdir_init may not
  # yet have been called (e.g. during standalone use from a test harness).
  local tmp_base="${MACAUDIT_TMPDIR:-${TMPDIR:-/tmp}}"
  tmp_base="${tmp_base%/}"
  local err_file
  err_file=$(mktemp "${tmp_base}/macaudit-codesign.XXXXXX" 2>/dev/null) || {
    printf '%s\n' '{}'
    return 0
  }

  local rc=0
  codesign --verify --deep --strict -- "$path" >/dev/null 2>"$err_file" || rc=$?

  local first_line=""
  if [ -s "$err_file" ]; then
    first_line=$(head -n 1 -- "$err_file" 2>/dev/null | tr -d '\r')
  fi
  rm -f -- "$err_file" 2>/dev/null || true

  local valid_json="false"
  if [ "$rc" -eq 0 ]; then
    valid_json="true"
  fi

  jq -cn \
    --argjson valid "$valid_json" \
    --argjson exit_code "$rc" \
    --arg stderr_first_line "$first_line" \
    '{valid: $valid, exit_code: $exit_code, stderr_first_line: $stderr_first_line}' \
    2>/dev/null
}

# utils_fda_probe
#   exit 0 iff Full Disk Access is available to the current process. The
#   result is memoised in MACAUDIT_FDA_AVAILABLE (values: "yes" | "no");
#   subsequent calls read the memo and skip the SQLite work.
#
#   Mechanism: call `sqlite_safe_copy` on the system TCC.db; invoke
#   `SELECT COUNT(*) FROM access` in read-only mode on the checkpointed
#   copy. Exit 0 when the query succeeds AND returns a decimal integer.
#   Any other outcome — safe-copy failed, query failed, empty stdout,
#   non-numeric stdout — ⇒ exit 1.
#
#   Dependency: requires `sqlite_safe_copy` (lib/sqlite.sh). The entry
#   point sources sqlite.sh before any module that triggers the probe.
utils_fda_probe() {
  if [ -n "${MACAUDIT_FDA_AVAILABLE:-}" ]; then
    case "$MACAUDIT_FDA_AVAILABLE" in
      yes) return 0 ;;
      no)  return 1 ;;
    esac
  fi

  local tcc_path="/Library/Application Support/com.apple.TCC/TCC.db"
  # Honour an explicit override path so test harnesses can point at a
  # fixture database without needing actual FDA. The override mirrors
  # TCC_SYSTEM_PATH_OVERRIDE used by lib/tcc.sh.
  if [ -n "${TCC_SYSTEM_PATH_OVERRIDE:-}" ]; then
    tcc_path="$TCC_SYSTEM_PATH_OVERRIDE"
  fi

  local copy
  copy=$(sqlite_safe_copy "$tcc_path" 2>/dev/null)
  if [ -z "$copy" ] || [ ! -r "$copy" ]; then
    MACAUDIT_FDA_AVAILABLE=no
    export MACAUDIT_FDA_AVAILABLE
    return 1
  fi

  local count
  count=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
    'SELECT COUNT(*) FROM access;' 2>/dev/null)
  case "$count" in
    ''|*[!0-9]*)
      MACAUDIT_FDA_AVAILABLE=no
      export MACAUDIT_FDA_AVAILABLE
      return 1
      ;;
  esac
  MACAUDIT_FDA_AVAILABLE=yes
  export MACAUDIT_FDA_AVAILABLE
  return 0
}

# -----------------------------------------------------------------------------
# MDM enrolment probe
# -----------------------------------------------------------------------------
# `utils_mdm_managed` wraps `profiles status -type enrollment` and returns
# exit 0 iff the output reports "MDM enrollment: Yes" (case-insensitive).
# Used by lib/sysdb.sh (R4 gating for kext_user_approved_on_mdm) and by
# the cross-surface correlation pass (R1/R4) to decide whether MDM-scoped
# anomaly rules apply at all.
#
# The `profiles` binary is present on macOS 10.15+. On older releases, or
# when the binary exits non-zero / emits unparseable output, we log a
# single info line and return 1 so callers treat the device as
# non-managed.
#
# Result memoisation: MACAUDIT_MDM_MANAGED ∈ {yes, no} caches the probe
# across the per-run invocations so each call costs one string compare
# instead of a fresh fork. Test harnesses clear the memo between
# scenarios via `unset MACAUDIT_MDM_MANAGED`.
#
# Test override: `PROFILES_CMD_OVERRIDE` takes precedence over the
# system `profiles` binary so bats fixtures can drive the probe
# deterministically without a real MDM setup.

# utils_mdm_managed
#   exit 0 iff this device is MDM-enrolled. exit 1 otherwise.
utils_mdm_managed() {
  if [ -n "${MACAUDIT_MDM_MANAGED:-}" ]; then
    case "$MACAUDIT_MDM_MANAGED" in
      yes) return 0 ;;
      no)  return 1 ;;
    esac
  fi

  local profiles_cmd="${PROFILES_CMD_OVERRIDE:-profiles}"
  if ! command -v "$profiles_cmd" >/dev/null 2>&1; then
    utils_log_info "utils_mdm_managed: 'profiles' unavailable; treating device as non-managed"
    MACAUDIT_MDM_MANAGED=no
    export MACAUDIT_MDM_MANAGED
    return 1
  fi

  local out
  out=$("$profiles_cmd" status -type enrollment 2>/dev/null) || {
    MACAUDIT_MDM_MANAGED=no
    export MACAUDIT_MDM_MANAGED
    return 1
  }

  # Case-insensitive match: "MDM enrollment:" followed by "Yes".
  local lower
  lower=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"mdm enrollment: yes"*)
      MACAUDIT_MDM_MANAGED=yes
      export MACAUDIT_MDM_MANAGED
      return 0
      ;;
    *)
      MACAUDIT_MDM_MANAGED=no
      export MACAUDIT_MDM_MANAGED
      return 1
      ;;
  esac
}
