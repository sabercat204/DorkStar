#!/usr/bin/env bats
# tests/bats/utils.bats — unit tests for lib/utils.sh primitives.
#
# Each test re-sources utils.sh so function modifications in one test
# never leak into another. Fixtures are created in a per-test tmpdir
# and torn down in teardown().

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-utils.XXXXXX")"
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  # Ensure any exported tmpdir from a test is cleaned up.
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "${MACAUDIT_TMPDIR}" ]; then
    rm -rf -- "${MACAUDIT_TMPDIR}" || true
  fi
  unset MACAUDIT_TMPDIR
}

# -----------------------------------------------------------------------------
# utils_sha256_file / utils_sha256_stdin
# -----------------------------------------------------------------------------

@test "utils_sha256_file: matches shasum -a 256 for a known fixture" {
  fixture="${FIXTURE_DIR}/hello.txt"
  printf 'hello macaudit\n' > "${fixture}"
  expected=$(shasum -a 256 -- "${fixture}" | awk '{print $1}')
  got=$(utils_sha256_file "${fixture}")
  [ -n "${got}" ]
  [ "${got}" = "${expected}" ]
}

@test "utils_sha256_file: empty on missing path" {
  got=$(utils_sha256_file "${FIXTURE_DIR}/does-not-exist")
  [ -z "${got}" ]
}

@test "utils_sha256_stdin: matches shasum -a 256 over piped bytes" {
  bytes='the quick brown fox'
  expected=$(printf '%s' "${bytes}" | shasum -a 256 | awk '{print $1}')
  got=$(printf '%s' "${bytes}" | utils_sha256_stdin)
  [ "${got}" = "${expected}" ]
}

# -----------------------------------------------------------------------------
# utils_plist_format + utils_plist_to_canonical_json
# -----------------------------------------------------------------------------

@test "utils_plist_format: detects xml, binary, invalid, missing" {
  xml_plist="${FIXTURE_DIR}/p.xml.plist"
  bin_plist="${FIXTURE_DIR}/p.bin.plist"
  bad_plist="${FIXTURE_DIR}/p.bad.plist"

  # Build an XML plist from a seed JSON.
  seed="${FIXTURE_DIR}/seed.json"
  printf '{"alpha":"one","beta":2,"flag":true}' > "${seed}"
  plutil -convert xml1 -o "${xml_plist}" "${seed}"
  plutil -convert binary1 -o "${bin_plist}" "${seed}"
  printf 'not a plist at all\n' > "${bad_plist}"

  [ "$(utils_plist_format "${xml_plist}")" = "xml" ]
  [ "$(utils_plist_format "${bin_plist}")" = "binary" ]
  [ "$(utils_plist_format "${bad_plist}")" = "invalid" ]
  [ "$(utils_plist_format "${FIXTURE_DIR}/nope.plist")" = "invalid" ]
}

@test "utils_plist_format: json-serialized plist is rejected by plutil -lint (library behavior note)" {
  # NOTE: `plutil -convert json` writes JSON, but macOS `plutil -lint` rejects
  # raw JSON as a plist (it only accepts XML / binary). `utils_plist_format`
  # therefore returns "invalid" for json-serialized plists. The design doc
  # claims `json` would be returned for such files; in practice this code
  # path is unreachable given the current lint gate in utils_plist_format.
  seed="${FIXTURE_DIR}/seed.json"
  printf '{"alpha":"one","beta":2,"flag":true}' > "${seed}"
  json_plist="${FIXTURE_DIR}/p.json.plist"
  plutil -convert json -o "${json_plist}" "${seed}"
  got=$(utils_plist_format "${json_plist}")
  [ "${got}" = "invalid" ]
}

@test "utils_plist_to_canonical_json: byte-identical across xml/binary/json" {
  seed="${FIXTURE_DIR}/seed.json"
  printf '{"z":1,"a":"hello","nested":{"c":3,"b":[1,2,3]}}' > "${seed}"

  xml_plist="${FIXTURE_DIR}/p.xml.plist"
  bin_plist="${FIXTURE_DIR}/p.bin.plist"
  json_plist="${FIXTURE_DIR}/p.json.plist"
  plutil -convert xml1 -o "${xml_plist}" "${seed}"
  plutil -convert binary1 -o "${bin_plist}" "${seed}"
  plutil -convert json -o "${json_plist}" "${seed}"

  xml_out=$(utils_plist_to_canonical_json "${xml_plist}")
  bin_out=$(utils_plist_to_canonical_json "${bin_plist}")
  json_out=$(utils_plist_to_canonical_json "${json_plist}")

  [ -n "${xml_out}" ]
  [ "${xml_out}" = "${bin_out}" ]
  [ "${xml_out}" = "${json_out}" ]
}

