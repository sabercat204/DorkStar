#!/usr/bin/env bats
# tests/bats/xprotect.bats — unit tests for lib/xprotect.sh.
#
# Strategy: fixture bundles are materialised under a per-test
# FIXTURE_DIR; `XPROTECT_BUNDLE_OVERRIDE` points the capture at the
# fixture path so the tests never read Apple's real XProtect bundle.
# The real `codesign(1)` binary cannot be driven deterministically
# in a unit test (its verdict depends on the fixture's actual
# signature), so every test that needs a specific codesign verdict
# installs a tiny PATH shim that produces the exact exit code and
# stderr text we want.
#
# bash 3.2 / BSD-userland assumptions: uses `shasum -a 256` (not
# `sha256sum`), `stat -f %z` (not `stat -c`), and `plutil` for
# Info.plist authoring. jq is a hard dependency of the library under
# test so it is already required.

bats_require_minimum_version 1.5.0

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  # shellcheck source=/dev/null
  source "${LIB}/xprotect.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-xprotect.XXXXXX")"
  mkdir -p "${FIXTURE_DIR}/bin"
  ORIG_PATH="${PATH}"
  PATH="${FIXTURE_DIR}/bin:${PATH}"
  export PATH
  utils_tmpdir_init >/dev/null
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "${MACAUDIT_TMPDIR}" ]; then
    rm -rf -- "${MACAUDIT_TMPDIR}" || true
  fi
  unset MACAUDIT_TMPDIR
  unset XPROTECT_BUNDLE_OVERRIDE
}

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# _make_xprotect_bundle <bundle_root> <version>
#   Materialise a miniature XProtect bundle:
#     <bundle>/Contents/Info.plist                 (with CFBundleShortVersionString)
#     <bundle>/Contents/Resources/XProtect.yara    (deterministic bytes)
#     <bundle>/Contents/Resources/gk.db            (empty file)
#   The three files exercise the full code path: an Info.plist the
#   version helper must parse, a plain data file, and a SQLite
#   placeholder whose hash must also land in the files map.
_make_xprotect_bundle() {
  local bundle="$1"
  local version="$2"
  mkdir -p "${bundle}/Contents/Resources"

  # Author Info.plist via plutil so we get a real, lintable plist.
  cat > "${bundle}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleIdentifier</key>
  <string>com.apple.XProtect</string>
</dict>
</plist>
EOF

  # Deterministic YARA-rule bytes. Using an exact literal so we can
  # assert the sha256_raw below.
  printf 'rule Test { condition: false }\n' > "${bundle}/Contents/Resources/XProtect.yara"

  # Empty gk.db placeholder. An empty file has the well-known sha256
  # e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.
  : > "${bundle}/Contents/Resources/gk.db"
}

# _install_codesign_shim <exit_code> <stderr_body>
#   Write ${FIXTURE_DIR}/bin/codesign as a bash script that
#   unconditionally prints <stderr_body> on stderr and exits
#   with <exit_code>. We don't bother parsing the flags — the
#   library under test always calls codesign exactly one way
#   (--verify --deep --strict -- <bundle>).
_install_codesign_shim() {
  local rc="$1"
  local body="$2"
  local shim="${FIXTURE_DIR}/bin/codesign"
  local body_file="${FIXTURE_DIR}/codesign_stderr.txt"
  printf '%s' "$body" > "$body_file"
  cat > "$shim" <<SHIM
#!/bin/bash
# stderr only — utils_codesign_verify redirects stdout to /dev/null.
if [ -s "${body_file}" ]; then
  cat "${body_file}" >&2
fi
exit ${rc}
SHIM
  chmod +x "$shim"
}

# -----------------------------------------------------------------------------
# xprotect_bundle_path
# -----------------------------------------------------------------------------

@test "xprotect_bundle_path: returns the canonical system path when no override" {
  unset XPROTECT_BUNDLE_OVERRIDE
  got=$(xprotect_bundle_path)
  [ "${got}" = "/Library/Apple/System/Library/CoreServices/XProtect.bundle" ]
}

