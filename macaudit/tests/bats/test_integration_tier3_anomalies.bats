#!/usr/bin/env bats
# tests/bats/test_integration_tier3_anomalies.bats — end-to-end
# integration scenarios for tasks 16.13 through 16.17 of the macaudit
# spec. Every scenario drives a Tier 3 anomaly rule through a full
# baseline → audit cycle via the CLI child-process pattern established
# in test_integration_tier12.bats.
#
# Each test:
#
#   * Creates a per-test $FIXTURE_DIR and seeds it as a fake $HOME
#     with the Library subdirs the Tier 1 / Tier 2 walks need so they
#     do not error out before Tier 3 runs.
#   * Seeds the specific Tier 3 fixture surface (TCC.db, KextPolicy,
#     SystemPolicy, XProtect bundle) via `sqlite3` / file writes.
#   * Pins the relevant `*_PATH_OVERRIDE` env var at the fixture so
#     no test ever touches /Library or /var.
#   * Pins MACAUDIT_FDA_AVAILABLE and MACAUDIT_MDM_MANAGED where
#     needed to avoid real probes.
#   * Uses `--tier all` (or `--tier 3`) so Tier 3 actually captures.
#   * Tears everything down (rm -rf FIXTURE_DIR + unsets every env
#     var the test set) in teardown.
#
# The assertions focus on anomaly surfacing through the delta JSON:
#
#   * tier3.suspicious — current-state entries with a non-empty
#     anomalies[] array. Membership is driven by the current
#     manifest alone (Requirement 29.2).
#   * tier3.modified   — before/after field diff for drift cases.
#   * Exit status 3    — any tier with a non-empty category AND at
#                        least one suspicious entry triggers the
#                        three-way rule's suspicious exit.

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Fixtures + shared helpers
# ---------------------------------------------------------------------------

setup() {
  MACAUDIT="${BATS_TEST_DIRNAME}/../../macaudit.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-tier3a.XXXXXX")"
  FAKE_HOME="${FIXTURE_DIR}/home"
  mkdir -p -- "${FAKE_HOME}/Library/LaunchAgents"
  mkdir -p -- "${FAKE_HOME}/Library/Preferences"
  # Per-user TCC.db location — the Tier 3 walk probes this path on
  # every enumerable home. Creating the parent keeps the walk from
  # logging a benign "path unreadable" during baseline.
  mkdir -p -- "${FAKE_HOME}/Library/Application Support/com.apple.TCC"

  # A scratch bin dir for PATH-shims (codesign in 16.16). Empty by
  # default; individual tests populate it and prepend to PATH.
  SHIM_DIR="${FIXTURE_DIR}/bin"
  mkdir -p -- "${SHIM_DIR}"

  ORIG_PATH="${PATH}"
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH

  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    chmod -R u+rwX "${FIXTURE_DIR}" 2>/dev/null || true
    rm -rf -- "${FIXTURE_DIR}" || true
  fi

  # Unset every env override any scenario in this file may have set
  # so the next test starts from a clean slate.
  unset MACAUDIT_FDA_AVAILABLE
  unset MACAUDIT_MDM_MANAGED
  unset TCC_SYSTEM_PATH_OVERRIDE
  unset KEXTPOLICY_PATH_OVERRIDE
  unset EXECPOLICY_PATH_OVERRIDE
  unset SYSTEMPOLICY_PATH_OVERRIDE
  unset XPROTECT_BUNDLE_OVERRIDE
  unset SECURITY_CMD_OVERRIDE
  unset PROFILES_CMD_OVERRIDE
  unset SPCTL_STATUS_OVERRIDE
  unset SPCTL_DEVID_OVERRIDE
  unset SYSTEM_PLUGIN_DIR_OVERRIDE
  unset THIRD_PARTY_PLUGIN_DIR_OVERRIDE
  unset MACAUDIT_PPPC_JSON
  unset MACAUDIT_BATS_CODESIGN_RC
  unset MACAUDIT_BATS_CODESIGN_STDERR
}

# ---------------------------------------------------------------------------
# Fixture builders — SQLite shape helpers
# ---------------------------------------------------------------------------
# Factored after the reference builders in test_enumerate_databases.bats
# so the two suites share one understanding of the fixture schemas.