# -----------------------------------------------------------------------------
# utils_xattrs_json
# -----------------------------------------------------------------------------

@test "utils_xattrs_json: empty object for /dev/null" {
  got=$(utils_xattrs_json /dev/null)
  [ "${got}" = "{}" ]
}

@test "utils_xattrs_json: emits name -> base64 for a set xattr" {
  target="${FIXTURE_DIR}/with_xattr.txt"
  : > "${target}"
  # Some filesystems reject xattrs. Skip gracefully if the write fails.
  if ! xattr -w com.example.test 'hello-xattr' "${target}" 2>/dev/null; then
    skip "cannot set xattrs on this filesystem"
  fi
  got=$(utils_xattrs_json "${target}")
  # Must parse as JSON.
  echo "${got}" | jq -e . >/dev/null
  # Key must be present.
  has_key=$(printf '%s' "${got}" | jq -r 'has("com.example.test")')
  [ "${has_key}" = "true" ]
  # Base64 value must round-trip to the original.
  decoded=$(printf '%s' "${got}" | jq -r '."com.example.test"' | base64 -D)
  [ "${decoded}" = "hello-xattr" ]
}

# -----------------------------------------------------------------------------
# OS / environment helpers
# -----------------------------------------------------------------------------

@test "utils_os_version / utils_os_major / utils_hostname are non-empty" {
  [ -n "$(utils_os_version)" ]
  [ -n "$(utils_os_major)" ]
  [ -n "$(utils_hostname)" ]
}

@test "utils_os_major: honours OS_MAJOR_OVERRIDE" {
  OS_MAJOR_OVERRIDE=12
  got=$(utils_os_major)
  [ "${got}" = "12" ]
}

@test "utils_sip_status / utils_ssv_status: return one of enabled|disabled|unknown" {
  sip=$(utils_sip_status)
  ssv=$(utils_ssv_status)
  case "${sip}" in enabled|disabled|unknown) : ;; *) false ;; esac
  case "${ssv}" in enabled|disabled|unknown) : ;; *) false ;; esac
}

@test "utils_iso_now: matches ISO 8601 with colon in offset" {
  got=$(utils_iso_now)
  [ -n "${got}" ]
  # YYYY-MM-DDTHH:MM:SS[+-]HH:MM
  echo "${got}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$'
}

@test "utils_has_sudo: exits non-zero for a non-root test runner" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root — skipping non-root branch"
  fi
  run utils_has_sudo
  [ "${status}" -ne 0 ]
}

@test "utils_require_bash: returns 0 under bash 3.2+" {
  run utils_require_bash
  [ "${status}" -eq 0 ]
}

# -----------------------------------------------------------------------------
# utils_tmpdir_init / cleanup / EXIT + INT traps
# -----------------------------------------------------------------------------

@test "utils_tmpdir_init: creates a dir under TMPDIR and exports MACAUDIT_TMPDIR" {
  unset MACAUDIT_TMPDIR
  # Call without command substitution so the EXIT trap installs in *this*
  # shell rather than firing in a subshell. Command-substitution usage
  # (`dir=$(utils_tmpdir_init)`) would trigger cleanup immediately because
  # the subshell exits.
  utils_tmpdir_init >/dev/null
  [ -n "${MACAUDIT_TMPDIR}" ]
  [ -d "${MACAUDIT_TMPDIR}" ]
  base="${TMPDIR:-/tmp}"
  base="${base%/}"
  case "${MACAUDIT_TMPDIR}" in
    "${base}"/macaudit.*) : ;;
    *) false ;;
  esac
}

@test "utils_tmpdir_init: second call is idempotent" {
  unset MACAUDIT_TMPDIR
  utils_tmpdir_init >/dev/null
  a="${MACAUDIT_TMPDIR}"
  utils_tmpdir_init >/dev/null
  b="${MACAUDIT_TMPDIR}"
  [ "${a}" = "${b}" ]
  [ -d "${a}" ]
}