@test "xprotect_bundle_path: honours XPROTECT_BUNDLE_OVERRIDE" {
  XPROTECT_BUNDLE_OVERRIDE="${FIXTURE_DIR}/fake.bundle"
  got=$(xprotect_bundle_path)
  [ "${got}" = "${FIXTURE_DIR}/fake.bundle" ]
}

# -----------------------------------------------------------------------------
# xprotect_version
# -----------------------------------------------------------------------------

@test "xprotect_version: reads CFBundleShortVersionString from Info.plist" {
  bundle="${FIXTURE_DIR}/XProtect.bundle"
  _make_xprotect_bundle "${bundle}" "5295"
  got=$(xprotect_version "${bundle}")
  [ "${got}" = "5295" ]
}

@test "xprotect_version: empty when Info.plist is missing" {
  bundle="${FIXTURE_DIR}/EmptyBundle"
  mkdir -p "${bundle}"
  got=$(xprotect_version "${bundle}")
  [ -z "${got}" ]
}

@test "xprotect_version: empty when Info.plist lacks the version key" {
  bundle="${FIXTURE_DIR}/NoVersionBundle"
  mkdir -p "${bundle}/Contents"
  cat > "${bundle}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.apple.XProtect</string>
</dict>
</plist>
EOF
  got=$(xprotect_version "${bundle}")
  [ -z "${got}" ]
}

# -----------------------------------------------------------------------------
# xprotect_capture — happy path
# -----------------------------------------------------------------------------

@test "xprotect_capture: emits one well-formed entry when codesign is clean" {
  bundle="${FIXTURE_DIR}/XProtect.bundle"
  _make_xprotect_bundle "${bundle}" "5295"
  _install_codesign_shim 0 ""

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  run xprotect_capture "${bundle}" "${scratch}"
  [ "${status}" -eq 0 ]
  [ -s "${scratch}" ]

  # Exactly one entry was appended.
  line_count=$(wc -l < "${scratch}" | tr -d ' ')
  [ "${line_count}" = "1" ]

  entry=$(cat "${scratch}")
  echo "${entry}" | jq -e . >/dev/null

  # Tier / surface / format.
  [ "$(echo "${entry}" | jq -r '.tier')" = "3" ]
  [ "$(echo "${entry}" | jq -r '.surface')" = "xprotect" ]
  [ "$(echo "${entry}" | jq -r '.format')" = "bundle" ]
  [ "$(echo "${entry}" | jq -r '.path')" = "${bundle}" ]

  # Version is populated (in both the top-level bundle_version and
  # the content blob).
  [ "$(echo "${entry}" | jq -r '.bundle_version')" = "5295" ]
  [ "$(echo "${entry}" | jq -r '.content.bundle_version')" = "5295" ]

  # Files map contains our three fixture files.
  [ "$(echo "${entry}" | jq -r '.files | type')" = "object" ]
  [ "$(echo "${entry}" | jq -r '.files | has("Contents/Info.plist")')" = "true" ]
  [ "$(echo "${entry}" | jq -r '.files | has("Contents/Resources/XProtect.yara")')" = "true" ]
  [ "$(echo "${entry}" | jq -r '.files | has("Contents/Resources/gk.db")')" = "true" ]
  fc=$(echo "${entry}" | jq -r '.files | length')
  [ "${fc}" = "3" ]

  # Each file has both sha256_raw (64 hex chars) and a numeric size.
  for rel in "Contents/Info.plist" "Contents/Resources/XProtect.yara" "Contents/Resources/gk.db"; do
    h=$(echo "${entry}" | jq -r --arg r "$rel" '.files[$r].sha256_raw')
    echo "${h}" | grep -Eq '^[0-9a-f]{64}$'
    t=$(echo "${entry}" | jq -r --arg r "$rel" '.files[$r].size_bytes | type')
    [ "${t}" = "number" ]
  done

  # Codesign was clean.
  [ "$(echo "${entry}" | jq -r '.codesign.valid')" = "true" ]
  [ "$(echo "${entry}" | jq -r '.codesign.exit_code')" = "0" ]

  # No anomalies.
  [ "$(echo "${entry}" | jq -c '.anomalies')" = "[]" ]
}

