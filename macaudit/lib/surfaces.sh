#!/bin/bash
# lib/surfaces.sh — canonical definitions of audit surfaces: Tier 1 (persistence)
# and Tier 2 (preferences) path lists, per-domain security-critical key maps,
# tier membership predicates, the launch-key extraction set, Tier 3 (security
# databases) surface mapping, and the anomaly rule registry.
#
# All functions are pure: no mutation of the environment, no side effects.
# Output uses `printf '%s\n'` (never `echo`) for deterministic handling of
# whitespace and flag-like values. Paths with spaces (e.g. "/Library/Managed
# Preferences") are emitted intact and must be consumed quoting-safely by
# callers — a `while read -r line` loop is safer than word-splitting.
#
# bash 3.2 compatibility: no associative arrays, no `readonly` at file scope.
# Domain→keys and path→tier mappings use `case` statements.

# -----------------------------------------------------------------------------
# Section 1: Path enumerators (Tier 1, Tier 2, Tier 3, FDA-protected subset)
# -----------------------------------------------------------------------------
# Each enumerator emits newline-separated absolute paths (or glob patterns
# that callers expand). Functions taking a `$home` argument default to
# `${HOME}` when the argument is empty; functions taking `$user` as well
# default to `${USER:-}` and omit user-scoped lines when the resolved user
# is the empty string. Empty output is a legitimate state and the
# functions still return exit 0.

# surfaces_tier1_system_paths
#   stdout: Tier 1 system-scope persistence roots, one path per line.
surfaces_tier1_system_paths() {
  printf '%s\n' /Library/LaunchDaemons
  printf '%s\n' /Library/LaunchAgents
  printf '%s\n' /etc/periodic/daily
  printf '%s\n' /etc/periodic/weekly
  printf '%s\n' /etc/periodic/monthly
  printf '%s\n' /Library/Security/SecurityAgentPlugins
  printf '%s\n' /etc/emond.d/rules
  printf '%s\n' /var/at/tabs
}

# surfaces_tier1_user_paths [home]
#   stdout: Tier 1 per-user persistence roots for the supplied home directory.
#           Defaults to ${HOME} when $1 is empty.
surfaces_tier1_user_paths() {
  local home="${1:-$HOME}"
  printf '%s\n' "${home}/Library/LaunchAgents"
}

# surfaces_tier2_system_paths
#   stdout: Tier 2 system-scope preference roots.
surfaces_tier2_system_paths() {
  printf '%s\n' /Library/Preferences
  printf '%s\n' "/Library/Managed Preferences"
}

# surfaces_tier2_user_paths [home]
#   stdout: Tier 2 per-user preference root for the supplied home directory.
surfaces_tier2_user_paths() {
  local home="${1:-$HOME}"
  printf '%s\n' "${home}/Library/Preferences"
}

# surfaces_tier2_managed_paths [home] [user]
#   stdout: Managed-preferences paths. The system-wide managed root always
#           appears; the per-user managed root is appended only when $user
#           resolves to a non-empty value.
surfaces_tier2_managed_paths() {
  local home="${1:-$HOME}"
  local user="${2:-${USER:-}}"
  printf '%s\n' "/Library/Managed Preferences"
  if [ -n "$user" ]; then
    printf '%s\n' "/Library/Managed Preferences/${user}"
  fi
}

# surfaces_tier3_system_paths
#   stdout: Tier 3 system-scope security-database paths.
surfaces_tier3_system_paths() {
  printf '%s\n' "/Library/Application Support/com.apple.TCC/TCC.db"
  printf '%s\n' /var/db/SystemPolicyConfiguration/KextPolicy
  printf '%s\n' /var/db/SystemPolicyConfiguration/ExecPolicy
  printf '%s\n' /var/db/SystemPolicyConfiguration/SystemPolicy
  printf '%s\n' /Library/Apple/System/Library/CoreServices/XProtect.bundle
}

