#!/usr/bin/env bats
# tests/bats/persistence.bats — unit tests for lib/persistence.sh.
#
# Strategy: the real `launchctl`, `sfltool`, `plutil`, and `sudo`
# binaries are not safe to drive in unit tests. Each test that needs
# their output prepends a per-test `${FIXTURE_DIR}/bin` to PATH and
# writes a throwaway shim script there. `teardown` tears the whole
# fixture directory down so no shim leaks between tests.
#
# For the correlate / detect_injections tests we can use real files
# directly — no shim needed, the pure-text set operations require no
# external tooling beyond `jq`, `awk`, `sort`, and `comm`, all of which
# are assumed to be available on any macOS system that runs macaudit.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-persistence.XXXXXX")"
  mkdir -p "${FIXTURE_DIR}/bin"
  ORIG_PATH="${PATH}"
  PATH="${FIXTURE_DIR}/bin:${PATH}"
  export PATH
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  unset OS_MAJOR_OVERRIDE
}

# _install_shim <name> <exit_code> <stdout_body>
#   Write ${FIXTURE_DIR}/bin/<name> as a tiny bash script that cats a
#   sibling body file and exits with the given code. The body is
#   written verbatim so tests can embed newlines, tabs, and other
#   whitespace.
_install_shim() {
  local name="$1" rc="$2" body="$3"
  local body_file="${FIXTURE_DIR}/${name}_body.txt"
  printf '%s' "$body" > "$body_file"
  cat > "${FIXTURE_DIR}/bin/${name}" <<SHIM
#!/bin/bash
cat "${body_file}"
exit ${rc}
SHIM
  chmod +x "${FIXTURE_DIR}/bin/${name}"
}

# _install_sudo_passthrough
#   Install a sudo shim that simply `exec`s its arguments (as the
#   invoking user, since the real `sudo launchctl list` in the
#   collector would run the same command but with a different uid).
#   This lets us exercise the `sudo launchctl list` branch without
#   actually elevating privileges.
_install_sudo_passthrough() {
  cat > "${FIXTURE_DIR}/bin/sudo" <<'SHIM'
#!/bin/bash
exec "$@"
SHIM
  chmod +x "${FIXTURE_DIR}/bin/sudo"
}

# -----------------------------------------------------------------------------
# persistence_collect_launchctl_user
# -----------------------------------------------------------------------------

@test "collect_launchctl_user: header row is filtered, data rows produce TSV" {
  body=$'PID\tStatus\tLabel\n123\t0\tcom.example.foo\n-\t0\tcom.example.bar\n'
  _install_shim launchctl 0 "$body"
  out=$(persistence_collect_launchctl_user)
  [ -n "${out}" ]
  # Expected rows: com.example.foo\t123\t0 and com.example.bar\t0\t0
  # (hyphen pid normalised to 0). No PID/Status/Label header row.
  line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "${line_count}" -eq 2 ]
  # Verify first row fields (label\tpid\tstatus).
  foo_line=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "com.example.foo"')
  [ "$(printf '%s' "$foo_line" | awk -F '\t' '{print $2}')" = "123" ]
  [ "$(printf '%s' "$foo_line" | awk -F '\t' '{print $3}')" = "0"   ]
  # Hyphen row: pid normalised to 0.
  bar_line=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "com.example.bar"')
  [ "$(printf '%s' "$bar_line" | awk -F '\t' '{print $2}')" = "0" ]
  [ "$(printf '%s' "$bar_line" | awk -F '\t' '{print $3}')" = "0" ]
}

@test "collect_launchctl_user: hyphen status is normalised to 0" {
  body=$'PID\tStatus\tLabel\n42\t-\tcom.example.hyphenstatus\n'
  _install_shim launchctl 0 "$body"
  out=$(persistence_collect_launchctl_user)
  row=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "com.example.hyphenstatus"')
  [ -n "${row}" ]
  [ "$(printf '%s' "$row" | awk -F '\t' '{print $2}')" = "42" ]
  [ "$(printf '%s' "$row" | awk -F '\t' '{print $3}')" = "0"  ]
}

@test "collect_launchctl_user: empty launchctl output produces empty result" {
  _install_shim launchctl 0 ""
  out=$(persistence_collect_launchctl_user)
  [ -z "${out}" ]
}

@test "collect_launchctl_user: non-zero exit from launchctl still yields empty output" {
  _install_shim launchctl 1 ""
  out=$(persistence_collect_launchctl_user)
  [ -z "${out}" ]
}

# -----------------------------------------------------------------------------
# persistence_collect_launchctl_system — sudo gating
# -----------------------------------------------------------------------------

