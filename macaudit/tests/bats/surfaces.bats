#!/usr/bin/env bats
# tests/bats/surfaces.bats — unit tests for lib/surfaces.sh tier classifiers,
# key tables, and anomaly rule registry.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/surfaces.sh"
  HOME_FIXTURE="/Users/tester"
}

# -----------------------------------------------------------------------------
# Tier 1 path classification
# -----------------------------------------------------------------------------

@test "surfaces_tier_of: every tier-1 system path classifies as 1" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "1" ] || { echo "expected tier=1 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier1_system_paths)
}

@test "surfaces_tier_of: every tier-1 user path classifies as 1" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "1" ] || { echo "expected tier=1 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier1_user_paths "${HOME_FIXTURE}")
}

# -----------------------------------------------------------------------------
# Tier 2 path classification — QuarantineEventsV2 is the Tier 3 carve-out
# -----------------------------------------------------------------------------

@test "surfaces_tier_of: every tier-2 system path classifies as 2" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "2" ] || { echo "expected tier=2 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier2_system_paths)
}

@test "surfaces_tier_of: every tier-2 user path classifies as 2" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "2" ] || { echo "expected tier=2 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier2_user_paths "${HOME_FIXTURE}")
}

@test "surfaces_tier_of: every tier-2 managed path classifies as 2" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "2" ] || { echo "expected tier=2 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier2_managed_paths "${HOME_FIXTURE}" "tester")
}

# -----------------------------------------------------------------------------
# Tier 3 path classification — virtual + on-disk + QuarantineEventsV2 carve-out
# -----------------------------------------------------------------------------

@test "surfaces_tier_of: every tier-3 system path classifies as 3" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "3" ] || { echo "expected tier=3 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier3_system_paths)
}

@test "surfaces_tier_of: every tier-3 user path classifies as 3 (incl. QuarantineEventsV2)" {
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    tier=$(surfaces_tier_of "${line}")
    [ "${tier}" = "3" ] || { echo "expected tier=3 for '${line}', got '${tier}'"; false; }
  done < <(surfaces_tier3_user_paths "${HOME_FIXTURE}")
}

@test "surfaces_tier_of: security:// and correlation:// virtual paths are tier 3" {
  [ "$(surfaces_tier_of 'security://authorizationdb/system.privilege.admin')" = "3" ]
  [ "$(surfaces_tier_of 'correlation://R1:some-label')" = "3" ]
}