# surfaces_tier3_user_paths [home]
#   stdout: Tier 3 per-user security-database paths.
surfaces_tier3_user_paths() {
  local home="${1:-$HOME}"
  printf '%s\n' "${home}/Library/Application Support/com.apple.TCC/TCC.db"
  printf '%s\n' "${home}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
}

# surfaces_tier3_fda_protected_paths
#   stdout: subset of Tier 3 system paths that require Full Disk Access to
#           read. Used by the FDA probe to gate capture attempts.
surfaces_tier3_fda_protected_paths() {
  printf '%s\n' "/Library/Application Support/com.apple.TCC/TCC.db"
  printf '%s\n' /var/db/SystemPolicyConfiguration/KextPolicy
  printf '%s\n' /var/db/SystemPolicyConfiguration/ExecPolicy
}

# -----------------------------------------------------------------------------
# Section 2: Key extraction tables (launch keys, per-domain security keys)
# -----------------------------------------------------------------------------
# The launch-key set is the stable list of plist keys the tool extracts
# from every Tier 1 launchd plist. The per-domain security-critical key
# map is the hardcoded list of high-value keys read from each Tier 2
# preference domain. Both tables are defined here so rule identifiers
# and extraction fields remain consistent across releases.

# surfaces_launch_keys
#   stdout: the 12 launch-key names, one per line. Order is stable across
#           invocations but callers should not depend on a specific order.
surfaces_launch_keys() {
  printf '%s\n' Label
  printf '%s\n' Program
  printf '%s\n' ProgramArguments
  printf '%s\n' RunAtLoad
  printf '%s\n' KeepAlive
  printf '%s\n' WatchPaths
  printf '%s\n' StartInterval
  printf '%s\n' StartCalendarInterval
  printf '%s\n' MachServices
  printf '%s\n' Sockets
  printf '%s\n' UserName
  printf '%s\n' GroupName
}

# surfaces_security_keys_for_domain <domain>
#   stdout: the security-critical key list for the supplied preference
#           domain, one key per line. Empty output for any unrecognised
#           domain. "NSGlobalDomain" is accepted as a synonym for
#           ".GlobalPreferences".
surfaces_security_keys_for_domain() {
  local domain="$1"
  case "$domain" in
    com.apple.loginwindow)
      printf '%s\n' LoginHook
      printf '%s\n' LogoutHook
      printf '%s\n' autoLoginUser
      printf '%s\n' SHOWFULLNAME
      printf '%s\n' DisableConsoleAccess
      ;;
    com.apple.screensaver)
      printf '%s\n' askForPassword
      printf '%s\n' askForPasswordDelay
      printf '%s\n' idleTime
      ;;
    com.apple.SoftwareUpdate)
      printf '%s\n' AutomaticCheckEnabled
      printf '%s\n' AutomaticDownload
      printf '%s\n' AutomaticallyInstallMacOSUpdates
      printf '%s\n' CriticalUpdateInstall
      ;;
    com.apple.alf)
      printf '%s\n' globalstate
      printf '%s\n' allowsignedenabled
      printf '%s\n' stealthenabled
      printf '%s\n' loggingenabled
      ;;
    .GlobalPreferences|NSGlobalDomain)
      printf '%s\n' com.apple.security.firewall.enable
      printf '%s\n' AppleShowAllExtensions
      printf '%s\n' NSQuitAlwaysKeepsWindows
      ;;
    com.apple.Safari)
      printf '%s\n' AutoFillPasswords
      printf '%s\n' AutoOpenSafeDownloads
      printf '%s\n' WarnAboutFraudulentWebsites
      ;;
    *)
      : # unknown domain — emit nothing
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Section 3: Tier / surface predicates
# -----------------------------------------------------------------------------
# Classifiers mapping absolute paths (and virtual "security://" /
# "correlation://" identifiers) to their audit tier and, for Tier 3,
# to a stable surface name. Used by `audit.sh` and `report.sh` to
# route entries and to validate that every manifest entry carries a
# recognised tier.

