#!/bin/bash
# lib/baseline.sh — baseline capture orchestrator. One public entry point
# (`baseline_run`) walks every Tier 1 and Tier 2 surface defined in
# lib/surfaces.sh, computes the dual hash for every plist, cross-references
# preference domains against cfprefsd, detects launchctl injections, and
# emits a JSONL manifest with a properly populated header as the first line.
#
# Key invariants (enforced by the layout of this file):
#
#   1. The manifest is NEVER loaded into a bash variable — every entry
#      streams directly to a scratch file under ${MACAUDIT_TMPDIR}. The
#      final output file is built by `cat`-ing the header plus the
#      scratch file to a .tmp sibling and atomically `mv`-ing it into
#      place. SIGINT mid-run leaves no partial manifest behind.
#
#   2. launchctl and BTM are forked exactly ONCE per run. Their outputs
#      are cached to scratch files and threaded through
#      `persistence_correlate` for every Tier 1 plist.
#
#   3. The cfprefsd cross-reference on Tier 2 plists runs both the disk
#      and the live halves through `utils_canonical_json_stdin` (via
#      `cfprefsd_live_canonical`) so a byte-for-byte match is achievable
#      whenever the two views agree.
#
#   4. Tier 2 `content` objects contain ONLY the keys enumerated in
#      `surfaces_security_keys_for_domain`. Arbitrary preference data is
#      never exfiltrated.
#
#   5. A path that cannot be read is recorded in `header.skipped_paths`
#      with an explicit reason — never silently dropped.
#
#   6. Two back-to-back runs against identical system state produce
#      byte-identical `(path, sha256_canonical)` pairs.
#
# File structure:
#   Section 1 — Top-level dispatcher (`baseline_run` + flag parsing).
#   Section 2 — Tier 1 walk (plists + legacy persistence + injection).
#   Section 3 — Tier 2 walk (preferences + cfprefsd cross-reference).
#   Section 4 — Tier 3 walk (security databases + cross-surface correlation).
#   Section 5 — Header finalisation and atomic write.
#
# bash 3.2 compatible. No `set -euo pipefail` — library files never
# globally enable strict mode because they are sourced into long-running
# shells. `echo` is banned; every stdout write uses `printf '%s\n'`.

# =============================================================================
# Section 1: Top-level dispatcher
# =============================================================================
# `baseline_run` is the only public function. It parses flags, initialises
# the scratch tmpdir, calls into the Tier 1 / Tier 2 walkers (Sections 2 and
# 3), and hands off to the header+atomic-write stage (Section 4).
#
# Exit codes:
#   0 — success, manifest written, final path printed to stdout.
#   2 — unrecoverable error (bad flag, missing output directory after
#       we tried to create it, plutil missing, etc.).

# baseline_run [--output <path>] [--tier 1|2|3|all] [--user-only]
baseline_run() {
  local tier="all"
  local user_only=0
  local output=""

  # -- flag parsing --------------------------------------------------------
  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        if [ $# -lt 2 ]; then
          utils_log_err "baseline_run: --output requires a value"
          return 2
        fi
        output="$2"; shift 2
        ;;
      --tier)
        if [ $# -lt 2 ]; then
          utils_log_err "baseline_run: --tier requires a value"
          return 2
        fi
        tier="$2"; shift 2
        ;;
      --user-only)
        user_only=1; shift 1
        ;;
      *)
        utils_log_err "baseline_run: unknown flag '$1'"
        return 2
        ;;
    esac
  done

  case "$tier" in
    1|2|3|all) : ;;
    *)
      utils_log_err "baseline_run: invalid --tier '$tier' (expected 1, 2, 3, or all)"
      return 2
      ;;
  esac

  # -- default output path -------------------------------------------------
  if [ -z "$output" ]; then
    local stamp
    stamp=$(date +%Y%m%d_%H%M%S 2>/dev/null) || stamp="now"
    # Create manifests/ if missing; callers run `baseline_run` from the
    # project root so a relative path is the natural default.
    if [ ! -d manifests ]; then
      mkdir -p manifests 2>/dev/null || {
        utils_log_err "baseline_run: unable to create 'manifests/' directory"
        return 2
      }
    fi
    output="manifests/baseline_${stamp}.jsonl"
  fi

  # -- sanity check: plutil must be available for any plist work ---------
  if ! command -v plutil >/dev/null 2>&1; then
    utils_log_err "baseline_run: plutil not found on PATH"
    return 2
  fi

  # -- scratch tmpdir ------------------------------------------------------
  # utils_tmpdir_init is idempotent — if a parent has already set one up
  # we reuse it. The EXIT trap installed by utils_tmpdir_init removes the
  # scratch directory on normal exit OR on SIGINT, which is how the
  # "SIGINT leaves no partial manifest" invariant is enforced: the final
  # output file is only created by an atomic mv at the very end, so if
  # the process dies before that mv, nothing lands at the output path.
  if ! utils_tmpdir_init >/dev/null; then
    utils_log_err "baseline_run: unable to initialise scratch tmpdir"
    return 2
  fi

  local scratch_entries="${MACAUDIT_TMPDIR}/entries.jsonl"
  local scratch_skipped="${MACAUDIT_TMPDIR}/skipped.jsonl"
  local scratch_labels="${MACAUDIT_TMPDIR}/on_disk_labels.txt"
  local scratch_launchctl="${MACAUDIT_TMPDIR}/launchctl.tsv"
  local scratch_launchctl_labels="${MACAUDIT_TMPDIR}/launchctl_labels.txt"
  local scratch_btm="${MACAUDIT_TMPDIR}/btm.jsonl"

  # Start every scratch file empty so a re-run inside a long-lived shell
  # never carries over stale data.
  : > "$scratch_entries"
  : > "$scratch_skipped"
  : > "$scratch_labels"
  : > "$scratch_launchctl"
  : > "$scratch_btm"

  # -- Tier 1 --------------------------------------------------------------
  case "$tier" in
    1|all)
      _baseline_tier1_walk \
        "$user_only" \
        "$scratch_entries" \
        "$scratch_skipped" \
        "$scratch_labels" \
        "$scratch_launchctl" \
        "$scratch_btm" \
        || return 2

      # Compute the launchctl-labels file for injection detection once,
      # regardless of whether we eventually emit injection entries.
      # NOTE: we DO NOT pass `--` to awk here. BSD awk (the macOS
      # default) does not recognise `--` as an end-of-options marker
      # and would treat it as a literal filename, leaving the label
      # file empty and causing every injection to be silently dropped.
      if [ -s "$scratch_launchctl" ]; then
        awk -F '\t' '{print $1}' "$scratch_launchctl" \
          > "$scratch_launchctl_labels" 2>/dev/null || true
      else
        : > "$scratch_launchctl_labels"
      fi

      _baseline_emit_injections \
        "$scratch_entries" \
        "$scratch_labels" \
        "$scratch_launchctl_labels" \
        "$scratch_launchctl" \
        "$scratch_btm" \
        || return 2
      ;;
  esac

  # -- Tier 2 --------------------------------------------------------------
  case "$tier" in
    2|all)
      _baseline_tier2_walk \
        "$user_only" \
        "$scratch_entries" \
        "$scratch_skipped" \
        || return 2
      ;;
  esac

  # -- Tier 3 --------------------------------------------------------------
  # Tracks whether at least one Tier 3 surface ran so the finaliser
  # knows to upgrade manifest_version to 1.1 and populate the
  # environment block. `fda_available` is recorded as a JSON literal
  # ("true" | "false" | "null"); "null" means the Tier 3 block did
  # not run at all so the probe was never consulted.
  local tier3_ran=0
  local fda_available_json="null"
  case "$tier" in
    3|all)
      # Defensive gate: the Tier 3 capture modules live in their own
      # library files (lib/sqlite.sh, lib/tcc.sh, lib/sysdb.sh,
      # lib/quarantine.sh, lib/xprotect.sh). When baseline.sh is
      # sourced without them — a common test-harness pattern — we
      # cannot honour the Tier 3 request. Rather than fail, we quietly
      # skip the Tier 3 block so Tier 1 + Tier 2 output still lands.
      # The entry point (macaudit.sh) sources every Tier 3 module so
      # production runs always take the branch body below.
      if _baseline_tier3_available; then
        tier3_ran=1
        # The FDA probe is computed ONCE here and threaded through the
        # Tier 3 walkers so no downstream module reforks utils_fda_probe.
        if utils_fda_probe; then
          fda_available_json=true
        else
          fda_available_json=false
        fi
        # `_baseline_tier3_walk` is the orchestration core; it populates
        # `$scratch_entries` / `$scratch_skipped` with Tier 3 rows AND
        # writes the run-wide env JSON to `${MACAUDIT_TMPDIR}/tier3_env.json`
        # so `baseline_correlate` can read it back without reforking
        # any probe (utils_mdm_managed / plugin-dirs / PPPC stub).
        _baseline_tier3_walk \
          "$scratch_entries" \
          "$scratch_skipped" \
          "$user_only" \
          "$fda_available_json" \
          || return 2

        # Cross-surface correlation — new three-file signature. Reads
        # tier1 + tier3 entries from the shared scratch file (jq's
        # `select(.tier == 1)` / `select(.tier == 3)` partitions them
        # on the fly), reads env from tier3_env.json, and emits any
        # correlation rows to stdout. We pipe stdout into the shared
        # scratch file so the finaliser's atomic write picks them up
        # alongside the tier3 rows.
        local env_file="${MACAUDIT_TMPDIR}/tier3_env.json"
        local corr_out
        corr_out=$(baseline_correlate \
          "$scratch_entries" \
          "$scratch_entries" \
          "$env_file") || return 2
        if [ -n "$corr_out" ]; then
          printf '%s\n' "$corr_out" >> "$scratch_entries"
        fi
      fi
      ;;
  esac

  # -- Header + atomic write ----------------------------------------------
  _baseline_finalize \
    "$output" \
    "$tier" \
    "$user_only" \
    "$scratch_entries" \
    "$scratch_skipped" \
    "$tier3_ran" \
    "$fda_available_json" \
    || return 2

  printf '%s\n' "$output"
  return 0
}

