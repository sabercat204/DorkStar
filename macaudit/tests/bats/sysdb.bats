#!/usr/bin/env bats
# tests/bats/sysdb.bats — unit tests for lib/sysdb.sh + utils_mdm_managed.
#
# Strategy:
#   * Plugin-directory classification is exercised by pointing the
#     SYSTEM_PLUGIN_DIR_OVERRIDE / THIRD_PARTY_PLUGIN_DIR_OVERRIDE env
#     vars at fixture directories under FIXTURE_DIR. Each test calls
#     `sysdb_plugin_listing_reset` before classification so the
#     memoised listing is rebuilt from the current fixture state.
#   * `security`, `spctl`, and `profiles` are driven via override env
#     vars (SECURITY_CMD_OVERRIDE, SPCTL_STATUS_OVERRIDE,
#     SPCTL_DEVID_OVERRIDE, PROFILES_CMD_OVERRIDE) and per-test shim
#     binaries under FIXTURE_DIR/bin.
#   * KextPolicy fixture DBs are built via sqlite3 into FIXTURE_DIR
#     and routed to the capture via KEXTPOLICY_PATH_OVERRIDE.

bats_require_minimum_version 1.5.0

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/sqlite.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  # shellcheck source=/dev/null
  source "${LIB}/sysdb.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-sysdb.XXXXXX")"
  mkdir -p "${FIXTURE_DIR}/bin"
  mkdir -p "${FIXTURE_DIR}/sys"
  mkdir -p "${FIXTURE_DIR}/third"
  utils_tmpdir_init >/dev/null

  # Redirect plugin lookups into our per-test fixture dirs by default.
  # Individual tests may override these before calling the classifier.
  export SYSTEM_PLUGIN_DIR_OVERRIDE="${FIXTURE_DIR}/sys"
  export THIRD_PARTY_PLUGIN_DIR_OVERRIDE="${FIXTURE_DIR}/third"
  sysdb_plugin_listing_reset
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "${MACAUDIT_TMPDIR}" ]; then
    rm -rf -- "${MACAUDIT_TMPDIR}" || true
  fi
  unset MACAUDIT_TMPDIR
  unset MACAUDIT_MDM_MANAGED
  unset MACAUDIT_PLUGIN_LISTING
  unset MACAUDIT_FDA_AVAILABLE
  unset SYSTEM_PLUGIN_DIR_OVERRIDE
  unset THIRD_PARTY_PLUGIN_DIR_OVERRIDE
  unset KEXTPOLICY_PATH_OVERRIDE
  unset EXECPOLICY_PATH_OVERRIDE
  unset SYSTEMPOLICY_PATH_OVERRIDE
  unset SECURITY_CMD_OVERRIDE
  unset SPCTL_STATUS_OVERRIDE
  unset SPCTL_DEVID_OVERRIDE
  unset PROFILES_CMD_OVERRIDE
}

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# _seed_system_plugin <name>
#   Create <FIXTURE_DIR>/sys/<name>.bundle as a directory.
_seed_system_plugin() {
  local name="$1"
  mkdir -p "${FIXTURE_DIR}/sys/${name}.bundle"
  sysdb_plugin_listing_reset
}

# _seed_third_party_plugin <name>
#   Create <FIXTURE_DIR>/third/<name>.bundle as a directory.
_seed_third_party_plugin() {
  local name="$1"
  mkdir -p "${FIXTURE_DIR}/third/${name}.bundle"
  sysdb_plugin_listing_reset
}

# _install_security_shim <xml_body>
#   Write a `security` shim at FIXTURE_DIR/bin/security that emits
#   <xml_body> verbatim on stdout for any `authorizationdb read` call.
#   Point SECURITY_CMD_OVERRIDE at it.
_install_security_shim() {
  local body="$1"
  local body_file="${FIXTURE_DIR}/security_body.xml"
  printf '%s' "$body" > "$body_file"
  local shim="${FIXTURE_DIR}/bin/security"
  cat > "$shim" <<SHIM
#!/bin/bash
cat "${body_file}"
exit 0
SHIM
  chmod +x "$shim"
  export SECURITY_CMD_OVERRIDE="$shim"
}

# _install_profiles_shim <exit_code> <stdout_body>
#   Write a `profiles` shim emitting <stdout_body> and exiting with
#   <exit_code>. Point PROFILES_CMD_OVERRIDE at it.
_install_profiles_shim() {
  local rc="$1"
  local body="$2"
  local body_file="${FIXTURE_DIR}/profiles_body.txt"
  printf '%s' "$body" > "$body_file"
  local shim="${FIXTURE_DIR}/bin/profiles"
  cat > "$shim" <<SHIM
#!/bin/bash
cat "${body_file}"
exit ${rc}
SHIM
  chmod +x "$shim"
  export PROFILES_CMD_OVERRIDE="$shim"
  unset MACAUDIT_MDM_MANAGED
}