# -----------------------------------------------------------------------------
# xprotect_capture — per-file sha256 matches the expected value
# -----------------------------------------------------------------------------

@test "xprotect_capture: per-file sha256_raw matches utils_sha256_file" {
  bundle="${FIXTURE_DIR}/XProtect.bundle"
  _make_xprotect_bundle "${bundle}" "5295"
  _install_codesign_shim 0 ""

  # Compute expected hashes out-of-band.
  expect_yara=$(utils_sha256_file "${bundle}/Contents/Resources/XProtect.yara")
  expect_gk=$(utils_sha256_file "${bundle}/Contents/Resources/gk.db")

  # Empty-file sha256 is a well-known fixed value.
  [ "${expect_gk}" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run xprotect_capture "${bundle}" "${scratch}"
  [ "${status}" -eq 0 ]
  entry=$(cat "${scratch}")

  got_yara=$(echo "${entry}" | jq -r '.files["Contents/Resources/XProtect.yara"].sha256_raw')
  got_gk=$(echo "${entry}" | jq -r '.files["Contents/Resources/gk.db"].sha256_raw')
  [ "${got_yara}" = "${expect_yara}" ]
  [ "${got_gk}" = "${expect_gk}" ]
}

# -----------------------------------------------------------------------------
# xprotect_capture — codesign fail fires xprotect_codesign_fail
# -----------------------------------------------------------------------------

@test "xprotect_capture: fires xprotect_codesign_fail when codesign verdict is invalid" {
  bundle="${FIXTURE_DIR}/XProtect.bundle"
  _make_xprotect_bundle "${bundle}" "5295"
  # Real codesign stderr on a bundle that isn't signed at all.
  _install_codesign_shim 1 "code object is not signed at all"

  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"
  run xprotect_capture "${bundle}" "${scratch}"
  [ "${status}" -eq 0 ]
  entry=$(cat "${scratch}")
  echo "${entry}" | jq -e . >/dev/null

  # Codesign verdict reflects the shim.
  [ "$(echo "${entry}" | jq -r '.codesign.valid')" = "false" ]
  [ "$(echo "${entry}" | jq -r '.codesign.exit_code')" = "1" ]
  [ "$(echo "${entry}" | jq -r '.codesign.stderr_first_line')" = "code object is not signed at all" ]

  # Exactly one anomaly, shape as specified by design.md.
  n=$(echo "${entry}" | jq -r '.anomalies | length')
  [ "${n}" = "1" ]
  [ "$(echo "${entry}" | jq -r '.anomalies[0].rule')" = "xprotect_codesign_fail" ]
  [ "$(echo "${entry}" | jq -r '.anomalies[0].severity')" = "high" ]
  detail=$(echo "${entry}" | jq -r '.anomalies[0].detail')
  # Detail must contain the stderr_first_line value.
  echo "${detail}" | grep -q "code object is not signed at all"
  # Detail must also name the subject so operators know what failed.
  echo "${detail}" | grep -q "XProtect bundle failed codesign"
}

# -----------------------------------------------------------------------------
# xprotect_capture — missing bundle returns 1 and writes nothing
# -----------------------------------------------------------------------------

@test "xprotect_capture: returns 1 and writes nothing when the bundle is missing" {
  missing="${FIXTURE_DIR}/does-not-exist.bundle"
  scratch="${FIXTURE_DIR}/entries.jsonl"
  : > "${scratch}"

  # Use --separate-stderr so the diagnostic line is routed away
  # from $output (we're only asserting on stdout + exit status here).
  run --separate-stderr xprotect_capture "${missing}" "${scratch}"
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
  [ ! -s "${scratch}" ]
}