# _make_tcc_db <path> <auth_reason1> [<auth_reason2>...]
#   Materialise a TCC.db with one row per auth_reason argument. Every
#   row uses a unique client so the compound primary key stays
#   collision-free.
_make_tcc_db() {
  local p="$1"
  shift
  local dir
  dir=$(dirname -- "$p")
  mkdir -p -- "$dir"
  sqlite3 "$p" <<'SQL'
CREATE TABLE access (
  service TEXT NOT NULL,
  client TEXT NOT NULL,
  client_type INTEGER NOT NULL,
  auth_value INTEGER NOT NULL,
  auth_reason INTEGER NOT NULL,
  auth_version INTEGER NOT NULL,
  last_modified INTEGER NOT NULL,
  indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
  PRIMARY KEY (service, client, client_type, indirect_object_identifier)
);
SQL
  local i=0 reason
  for reason in "$@"; do
    sqlite3 "$p" "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified, indirect_object_identifier) VALUES ('kTCCServiceAccessibility', 'com.example.c${i}', 0, 2, ${reason}, 1, 1700000000, 'UNUSED');"
    i=$((i + 1))
  done
}

# _make_kextpolicy_db <path> <user_row_count> <mdm_row_count>
#   Build a KextPolicy DB with <user_row_count> rows in kext_policy
#   and <mdm_row_count> rows in kext_policy_mdm. Team IDs and bundle
#   IDs are deliberately disjoint across the two tables so the
#   R4 matcher sees the user rows as unmatched.
_make_kextpolicy_db() {
  local p="$1" u="$2" m="$3"
  mkdir -p -- "$(dirname -- "$p")"
  sqlite3 "$p" <<'SQL'
CREATE TABLE kext_policy (team_id TEXT, bundle_id TEXT, allowed INTEGER, developer_name TEXT, flags INTEGER, PRIMARY KEY (team_id, bundle_id));
CREATE TABLE kext_policy_mdm (team_id TEXT, bundle_id TEXT, allowed INTEGER, developer_name TEXT, flags INTEGER, PRIMARY KEY (team_id, bundle_id));
SQL
  local i=0
  while [ "$i" -lt "$u" ]; do
    sqlite3 "$p" "INSERT INTO kext_policy VALUES ('TEAMU${i}', 'com.user.kext.${i}', 1, 'DevU${i}', 0);"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$m" ]; do
    sqlite3 "$p" "INSERT INTO kext_policy_mdm VALUES ('TEAMM${i}', 'com.mdm.kext.${i}', 1, 'DevM${i}', 0);"
    i=$((i + 1))
  done
}

# _make_systempolicy_db <path>
#   Build a minimal SystemPolicy DB with an empty `authority` table
#   so sysdb_capture_systempolicy can safe-copy it without erroring
#   on an absent table.
_make_systempolicy_db() {
  local p="$1"
  mkdir -p -- "$(dirname -- "$p")"
  sqlite3 "$p" "CREATE TABLE authority (id INTEGER PRIMARY KEY);"
}

# ---------------------------------------------------------------------------
# 16.13 — TCC Override Policy suspicious finding
# ---------------------------------------------------------------------------
# Seed a TCC.db with one clean row (auth_reason=1) and one override
# policy row (auth_reason=7). After baseline, mutate the DB to add a
# second auth_reason=7 row. Audit must:
#   * classify the TCC entry under tier3.modified (its sha256_checkpointed
#     changed);
#   * classify the TCC entry under tier3.suspicious with TWO anomalies
#     whose rule == "tcc_override_policy";
#   * exit 3 (some drift AND suspicious > 0).