# _make_kextpolicy_db <path>
#   Build a KextPolicy fixture DB with both kext_policy and
#   kext_policy_mdm tables using the real schema.
_make_kextpolicy_db() {
  local p="$1"
  sqlite3 "${p}" <<'SQL'
CREATE TABLE kext_policy (
  team_id TEXT,
  bundle_id TEXT,
  allowed INTEGER,
  developer_name TEXT,
  flags INTEGER,
  PRIMARY KEY (team_id, bundle_id)
);
CREATE TABLE kext_policy_mdm (
  team_id TEXT,
  bundle_id TEXT,
  allowed INTEGER,
  developer_name TEXT,
  flags INTEGER,
  PRIMARY KEY (team_id, bundle_id)
);
SQL
}

# _kext_insert_user <db> <team> <bundle> <dev>
_kext_insert_user() {
  local db="$1" team="$2" bundle="$3" dev="$4"
  sqlite3 "${db}" \
    "INSERT INTO kext_policy (team_id, bundle_id, allowed, developer_name, flags)
     VALUES ('${team}', '${bundle}', 1, '${dev}', 0);"
}

# _kext_insert_mdm <db> <team> <bundle> <dev>
_kext_insert_mdm() {
  local db="$1" team="$2" bundle="$3" dev="$4"
  sqlite3 "${db}" \
    "INSERT INTO kext_policy_mdm (team_id, bundle_id, allowed, developer_name, flags)
     VALUES ('${team}', '${bundle}', 1, '${dev}', 0);"
}

# _authdb_xml <mechanisms_csv>
#   Emit a minimal XML plist representing an authorization right with
#   the supplied mechanisms (comma-separated list of "<prefix>:<name>"
#   strings). Plus class=evaluate-mechanisms, shared=true, timeout=30.
_authdb_xml() {
  local mechs_csv="$1"
  # Build a seed JSON and convert to XML via plutil for fidelity.
  local seed="${FIXTURE_DIR}/authdb_seed.json"
  {
    printf '{"class":"evaluate-mechanisms","shared":true,"timeout":30,"tries":10000,"mechanisms":['
    local first=1 IFS=,
    local m
    for m in $mechs_csv; do
      if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
      printf '"%s"' "$m"
    done
    printf ']}'
  } > "$seed"
  local out="${FIXTURE_DIR}/authdb.xml"
  plutil -convert xml1 -o "$out" "$seed"
  cat "$out"
}

# -----------------------------------------------------------------------------
# sysdb_classify_mechanism
# -----------------------------------------------------------------------------

@test "sysdb_classify_mechanism: builtin prefix always classifies as builtin" {
  got=$(sysdb_classify_mechanism "builtin:policy-banner")
  [ "${got}" = "builtin" ]
  # Even with no fixture seeded, builtin should still classify.
  got2=$(sysdb_classify_mechanism "builtin:anything")
  [ "${got2}" = "builtin" ]
}

@test "sysdb_classify_mechanism: system-plugin when bundle lives in the system dir" {
  _seed_system_plugin "loginwindow"
  got=$(sysdb_classify_mechanism "loginwindow:login")
  [ "${got}" = "system-plugin" ]
}

@test "sysdb_classify_mechanism: third-party-plugin when bundle lives only under /Library" {
  _seed_third_party_plugin "MyPlugin"
  got=$(sysdb_classify_mechanism "MyPlugin:invoke")
  [ "${got}" = "third-party-plugin" ]
}

@test "sysdb_classify_mechanism: missing when no matching bundle" {
  got=$(sysdb_classify_mechanism "NoSuchPlugin:nowhere")
  [ "${got}" = "missing" ]
}

@test "sysdb_classify_mechanism: system precedence when bundle exists in both dirs" {
  _seed_system_plugin "loginwindow"
  _seed_third_party_plugin "loginwindow"
  got=$(sysdb_classify_mechanism "loginwindow:auth")
  [ "${got}" = "system-plugin" ]
}

@test "sysdb_classify_mechanism: empty input emits empty stdout" {
  got=$(sysdb_classify_mechanism "")
  [ -z "${got}" ]
}

