#!/bin/bash
# lib/cfprefsd.sh — disk-vs-live preference cross-reference. Exports a domain
# via `defaults export` and compares its canonical hash to the on-disk
# canonical hash using the identical canonicalization pipeline.
#
# The cross-reference is the mechanism behind the `[?] STALE` delta
# category: when the canonical hash of a preference plist on disk does not
# match the canonical hash of what cfprefsd is serving live, either the
# disk file or the in-memory cache is stale. The comparison is strictly
# hash-based — this module never diffs preference payloads directly,
# because the only "content" ever persisted in the manifest is the subset
# of security-critical keys enumerated by surfaces.sh.
#
# Output is tri-state: `true` when both canonical hashes exist and match,
# `false` when both exist and differ, and the empty string (representing
# JSON `null`) when either side is unavailable (unknown domain, empty
# `defaults export`, `defaults` failure, or unreadable disk file).
#
# All functions are side-effect free apart from `cfprefsd_live_canonical`,
# which forks `defaults export` — unavoidable, since that is the only way
# to read cfprefsd's in-memory view.
#
# Drift-prevention: the canonicalization pipeline routes through
# `utils_canonical_json_stdin` (defined in lib/utils.sh). Both the disk
# side (`utils_plist_to_canonical_json`) and the live side
# (`cfprefsd_live_canonical`) feed their respective `plutil -convert json`
# output through that same helper. Any change to the canonical jq filter
# MUST be made in one place — diverging the two pipelines by even one flag
# would produce a systemic false-positive `[?] STALE` finding on every
# Tier 2 domain.

# =============================================================================
# Section 1: Domain resolution
# =============================================================================
# Map a preference plist path to the domain name cfprefsd uses for it.
# The mapping rules cover the four locations where macaudit reads
# preferences:
#
#   /Library/Preferences/<domain>.plist                 -> <domain>
#   ~/Library/Preferences/<domain>.plist                -> <domain>
#   /Library/Managed Preferences/<domain>.plist         -> <domain>
#   /Library/Managed Preferences/<user>/<domain>.plist  -> <domain>
#
# Plus two special cases for the global defaults domain:
#   /Library/Preferences/.GlobalPreferences.plist       -> NSGlobalDomain
#   ~/Library/Preferences/.GlobalPreferences.plist      -> NSGlobalDomain
#
# Anything else — including Tier 1 launchd plists under /Library/Launch*
# and ~/Library/LaunchAgents — returns the empty string. Callers interpret
# an empty domain as "this path has no cfprefsd cross-reference" and pass
# it downstream as `cfprefsd_match=null`.