@test "16.13 TCC override policy drift surfaces two tcc_override_policy anomalies and exits 3" {
  local tcc_sys="${FIXTURE_DIR}/TCC.db"
  # Baseline state: one clean row (auth_reason=1) and one override
  # policy row (auth_reason=7).
  _make_tcc_db "${tcc_sys}" 1 7

  export TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}"
  export MACAUDIT_FDA_AVAILABLE=yes

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]
  [ -f "${baseline}" ]

  # Mutate: add a SECOND auth_reason=7 row after baseline.
  sqlite3 "${tcc_sys}" "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified, indirect_object_identifier) VALUES ('kTCCServiceAccessibility', 'com.example.extra7', 0, 2, 7, 1, 1700000100, 'UNUSED');"

  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      TCC_SYSTEM_PATH_OVERRIDE="${tcc_sys}" \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  # tier3.modified includes the TCC entry.
  local modified
  modified=$(printf '%s' "${delta}" | jq -c --arg p "${tcc_sys}" \
    '.tiers["3"].modified[] | select(.path == $p)')
  [ -n "${modified}" ]

  # tier3.suspicious includes the TCC entry with TWO tcc_override_policy
  # anomalies (one per auth_reason=7 row).
  local anoms
  anoms=$(printf '%s' "${delta}" | jq -c --arg p "${tcc_sys}" \
    '.tiers["3"].suspicious[] | select(.path == $p) | .anomalies')
  [ -n "${anoms}" ]
  local override_count
  override_count=$(printf '%s' "${anoms}" \
    | jq -r '[.[] | select(.rule == "tcc_override_policy")] | length')
  [ "${override_count}" = "2" ]
}

# ---------------------------------------------------------------------------
# 16.14 — Authorization plugin injection
# ---------------------------------------------------------------------------
# `security authorizationdb read system.login.console` is shimmed to
# return a mechanisms list that includes MyEvilPlugin:invoke,privileged.
# Empty system and third-party plugin dirs force the classifier to
# label MyEvilPlugin as "missing" — which fires authdb_missing_plugin
# in the authdb entry AND correlation:authdb_missing_plugin via the
# R5 cross-surface pass.
#
# Baseline and audit both run against the same shimmed state, so
# there is no drift — the exit-3 verdict is driven by suspicious alone
# (tier3.suspicious > 0 with tier3.added / modified / removed empty
# is still a "some category non-empty" case because suspicious counts
# against the total in the three-way rule).