# _baseline_user_only_bool <flag_int>
#   Translate the integer user_only flag (0 or 1) into the JSON boolean
#   string the manifest header expects.
_baseline_user_only_bool() {
  if [ "$1" -eq 1 ] 2>/dev/null; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

# _baseline_append_skipped <skipped_file> <path> <reason>
#   Append one `{path, reason}` object to the running skipped JSONL file.
_baseline_append_skipped() {
  local file="$1" path="$2" reason="$3"
  local rec
  rec=$(jq -cn --arg path "$path" --arg reason "$reason" \
          '{path:$path,reason:$reason}' 2>/dev/null) || return 0
  printf '%s\n' "$rec" >> "$file"
}

# _baseline_surface_for_tier1_path <path>
#   stdout: the `surface` string for a Tier 1 plist path — one of
#           launchd_system, launchd_user, cron, periodic, login_hooks,
#           authplugin, emond. Empty when the path is not recognised.
_baseline_surface_for_tier1_path() {
  local path="$1"
  case "$path" in
    /Library/LaunchDaemons/*|/Library/LaunchAgents/*)
      printf '%s\n' launchd_system ;;
    */Library/LaunchAgents/*)
      printf '%s\n' launchd_user ;;
    /etc/periodic/*)
      printf '%s\n' periodic ;;
    /Library/Security/SecurityAgentPlugins/*)
      printf '%s\n' authplugin ;;
    /etc/emond.d/rules/*)
      printf '%s\n' emond ;;
    /var/at/tabs/*)
      printf '%s\n' cron ;;
    *) : ;;
  esac
}

# _baseline_surface_for_tier2_path <path>
#   stdout: the `surface` string for a Tier 2 plist path — one of
#           preferences_system, preferences_user, preferences_managed.
_baseline_surface_for_tier2_path() {
  local path="$1"
  case "$path" in
    "/Library/Managed Preferences"/*)
      printf '%s\n' preferences_managed ;;
    /Library/Preferences/*)
      printf '%s\n' preferences_system ;;
    */Library/Preferences/*)
      printf '%s\n' preferences_user ;;
    *) : ;;
  esac
}

# _baseline_project_keys <plist_path> <key1> [<key2> ...]
#   Internal projection helper used by both the launch-key and the
#   security-key extractors. Emits a one-line JSON object whose keys
#   are the intersection of the requested key list and the keys
#   actually present in the plist. Empty object `{}` when:
#     • the plist is unreadable
#     • the plist top-level is not a dict (plutil's JSON conversion
#       yields an array, string, etc. — projecting dict keys would
#       throw inside jq)
#     • no requested key is present
#
# Strategy: one `plutil -convert json` fork per plist, then one jq
# invocation to project the wanted keys. Much cheaper than N forks of
# `plutil -extract`, and it dodges the `-extract <key> json` quirk
# where plutil refuses to emit bare scalars ("Invalid object in plist
# for JSON format") — a regression the naive per-key approach kept
# silently hitting for Label, RunAtLoad, and every other scalar key.
#
# The jq filter walks an explicit `$keys` array, so only requested keys
# can ever appear in the output — which is the contract P15 enforces.
_baseline_project_keys() {
  local path="$1"; shift

  local full
  full=$(plutil -convert json -o - -- "$path" 2>/dev/null) || {
    printf '%s\n' '{}'
    return 0
  }
  [ -n "$full" ] || { printf '%s\n' '{}'; return 0; }

  # Only project if the top-level is an object.
  local top_type
  top_type=$(printf '%s' "$full" | jq -r 'type' 2>/dev/null)
  if [ "$top_type" != "object" ]; then
    printf '%s\n' '{}'
    return 0
  fi

  # Build a JSON array of the requested keys so we can hand it to jq
  # as a single --argjson. Using `printf '%s\n' "$@" | jq -R . | jq -s .`
  # gives us a canonical JSON array of the positional arguments.
  local keys_json
  keys_json=$(printf '%s\n' "$@" | jq -R . 2>/dev/null | jq -cs '.' 2>/dev/null)
  [ -n "$keys_json" ] || keys_json='[]'

  local projected
  projected=$(printf '%s' "$full" \
    | jq -c --argjson keys "$keys_json" \
        '. as $in | reduce $keys[] as $k ({}; if ($in | has($k)) then . + {($k): $in[$k]} else . end)' \
        2>/dev/null)

  [ -n "$projected" ] || projected='{}'
  printf '%s\n' "$projected"
}

# _baseline_extract_launch_content <plist_path>
#   stdout: one-line JSON object containing ONLY the keys listed in
#           `surfaces_launch_keys` that actually appear in the plist.
#           Missing keys are silently omitted. Empty object `{}` when
#           no launch keys are present or the file is unreadable.
_baseline_extract_launch_content() {
  local path="$1"
  # Expand surfaces_launch_keys into positional arguments. Launch-key
  # names are pure ASCII identifiers, so word splitting on whitespace
  # is safe here.
  local key
  local args=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    args+=("$key")
  done < <(surfaces_launch_keys)
  _baseline_project_keys "$path" "${args[@]}"
}

# _baseline_extract_security_content <plist_path> <domain>
#   stdout: one-line JSON object containing ONLY the security-critical
#           keys for <domain> that are present in <plist_path>. Empty
#           object `{}` when the domain is unknown or no keys match.
#           This is the function that enforces Property P15 (Tier 2
#           content scope) — arbitrary preference data is never
#           exfiltrated because only the hardcoded allow-list from
#           `surfaces_security_keys_for_domain` reaches jq.
_baseline_extract_security_content() {
  local path="$1" domain="$2"
  if [ -z "$domain" ]; then
    printf '%s\n' '{}'
    return 0
  fi
  local key
  local args=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    args+=("$key")
  done < <(surfaces_security_keys_for_domain "$domain")
  if [ "${#args[@]}" -eq 0 ]; then
    printf '%s\n' '{}'
    return 0
  fi
  _baseline_project_keys "$path" "${args[@]}"
}


# =============================================================================
# Section 2: Tier 1 walk
# =============================================================================
# The Tier 1 walk does three things in strict order:
#
#   (a) Forks launchctl (user + system-when-sudo) and `sfltool dumpbtm`
#       (system-when-sudo + macOS ≥ 13) exactly once, persisting the
#       results to the scratch files under MACAUDIT_TMPDIR. Every
#       downstream per-plist correlation reads from those files; nothing
#       re-forks the collectors.
#
#   (b) Walks every Tier 1 path emitted by `surfaces_tier1_system_paths`
#       (gated by --user-only / sudo) and `surfaces_tier1_user_paths`,
#       emitting one manifest entry per `*.plist` encountered and
#       recording per-root skip entries in the skipped JSONL when sudo
#       is missing or the directory is unreadable.
#
#   (c) Handles the legacy persistence mechanisms (cron, periodic,
#       login hooks, authplugins, emond) via dedicated helpers. Each
#       helper respects the same sudo gating as the plist walk.

# _baseline_tier1_walk <user_only> <entries> <skipped> <labels> <launchctl_tsv> <btm_jsonl>
#   Main Tier 1 orchestration helper. Populates every scratch file
#   listed above except the launchctl-labels file (which is produced by
#   the caller via a one-shot awk after this returns).
_baseline_tier1_walk() {
  local user_only="$1"
  local entries="$2"
  local skipped="$3"
  local labels="$4"
  local launchctl_tsv="$5"
  local btm_jsonl="$6"

  # -- launchctl snapshot (single fork, concatenated) ----------------------
  # We deliberately append to the same file for user + system because
  # downstream consumers — persistence_correlate and the injection
  # detector — only care about membership in the combined set. Having
  # one file avoids a second awk/cat hop in every per-plist inner loop.
  persistence_collect_launchctl_user >> "$launchctl_tsv" 2>/dev/null || true
  if [ "$user_only" -ne 1 ] && utils_has_sudo; then
    persistence_collect_launchctl_system >> "$launchctl_tsv" 2>/dev/null || true
  fi

  # -- BTM snapshot (only when the three gating conditions agree) ----------
  # persistence_collect_btm already internally gates on sudo and
  # os_major ≥ 13; we still early-out on --user-only because BTM is a
  # system-scope view. Calling the collector always produces a valid
  # (possibly empty) file, which `persistence_correlate` reads as
  # "btm_registered is null" — exactly the desired semantics.
  if [ "$user_only" -ne 1 ]; then
    persistence_collect_btm >> "$btm_jsonl" 2>/dev/null || true
  fi

  local have_sudo=0
  if utils_has_sudo; then have_sudo=1; fi

  # -- Tier 1 system roots -------------------------------------------------
  if [ "$user_only" -ne 1 ]; then
    local root
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      if [ "$have_sudo" -eq 0 ]; then
        _baseline_append_skipped "$skipped" "$root" "no-sudo"
        continue
      fi
      if [ ! -d "$root" ]; then
        # A non-existent root is not a permission problem — it just
        # means this macOS install does not ship that surface. We
        # skip it silently; the `skipped_paths` field is for paths
        # the tool COULD NOT read, not for paths that do not exist.
        continue
      fi
      if [ ! -r "$root" ]; then
        _baseline_append_skipped "$skipped" "$root" "permission-denied"
        continue
      fi
      _baseline_tier1_process_root "$root" "$entries" "$skipped" "$labels"
    done < <(surfaces_tier1_system_paths)
  fi

  # -- Tier 1 user roots ---------------------------------------------------
  local uroot
  while IFS= read -r uroot; do
    [ -n "$uroot" ] || continue
    [ -d "$uroot" ] || continue
    if [ ! -r "$uroot" ]; then
      _baseline_append_skipped "$skipped" "$uroot" "permission-denied"
      continue
    fi
    _baseline_tier1_process_root "$uroot" "$entries" "$skipped" "$labels"
  done < <(surfaces_tier1_user_paths "$HOME")

  # -- Legacy persistence mechanisms --------------------------------------
  _baseline_emit_cron_entries     "$user_only" "$entries" "$skipped"
  _baseline_emit_periodic_entries "$user_only" "$entries" "$skipped"
  _baseline_emit_loginhook_entry  "$user_only" "$entries"
  _baseline_emit_authplugin_entries "$user_only" "$entries" "$skipped"
  _baseline_emit_emond_entries    "$user_only" "$entries" "$skipped"

  return 0
}

# _baseline_tier1_process_root <root> <entries> <skipped> <labels>
#   Iterate every *.plist child of <root>. Treats LaunchDaemons,
#   LaunchAgents (both scopes), and emond as plist-bearing surfaces —
#   everything else is ignored here and handled by the dedicated
#   legacy-persistence helpers below.
_baseline_tier1_process_root() {
  local root="$1"
  local entries="$2"
  local skipped="$3"
  local labels="$4"

  # Only the launchd, authplugin, and emond surfaces have plists; the
  # plist walk is a nullable no-op for cron/periodic/auth-plugin bundle
  # roots. We key off the root path rather than scanning every file.
  case "$root" in
    /Library/LaunchDaemons|/Library/LaunchAgents|*/Library/LaunchAgents)
      : ;; # fall through to the plist scan below
    *)
      # Other roots are handled by the per-surface legacy emitters; we
      # return without walking so plist-only code paths don't pick up
      # shell scripts, bundles, or SQLite files.
      return 0 ;;
  esac

  local child
  for child in "$root"/*.plist; do
    # Guard against the literal glob leaking through when the root is
    # empty of .plist files.
    [ -e "$child" ] || continue
    if [ ! -r "$child" ]; then
      _baseline_append_skipped "$skipped" "$child" "permission-denied"
      continue
    fi
    _baseline_tier1_emit_plist_entry "$child" "$entries" "$labels"
  done
}

# _baseline_tier1_emit_plist_entry <plist> <entries> <labels>
#   Compute hashes, extract launch keys, correlate with launchctl+BTM,
#   emit one entry, and append the Label to the on-disk labels file
#   (so the injection detector can subtract it from the launchctl set
#   later).
_baseline_tier1_emit_plist_entry() {
  local plist="$1"
  local entries="$2"
  local labels="$3"

  local sha_raw sha_canon fmt label content xattrs size mtime
  sha_raw=$(utils_sha256_file "$plist")
  sha_canon=$(utils_plist_to_canonical_json "$plist" | utils_sha256_stdin)
  fmt=$(utils_plist_format "$plist")
  label=$(persistence_extract_label "$plist")
  content=$(_baseline_extract_launch_content "$plist")
  xattrs=$(utils_xattrs_json "$plist")
  size=$(utils_file_size "$plist")
  mtime=$(utils_file_mtime_iso "$plist")

  # Remember the Label for injection detection. An empty label (plists
  # that don't set Label) is skipped — they cannot produce an injection
  # finding either way, and including empty lines would break the
  # set-difference comparison in `persistence_detect_injections`.
  if [ -n "$label" ]; then
    printf '%s\n' "$label" >> "$labels"
  fi

  local surface
  surface=$(_baseline_surface_for_tier1_path "$plist")
  [ -n "$surface" ] || surface="launchd_system"

  # Correlate against the launchctl + BTM scratch files. The correlator
  # returns JSON {launchctl_loaded, btm_registered}; we pluck the two
  # tri-bool fields out for the manifest entry flags.
  local correlation launchctl_loaded btm_registered
  correlation=$(persistence_correlate \
    "$label" \
    "${MACAUDIT_TMPDIR}/launchctl.tsv" \
    "${MACAUDIT_TMPDIR}/btm.jsonl")
  launchctl_loaded=$(printf '%s' "$correlation" | jq -r '.launchctl_loaded' 2>/dev/null)
  btm_registered=$(printf '%s' "$correlation" | jq -r '.btm_registered' 2>/dev/null)
  # Normalise empty parses to "null" so manifest_build_entry accepts
  # the tri-bool validation.
  case "$launchctl_loaded" in true|false) : ;; *) launchctl_loaded=null ;; esac
  case "$btm_registered"   in true|false) : ;; *) btm_registered=null   ;; esac

  # Invalid / unreadable plists: emit the entry with empty canonical
  # hash and an empty content object. The raw hash is still valid over
  # the file bytes, so integrity auditing still sees drift.
  [ -n "$fmt" ] || fmt=invalid
  [ -n "$content" ] || content='{}'
  [ -n "$xattrs" ] || xattrs='{}'

  local entry
  entry=$(manifest_build_entry \
    --path "$plist" \
    --tier 1 \
    --surface "$surface" \
    --format "$fmt" \
    --sha256-raw "$sha_raw" \
    --sha256-canonical "$sha_canon" \
    --size "$size" \
    --mtime "$mtime" \
    --xattrs-json "$xattrs" \
    --content-json "$content" \
    --cfprefsd-match null \
    --launchctl-loaded "$launchctl_loaded" \
    --btm-registered "$btm_registered") || return 0

  printf '%s\n' "$entry" >> "$entries"
}

# _baseline_emit_cron_entries <user_only> <entries> <skipped>
#   One entry per non-empty crontab under /var/at/tabs. Requires sudo.
#   Each crontab is counted by non-empty line and the content object
#   records {user, line_count}; sha256_raw is computed over the raw
#   file bytes.
_baseline_emit_cron_entries() {
  local user_only="$1" entries="$2" skipped="$3"
  local root="/var/at/tabs"

  if [ "$user_only" -eq 1 ]; then
    return 0
  fi
  if ! utils_has_sudo; then
    # `_baseline_tier1_walk` already recorded /var/at/tabs with reason
    # "no-sudo" as part of the system-roots pass. We don't duplicate
    # that record here.
    return 0
  fi
  [ -d "$root" ] || return 0

  local file user sha line_count content xattrs size mtime entry
  for file in "$root"/*; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || continue
    if [ ! -r "$file" ]; then
      _baseline_append_skipped "$skipped" "$file" "permission-denied"
      continue
    fi
    # Skip empty crontabs — the absence of content is the clean state.
    if [ ! -s "$file" ]; then
      continue
    fi
    user=$(basename -- "$file")
    sha=$(utils_sha256_file "$file")
    line_count=$(grep -c -v '^[[:space:]]*$' -- "$file" 2>/dev/null || printf '0')
    content=$(jq -cn --arg user "$user" --argjson line_count "${line_count:-0}" \
      '{user:$user,line_count:$line_count}')
    xattrs=$(utils_xattrs_json "$file")
    size=$(utils_file_size "$file")
    mtime=$(utils_file_mtime_iso "$file")

    entry=$(manifest_build_entry \
      --path "$file" \
      --tier 1 \
      --surface cron \
      --format n/a \
      --sha256-raw "$sha" \
      --sha256-canonical "" \
      --size "$size" \
      --mtime "$mtime" \
      --xattrs-json "$xattrs" \
      --content-json "$content" \
      --cfprefsd-match null \
      --launchctl-loaded null \
      --btm-registered null) || continue
    printf '%s\n' "$entry" >> "$entries"
  done
}

# _baseline_emit_periodic_entries <user_only> <entries> <skipped>
#   One entry per script under /etc/periodic/{daily,weekly,monthly}.
#   These scripts run as root; reading them requires no privilege, but
#   we still record them under the Tier 1 `periodic` surface. Each
#   entry captures {filename, dir} as content and hashes the script
#   bytes.
_baseline_emit_periodic_entries() {
  local user_only="$1" entries="$2" skipped="$3"

  if [ "$user_only" -eq 1 ]; then
    return 0
  fi

  local d dir_name file filename sha content xattrs size mtime entry
  for d in /etc/periodic/daily /etc/periodic/weekly /etc/periodic/monthly; do
    [ -d "$d" ] || continue
    if [ ! -r "$d" ]; then
      _baseline_append_skipped "$skipped" "$d" "permission-denied"
      continue
    fi
    dir_name=$(basename -- "$d")
    for file in "$d"/*; do
      [ -e "$file" ] || continue
      [ -f "$file" ] || continue
      if [ ! -r "$file" ]; then
        _baseline_append_skipped "$skipped" "$file" "permission-denied"
        continue
      fi
      filename=$(basename -- "$file")
      sha=$(utils_sha256_file "$file")
      content=$(jq -cn --arg filename "$filename" --arg dir "$dir_name" \
        '{filename:$filename,dir:$dir}')
      xattrs=$(utils_xattrs_json "$file")
      size=$(utils_file_size "$file")
      mtime=$(utils_file_mtime_iso "$file")
      entry=$(manifest_build_entry \
        --path "$file" \
        --tier 1 \
        --surface periodic \
        --format n/a \
        --sha256-raw "$sha" \
        --sha256-canonical "" \
        --size "$size" \
        --mtime "$mtime" \
        --xattrs-json "$xattrs" \
        --content-json "$content" \
        --cfprefsd-match null \
        --launchctl-loaded null \
        --btm-registered null) || continue
      printf '%s\n' "$entry" >> "$entries"
    done
  done
}

# _baseline_emit_loginhook_entry <user_only> <entries>
#   At most one entry for the login hooks — the hooks live in
#   com.apple.loginwindow under LoginHook / LogoutHook. Absence of
#   both keys is the clean state and produces no entry at all. The
#   canonical system path for the domain (/Library/Preferences/...)
#   is system-scoped, so we suppress this surface under --user-only.
_baseline_emit_loginhook_entry() {
  local user_only="$1"
  local entries="$2"

  if [ "$user_only" -eq 1 ]; then
    return 0
  fi

  local login_hook logout_hook
  login_hook=$(defaults read com.apple.loginwindow LoginHook 2>/dev/null)
  logout_hook=$(defaults read com.apple.loginwindow LogoutHook 2>/dev/null)

  # Trim whitespace-only results — `defaults read` sometimes emits a
  # lone newline even when the key is absent.
  case "$login_hook"  in *[![:space:]]*) : ;; *) login_hook=""  ;; esac
  case "$logout_hook" in *[![:space:]]*) : ;; *) logout_hook="" ;; esac

  if [ -z "$login_hook" ] && [ -z "$logout_hook" ]; then
    return 0
  fi

  local login_arg logout_arg
  if [ -n "$login_hook" ]; then login_arg="$login_hook"; else login_arg=""; fi
  if [ -n "$logout_hook" ]; then logout_arg="$logout_hook"; else logout_arg=""; fi

  # Encode absent values as JSON null rather than empty string so the
  # manifest consumer can tell "key unset" from "key set to the empty
  # string".
  local content
  if [ -n "$login_hook" ] && [ -n "$logout_hook" ]; then
    content=$(jq -cn --arg login "$login_arg" --arg logout "$logout_arg" \
      '{LoginHook:$login,LogoutHook:$logout}')
  elif [ -n "$login_hook" ]; then
    content=$(jq -cn --arg login "$login_arg" \
      '{LoginHook:$login,LogoutHook:null}')
  else
    content=$(jq -cn --arg logout "$logout_arg" \
      '{LoginHook:null,LogoutHook:$logout}')
  fi

  local entry
  entry=$(manifest_build_entry \
    --path "/Library/Preferences/com.apple.loginwindow.plist" \
    --tier 1 \
    --surface login_hooks \
    --format n/a \
    --sha256-raw "" \
    --sha256-canonical "" \
    --content-json "$content" \
    --cfprefsd-match null \
    --launchctl-loaded null \
    --btm-registered null) || return 0
  printf '%s\n' "$entry" >> "$entries"
}

# _baseline_emit_authplugin_entries <user_only> <entries> <skipped>
#   One entry per bundle under /Library/Security/SecurityAgentPlugins.
#   Each entry hashes the bundle's Info.plist (the stable identity
#   anchor for a loadable plugin); bundles without Info.plist emit a
#   hashless entry recording only the bundle name.
_baseline_emit_authplugin_entries() {
  local user_only="$1" entries="$2" skipped="$3"

  if [ "$user_only" -eq 1 ]; then
    return 0
  fi

  local root="/Library/Security/SecurityAgentPlugins"
  [ -d "$root" ] || return 0
  if [ ! -r "$root" ]; then
    _baseline_append_skipped "$skipped" "$root" "permission-denied"
    return 0
  fi

  local bundle name info sha content entry
  for bundle in "$root"/*; do
    [ -e "$bundle" ] || continue
    [ -d "$bundle" ] || continue
    name=$(basename -- "$bundle")
    info="$bundle/Contents/Info.plist"
    if [ -r "$info" ]; then
      sha=$(utils_sha256_file "$info")
    else
      sha=""
    fi
    content=$(jq -cn --arg name "$name" '{name:$name}')
    entry=$(manifest_build_entry \
      --path "$bundle" \
      --tier 1 \
      --surface authplugin \
      --format bundle \
      --sha256-raw "$sha" \
      --sha256-canonical "" \
      --content-json "$content" \
      --cfprefsd-match null \
      --launchctl-loaded null \
      --btm-registered null) || continue
    printf '%s\n' "$entry" >> "$entries"
  done
}

# _baseline_emit_emond_entries <user_only> <entries> <skipped>
#   One entry per plist under /etc/emond.d/rules. emond is deprecated
#   but still runnable on many macOS releases; any rule file here is a
#   notable persistence vector.
_baseline_emit_emond_entries() {
  local user_only="$1" entries="$2" skipped="$3"

  if [ "$user_only" -eq 1 ]; then
    return 0
  fi

  local root="/etc/emond.d/rules"
  [ -d "$root" ] || return 0
  if [ ! -r "$root" ]; then
    _baseline_append_skipped "$skipped" "$root" "permission-denied"
    return 0
  fi

  local file filename sha_raw sha_canon fmt content xattrs size mtime entry
  for file in "$root"/*.plist; do
    [ -e "$file" ] || continue
    if [ ! -r "$file" ]; then
      _baseline_append_skipped "$skipped" "$file" "permission-denied"
      continue
    fi
    filename=$(basename -- "$file")
    sha_raw=$(utils_sha256_file "$file")
    sha_canon=$(utils_plist_to_canonical_json "$file" | utils_sha256_stdin)
    fmt=$(utils_plist_format "$file")
    [ -n "$fmt" ] || fmt=invalid
    content=$(jq -cn --arg filename "$filename" '{filename:$filename}')
    xattrs=$(utils_xattrs_json "$file")
    size=$(utils_file_size "$file")
    mtime=$(utils_file_mtime_iso "$file")
    entry=$(manifest_build_entry \
      --path "$file" \
      --tier 1 \
      --surface emond \
      --format "$fmt" \
      --sha256-raw "$sha_raw" \
      --sha256-canonical "$sha_canon" \
      --size "$size" \
      --mtime "$mtime" \
      --xattrs-json "$xattrs" \
      --content-json "$content" \
      --cfprefsd-match null \
      --launchctl-loaded null \
      --btm-registered null) || continue
    printf '%s\n' "$entry" >> "$entries"
  done
}

# _baseline_emit_injections <entries> <on_disk_labels> <launchctl_labels> <launchctl_tsv> <btm_jsonl>
#   Compute the set difference launchctl - on_disk and emit one entry
#   per result label. Every injection entry carries:
#     • surface="injection"
#     • format="n/a"
#     • empty hashes (there is no on-disk file to hash)
#     • content={label, pid, status} sourced from the launchctl TSV
#     • launchctl_loaded=true always (by definition)
#     • btm_registered sourced from the BTM cache (null when the BTM
#       view was not collected, i.e. macOS < 13 or no sudo)
_baseline_emit_injections() {
  local entries="$1"
  local on_disk="$2"
  local launchctl_labels="$3"
  local launchctl_tsv="$4"
  local btm_jsonl="$5"

  # If we never got a launchctl snapshot, there are no injections to
  # detect — return quietly.
  [ -s "$launchctl_labels" ] || return 0

  local injections
  injections=$(persistence_detect_injections "$on_disk" "$launchctl_labels")
  [ -n "$injections" ] || return 0

  local label row pid status content correlation btm_registered entry
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    # Pull pid/status from the first launchctl row matching this label.
    row=$(awk -v L="$label" -F '\t' '$1 == L { print; exit }' "$launchctl_tsv")
    if [ -n "$row" ]; then
      pid=$(printf '%s' "$row" | awk -F '\t' '{print $2}')
      status=$(printf '%s' "$row" | awk -F '\t' '{print $3}')
    else
      pid=0
      status=0
    fi
    # Defensive: if the fields are non-numeric (shouldn't happen given
    # the collector's normalisation of "-" to "0", but belt-and-braces
    # since the TSV is shared state), coerce them to 0.
    case "$pid"    in *[!0-9-]*|'') pid=0    ;; esac
    case "$status" in *[!0-9-]*|'') status=0 ;; esac

    content=$(jq -cn --arg label "$label" \
      --argjson pid "${pid:-0}" --argjson status "${status:-0}" \
      '{label:$label,pid:$pid,status:$status}')

    # btm_registered mirrors the correlator's tri-bool output. We pass
    # an empty label to the correlator would match nothing; we pass
    # the real label so membership is computed correctly.
    correlation=$(persistence_correlate "$label" "$launchctl_tsv" "$btm_jsonl")
    btm_registered=$(printf '%s' "$correlation" | jq -r '.btm_registered' 2>/dev/null)
    case "$btm_registered" in true|false) : ;; *) btm_registered=null ;; esac

    entry=$(manifest_build_entry \
      --path "launchctl://${label}" \
      --tier 1 \
      --surface injection \
      --format n/a \
      --sha256-raw "" \
      --sha256-canonical "" \
      --content-json "$content" \
      --cfprefsd-match null \
      --launchctl-loaded true \
      --btm-registered "$btm_registered") || continue
    printf '%s\n' "$entry" >> "$entries"
  done < <(printf '%s\n' "$injections")
}


# =============================================================================
# Section 3: Tier 2 walk
# =============================================================================
# Every Tier 2 entry is a preference plist. The walk iterates the
# system, user, and managed roots (subject to --user-only / sudo
# gating), and for each `*.plist` child of a readable root it:
#
#   1. Computes the dual hash.
#   2. Resolves the cfprefsd domain from the path via
#      `cfprefsd_domain_from_path`.
#   3. Extracts ONLY the `surfaces_security_keys_for_domain` keys into
#      the content object (P15 / Requirement 5.3 — arbitrary preference
#      data is never exfiltrated).
#   4. Computes the live canonical hash via `cfprefsd_live_canonical`
#      and compares against the disk canonical hash via
#      `cfprefsd_compare`.
#   5. Emits the entry with `launchctl_loaded=null` and
#      `btm_registered=null` (Tier 2 has no persistence correlation).

# _baseline_tier2_walk <user_only> <entries> <skipped>
_baseline_tier2_walk() {
  local user_only="$1"
  local entries="$2"
  local skipped="$3"

  local have_sudo=0
  if utils_has_sudo; then have_sudo=1; fi

  # -- System preferences roots (sudo-gated when --user-only is unset) ----
  if [ "$user_only" -ne 1 ]; then
    local sroot
    while IFS= read -r sroot; do
      [ -n "$sroot" ] || continue
      if [ "$have_sudo" -eq 0 ]; then
        _baseline_append_skipped "$skipped" "$sroot" "no-sudo"
        continue
      fi
      [ -d "$sroot" ] || continue
      if [ ! -r "$sroot" ]; then
        _baseline_append_skipped "$skipped" "$sroot" "permission-denied"
        continue
      fi
      _baseline_tier2_process_root "$sroot" "$entries" "$skipped"
    done < <(surfaces_tier2_system_paths)
  fi

  # -- User preferences root (always attempted) ----------------------------
  local uroot
  while IFS= read -r uroot; do
    [ -n "$uroot" ] || continue
    [ -d "$uroot" ] || continue
    if [ ! -r "$uroot" ]; then
      _baseline_append_skipped "$skipped" "$uroot" "permission-denied"
      continue
    fi
    _baseline_tier2_process_root "$uroot" "$entries" "$skipped"
  done < <(surfaces_tier2_user_paths "$HOME")

  return 0
}

# _baseline_tier2_process_root <root> <entries> <skipped>
#   Walk every *.plist directly under <root>. Nested subdirectories of
#   /Library/Managed Preferences (per-user variants like
#   "/Library/Managed Preferences/<user>/com.foo.plist") are handled by
#   the explicit enumerator — the top-level root walk stays one level
#   deep so we don't double-count.
#
# Dotfile-stemmed plists (only `.GlobalPreferences.plist` is known in
# practice) are swept up by a second glob pass since the default bash
# glob omits names starting with `.`. We iterate both patterns rather
# than `shopt -s dotglob` so we never accidentally scoop up `.` / `..`.
_baseline_tier2_process_root() {
  local root="$1"
  local entries="$2"
  local skipped="$3"

  local child
  for child in "$root"/*.plist "$root"/.*.plist; do
    [ -e "$child" ] || continue
    [ -f "$child" ] || continue
    if [ ! -r "$child" ]; then
      _baseline_append_skipped "$skipped" "$child" "permission-denied"
      continue
    fi
    _baseline_tier2_emit_plist_entry "$child" "$entries"
  done
}

# _baseline_tier2_emit_plist_entry <plist> <entries>
#   Build and append one Tier 2 manifest entry.
_baseline_tier2_emit_plist_entry() {
  local plist="$1"
  local entries="$2"

  local sha_raw sha_canon fmt domain content xattrs size mtime surface
  sha_raw=$(utils_sha256_file "$plist")
  sha_canon=$(utils_plist_to_canonical_json "$plist" | utils_sha256_stdin)
  fmt=$(utils_plist_format "$plist")
  [ -n "$fmt" ] || fmt=invalid
  domain=$(cfprefsd_domain_from_path "$plist")
  content=$(_baseline_extract_security_content "$plist" "$domain")
  [ -n "$content" ] || content='{}'
  xattrs=$(utils_xattrs_json "$plist")
  size=$(utils_file_size "$plist")
  mtime=$(utils_file_mtime_iso "$plist")
  surface=$(_baseline_surface_for_tier2_path "$plist")
  [ -n "$surface" ] || surface=preferences_system

  # cfprefsd cross-reference — empty domain means "no cfprefsd-served
  # domain maps to this path" which collapses to cfprefsd_match=null.
  local live match match_json
  if [ -n "$domain" ]; then
    live=$(cfprefsd_live_canonical "$domain")
    match=$(cfprefsd_compare "$sha_canon" "$live")
  else
    live=""
    match=""
  fi
  case "$match" in
    true|false) match_json="$match" ;;
    *)          match_json=null    ;;
  esac

  local entry
  entry=$(manifest_build_entry \
    --path "$plist" \
    --tier 2 \
    --surface "$surface" \
    --format "$fmt" \
    --sha256-raw "$sha_raw" \
    --sha256-canonical "$sha_canon" \
    --size "$size" \
    --mtime "$mtime" \
    --xattrs-json "$xattrs" \
    --content-json "$content" \
    --cfprefsd-match "$match_json" \
    --launchctl-loaded null \
    --btm-registered null) || return 0
  printf '%s\n' "$entry" >> "$entries"
}

# =============================================================================
# Section 4: Tier 3 walk + cross-surface correlation
# =============================================================================
# Tier 3 orchestration follows the control flow in design.md §"Amended
# Baseline Control Flow":
#
#   1. FDA probe (computed ONCE at the top of baseline_run_tier3 and
#      threaded as --fda-available-json so downstream captures never
#      refork utils_fda_probe).
#
#   2. FDA-gated surfaces: system TCC.db, KextPolicy, ExecPolicy. When
#      FDA is available we capture each one; when unavailable we write
#      a `{path, reason: "fda-unavailable"}` row into the skipped file
#      so the header's `skipped_paths` array explains the gap.
#
#   3. Non-FDA surfaces: SystemPolicy (sudo-gated on read — the module
#      degrades gracefully when sudo is absent and still records the
#      Gatekeeper spctl state), AuthorizationDB, XProtect, per-user
#      quarantine events. These are always attempted.
#
#   4. Cross-surface correlation — see `baseline_correlate` below for
#      the R1–R5 rule descriptions.
#
# The Tier 3 walk reuses the same `$scratch_entries` file as Tier 1
# and Tier 2 so `baseline_correlate` can slurp the combined stream in
# one shot via `jq -s .`. Skipped surfaces go to `$scratch_skipped`
# exactly like the other tiers so the finaliser's `skipped_paths`
# array has a uniform shape.

# _baseline_tier3_available
#   exit 0 iff every Tier 3 capture helper baseline_run_tier3 depends
#   on is defined in the current shell environment (i.e. the caller
#   has sourced lib/sqlite.sh, lib/tcc.sh, lib/sysdb.sh,
#   lib/quarantine.sh, lib/xprotect.sh alongside lib/baseline.sh).
#
#   When any helper is missing we skip the entire Tier 3 block and
#   leave the header at manifest_version 1.0. This is the graceful
#   degradation test harnesses rely on when they deliberately source
#   only the Tier 1 + Tier 2 subset of the library.
_baseline_tier3_available() {
  local fn
  for fn in \
      sqlite_safe_copy \
      tcc_capture_system tcc_capture_user tcc_system_path tcc_user_path \
      sysdb_capture_kextpolicy sysdb_capture_execpolicy \
      sysdb_capture_systempolicy sysdb_capture_authdb \
      sysdb_classify_mechanism sysdb_plugin_dirs_listing \
      quarantine_capture_user quarantine_xattr_uuid quarantine_lookup_uuid \
      xprotect_bundle_path xprotect_version xprotect_capture \
      utils_fda_probe utils_mdm_managed utils_codesign_verify
  do
    if ! command -v "$fn" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

# _baseline_enumerable_homes <user_only>
#   stdout: newline-separated list of home directories to iterate for
#           per-user Tier 3 captures (TCC user, quarantine).
#
#   Behaviour:
#     - Always includes `$HOME` first (when non-empty).
#     - Under --user-only: only `$HOME` is emitted; the caller scopes
#       the capture to the running user.
#     - Otherwise: `/Users/*` is scanned; every directory that is:
#           * readable
#           * not `Shared` / `Guest`
#           * not dotfile-prefixed (e.g. `.localized`)
#           * not equal to `$HOME` (already emitted first)
#       is appended.
#
#   Honours `MACAUDIT_USERS_DIR_OVERRIDE` for test harnesses so the
#   walk can be driven against a fixture tree without mutating the
#   real `/Users` directory.
_baseline_enumerable_homes() {
  local user_only="$1"

  # Always emit $HOME first so the caller has a stable, de-duplicated
  # ordering regardless of how /Users is laid out.
  if [ -n "${HOME:-}" ]; then
    printf '%s\n' "$HOME"
  fi

  if [ "$user_only" -eq 1 ] 2>/dev/null; then
    return 0
  fi

  local users_root="${MACAUDIT_USERS_DIR_OVERRIDE:-/Users}"
  [ -d "$users_root" ] || return 0
  [ -r "$users_root" ] || return 0

  local candidate base
  for candidate in "$users_root"/*; do
    [ -e "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    [ -r "$candidate" ] || continue
    base=$(basename -- "$candidate")
    case "$base" in
      Shared|Guest) continue ;;
      .*)           continue ;;
    esac
    # Skip if this path matches $HOME (case-sensitive compare — macOS
    # HFS+ is case-insensitive by default but the on-disk path string
    # is what we've already emitted).
    if [ -n "${HOME:-}" ] && [ "$candidate" = "$HOME" ]; then
      continue
    fi
    printf '%s\n' "$candidate"
  done
}

# _baseline_plugin_dirs_json
#   stdout: JSON array of the two plugin directories — system first,
#           third-party second — honouring SYSTEM_PLUGIN_DIR_OVERRIDE
#           and THIRD_PARTY_PLUGIN_DIR_OVERRIDE. This is the single
#           source of truth shared by `_baseline_build_tier3_env_file`
#           and the (future) in-process classifier shims.
_baseline_plugin_dirs_json() {
  local system_dir="${SYSTEM_PLUGIN_DIR_OVERRIDE:-/System/Library/CoreServices/SecurityAgentPlugins}"
  local thirdp_dir="${THIRD_PARTY_PLUGIN_DIR_OVERRIDE:-/Library/Security/SecurityAgentPlugins}"
  jq -cn --arg a "$system_dir" --arg b "$thirdp_dir" '[$a, $b]'
}

# _baseline_build_tier3_env_file <env_file_path>
#   Write a one-line JSON object to <env_file_path> describing the
#   run-wide environment inputs to the correlation pass:
#     {
#       pppc_profile_payload_identifiers: [...],
#       mdm_managed: true|false,
#       plugin_dirs: ["<system>", "<thirdparty>"]
#     }
#   Probes are evaluated ONCE here so downstream rules (R1, R4, R5) do
#   not refork utils_mdm_managed / plutil / stat.
_baseline_build_tier3_env_file() {
  local env_file="$1"
  [ -n "$env_file" ] || return 1

  local pppc plugin_dirs mdm_json
  pppc=$(_baseline_pppc_payloads_json)
  [ -n "$pppc" ] || pppc='[]'
  plugin_dirs=$(_baseline_plugin_dirs_json)
  [ -n "$plugin_dirs" ] || plugin_dirs='[]'
  mdm_json=false
  if utils_mdm_managed; then mdm_json=true; fi

  jq -cn \
    --argjson pppc "$pppc" \
    --argjson mdm "$mdm_json" \
    --argjson dirs "$plugin_dirs" \
    '{
       pppc_profile_payload_identifiers: $pppc,
       mdm_managed: $mdm,
       plugin_dirs: $dirs
     }' > "$env_file" || return 1
  return 0
}

# _baseline_pppc_payloads_json
#   stdout: JSON array of PPPC profile payload identifiers. Sourced
#           from the `MACAUDIT_PPPC_JSON` env override when set; else
#           falls back to `[]`. The real implementation that parses
#           `profiles show -type configuration` lands with the
#           profiles collector in a later task — this stub keeps the
#           correlation pass testable without that dependency.
_baseline_pppc_payloads_json() {
  local src="${MACAUDIT_PPPC_JSON:-[]}"
  if ! printf '%s' "$src" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s\n' '[]'
    return 0
  fi
  printf '%s' "$src" | jq -c '.' 2>/dev/null
}

# _baseline_gatekeeper_enabled
#   stdout: `true` | `false` | `null` JSON literal (one per line).
#           Derived from `spctl --status`:
#             "assessments enabled"  -> true
#             "assessments disabled" -> false
#             anything else / empty  -> null
#   Honours SPCTL_STATUS_OVERRIDE via the existing _sysdb_spctl_run
#   shim.
_baseline_gatekeeper_enabled() {
  local out lower
  out=$(_sysdb_spctl_run --status 2>/dev/null)
  if [ -z "$out" ]; then
    printf '%s\n' null
    return 0
  fi
  lower=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"assessments enabled"*)  printf '%s\n' true ;;
    *"assessments disabled"*) printf '%s\n' false ;;
    *)                        printf '%s\n' null ;;
  esac
}

# _baseline_xprotect_version_safe
#   stdout: the XProtect bundle's CFBundleShortVersionString, or empty
#           when the bundle is absent / unreadable. Thin wrapper over
#           `xprotect_version` that resolves the bundle path via
#           `xprotect_bundle_path` (honouring XPROTECT_BUNDLE_OVERRIDE).
_baseline_xprotect_version_safe() {
  local bundle
  bundle=$(xprotect_bundle_path)
  [ -n "$bundle" ] || return 0
  [ -d "$bundle" ] || return 0
  xprotect_version "$bundle"
}

# _baseline_build_environment <fda_available_json>
#   stdout: one-line JSON object
#     {fda_available, has_sudo, gatekeeper_enabled, mdm_managed, xprotect_version}
#   Every field is a JSON literal (bool / null) or a string. Never
#   reforks utils_fda_probe — the caller threads the already-computed
#   value in as `$fda_available_json`.
_baseline_build_environment() {
  local fda_json="$1"
  case "$fda_json" in
    true|false|null) : ;;
    *) fda_json=null ;;
  esac

  local has_sudo_json=false
  if utils_has_sudo; then has_sudo_json=true; fi

  local gk_json
  gk_json=$(_baseline_gatekeeper_enabled)
  case "$gk_json" in
    true|false|null) : ;;
    *) gk_json=null ;;
  esac

  local mdm_json=false
  if utils_mdm_managed; then mdm_json=true; fi

  local xp_version
  xp_version=$(_baseline_xprotect_version_safe)
  # JSON-ify: empty string -> null; otherwise a JSON string literal.
  local xp_json
  if [ -z "$xp_version" ]; then
    xp_json=null
  else
    xp_json=$(jq -cn --arg v "$xp_version" '$v')
  fi

  jq -cn \
    --argjson fda_available       "$fda_json" \
    --argjson has_sudo            "$has_sudo_json" \
    --argjson gatekeeper_enabled  "$gk_json" \
    --argjson mdm_managed         "$mdm_json" \
    --argjson xprotect_version    "$xp_json" \
    '{
       fda_available:      $fda_available,
       has_sudo:           $has_sudo,
       gatekeeper_enabled: $gatekeeper_enabled,
       mdm_managed:        $mdm_managed,
       xprotect_version:   $xprotect_version
     }'
}

# _baseline_tier3_walk <scratch_entries> <scratch_skipped> <user_only> <fda_available_json>
#   Private Tier 3 orchestration core. Invoked by the public facade
#   `baseline_run_tier3`. Builds the run-wide env file (consumed by
#   `baseline_correlate`), then drives the five Tier 3 capture modules
#   per design.md §"Amended Baseline Control Flow":
#
#     1. FDA-gated surfaces (system TCC.db, KextPolicy, ExecPolicy)
#     2. Per-user TCC.db, one per enumerable home
#     3. SystemPolicy (degrades gracefully without sudo)
#     4. AuthorizationDB
#     5. XProtect bundle walk
#     6. Per-user quarantine events, one per enumerable home
#
#   Return 0 when the walk completes (individual surface failures are
#   recorded as skipped-path entries, not propagated as errors);
#   return 2 only on a fundamental wiring failure.
_baseline_tier3_walk() {
  local scratch_entries="$1"
  local scratch_skipped="$2"
  local user_only="$3"
  local fda_available_json="$4"

  if [ -z "$scratch_entries" ] || [ -z "$scratch_skipped" ]; then
    utils_log_err "_baseline_tier3_walk: scratch files are required"
    return 2
  fi

  # Normalise the tri-bool. The baseline_run dispatcher always hands
  # us a concrete value, but being defensive here keeps this function
  # safe to call from a test harness that passes an empty string.
  case "$fda_available_json" in
    true|false) : ;;
    *) fda_available_json=false ;;
  esac

  local fda_ok=0
  if [ "$fda_available_json" = "true" ]; then
    fda_ok=1
  fi

  # Build the run-wide env JSON file ONCE so the correlation pass
  # (R1, R4, R5) can read back the PPPC list, MDM managed flag, and
  # plugin directory listing without reforking probes.
  local env_file="${MACAUDIT_TMPDIR}/tier3_env.json"
  _baseline_build_tier3_env_file "$env_file" || {
    utils_log_err "_baseline_tier3_walk: failed to build env file"
    return 2
  }

  local pppc_json
  pppc_json=$(jq -c '.pppc_profile_payload_identifiers' "$env_file" 2>/dev/null)
  [ -n "$pppc_json" ] || pppc_json='[]'

  # -- FDA-gated surfaces -------------------------------------------------
  if [ "$fda_ok" -eq 1 ]; then
    # System TCC.db
    tcc_capture_system "$scratch_entries" "$pppc_json" >/dev/null 2>&1 \
      || _baseline_append_skipped "$scratch_skipped" \
           "$(tcc_system_path)" "permission-denied"

    # Per-user TCC.db, one per enumerable home.
    local home
    while IFS= read -r home; do
      [ -n "$home" ] || continue
      local user_tcc
      user_tcc=$(tcc_user_path "$home")
      if [ ! -r "$user_tcc" ]; then
        # No per-user TCC.db for this home is a normal state on a
        # newly-provisioned account — do not flag it.
        continue
      fi
      tcc_capture_user "$home" "$scratch_entries" "$pppc_json" >/dev/null 2>&1 \
        || _baseline_append_skipped "$scratch_skipped" \
             "$user_tcc" "permission-denied"
    done < <(_baseline_enumerable_homes "$user_only")

    # KextPolicy / ExecPolicy
    sysdb_capture_kextpolicy "$scratch_entries" >/dev/null 2>&1 \
      || _baseline_append_skipped "$scratch_skipped" \
           "${KEXTPOLICY_PATH_OVERRIDE:-/var/db/SystemPolicyConfiguration/KextPolicy}" \
           "permission-denied"
    sysdb_capture_execpolicy "$scratch_entries" >/dev/null 2>&1 \
      || _baseline_append_skipped "$scratch_skipped" \
           "${EXECPOLICY_PATH_OVERRIDE:-/var/db/SystemPolicyConfiguration/ExecPolicy}" \
           "permission-denied"
  else
    # FDA unavailable — record each FDA-protected surface in skipped.
    _baseline_append_skipped "$scratch_skipped" \
      "$(tcc_system_path)" "fda-unavailable"
    _baseline_append_skipped "$scratch_skipped" \
      "${KEXTPOLICY_PATH_OVERRIDE:-/var/db/SystemPolicyConfiguration/KextPolicy}" \
      "fda-unavailable"
    _baseline_append_skipped "$scratch_skipped" \
      "${EXECPOLICY_PATH_OVERRIDE:-/var/db/SystemPolicyConfiguration/ExecPolicy}" \
      "fda-unavailable"
  fi

  # -- Non-FDA surfaces (always attempted) --------------------------------
  # SystemPolicy: the module itself degrades gracefully when sudo is
  # absent (still emits an entry with the spctl-derived Gatekeeper
  # state and an empty policy_scan). We still record a "no-sudo" skip
  # note when utils_has_sudo is false so the operator sees WHY the
  # policy_scan array is empty on their report.
  if ! utils_has_sudo; then
    _baseline_append_skipped "$scratch_skipped" \
      "${SYSTEMPOLICY_PATH_OVERRIDE:-/var/db/SystemPolicyConfiguration/SystemPolicy}" \
      "no-sudo"
  fi
  sysdb_capture_systempolicy "$scratch_entries" >/dev/null 2>&1 || true

  # AuthorizationDB — read via `security authorizationdb read`; no
  # FDA / sudo gate. Missing rule/right names are logged but do not
  # propagate as a walk failure.
  sysdb_capture_authdb "$scratch_entries" >/dev/null 2>&1 || true

  # XProtect — bundle walk, always attempted. A missing bundle (e.g.
  # on a test harness without XPROTECT_BUNDLE_OVERRIDE) is recorded
  # in skipped_paths with reason "missing" rather than silently
  # dropped, per the header-schema expectation.
  local xp_bundle
  xp_bundle=$(xprotect_bundle_path)
  if [ -n "$xp_bundle" ] && [ -d "$xp_bundle" ]; then
    xprotect_capture "$xp_bundle" "$scratch_entries" >/dev/null 2>&1 \
      || _baseline_append_skipped "$scratch_skipped" \
           "$xp_bundle" "permission-denied"
  else
    _baseline_append_skipped "$scratch_skipped" \
      "${xp_bundle:-/Library/Apple/System/Library/CoreServices/XProtect.bundle}" \
      "missing"
  fi

  # Per-user quarantine events — one per enumerable home.
  local uhome
  while IFS= read -r uhome; do
    [ -n "$uhome" ] || continue
    quarantine_capture_user "$uhome" "$scratch_entries" >/dev/null 2>&1 || true
  done < <(_baseline_enumerable_homes "$user_only")

  return 0
}

# baseline_run_tier3 <scratch_entries> <scratch_skipped> <user_only> <fda_available_json>
#   Public facade over `_baseline_tier3_walk`. The signature is kept
#   stable for the test harness and any future external caller; all
#   real work happens inside the walker.
baseline_run_tier3() {
  _baseline_tier3_walk "$@"
}

# -----------------------------------------------------------------------------
# Cross-surface correlation (R1–R5)
# -----------------------------------------------------------------------------
# `baseline_correlate` implements the five correlation rules in
# design.md §"Algorithm: Cross-Surface Correlation (R1–R5)":
#
#   R1 tcc_mdm_without_profile   — tcc access row with auth_reason == 6
#                                  whose client is absent from the
#                                  PPPC profile identifier set.
#   R2 persistence_quarantine_orphan
#                                — Tier 1 plist carries a quarantine
#                                  xattr whose UUID does not resolve
#                                  against any quarantine_events entry.
#                                  (The "no quarantine" variant is
#                                  deferred to audit.sh task 15G so
#                                  the strict "added" gate can be
#                                  applied against the delta.)
#   R3 persistence_codesign_fail — Tier 1 plist Program or
#                                  ProgramArguments[0] binary fails
#                                  `codesign --verify --deep --strict`.
#   R4 kext_user_approved_on_mdm — kext_policy row missing from
#                                  kext_policy_mdm by (team_id,
#                                  bundle_id), on an MDM-managed host.
#   R5 authdb_missing_plugin     — authorizationdb mechanism whose
#                                  classification is "missing".
#
# Every correlation entry is built via `manifest_build_entry` with the
# Tier-3 triplet coaxing (empty --sha256-checkpointed, false
# --wal-present, empty --wal-sha256, '{}' --table-snapshots-json) so
# the resulting row carries an `anomalies[]` array under the standard
# Tier 3 schema.

# _baseline_emit_correlation_to_stdout <rule_id> <rule_name> <severity> <detail_json>
#   Emit one correlation entry to stdout (one line of JSONL). The
#   entry's `surface` is "correlation" and its `path` is
#     correlation://<rule_id>:<rule_name>
#   The anomalies[] field holds exactly one `{rule, severity, detail}`
#   object.
#
#   Returns 0 on success, 1 on a `manifest_build_entry` failure. When
#   severity is absent we look it up via `surfaces_anomaly_severity_for_rule`.
_baseline_emit_correlation_to_stdout() {
  local rule_id="$1"
  local rule_name="$2"
  local severity="$3"
  local detail_json="$4"

  [ -n "$rule_id" ]   || return 1
  [ -n "$rule_name" ] || return 1
  if [ -z "$severity" ]; then
    severity=$(surfaces_anomaly_severity_for_rule "correlation:${rule_name}")
  fi
  [ -n "$severity" ]  || return 1
  [ -n "$detail_json" ] || detail_json='null'

  # Validate the detail JSON up front; if it does not parse, fall
  # back to a null detail so the correlation entry still lands.
  if ! printf '%s' "$detail_json" | jq . >/dev/null 2>&1; then
    detail_json='null'
  fi

  local path="correlation://${rule_id}:${rule_name}"
  local anomalies
  anomalies=$(jq -cn \
    --arg rule "correlation:${rule_name}" \
    --arg severity "$severity" \
    --argjson detail "$detail_json" \
    '[{rule: $rule, severity: $severity, detail: $detail}]')
  [ -n "$anomalies" ] || return 1

  local entry
  entry=$(manifest_build_entry \
    --path "$path" \
    --tier 3 \
    --surface "correlation" \
    --format "n/a" \
    --sha256-raw "" \
    --sha256-canonical "" \
    --size "" \
    --mtime "" \
    --xattrs-json '{}' \
    --content-json '{}' \
    --sha256-checkpointed "" \
    --wal-present false \
    --wal-sha256 "" \
    --table-snapshots-json '{}' \
    --anomalies-json "$anomalies")
  [ -n "$entry" ] || return 1

  printf '%s\n' "$entry"
  return 0
}

# _baseline_emit_correlation <scratch_entries> <rule_id> <rule_name> <severity> <detail_json>
#   Back-compat shim used by the legacy `baseline_correlate` call
#   path. Writes the resulting entry to the scratch file via
#   `manifest_write_entry`. New code should call
#   `_baseline_emit_correlation_to_stdout` and aggregate in the
#   caller.
_baseline_emit_correlation() {
  local scratch="$1"
  local rule_id="$2"
  local rule_name="$3"
  local severity="$4"
  local detail_json="$5"

  [ -n "$scratch" ]   || return 1

  local entry
  entry=$(_baseline_emit_correlation_to_stdout \
    "$rule_id" "$rule_name" "$severity" "$detail_json")
  [ -n "$entry" ] || return 1

  manifest_write_entry "$scratch" "$entry" || return 1
  return 0
}

# _baseline_correlate_r1 <tier3_entries_file> <pppc_json>
#   R1: For every (tcc_system, tcc_user) entry's
#   table_snapshots.access.rows[], emit tcc_mdm_without_profile to
#   stdout for each row where auth_reason == 6 AND client is not in
#   $pppc.
#
#   jq gotcha note (design.md): `index(filter)` inside a select on a
#   row runs the filter against the array as `.`, not the outer row.
#   We bind the row into `$r` first so the client lookup is against
#   the row's own `client` field.
_baseline_correlate_r1() {
  local tier3="$1"
  local pppc_json="$2"

  [ -s "$tier3" ] || return 0
  [ -n "$pppc_json" ] || pppc_json='[]'

  local hits
  hits=$(jq -s -c \
    --argjson pppc "$pppc_json" \
    '
      [ .[]
        | select(.surface == "tcc_system" or .surface == "tcc_user")
        | .table_snapshots.access.rows // []
        | .[] as $r
        | select($r.auth_reason == 6
                 and ($pppc | index($r.client)) == null)
        | $r
      ]
      | .[]
    ' \
    "$tier3" 2>/dev/null) || return 0

  [ -n "$hits" ] || return 0

  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    _baseline_emit_correlation_to_stdout \
      "R1" "tcc_mdm_without_profile" "high" "$row"
  done <<EOF
$hits
EOF
  return 0
}

# _baseline_correlate_r2 <tier1_entries_file> <tier3_entries_file>
#   R2 (orphan only — the "no quarantine" variant is deferred to
#   audit.sh / task 15G): for every Tier 1 plist entry that carries a
#   com.apple.quarantine xattr whose UUID does not resolve in any
#   quarantine_events checkpoint, emit persistence_quarantine_orphan
#   to stdout.
_baseline_correlate_r2() {
  local tier1="$1"
  local tier3="$2"

  [ -s "$tier1" ] || return 0

  # Collect every quarantine_events checkpointed copy path present in
  # the current run. The R2 lookup is done against the checkpointed
  # copy (via quarantine_lookup_uuid) rather than the live DB.
  local qe_copies=""
  if [ -s "$tier3" ]; then
    qe_copies=$(jq -sr '
        map(select(.surface == "quarantine_events"))
        | map(.path // empty)
        | .[]
      ' "$tier3" 2>/dev/null)
  fi

  # Collect every Tier 1 plist path for which we have an on-disk file
  # with a quarantine xattr.
  local tier1_paths
  tier1_paths=$(jq -sr '
      map(select(.tier == 1 and (.path | startswith("launchctl://") | not)))
      | map(.path // empty)
      | .[]
    ' "$tier1" 2>/dev/null)
  [ -n "$tier1_paths" ] || return 0

  local plist uuid qe_db matched detail
  while IFS= read -r plist; do
    [ -n "$plist" ] || continue
    [ -e "$plist" ] || continue
    uuid=$(quarantine_xattr_uuid "$plist")
    [ -n "$uuid" ] || continue

    matched=0
    if [ -n "$qe_copies" ]; then
      while IFS= read -r qe_db; do
        [ -n "$qe_db" ] || continue
        local copy
        copy=$(sqlite_safe_copy "$qe_db")
        [ -n "$copy" ] || continue
        if quarantine_lookup_uuid "$copy" "$uuid"; then
          matched=1
          break
        fi
      done <<EOF
$qe_copies
EOF
    fi

    if [ "$matched" -eq 0 ]; then
      detail=$(jq -cn --arg plist "$plist" --arg uuid "$uuid" \
        '{plist_path: $plist, uuid: $uuid}')
      _baseline_emit_correlation_to_stdout "R2" \
        "persistence_quarantine_orphan" "info" "$detail"
    fi
  done <<EOF
$tier1_paths
EOF
  return 0
}

# _baseline_correlate_r3 <tier1_entries_file>
#   R3: every Tier 1 plist whose Program / ProgramArguments[0] binary
#   starts with `/` AND fails codesign --verify --deep --strict. We
#   exploit the content.Program / content.ProgramArguments captured
#   by _baseline_extract_launch_content.
_baseline_correlate_r3() {
  local tier1="$1"

  [ -s "$tier1" ] || return 0

  # One line per Tier 1 plist: "<plist_path>\t<binary>"
  local pairs
  pairs=$(jq -sr '
      map(select(.tier == 1))
      | map({path: (.path // ""), bin: (
          (.content.Program // null)
          // (.content.ProgramArguments // [] | .[0] // null)
        )})
      | map(select((.bin // "") | type == "string" and startswith("/")))
      | .[]
      | "\(.path)\t\(.bin)"
    ' "$tier1" 2>/dev/null)
  [ -n "$pairs" ] || return 0

  local line plist bin cs_json valid exit_code stderr_line detail
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    plist=$(printf '%s' "$line" | awk -F '\t' '{print $1}')
    bin=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
    [ -n "$plist" ] || continue
    [ -n "$bin" ]   || continue

    cs_json=$(utils_codesign_verify "$bin")
    if [ -z "$cs_json" ] || ! printf '%s' "$cs_json" | jq -e . >/dev/null 2>&1; then
      # codesign unavailable → cannot fire the rule deterministically.
      continue
    fi
    valid=$(printf '%s' "$cs_json" | jq -r '.valid // false' 2>/dev/null)
    if [ "$valid" = "true" ]; then
      continue
    fi
    exit_code=$(printf '%s' "$cs_json" | jq -r '.exit_code // 0' 2>/dev/null)
    stderr_line=$(printf '%s' "$cs_json" | jq -r '.stderr_first_line // ""' 2>/dev/null)
    # Clip stderr to 200 chars to keep the correlation detail compact.
    stderr_line=$(printf '%s' "$stderr_line" | cut -c1-200)

    detail=$(jq -cn \
      --arg plist "$plist" \
      --arg binary "$bin" \
      --argjson exit_code "${exit_code:-0}" \
      --arg stderr "$stderr_line" \
      '{plist_path: $plist, binary: $binary, exit_code: $exit_code, stderr: $stderr}')
    _baseline_emit_correlation_to_stdout \
      "R3" "persistence_codesign_fail" "high" "$detail"
  done <<EOF
$pairs
EOF
  return 0
}

# _baseline_correlate_r4 <tier3_entries_file> <mdm_managed_bool>
#   R4: on MDM-managed hosts, emit kext_user_approved_on_mdm for every
#   kext_policy row that is NOT matched by a (team_id, bundle_id)
#   entry in kext_policy_mdm.
_baseline_correlate_r4() {
  local tier3="$1"
  local mdm_managed="$2"

  [ -s "$tier3" ] || return 0

  # Gate on MDM managed state — the env file already records this
  # once per run, so we take it as a parameter rather than re-probing.
  if [ "$mdm_managed" != "true" ]; then
    return 0
  fi

  local hits
  hits=$(jq -s -c '
      map(select(.surface == "kextpolicy"))
      | .[0] // null
      | if . == null then []
        else
          (.table_snapshots.kext_policy.rows // []) as $user
          | (.table_snapshots.kext_policy_mdm.rows // []) as $mdm
          | ($mdm | map({team_id, bundle_id})) as $keys
          | $user | map(select(
              (. as $r | $keys | index({team_id: $r.team_id, bundle_id: $r.bundle_id})) == null
            ))
        end
      | .[]
    ' "$tier3" 2>/dev/null)
  [ -n "$hits" ] || return 0

  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    _baseline_emit_correlation_to_stdout \
      "R4" "kext_user_approved_on_mdm" "high" "$row"
  done <<EOF
$hits
EOF
  return 0
}

# _baseline_correlate_r5 <tier3_entries_file>
#   R5: for each authdb entry, for each mechanism in
#   content.mechanisms, classify via sysdb_classify_mechanism. When
#   the classification is "missing", emit authdb_missing_plugin.
#
#   The plugin directory listing cache (MACAUDIT_PLUGIN_LISTING) is
#   populated once per run via sysdb_plugin_dirs_listing before the
#   loop, so each classification reuses the cached listing.
_baseline_correlate_r5() {
  local tier3="$1"

  [ -s "$tier3" ] || return 0

  # Populate the plugin listing cache once; subsequent classifier
  # calls all read MACAUDIT_PLUGIN_LISTING.
  sysdb_plugin_dirs_listing >/dev/null 2>&1

  # Emit "<path>\t<mech>" pairs for every mechanism of every authdb
  # entry. We keep one pair per line so the shell can walk the set
  # without a jq `--raw-output0` that not every jq build supports.
  local pairs
  pairs=$(jq -sr '
      map(select(.surface == "authdb"))
      | map(. as $e
            | (($e.content.mechanisms // []) | map(tostring)) as $ms
            | $ms | map([$e.path, .] | @tsv)
            | .[])
      | .[]
    ' "$tier3" 2>/dev/null)
  [ -n "$pairs" ] || return 0

  local line rule_path mech cls detail
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rule_path=$(printf '%s' "$line" | awk -F '\t' '{print $1}')
    mech=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
    [ -n "$mech" ] || continue
    cls=$(sysdb_classify_mechanism "$mech")
    if [ "$cls" != "missing" ]; then
      continue
    fi
    detail=$(jq -cn --arg r "$rule_path" --arg m "$mech" \
      '{rule_or_right: $r, mechanism: $m}')
    _baseline_emit_correlation_to_stdout \
      "R5" "authdb_missing_plugin" "high" "$detail"
  done <<EOF
$pairs
EOF
  return 0
}

# baseline_correlate <tier1_entries_file> <tier3_entries_file> <env_file>
#   Implement the R1–R5 cross-surface correlation pass per design.md
#   §"Algorithm: Cross-Surface Correlation". Reads tier1 entries from
#   <tier1_entries_file>, tier3 entries from <tier3_entries_file>
#   (both may point to the same combined JSONL stream — jq partitions
#   via `select(.tier == N)`), and the run-wide env object (PPPC
#   payloads, MDM-managed flag, plugin dirs) from <env_file>.
#
#   stdout: zero or more correlation entries as JSONL (one per line).
#   return: 0 on success; 1 on invalid arguments.
baseline_correlate() {
  local tier1_file="$1"
  local tier3_file="$2"
  local env_file="$3"

  if [ -z "$tier1_file" ] || [ -z "$tier3_file" ] || [ -z "$env_file" ]; then
    utils_log_err "baseline_correlate: three file arguments are required"
    return 1
  fi
  if [ ! -r "$env_file" ]; then
    utils_log_err "baseline_correlate: env file '$env_file' is unreadable"
    return 1
  fi

  # Parse env once.
  local pppc_json mdm_managed plugin_system plugin_3p
  pppc_json=$(jq -c '.pppc_profile_payload_identifiers // []' "$env_file" 2>/dev/null)
  [ -n "$pppc_json" ] || pppc_json='[]'
  mdm_managed=$(jq -r '.mdm_managed // false' "$env_file" 2>/dev/null)
  case "$mdm_managed" in true|false) : ;; *) mdm_managed=false ;; esac
  plugin_system=$(jq -r '.plugin_dirs[0] // ""' "$env_file" 2>/dev/null)
  plugin_3p=$(jq -r '.plugin_dirs[1] // ""' "$env_file" 2>/dev/null)

  # Cache plugin-directory listings under MACAUDIT_TMPDIR so R5
  # never ls's per mechanism. Two scratch files — system first,
  # third-party second — match the env.plugin_dirs ordering.
  local tmp_root="${MACAUDIT_TMPDIR:-${TMPDIR:-/tmp}}"
  tmp_root="${tmp_root%/}"
  local sys_listing="${tmp_root}/plugins_system.txt"
  local tp_listing="${tmp_root}/plugins_3p.txt"
  : > "$sys_listing" 2>/dev/null || true
  : > "$tp_listing"  2>/dev/null || true
  if [ -n "$plugin_system" ] && [ -d "$plugin_system" ] && [ -r "$plugin_system" ]; then
    # macOS BSD `ls` does NOT accept `--` reliably for unusual
    # names; we pipe `ls -1` directly. Basenames only — the classifier
    # expects a name-only listing.
    ls -1 "$plugin_system" 2>/dev/null > "$sys_listing" || true
  fi
  if [ -n "$plugin_3p" ] && [ -d "$plugin_3p" ] && [ -r "$plugin_3p" ]; then
    ls -1 "$plugin_3p" 2>/dev/null > "$tp_listing" || true
  fi

  # Drive each rule. The rules write JSONL to stdout; we append each
  # rule's stdout in order so the final stream is deterministic.
  _baseline_correlate_r1 "$tier3_file" "$pppc_json"
  _baseline_correlate_r2 "$tier1_file" "$tier3_file"
  _baseline_correlate_r3 "$tier1_file"
  _baseline_correlate_r4 "$tier3_file" "$mdm_managed"
  _baseline_correlate_r5 "$tier3_file"

  return 0
}

# =============================================================================
# Section 5: Header finalisation and atomic write
# =============================================================================
# The header is built LAST because `skipped_paths` can only be known
# after both tier walks complete. We write the header to a `.tmp`
# sibling of the final output path, `cat` the scratch entries into the
# same file, then atomically `mv` it into place. Any failure before the
# mv leaves the `.tmp` for cleanup (best-effort) and the final output
# path untouched — which is what the "SIGINT leaves no partial
# manifest" invariant requires.

# _baseline_finalize <output> <tier> <user_only> <entries> <skipped> <tier3_ran> <fda_available_json>
_baseline_finalize() {
  local output="$1"
  local tier="$2"
  local user_only="$3"
  local entries="$4"
  local skipped="$5"
  local tier3_ran="${6:-0}"
  local fda_available_json="${7:-null}"

  # -- skipped_paths: slurp the JSONL into a JSON array -------------------
  local skipped_array
  if [ -s "$skipped" ]; then
    skipped_array=$(jq -cs '.' < "$skipped" 2>/dev/null)
  fi
  [ -n "$skipped_array" ] || skipped_array='[]'

  # -- header ------------------------------------------------------------
  local user_only_bool
  user_only_bool=$(_baseline_user_only_bool "$user_only")

  # When Tier 3 ran, compose an environment block and upgrade the
  # version fields (via --has-tier3). Otherwise keep the env/fda
  # fields at their Tier 1/2 defaults (null / 1.0 / 0.1.0-phase1).
  local header
  if [ "$tier3_ran" -eq 1 ]; then
    local environment_json
    environment_json=$(_baseline_build_environment "$fda_available_json")
    [ -n "$environment_json" ] || environment_json='null'

    header=$(manifest_build_header \
      --tier "$tier" \
      --user-only "$user_only_bool" \
      --skipped-json "$skipped_array" \
      --fda-available "$fda_available_json" \
      --environment-json "$environment_json" \
      --has-tier3) || return 1
  else
    header=$(manifest_build_header \
      --tier "$tier" \
      --user-only "$user_only_bool" \
      --skipped-json "$skipped_array") || return 1
  fi

  # -- atomic write ------------------------------------------------------
  # Ensure the output directory exists — if the caller passed a path
  # whose parent does not exist, we refuse with exit 2 at the
  # dispatcher rather than silently creating surprise directories.
  local parent
  parent=$(dirname -- "$output")
  if [ -n "$parent" ] && [ "$parent" != "." ] && [ ! -d "$parent" ]; then
    utils_log_err "baseline_run: output directory '$parent' does not exist"
    return 1
  fi

  local tmp="${output}.tmp"
  # Explicitly overwrite any prior .tmp so a failed earlier attempt
  # doesn't pollute this run.
  : > "$tmp" || {
    utils_log_err "baseline_run: unable to write '$tmp'"
    return 1
  }
  printf '%s\n' "$header" >> "$tmp" || {
    rm -f -- "$tmp"
    utils_log_err "baseline_run: unable to write header to '$tmp'"
    return 1
  }
  if [ -s "$entries" ]; then
    cat -- "$entries" >> "$tmp" || {
      rm -f -- "$tmp"
      utils_log_err "baseline_run: unable to append entries to '$tmp'"
      return 1
    }
  fi

  if ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    utils_log_err "baseline_run: unable to move '$tmp' to '$output'"
    return 1
  fi

  return 0
}