@test "sysdb_classify_mechanism: no colon emits empty stdout" {
  got=$(sysdb_classify_mechanism "NoColon")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# sysdb_capture_authdb
# -----------------------------------------------------------------------------

@test "sysdb_capture_authdb: happy path emits one entry per curated right" {
  # Install a shim that returns a stable plist for every name so we
  # exercise the full loop.
  xml=$(_authdb_xml "builtin:policy-banner,builtin:prelogin,loginwindow:login")
  _install_security_shim "${xml}"
  _seed_system_plugin "loginwindow"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_authdb "${scratch}"
  [ "${status}" -eq 0 ]

  # Five rights in the curated list.
  line_count=$(wc -l < "${scratch}" | tr -d ' ')
  [ "${line_count}" = "5" ]

  # Every line parses.
  while IFS= read -r line; do
    echo "${line}" | jq -e . >/dev/null
  done < "${scratch}"

  # Find the system.login.console entry and verify its shape.
  entry=$(jq -c 'select(.path == "security://authorizationdb/system.login.console")' "${scratch}")
  [ -n "${entry}" ]
  [ "$(echo "${entry}" | jq -r '.tier')" = "3" ]
  [ "$(echo "${entry}" | jq -r '.surface')" = "authdb" ]
  [ "$(echo "${entry}" | jq -r '.format')" = "authdb" ]
  # Canonical hash is populated.
  sha=$(echo "${entry}" | jq -r '.sha256_canonical')
  echo "${sha}" | grep -Eq '^[0-9a-f]{64}$'
  # Content carries mechanisms.
  mechs=$(echo "${entry}" | jq -c '.content.mechanisms')
  echo "${mechs}" | jq -e 'contains(["builtin:policy-banner"])' >/dev/null
  echo "${mechs}" | jq -e 'contains(["loginwindow:login"])' >/dev/null
  # No anomalies — every mechanism is builtin or system-plugin.
  [ "$(echo "${entry}" | jq -r '.anomalies | length')" = "0" ]
}

@test "sysdb_capture_authdb: third-party plugin produces authdb_third_party_plugin anomaly" {
  xml=$(_authdb_xml "builtin:policy-banner,MyPlugin:invoke,privileged")
  _install_security_shim "${xml}"
  _seed_third_party_plugin "MyPlugin"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_authdb "${scratch}"
  [ "${status}" -eq 0 ]

  entry=$(head -n 1 "${scratch}")
  [ "$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "authdb_third_party_plugin")] | length')" = "1" ]
  sev=$(echo "${entry}" | jq -r '.anomalies[] | select(.rule == "authdb_third_party_plugin") | .severity')
  [ "${sev}" = "warn" ]
}

@test "sysdb_capture_authdb: missing plugin produces authdb_missing_plugin anomaly" {
  xml=$(_authdb_xml "builtin:policy-banner,BogusPlugin:invoke")
  _install_security_shim "${xml}"
  # Deliberately no fixture for BogusPlugin.

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_authdb "${scratch}"
  [ "${status}" -eq 0 ]

  entry=$(head -n 1 "${scratch}")
  count=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "authdb_missing_plugin")] | length')
  [ "${count}" = "1" ]
  sev=$(echo "${entry}" | jq -r '.anomalies[] | select(.rule == "authdb_missing_plugin") | .severity')
  [ "${sev}" = "high" ]
}

# -----------------------------------------------------------------------------
# sysdb_capture_systempolicy
# -----------------------------------------------------------------------------

@test "sysdb_capture_systempolicy: gatekeeper_disabled anomaly fires when spctl reports disabled" {
  export SPCTL_STATUS_OVERRIDE="assessments disabled"
  export SPCTL_DEVID_OVERRIDE="assessments enabled"
  # Point the DB override at a non-existent path so we exercise the
  # spctl-only branch without needing sudo.
  export SYSTEMPOLICY_PATH_OVERRIDE="${FIXTURE_DIR}/never.db"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_systempolicy "${scratch}"
  [ "${status}" -eq 0 ]
  [ -s "${scratch}" ]

  entry=$(head -n 1 "${scratch}")
  echo "${entry}" | jq -e . >/dev/null
  [ "$(echo "${entry}" | jq -r '.surface')" = "systempolicy" ]
  [ "$(echo "${entry}" | jq -r '.content.gatekeeper.assessments')" = "disabled" ]
  # Anomaly present.
  count=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "gatekeeper_disabled")] | length')
  [ "${count}" = "1" ]
  sev=$(echo "${entry}" | jq -r '.anomalies[] | select(.rule == "gatekeeper_disabled") | .severity')
  [ "${sev}" = "high" ]
}

@test "sysdb_capture_systempolicy: no anomaly when assessments are enabled" {
  export SPCTL_STATUS_OVERRIDE="assessments enabled"
  export SPCTL_DEVID_OVERRIDE="assessments enabled"
  export SYSTEMPOLICY_PATH_OVERRIDE="${FIXTURE_DIR}/never.db"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_systempolicy "${scratch}"
  [ "${status}" -eq 0 ]
  entry=$(head -n 1 "${scratch}")
  [ "$(echo "${entry}" | jq -r '.content.gatekeeper.assessments')" = "enabled" ]
  [ "$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "gatekeeper_disabled")] | length')" = "0" ]
}