@test "collect_launchctl_system: emits empty when caller is not root" {
  # Override utils_has_sudo in the test body so we don't need to fake
  # `id` output. This also mirrors how baseline.sh calls the function
  # — it always checks sudo before invoking the collector.
  utils_has_sudo() { return 1; }
  out=$(persistence_collect_launchctl_system)
  [ -z "${out}" ]
}

@test "collect_launchctl_system: with has_sudo shimmed, emits parsed TSV rows" {
  body=$'PID\tStatus\tLabel\n9\t0\tcom.example.sys\n-\t0\tcom.example.sys2\n'
  _install_shim launchctl 0 "$body"
  _install_sudo_passthrough

  # Override utils_has_sudo so the gate passes. The sudo passthrough
  # shim then forwards the launchctl invocation to the launchctl shim
  # on PATH.
  utils_has_sudo() { return 0; }

  out=$(persistence_collect_launchctl_system)
  [ -n "${out}" ]
  line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "${line_count}" -eq 2 ]
  # Hyphen in PID normalised to 0.
  sys2=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "com.example.sys2"')
  [ "$(printf '%s' "$sys2" | awk -F '\t' '{print $2}')" = "0" ]
}

# -----------------------------------------------------------------------------
# persistence_collect_btm — macOS gating + sudo gating + parsing
# -----------------------------------------------------------------------------

@test "collect_btm: macOS 12 → empty regardless of shim" {
  export OS_MAJOR_OVERRIDE=12
  # Install an sfltool shim that would emit a record if called. If
  # gating is broken this test fails because the record leaks through.
  _install_shim sfltool 0 $'Identifier: com.leak.me\nType: 0x8\n\n'
  _install_sudo_passthrough
  utils_has_sudo() { return 0; }

  out=$(persistence_collect_btm)
  [ -z "${out}" ]
}

@test "collect_btm: not root → empty" {
  export OS_MAJOR_OVERRIDE=15
  _install_shim sfltool 0 $'Identifier: com.leak.me\n\n'
  utils_has_sudo() { return 1; }

  out=$(persistence_collect_btm)
  [ -z "${out}" ]
}

@test "collect_btm: missing sfltool → empty" {
  export OS_MAJOR_OVERRIDE=15
  utils_has_sudo() { return 0; }
  # Override PATH entirely to just the per-test bin dir (which has no
  # sfltool shim installed). That guarantees `command -v sfltool`
  # returns non-zero regardless of what's on the system's real PATH.
  PATH="${FIXTURE_DIR}/bin"
  export PATH
  out=$(persistence_collect_btm)
  [ -z "${out}" ]
}

@test "collect_btm: macOS 15 + sudo + fixture block → JSONL record with all fields" {
  export OS_MAJOR_OVERRIDE=15
  utils_has_sudo() { return 0; }
  _install_sudo_passthrough

  # Two records separated by a blank line, plus a trailing blank.
  body="Identifier: com.example.one
Type: 0x8
Developer Name: Example, Inc
Team Identifier: ABCDE12345
Parent Identifier: com.example.parent
URL: file:///Library/LaunchAgents/com.example.one.plist
Disposition: enabled
UUID: 1234-5678

Identifier: com.example.two
Type: 0x2
Developer Name: Two Corp
Team Identifier: FGHIJ67890
Disposition: disabled
"
  _install_shim sfltool 0 "$body"

  out=$(persistence_collect_btm)
  [ -n "${out}" ]
  line_count=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "${line_count}" -eq 2 ]

  # Verify record 1 fields via jq.
  first=$(printf '%s\n' "$out" | head -n 1)
  echo "${first}" | jq -e . >/dev/null
  [ "$(echo "$first" | jq -r '.label')"           = "com.example.one" ]
  [ "$(echo "$first" | jq -r '.type')"            = "0x8" ]
  [ "$(echo "$first" | jq -r '.developer')"       = "Example, Inc" ]
  [ "$(echo "$first" | jq -r '.team_identifier')" = "ABCDE12345" ]
  [ "$(echo "$first" | jq -r '.parent')"          = "com.example.parent" ]
  [ "$(echo "$first" | jq -r '.url')"             = "file:///Library/LaunchAgents/com.example.one.plist" ]
  [ "$(echo "$first" | jq -r '.disposition')"     = "enabled" ]

  # Verify record 2 — fewer fields present; absent ones should be empty string.
  second=$(printf '%s\n' "$out" | sed -n '2p')
  echo "${second}" | jq -e . >/dev/null
  [ "$(echo "$second" | jq -r '.label')"           = "com.example.two" ]
  [ "$(echo "$second" | jq -r '.type')"            = "0x2" ]
  [ "$(echo "$second" | jq -r '.developer')"       = "Two Corp" ]
  [ "$(echo "$second" | jq -r '.team_identifier')" = "FGHIJ67890" ]
  [ "$(echo "$second" | jq -r '.parent')"          = "" ]
  [ "$(echo "$second" | jq -r '.url')"             = "" ]
  [ "$(echo "$second" | jq -r '.disposition')"     = "disabled" ]
}