@test "utils_tmpdir_cleanup: removes dir and unsets MACAUDIT_TMPDIR" {
  unset MACAUDIT_TMPDIR
  utils_tmpdir_init >/dev/null
  dir="${MACAUDIT_TMPDIR}"
  [ -d "${dir}" ]
  utils_tmpdir_cleanup
  [ ! -d "${dir}" ]
  [ -z "${MACAUDIT_TMPDIR:-}" ]
}

@test "utils_tmpdir EXIT trap: tmpdir removed when subshell exits cleanly" {
  # Run in a dedicated bash; the subshell installs its own EXIT trap, which
  # fires on normal exit and removes MACAUDIT_TMPDIR.
  run bash -c "
    set -e
    source '${LIB}/utils.sh'
    utils_tmpdir_init >/dev/null
    printf '%s\n' \"\${MACAUDIT_TMPDIR}\"
  "
  [ "${status}" -eq 0 ]
  dir="${output}"
  [ -n "${dir}" ]
  # After subshell exit the EXIT trap must have removed the dir.
  [ ! -d "${dir}" ]
}

@test "utils_tmpdir INT trap: tmpdir removed on SIGINT and exit is 130" {
  # We spawn a bash subshell, initialise the tmpdir, print its path, then
  # raise SIGINT on ourselves. The INT trap in utils.sh calls cleanup and
  # `exit 130`, so the subshell exits 130 with the tmpdir already removed.
  tmp_stdout="${FIXTURE_DIR}/int.stdout"
  set +e
  bash -c "
    source '${LIB}/utils.sh'
    utils_tmpdir_init >/dev/null
    printf '%s\n' \"\${MACAUDIT_TMPDIR}\"
    kill -INT \$\$
    # Defensive: if the trap didn't run we'd fall through.
    sleep 2
    exit 99
  " > "${tmp_stdout}"
  rc=$?
  set -e
  dir="$(cat "${tmp_stdout}")"
  [ -n "${dir}" ]
  [ ! -d "${dir}" ]
  [ "${rc}" -eq 130 ]
}

# -----------------------------------------------------------------------------
# tty / color / logging
# -----------------------------------------------------------------------------

@test "utils_tty_supports_color: non-zero under command substitution" {
  # When invoked via $(...) stdout is a pipe, not a tty, so this MUST be false.
  run bash -c "source '${LIB}/utils.sh'; utils_tty_supports_color"
  [ "${status}" -ne 0 ]
}

@test "utils_color: empty output under command substitution" {
  got=$(utils_color red)
  [ -z "${got}" ]
  got=$(utils_color reset)
  [ -z "${got}" ]
}

@test "utils_log_info: writes prefixed line to stderr, nothing to stdout" {
  out_file="${FIXTURE_DIR}/out"
  err_file="${FIXTURE_DIR}/err"
  utils_log_info "hello" >"${out_file}" 2>"${err_file}"
  [ ! -s "${out_file}" ]
  got=$(cat "${err_file}")
  [ "${got}" = "[i] hello" ]
}

@test "utils_log_warn/err/skip: each writes its prefixed line to stderr" {
  err_file="${FIXTURE_DIR}/err"
  {
    utils_log_warn "w"
    utils_log_err  "e"
    utils_log_skip "/path" "reason"
  } 2>"${err_file}"
  lines=$(wc -l <"${err_file}" | tr -d ' ')
  [ "${lines}" -eq 3 ]
  grep -q '^\[!\] w$'                 "${err_file}"
  grep -q '^\[x\] e$'                 "${err_file}"
  grep -q '^\[skip\] /path (reason)$' "${err_file}"
}

# -----------------------------------------------------------------------------
# file metadata
# -----------------------------------------------------------------------------

@test "utils_file_size: returns byte count of a regular file" {
  f="${FIXTURE_DIR}/size.bin"
  dd if=/dev/zero of="${f}" bs=1 count=17 2>/dev/null
  got=$(utils_file_size "${f}")
  [ "${got}" = "17" ]
}

@test "utils_file_mtime_iso: returns ISO 8601 UTC timestamp" {
  f="${FIXTURE_DIR}/mt"
  : > "${f}"
  got=$(utils_file_mtime_iso "${f}")
  echo "${got}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}