# -----------------------------------------------------------------------------
# sysdb_capture_kextpolicy
# -----------------------------------------------------------------------------

@test "sysdb_capture_kextpolicy: anomaly fires on MDM-managed device without matching MDM row" {
  db="${FIXTURE_DIR}/KextPolicy"
  _make_kextpolicy_db "${db}"
  _kext_insert_user "${db}" "ABCD1234" "com.example.kext" "Example Inc"
  # No matching kext_policy_mdm row.

  export KEXTPOLICY_PATH_OVERRIDE="${db}"
  # Force MDM-managed by pre-seeding the memo — bypasses profiles shim.
  export MACAUDIT_MDM_MANAGED=yes

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_kextpolicy "${scratch}"
  [ "${status}" -eq 0 ]
  [ -s "${scratch}" ]

  entry=$(head -n 1 "${scratch}")
  [ "$(echo "${entry}" | jq -r '.surface')" = "kextpolicy" ]
  count=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "kext_user_approved_on_mdm")] | length')
  [ "${count}" = "1" ]
  sev=$(echo "${entry}" | jq -r '.anomalies[] | select(.rule == "kext_user_approved_on_mdm") | .severity')
  [ "${sev}" = "high" ]

  # Snapshot structure is well-formed.
  [ "$(echo "${entry}" | jq -r '.table_snapshots.kext_policy.row_count')" = "1" ]
  [ "$(echo "${entry}" | jq -r '.table_snapshots.kext_policy_mdm.row_count')" = "0" ]
}

@test "sysdb_capture_kextpolicy: no anomaly on non-MDM device even without matching MDM row" {
  db="${FIXTURE_DIR}/KextPolicy"
  _make_kextpolicy_db "${db}"
  _kext_insert_user "${db}" "ABCD1234" "com.example.kext" "Example Inc"

  export KEXTPOLICY_PATH_OVERRIDE="${db}"
  export MACAUDIT_MDM_MANAGED=no

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_kextpolicy "${scratch}"
  [ "${status}" -eq 0 ]
  entry=$(head -n 1 "${scratch}")
  count=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "kext_user_approved_on_mdm")] | length')
  [ "${count}" = "0" ]
}

@test "sysdb_capture_kextpolicy: no anomaly when matching MDM row exists on MDM-managed device" {
  db="${FIXTURE_DIR}/KextPolicy"
  _make_kextpolicy_db "${db}"
  _kext_insert_user "${db}" "ABCD1234" "com.example.kext" "Example Inc"
  _kext_insert_mdm  "${db}" "ABCD1234" "com.example.kext" "Example Inc"

  export KEXTPOLICY_PATH_OVERRIDE="${db}"
  export MACAUDIT_MDM_MANAGED=yes

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run sysdb_capture_kextpolicy "${scratch}"
  [ "${status}" -eq 0 ]
  entry=$(head -n 1 "${scratch}")
  count=$(echo "${entry}" | jq -r '[.anomalies[] | select(.rule == "kext_user_approved_on_mdm")] | length')
  [ "${count}" = "0" ]
}

# -----------------------------------------------------------------------------
# utils_mdm_managed
# -----------------------------------------------------------------------------

@test "utils_mdm_managed: true case when profiles reports MDM enrolled" {
  body=$(printf 'Enrolled via DEP: Yes\nMDM enrollment: Yes (User Approved)\n')
  _install_profiles_shim 0 "${body}"
  utils_mdm_managed
  [ "$?" -eq 0 ]
  [ "${MACAUDIT_MDM_MANAGED}" = "yes" ]
}

@test "utils_mdm_managed: false case when profiles reports not enrolled" {
  body=$(printf 'Enrolled via DEP: No\nMDM enrollment: No\n')
  _install_profiles_shim 0 "${body}"
  rc=0
  utils_mdm_managed || rc=$?
  [ "${rc}" -ne 0 ]
  [ "${MACAUDIT_MDM_MANAGED}" = "no" ]
}

@test "utils_mdm_managed: case-insensitive match on upper-case MDM ENROLLMENT YES" {
  body=$(printf 'MDM ENROLLMENT: YES\n')
  _install_profiles_shim 0 "${body}"
  utils_mdm_managed
  [ "$?" -eq 0 ]
}

@test "utils_mdm_managed: memoised result short-circuits repeat calls" {
  export MACAUDIT_MDM_MANAGED=yes
  # Even with a non-existent profiles command, the memo wins.
  export PROFILES_CMD_OVERRIDE="/nope/does-not-exist"
  utils_mdm_managed
  [ "$?" -eq 0 ]

  export MACAUDIT_MDM_MANAGED=no
  rc=0
  utils_mdm_managed || rc=$?
  [ "${rc}" -ne 0 ]
}