@test "16.14 authorization plugin injection surfaces authdb_missing_plugin + correlation and exits 3" {
  # Empty plugin directories — MyEvilPlugin cannot resolve to either.
  local sys_plugin_dir="${FIXTURE_DIR}/SystemPlugins"
  local third_plugin_dir="${FIXTURE_DIR}/ThirdPartyPlugins"
  mkdir -p -- "${sys_plugin_dir}" "${third_plugin_dir}"

  # Build a canonical authorization-right plist. plutil ingests JSON
  # and emits XML, so we hand it the shape the real
  # `security authorizationdb read` returns: a dict with
  # class/shared/timeout/tries/mechanisms.
  local seed="${FIXTURE_DIR}/authdb_seed.json"
  printf '%s' '{"class":"evaluate-mechanisms","shared":true,"timeout":30,"tries":10000,"mechanisms":["builtin:policy-banner","MyEvilPlugin:invoke,privileged"]}' \
    > "${seed}"
  local authdb_xml="${FIXTURE_DIR}/authdb.xml"
  plutil -convert xml1 -o "${authdb_xml}" "${seed}"

  # `security` shim — emits the same plist for every invocation. The
  # real binary dispatches on `authorizationdb read <name>`; the
  # curated-names loop in sysdb_capture_authdb will call it five
  # times, but the same mechanisms list is fine for the assertions
  # below (we only need at least ONE authdb entry with the missing
  # plugin).
  local security_shim="${SHIM_DIR}/security"
  cat > "${security_shim}" <<SHIM
#!/bin/bash
cat "${authdb_xml}"
exit 0
SHIM
  chmod +x "${security_shim}"

  # No drift: baseline and audit both see the same shimmed state.
  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      SECURITY_CMD_OVERRIDE="${security_shim}" \
      SYSTEM_PLUGIN_DIR_OVERRIDE="${sys_plugin_dir}" \
      THIRD_PARTY_PLUGIN_DIR_OVERRIDE="${third_plugin_dir}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      SECURITY_CMD_OVERRIDE="${security_shim}" \
      SYSTEM_PLUGIN_DIR_OVERRIDE="${sys_plugin_dir}" \
      THIRD_PARTY_PLUGIN_DIR_OVERRIDE="${third_plugin_dir}" \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  # At least one authdb entry lands in tier3.suspicious carrying an
  # authdb_missing_plugin anomaly.
  local authdb_missing
  authdb_missing=$(printf '%s' "${delta}" | jq -c \
    '[.tiers["3"].suspicious[]
        | select(.path | startswith("security://authorizationdb/"))
        | select(.anomalies[]? | .rule == "authdb_missing_plugin")]
      | length')
  [ "${authdb_missing}" -ge 1 ]

  # A correlation://R5 entry with rule "correlation:authdb_missing_plugin"
  # fires as part of the cross-surface correlation pass.
  local corr_count
  corr_count=$(printf '%s' "${delta}" | jq -c \
    '[.tiers["3"].suspicious[]
        | select(.path | startswith("correlation://"))
        | select(.anomalies[]? | .rule == "correlation:authdb_missing_plugin")]
      | length')
  [ "${corr_count}" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 16.15 — KextPolicy user approval on MDM-managed device
# ---------------------------------------------------------------------------
# Seed a KextPolicy DB with one user-approved kext_policy row and no
# matching kext_policy_mdm row. Force MDM-managed via
# MACAUDIT_MDM_MANAGED=yes so _sysdb_kext_anomalies fires
# kext_user_approved_on_mdm AND baseline_correlate emits the
# correlation:kext_user_approved_on_mdm correlation entry.

@test "16.15 kext user approval on MDM surfaces kext_user_approved_on_mdm + correlation and exits 3" {
  local kp="${FIXTURE_DIR}/KextPolicy"
  # 1 user-approved row, 0 MDM-authorised rows — the single user row
  # is unmatched.
  _make_kextpolicy_db "${kp}" 1 0

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      MACAUDIT_MDM_MANAGED=yes \
      KEXTPOLICY_PATH_OVERRIDE="${kp}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=yes \
      MACAUDIT_MDM_MANAGED=yes \
      KEXTPOLICY_PATH_OVERRIDE="${kp}" \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  # The KextPolicy entry lives under tier3.suspicious and carries a
  # kext_user_approved_on_mdm anomaly.
  local kp_suspicious
  kp_suspicious=$(printf '%s' "${delta}" | jq -c --arg p "${kp}" \
    '.tiers["3"].suspicious[] | select(.path == $p)')
  [ -n "${kp_suspicious}" ]
  local kp_rule_count
  kp_rule_count=$(printf '%s' "${kp_suspicious}" \
    | jq -r '[.anomalies[] | select(.rule == "kext_user_approved_on_mdm")] | length')
  [ "${kp_rule_count}" -ge 1 ]

  # The correlation entry fires with rule correlation:kext_user_approved_on_mdm.
  local corr_count
  corr_count=$(printf '%s' "${delta}" | jq -c \
    '[.tiers["3"].suspicious[]
        | select(.path | startswith("correlation://"))
        | select(.anomalies[]? | .rule == "correlation:kext_user_approved_on_mdm")]
      | length')
  [ "${corr_count}" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 16.16 — XProtect bundle codesign failure
# ---------------------------------------------------------------------------
# Create a fixture XProtect bundle with a minimal Contents/Info.plist
# carrying CFBundleShortVersionString. Install a PATH-shim `codesign`
# that returns exit 1 for any invocation. Baseline + audit must both
# record xprotect_codesign_fail in the XProtect entry's anomalies[]
# array, and the audit must surface the entry as suspicious with
# exit 3.

@test "16.16 XProtect bundle codesign failure surfaces xprotect_codesign_fail and exits 3" {
  # Build a minimal XProtect bundle with just enough structure to
  # satisfy xprotect_version + xprotect_capture. The Info.plist
  # carries CFBundleShortVersionString so enumerate / the manifest
  # entry's bundle_version is a real string.
  local bundle="${FIXTURE_DIR}/XProtect.bundle"
  mkdir -p -- "${bundle}/Contents"
  cat > "${bundle}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>2173</string>
</dict>
</plist>
PLIST

  # Install the codesign PATH-shim. The shim lives under tests/bin/
  # and keys off MACAUDIT_BATS_CODESIGN_RC for its exit code. We
  # prepend tests/bin to PATH for the CLI invocations below so the
  # shim intercepts utils_codesign_verify's `codesign --verify ...`.
  local shim_dir="${BATS_TEST_DIRNAME}/../bin"
  [ -x "${shim_dir}/codesign" ] || chmod +x "${shim_dir}/codesign"

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      XPROTECT_BUNDLE_OVERRIDE="${bundle}" \
      MACAUDIT_BATS_CODESIGN_RC=1 \
      MACAUDIT_BATS_CODESIGN_STDERR="bundle failed: invalid signature" \
      PATH="${shim_dir}:${ORIG_PATH}" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  # Assert the baseline's XProtect entry already carries the anomaly.
  local base_anom_count
  base_anom_count=$(tail -n +2 -- "${baseline}" \
    | jq -r --arg p "${bundle}" \
        'select(.path == $p)
         | [.anomalies[] | select(.rule == "xprotect_codesign_fail")] | length')
  [ "${base_anom_count}" = "1" ]

  # Audit with the same shimmed state — the re-captured entry carries
  # the same anomaly, so tier3.suspicious picks it up (even though
  # the bundle itself is byte-for-byte identical → modified is empty).
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      XPROTECT_BUNDLE_OVERRIDE="${bundle}" \
      MACAUDIT_BATS_CODESIGN_RC=1 \
      MACAUDIT_BATS_CODESIGN_STDERR="bundle failed: invalid signature" \
      PATH="${shim_dir}:${ORIG_PATH}" \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  local suspicious
  suspicious=$(printf '%s' "${delta}" | jq -c --arg p "${bundle}" \
    '.tiers["3"].suspicious[] | select(.path == $p)')
  [ -n "${suspicious}" ]
  local rule_count
  rule_count=$(printf '%s' "${suspicious}" \
    | jq -r '[.anomalies[] | select(.rule == "xprotect_codesign_fail")] | length')
  [ "${rule_count}" = "1" ]
}

# ---------------------------------------------------------------------------
# 16.17 — Gatekeeper disabled
# ---------------------------------------------------------------------------
# SPCTL_STATUS_OVERRIDE="assessments disabled" forces
# _sysdb_spctl_status_value to return "disabled", which in turn drives
# sysdb_capture_systempolicy to emit gatekeeper_disabled in the
# SystemPolicy entry's anomalies[]. No drift is needed — the anomaly
# alone puts the entry in tier3.suspicious and flips the exit code
# to 3.

@test "16.17 gatekeeper disabled surfaces gatekeeper_disabled in SystemPolicy and exits 3" {
  local sp="${FIXTURE_DIR}/SystemPolicy"
  _make_systempolicy_db "${sp}"

  local baseline="${FIXTURE_DIR}/B.jsonl"
  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      SYSTEMPOLICY_PATH_OVERRIDE="${sp}" \
      SPCTL_STATUS_OVERRIDE="assessments disabled" \
      bash "${MACAUDIT}" baseline --tier all --user-only \
        --output "${baseline}"
  [ "${status}" -eq 0 ]

  run env HOME="${FAKE_HOME}" \
      MACAUDIT_FDA_AVAILABLE=no \
      SYSTEMPOLICY_PATH_OVERRIDE="${sp}" \
      SPCTL_STATUS_OVERRIDE="assessments disabled" \
      bash "${MACAUDIT}" audit "${baseline}" --json \
        --output "${FIXTURE_DIR}/delta.json"
  [ "${status}" -eq 3 ]
  local delta
  delta=$(cat -- "${FIXTURE_DIR}/delta.json")

  # The SystemPolicy entry lands in tier3.suspicious with the
  # gatekeeper_disabled rule.
  local sp_suspicious
  sp_suspicious=$(printf '%s' "${delta}" | jq -c --arg p "${sp}" \
    '.tiers["3"].suspicious[] | select(.path == $p)')
  [ -n "${sp_suspicious}" ]
  local rule_count
  rule_count=$(printf '%s' "${sp_suspicious}" \
    | jq -r '[.anomalies[] | select(.rule == "gatekeeper_disabled")] | length')
  [ "${rule_count}" = "1" ]
}