# -----------------------------------------------------------------------------
# persistence_extract_label
# -----------------------------------------------------------------------------

@test "extract_label: plist with Label → the label string" {
  seed="${FIXTURE_DIR}/seed.json"
  plist="${FIXTURE_DIR}/agent.plist"
  printf '%s' '{"Label":"com.foo","ProgramArguments":["/bin/true"]}' > "${seed}"
  plutil -convert xml1 -o "${plist}" "${seed}"

  got=$(persistence_extract_label "${plist}")
  [ "${got}" = "com.foo" ]
}

@test "extract_label: plist without Label → empty" {
  seed="${FIXTURE_DIR}/seed.json"
  plist="${FIXTURE_DIR}/no_label.plist"
  printf '%s' '{"Other":"value"}' > "${seed}"
  plutil -convert xml1 -o "${plist}" "${seed}"

  got=$(persistence_extract_label "${plist}")
  [ -z "${got}" ]
}

@test "extract_label: invalid plist → empty" {
  bad="${FIXTURE_DIR}/not-a-plist.txt"
  printf 'this is not a plist at all\n' > "${bad}"
  got=$(persistence_extract_label "${bad}")
  [ -z "${got}" ]
}

@test "extract_label: missing path → empty" {
  got=$(persistence_extract_label "${FIXTURE_DIR}/does-not-exist.plist")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# persistence_correlate — full truth table
# -----------------------------------------------------------------------------
#
# Helpers for correlate tests: build a launchctl TSV and BTM JSONL from
# the tester's perspective. Both are plain files so we can drive the
# set-membership logic without involving any shims.

_make_launchctl_tsv() {
  local out="$1"; shift
  : >"$out"
  for label in "$@"; do
    printf '%s\t0\t0\n' "$label" >> "$out"
  done
}

_make_btm_jsonl() {
  local out="$1"; shift
  : >"$out"
  for label in "$@"; do
    jq -cn --arg l "$label" '{label:$l,type:"",developer:"",team_identifier:"",parent:"",url:"",disposition:""}' >> "$out"
  done
}

@test "correlate: label in both launchctl + BTM → launchctl_loaded:true, btm_registered:true" {
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.foo com.bar
  _make_btm_jsonl     "${btm}" com.foo

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  echo "${out}" | jq -e . >/dev/null
  [ "$(echo "$out" | jq -r '.launchctl_loaded')" = "true" ]
  [ "$(echo "$out" | jq -r '.btm_registered')"   = "true" ]
}

@test "correlate: label in launchctl only → {true,false}" {
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.foo
  _make_btm_jsonl     "${btm}" com.bar  # BTM populated but without com.foo

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  [ "$(echo "$out" | jq -r '.launchctl_loaded')" = "true" ]
  [ "$(echo "$out" | jq -r '.btm_registered')"   = "false" ]
}

@test "correlate: label in BTM only → {false,true}" {
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.other
  _make_btm_jsonl     "${btm}" com.foo

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  [ "$(echo "$out" | jq -r '.launchctl_loaded')" = "false" ]
  [ "$(echo "$out" | jq -r '.btm_registered')"   = "true" ]
}

@test "correlate: label in neither → {false,false}" {
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.a
  _make_btm_jsonl     "${btm}" com.b

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  [ "$(echo "$out" | jq -r '.launchctl_loaded')" = "false" ]
  [ "$(echo "$out" | jq -r '.btm_registered')"   = "false" ]
}

@test "correlate: empty BTM file → btm_registered:null regardless of launchctl state" {
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.foo
  : > "${btm}"  # empty

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  [ "$(echo "$out" | jq -r '.launchctl_loaded')"    = "true" ]
  [ "$(echo "$out" | jq -r '.btm_registered | type')" = "null" ]
}

@test "correlate: missing BTM file → btm_registered:null" {
  tsv="${FIXTURE_DIR}/lctl.tsv"
  _make_launchctl_tsv "${tsv}" com.foo
  # Intentionally pass a non-existent path.
  out=$(persistence_correlate com.foo "${tsv}" "${FIXTURE_DIR}/no-such-btm.jsonl")
  [ "$(echo "$out" | jq -r '.launchctl_loaded')"      = "true" ]
  [ "$(echo "$out" | jq -r '.btm_registered | type')" = "null" ]
}

@test "correlate: prefix label is not a false positive" {
  # `com.foo` must not match `com.foobar`. This guards the fix-me-later
  # failure mode of a naive `grep -F ^label` implementation.
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.foobar
  _make_btm_jsonl     "${btm}" com.foobar

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  [ "$(echo "$out" | jq -r '.launchctl_loaded')" = "false" ]
  [ "$(echo "$out" | jq -r '.btm_registered')"   = "false" ]
}

@test "correlate: OS_MAJOR_OVERRIDE=12 produces btm_registered:null via empty BTM file" {
  # On macOS < 13 the BTM collector returns empty, so the BTM file the
  # baseline passes downstream is zero-length. This test exercises that
  # path end-to-end: an empty BTM file ⇒ null.
  export OS_MAJOR_OVERRIDE=12
  tsv="${FIXTURE_DIR}/lctl.tsv"
  btm="${FIXTURE_DIR}/btm.jsonl"
  _make_launchctl_tsv "${tsv}" com.foo
  : > "${btm}"

  out=$(persistence_correlate com.foo "${tsv}" "${btm}")
  [ "$(echo "$out" | jq -r '.btm_registered | type')" = "null" ]
}

# -----------------------------------------------------------------------------
# persistence_detect_injections
# -----------------------------------------------------------------------------

@test "detect_injections: both empty → empty" {
  disk="${FIXTURE_DIR}/disk.txt"
  lctl="${FIXTURE_DIR}/lctl.txt"
  : >"${disk}"
  : >"${lctl}"
  out=$(persistence_detect_injections "${disk}" "${lctl}")
  [ -z "${out}" ]
}

@test "detect_injections: identical sets → empty" {
  disk="${FIXTURE_DIR}/disk.txt"
  lctl="${FIXTURE_DIR}/lctl.txt"
  printf 'com.a\ncom.b\ncom.c\n' >"${disk}"
  printf 'com.b\ncom.a\ncom.c\n' >"${lctl}"  # same set, different order
  out=$(persistence_detect_injections "${disk}" "${lctl}")
  [ -z "${out}" ]
}

@test "detect_injections: disjoint sets → full launchctl set, sorted" {
  disk="${FIXTURE_DIR}/disk.txt"
  lctl="${FIXTURE_DIR}/lctl.txt"
  printf 'com.a\ncom.b\n' >"${disk}"
  printf 'com.z\ncom.x\ncom.y\n' >"${lctl}"
  out=$(persistence_detect_injections "${disk}" "${lctl}")
  expected=$(printf 'com.x\ncom.y\ncom.z\n')
  [ "${out}" = "${expected}" ]
}

@test "detect_injections: overlap → just the launchctl-only elements, sorted" {
  disk="${FIXTURE_DIR}/disk.txt"
  lctl="${FIXTURE_DIR}/lctl.txt"
  printf 'com.a\ncom.b\ncom.c\n' >"${disk}"
  printf 'com.c\ncom.d\ncom.a\ncom.e\n' >"${lctl}"
  out=$(persistence_detect_injections "${disk}" "${lctl}")
  expected=$(printf 'com.d\ncom.e\n')
  [ "${out}" = "${expected}" ]
}

@test "detect_injections: output is always disjoint from on_disk set" {
  # Property-style sanity check: feed it a real overlap and verify
  # every output label is absent from the on_disk input.
  disk="${FIXTURE_DIR}/disk.txt"
  lctl="${FIXTURE_DIR}/lctl.txt"
  printf 'com.shared\ncom.ondisk\n' >"${disk}"
  printf 'com.shared\ncom.injection\n' >"${lctl}"
  out=$(persistence_detect_injections "${disk}" "${lctl}")
  # "com.shared" must NOT appear in the output.
  ! printf '%s\n' "${out}" | grep -qx 'com.shared'
  # "com.injection" MUST appear.
  printf '%s\n' "${out}" | grep -qx 'com.injection'
}

@test "detect_injections: duplicate launchctl entries deduplicated" {
  disk="${FIXTURE_DIR}/disk.txt"
  lctl="${FIXTURE_DIR}/lctl.txt"
  : >"${disk}"
  printf 'com.dup\ncom.dup\ncom.dup\n' >"${lctl}"
  out=$(persistence_detect_injections "${disk}" "${lctl}")
  [ "${out}" = "com.dup" ]
}

@test "detect_injections: missing on_disk file is treated as empty set" {
  lctl="${FIXTURE_DIR}/lctl.txt"
  printf 'com.x\n' >"${lctl}"
  out=$(persistence_detect_injections "${FIXTURE_DIR}/no-such-file" "${lctl}")
  [ "${out}" = "com.x" ]
}

@test "detect_injections: missing launchctl file yields empty output" {
  disk="${FIXTURE_DIR}/disk.txt"
  printf 'com.x\n' >"${disk}"
  out=$(persistence_detect_injections "${disk}" "${FIXTURE_DIR}/no-such-file")
  [ -z "${out}" ]
}