# surfaces_tier_of <path>
#   stdout: "1", "2", "3", or empty when the path does not map to any
#           recognised surface. Path matching is prefix-based and must
#           be tested in a specific order because Tier 3 user paths
#           live under the Tier 2 per-user preference root.
surfaces_tier_of() {
  local path="$1"

  # Tier 3 virtual paths: check first so they never fall through.
  case "$path" in
    security://*|correlation://*)
      printf '%s\n' 3
      return 0
      ;;
  esac

  # Tier 3 on-disk paths. The QuarantineEventsV2 plist sits under the
  # per-user Preferences root and must be classified before Tier 2.
  case "$path" in
    "/Library/Application Support/com.apple.TCC/TCC.db"*)
      printf '%s\n' 3
      return 0
      ;;
    */Library/Application\ Support/com.apple.TCC/TCC.db*)
      printf '%s\n' 3
      return 0
      ;;
    /var/db/SystemPolicyConfiguration/KextPolicy*)
      printf '%s\n' 3
      return 0
      ;;
    /var/db/SystemPolicyConfiguration/ExecPolicy*)
      printf '%s\n' 3
      return 0
      ;;
    /var/db/SystemPolicyConfiguration/SystemPolicy*)
      printf '%s\n' 3
      return 0
      ;;
    /Library/Apple/System/Library/CoreServices/XProtect.bundle*)
      printf '%s\n' 3
      return 0
      ;;
    */Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2*)
      printf '%s\n' 3
      return 0
      ;;
  esac

  # Tier 1: persistence surfaces.
  case "$path" in
    /Library/LaunchDaemons|/Library/LaunchDaemons/*)
      printf '%s\n' 1
      return 0
      ;;
    /Library/LaunchAgents|/Library/LaunchAgents/*)
      printf '%s\n' 1
      return 0
      ;;
    */Library/LaunchAgents|*/Library/LaunchAgents/*)
      printf '%s\n' 1
      return 0
      ;;
    /etc/periodic/daily*|/etc/periodic/weekly*|/etc/periodic/monthly*)
      printf '%s\n' 1
      return 0
      ;;
    /Library/Security/SecurityAgentPlugins|/Library/Security/SecurityAgentPlugins/*)
      printf '%s\n' 1
      return 0
      ;;
    /etc/emond.d/rules|/etc/emond.d/rules/*)
      printf '%s\n' 1
      return 0
      ;;
    /var/at/tabs|/var/at/tabs/*)
      printf '%s\n' 1
      return 0
      ;;
  esac

  # Tier 2: preference surfaces. System-wide managed and per-user
  # preferences both resolve here; the Tier 3 QuarantineEventsV2 case
  # above has already diverted the one path that shares the Tier 2
  # per-user prefix.
  case "$path" in
    /Library/Preferences|/Library/Preferences/*)
      printf '%s\n' 2
      return 0
      ;;
    "/Library/Managed Preferences"|"/Library/Managed Preferences"/*)
      printf '%s\n' 2
      return 0
      ;;
    */Library/Preferences|*/Library/Preferences/*)
      printf '%s\n' 2
      return 0
      ;;
  esac

  # Unknown — empty stdout, still exit 0.
  return 0
}

# surfaces_is_apple_signed_parent <path>
#   exit 0 iff $path begins with a conservative Apple-first-party prefix,
#   exit 1 otherwise. No stdout. Used by forensic notes such as
#   "RunAtLoad binary outside Apple prefix = suspicious".
surfaces_is_apple_signed_parent() {
  local path="$1"
  case "$path" in
    /usr/*|/System/*|/Library/Apple*|/Library/Developer/CommandLineTools/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# surfaces_tier3_surface_for_path <path>
#   stdout: the Tier 3 surface name for $path — one of tcc_system,
#           tcc_user, kextpolicy, execpolicy, systempolicy,
#           quarantine_events, authdb, xprotect, correlation.
#           Empty stdout for any path not on a Tier 3 surface.
surfaces_tier3_surface_for_path() {
  local path="$1"

  # Virtual-path prefixes first.
  case "$path" in
    security://authorizationdb/*)
      printf '%s\n' authdb
      return 0
      ;;
    correlation://*)
      printf '%s\n' correlation
      return 0
      ;;
  esac

  # System TCC.db is an exact prefix match (the path begins with "/Library/").
  case "$path" in
    "/Library/Application Support/com.apple.TCC/TCC.db"*)
      printf '%s\n' tcc_system
      return 0
      ;;
    */Library/Application\ Support/com.apple.TCC/TCC.db*)
      printf '%s\n' tcc_user
      return 0
      ;;
    /var/db/SystemPolicyConfiguration/KextPolicy*)
      printf '%s\n' kextpolicy
      return 0
      ;;
    /var/db/SystemPolicyConfiguration/ExecPolicy*)
      printf '%s\n' execpolicy
      return 0
      ;;
    /var/db/SystemPolicyConfiguration/SystemPolicy*)
      printf '%s\n' systempolicy
      return 0
      ;;
    */Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2*)
      printf '%s\n' quarantine_events
      return 0
      ;;
    /Library/Apple/System/Library/CoreServices/XProtect.bundle*)
      printf '%s\n' xprotect
      return 0
      ;;
  esac

  return 0
}