# cfprefsd_domain_from_path <path>
#   stdout: cfprefsd domain name, or empty string when the path does not
#           correspond to a known preference location.
#   exit:   always 0 (empty stdout signals "no domain").
cfprefsd_domain_from_path() {
  local path="$1"
  if [ -z "$path" ]; then
    return 0
  fi

  # Extract the basename without the trailing ".plist" extension so we
  # can map `.GlobalPreferences.plist` to `NSGlobalDomain` uniformly and
  # strip the extension exactly once at the end of the function.
  local base
  base=$(basename -- "$path")
  # Strip .plist (exactly one trailing occurrence). If the file is not a
  # .plist we bail out with an empty string since cfprefsd only serves
  # plist-shaped domains.
  case "$base" in
    *.plist) : ;;
    *) return 0 ;;
  esac
  local stem="${base%.plist}"

  # Special case: .GlobalPreferences → NSGlobalDomain for both the system
  # and user locations.
  if [ "$stem" = ".GlobalPreferences" ]; then
    case "$path" in
      /Library/Preferences/.GlobalPreferences.plist|*/Library/Preferences/.GlobalPreferences.plist)
        printf '%s\n' NSGlobalDomain
        return 0
        ;;
      *)
        # .GlobalPreferences under some other directory is not a real
        # cfprefsd domain; decline.
        return 0
        ;;
    esac
  fi

  case "$path" in
    # System preferences: /Library/Preferences/<stem>.plist
    /Library/Preferences/*.plist)
      # Reject nested subdirectories — cfprefsd only serves the top-level
      # file-per-domain layout at this location.
      local rest="${path#/Library/Preferences/}"
      case "$rest" in
        */*) return 0 ;;
      esac
      printf '%s\n' "$stem"
      return 0
      ;;

    # User preferences: ~/Library/Preferences/<stem>.plist (any home dir).
    */Library/Preferences/*.plist)
      local rest="${path##*/Library/Preferences/}"
      case "$rest" in
        */*) return 0 ;;
      esac
      printf '%s\n' "$stem"
      return 0
      ;;

    # Managed preferences: /Library/Managed Preferences/[<user>/]<stem>.plist
    "/Library/Managed Preferences/"*.plist)
      # Strip the directory prefix; rest is either "<domain>.plist" or
      # "<user>/<domain>.plist". Both cases map to <domain>.
      printf '%s\n' "$stem"
      return 0
      ;;
  esac

  # No match — not a cfprefsd-served location.
  return 0
}

# =============================================================================
# Section 2: Live export and availability
# =============================================================================
# `cfprefsd_live_canonical` is the only side-effecting function in this
# module: it invokes `defaults export <domain> -`, pipes the result
# through the shared canonicalization pipeline, and hashes the output.
# The contract is empty-string-on-anything-unusual so callers (and the
# manifest layer) can treat the result as a tri-state: a 64-hex hash
# means "live data available", and empty means "unknown — emit null".
#
# When called from a root context, the optional <user> argument lets the
# caller demote privileges via `sudo -u <user>` so per-user preferences
# can be read on behalf of a specific account. When <user> is omitted or
# empty, the invocation is a plain `defaults export`.

# cfprefsd_live_canonical <domain> [<user>]
#   stdout: lowercase 64-hex SHA-256 of the canonical live export, or
#           empty string when the live hash cannot be determined
#           (see below).
#
# Returns empty when any of the following hold:
#   - <domain> is empty
#   - `defaults export` exits non-zero
#   - the exported output is empty or whitespace-only
#   - the exported output is the literal `{}` (domain exists but empty)
#   - `plutil -convert json` refuses the export
#   - the canonical jq filter fails
cfprefsd_live_canonical() {
  local domain="$1"
  local user="${2:-}"
  if [ -z "$domain" ]; then
    return 0
  fi

  # Run `defaults export` either directly or via `sudo -u <user>`. We
  # capture stdout into a variable (not a temp file) because preference
  # domains are small — even the largest user defaults are well under a
  # megabyte.
  local export_out
  if [ -n "$user" ]; then
    export_out=$(sudo -u "$user" defaults export "$domain" - 2>/dev/null)
  else
    export_out=$(defaults export "$domain" - 2>/dev/null)
  fi
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    return 0
  fi
  if [ -z "$export_out" ]; then
    return 0
  fi
  # Treat whitespace-only output as empty.
  case "$export_out" in
    *[![:space:]]*) : ;;
    *) return 0 ;;
  esac

  # Convert the plist export to JSON. `defaults export <domain> -` writes
  # an XML plist to stdout, so `plutil -convert json -o - -` reads it from
  # stdin and writes JSON to stdout. Any failure here (malformed export,
  # plutil unavailable) collapses to the empty-string return.
  #
  # We use a temp file for the JSON output so we can both inspect it
  # for the `{}` empty-domain case and feed it into the canonical
  # pipeline without going through a command substitution — command
  # substitution strips trailing newlines, which would make the live
  # hash drift from the disk hash (whose pipeline preserves jq's
  # trailing newline).
  local json_tmp
  json_tmp=$(mktemp "${TMPDIR:-/tmp}/macaudit-cfprefsd.XXXXXX" 2>/dev/null) || return 0
  if ! printf '%s' "$export_out" | plutil -convert json -o - - >"$json_tmp" 2>/dev/null; then
    rm -f -- "$json_tmp"
    return 0
  fi
  if [ ! -s "$json_tmp" ]; then
    rm -f -- "$json_tmp"
    return 0
  fi

  # The literal `{}` indicates cfprefsd knows the domain but it is empty
  # — semantically indistinguishable from "unknown" for the purpose of
  # cross-referencing a concrete on-disk file, so we report null.
  local peek
  peek=$(tr -d '[:space:]' <"$json_tmp")
  if [ "$peek" = '{}' ]; then
    rm -f -- "$json_tmp"
    return 0
  fi

  # Route through the same canonicalization helper the disk side uses.
  # This is a direct pipe — no command substitution — so jq's trailing
  # newline is preserved end-to-end, matching the disk pipeline
  # (utils_plist_to_canonical_json <file> | utils_sha256_stdin) byte
  # for byte.
  local result
  result=$(utils_canonical_json_stdin <"$json_tmp" | utils_sha256_stdin)
  rm -f -- "$json_tmp"
  if [ -z "$result" ]; then
    return 0
  fi
  # Guard against the degenerate `{}\n` surviving jq — an empty object
  # canonicalises to `{}\n` and hashing that would be wrong (it's the
  # same null case).
  case "$peek" in
    '{}') return 0 ;;
  esac
  printf '%s\n' "$result"
}

# cfprefsd_available
#   exit 0 when `defaults` is usable on this system, exit 1 otherwise.
#
# Strategy: require `defaults` on PATH and do a trivial read (any exit
# status is acceptable as long as it does not segfault — the key may be
# missing, which is fine). We only care that the binary executes.
cfprefsd_available() {
  command -v defaults >/dev/null 2>&1 || return 1
  # The probe deliberately swallows both stdout and stderr — we are
  # probing for "does defaults run at all?", not for the value of the
  # key. A non-zero exit here (key missing on a fresh system) is still
  # "defaults works".
  defaults read NSGlobalDomain AppleShowAllExtensions >/dev/null 2>&1
  # Even if the read fails, defaults itself executed — that's the only
  # signal `cfprefsd_available` is checking for. Return 0.
  return 0
}

# =============================================================================
# Section 3: Compare and cross-reference
# =============================================================================
# `cfprefsd_compare` is a pure string comparison over the two canonical
# hashes. It drives the tri-state truth table:
#
#     disk \ live    (empty)   H2
#     ----------------------------------
#     (empty)        null      null
#     H1             null      H1 == H2 ? true : false
#
# Empty on either side collapses to `null`. When both are present, it's a
# plain string compare.
#
# `cfprefsd_cross_reference` is the convenience wrapper callers use when
# they want to go from a path + its disk canonical hash straight to a
# one-line JSON object encoding the result. It's used by baseline.sh and
# audit.sh to populate the `cfprefsd_match` field of a manifest entry.

# cfprefsd_compare <disk_canonical_hash> <live_canonical_hash>
#   stdout: literal `true`, `false`, or empty string (meaning null).
#   Pure string comparison — no side effects, no jq invocation.
cfprefsd_compare() {
  local disk="$1"
  local live="$2"
  if [ -z "$disk" ] || [ -z "$live" ]; then
    # Empty on either side → null.
    return 0
  fi
  if [ "$disk" = "$live" ]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

# cfprefsd_cross_reference <path> <disk_canonical_hash> [<user>]
#   Runs the full cross-reference pipeline for a single preference plist.
#   stdout: one-line JSON object of shape
#       {"match": true|false|null, "live": "<hash>|"}
#     * `match` is a JSON boolean or literal `null` — emitted via
#       `jq --argjson` so it lands as a real JSON literal rather than
#       the string "true"/"false"/"null".
#     * `live` is the canonical live hash, or the empty string when
#       the live side could not be determined.
#
# Empty <path> or any path that does not map to a cfprefsd domain
# short-circuits to `{"match": null, "live": ""}` — the canonical
# "unknown" shape.
cfprefsd_cross_reference() {
  local path="$1"
  local disk="$2"
  local user="${3:-}"

  local domain
  domain=$(cfprefsd_domain_from_path "$path")
  if [ -z "$domain" ]; then
    printf '%s\n' '{"match":null,"live":""}'
    return 0
  fi

  local live
  live=$(cfprefsd_live_canonical "$domain" "$user")

  local match
  match=$(cfprefsd_compare "$disk" "$live")
  # `cfprefsd_compare` emits "true", "false", or the empty string. Map
  # the empty string to the literal JSON `null` for the JSON object.
  local match_json
  case "$match" in
    true|false) match_json="$match" ;;
    *)          match_json=null ;;
  esac

  jq -cn \
    --argjson match "$match_json" \
    --arg     live  "$live" \
    '{match: $match, live: $live}' 2>/dev/null \
    || printf '{"match":%s,"live":"%s"}\n' "$match_json" "$live"
}