@test "surfaces_tier_of: unrecognised path returns empty" {
  got=$(surfaces_tier_of /tmp/random)
  [ -z "${got}" ]
  got=$(surfaces_tier_of "")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# Launch-key set: exactly 12, no duplicates
# -----------------------------------------------------------------------------

@test "surfaces_launch_keys: emits exactly 12 unique keys" {
  total=$(surfaces_launch_keys | wc -l | tr -d ' ')
  unique=$(surfaces_launch_keys | sort -u | wc -l | tr -d ' ')
  [ "${total}" -eq 12 ]
  [ "${unique}" -eq 12 ]
}

@test "surfaces_launch_keys: contains the documented twelve keys" {
  keys=$(surfaces_launch_keys)
  for k in Label Program ProgramArguments RunAtLoad KeepAlive WatchPaths \
           StartInterval StartCalendarInterval MachServices Sockets UserName GroupName; do
    echo "${keys}" | grep -Fxq "${k}" || { echo "missing key: ${k}"; false; }
  done
}

# -----------------------------------------------------------------------------
# Security-critical keys per domain
# -----------------------------------------------------------------------------

@test "surfaces_security_keys_for_domain: expected counts for each documented domain" {
  [ "$(surfaces_security_keys_for_domain com.apple.loginwindow | wc -l | tr -d ' ')" -eq 5 ]
  [ "$(surfaces_security_keys_for_domain com.apple.screensaver | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(surfaces_security_keys_for_domain com.apple.SoftwareUpdate | wc -l | tr -d ' ')" -eq 4 ]
  [ "$(surfaces_security_keys_for_domain com.apple.alf | wc -l | tr -d ' ')" -eq 4 ]
  [ "$(surfaces_security_keys_for_domain .GlobalPreferences | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(surfaces_security_keys_for_domain com.apple.Safari | wc -l | tr -d ' ')" -eq 3 ]
}

@test "surfaces_security_keys_for_domain: NSGlobalDomain aliases .GlobalPreferences" {
  a=$(surfaces_security_keys_for_domain .GlobalPreferences)
  b=$(surfaces_security_keys_for_domain NSGlobalDomain)
  [ "${a}" = "${b}" ]
  [ -n "${a}" ]
}

@test "surfaces_security_keys_for_domain: unknown domain returns empty" {
  got=$(surfaces_security_keys_for_domain com.unknown.example)
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# surfaces_is_apple_signed_parent
# -----------------------------------------------------------------------------

@test "surfaces_is_apple_signed_parent: returns 0 for apple-first-party prefixes" {
  run surfaces_is_apple_signed_parent /System/Library/Something
  [ "${status}" -eq 0 ]
  run surfaces_is_apple_signed_parent /usr/bin/whatever
  [ "${status}" -eq 0 ]
  run surfaces_is_apple_signed_parent /Library/Apple/FooBar
  [ "${status}" -eq 0 ]
}

@test "surfaces_is_apple_signed_parent: returns non-zero for third-party paths" {
  run surfaces_is_apple_signed_parent /tmp/x
  [ "${status}" -ne 0 ]
  run surfaces_is_apple_signed_parent /Applications/Chrome.app
  [ "${status}" -ne 0 ]
}

# -----------------------------------------------------------------------------
# surfaces_tier3_surface_for_path — one surface name per Tier 3 path category
# -----------------------------------------------------------------------------

@test "surfaces_tier3_surface_for_path: each Tier 3 path maps to the expected surface" {
  [ "$(surfaces_tier3_surface_for_path '/Library/Application Support/com.apple.TCC/TCC.db')" = "tcc_system" ]
  [ "$(surfaces_tier3_surface_for_path "${HOME_FIXTURE}/Library/Application Support/com.apple.TCC/TCC.db")" = "tcc_user" ]
  [ "$(surfaces_tier3_surface_for_path /var/db/SystemPolicyConfiguration/KextPolicy)" = "kextpolicy" ]
  [ "$(surfaces_tier3_surface_for_path /var/db/SystemPolicyConfiguration/ExecPolicy)" = "execpolicy" ]
  [ "$(surfaces_tier3_surface_for_path /var/db/SystemPolicyConfiguration/SystemPolicy)" = "systempolicy" ]
  [ "$(surfaces_tier3_surface_for_path "${HOME_FIXTURE}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")" = "quarantine_events" ]
  [ "$(surfaces_tier3_surface_for_path /Library/Apple/System/Library/CoreServices/XProtect.bundle)" = "xprotect" ]
  [ "$(surfaces_tier3_surface_for_path 'security://authorizationdb/system.privilege.admin')" = "authdb" ]
  [ "$(surfaces_tier3_surface_for_path 'correlation://R1:x')" = "correlation" ]
}

@test "surfaces_tier3_surface_for_path: unrecognised path returns empty" {
  got=$(surfaces_tier3_surface_for_path /tmp/x)
  [ -z "${got}" ]
  got=$(surfaces_tier3_surface_for_path /Library/LaunchDaemons/com.foo.plist)
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# Anomaly rule registry
# -----------------------------------------------------------------------------

@test "surfaces_anomaly_rule_ids: exactly 15 unique rule ids" {
  total=$(surfaces_anomaly_rule_ids | wc -l | tr -d ' ')
  unique=$(surfaces_anomaly_rule_ids | sort -u | wc -l | tr -d ' ')
  [ "${total}" -eq 15 ]
  [ "${unique}" -eq 15 ]
}

@test "surfaces_anomaly_severity_for_rule: severities for representative rules" {
  [ "$(surfaces_anomaly_severity_for_rule tcc_override_policy)" = "high" ]
  [ "$(surfaces_anomaly_severity_for_rule tcc_av_unusual_reason)" = "warn" ]
  [ "$(surfaces_anomaly_severity_for_rule 'correlation:persistence_quarantine_orphan')" = "info" ]
  [ "$(surfaces_anomaly_severity_for_rule authdb_third_party_plugin)" = "warn" ]
  [ "$(surfaces_anomaly_severity_for_rule xprotect_codesign_fail)" = "high" ]
}

@test "surfaces_anomaly_severity_for_rule: unknown rule returns empty" {
  got=$(surfaces_anomaly_severity_for_rule unknown_rule_xyz)
  [ -z "${got}" ]
}

@test "surfaces_anomaly_severity_for_rule: every registered rule has a severity" {
  while IFS= read -r rule; do
    [ -n "${rule}" ] || continue
    sev=$(surfaces_anomaly_severity_for_rule "${rule}")
    case "${sev}" in
      info|warn|high) : ;;
      *) echo "rule '${rule}' has unexpected severity '${sev}'"; false ;;
    esac
  done < <(surfaces_anomaly_rule_ids)
}