# -----------------------------------------------------------------------------
# Section 4: Anomaly rule registry
# -----------------------------------------------------------------------------
# Stable identifiers for every rule emitted in Tier 3 `anomalies` arrays
# and in the cross-surface correlation pass. Rule ids are hardcoded here
# so `audit.sh` and `report.sh` can validate unknown identifiers and so
# downstream consumers have a single source of truth. Severities follow
# the Anomaly Rule Registry table in design.md.

# surfaces_anomaly_rule_ids
#   stdout: every known anomaly rule id, one per line, no duplicates.
surfaces_anomaly_rule_ids() {
  printf '%s\n' tcc_override_policy
  printf '%s\n' tcc_av_unusual_reason
  printf '%s\n' tcc_fda_unsigned
  printf '%s\n' tcc_mdm_without_profile
  printf '%s\n' authdb_third_party_plugin
  printf '%s\n' authdb_missing_plugin
  printf '%s\n' kext_user_approved_on_mdm
  printf '%s\n' gatekeeper_disabled
  printf '%s\n' xprotect_codesign_fail
  printf '%s\n' correlation:persistence_quarantine_orphan
  printf '%s\n' correlation:persistence_no_quarantine
  printf '%s\n' correlation:persistence_codesign_fail
  printf '%s\n' correlation:kext_user_approved_on_mdm
  printf '%s\n' correlation:tcc_mdm_without_profile
  printf '%s\n' correlation:authdb_missing_plugin
}

# surfaces_anomaly_severity_for_rule <rule_id>
#   stdout: "info", "warn", "high", or empty for an unknown rule id.
surfaces_anomaly_severity_for_rule() {
  local rule="$1"
  case "$rule" in
    correlation:persistence_quarantine_orphan)
      printf '%s\n' info
      ;;
    tcc_av_unusual_reason|authdb_third_party_plugin|correlation:persistence_no_quarantine)
      printf '%s\n' warn
      ;;
    tcc_override_policy|tcc_fda_unsigned|tcc_mdm_without_profile|\
    authdb_missing_plugin|kext_user_approved_on_mdm|gatekeeper_disabled|\
    xprotect_codesign_fail|correlation:persistence_codesign_fail|\
    correlation:kext_user_approved_on_mdm|correlation:tcc_mdm_without_profile|\
    correlation:authdb_missing_plugin)
      printf '%s\n' high
      ;;
    *)
      : # unknown — empty stdout
      ;;
  esac
}
