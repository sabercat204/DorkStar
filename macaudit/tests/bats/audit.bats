#!/usr/bin/env bats
# tests/bats/audit.bats — unit tests for lib/audit.sh.
#
# Strategy: we construct baseline and "current" manifests entirely by
# hand via manifest_build_header + manifest_build_entry, so we never
# need to invoke the real baseline_run (which would walk the tester's
# actual macOS state). When a test exercises the audit_run entry point
# we redefine `baseline_run` inside the bats shell to copy a fixture
# "current" file into the expected tmpdir location, which mimics the
# re-capture step without any real system I/O.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  # shellcheck source=/dev/null
  source "${LIB}/audit.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-audit.XXXXXX")"
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
  if [ -n "${MACAUDIT_TMPDIR:-}" ] && [ -d "${MACAUDIT_TMPDIR}" ]; then
    rm -rf -- "${MACAUDIT_TMPDIR}" || true
  fi
  unset MACAUDIT_TMPDIR
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _mk_entry_t1 <path> <sha_canon> [<sha_raw>] [<content_json>] [<launchctl>] [<btm>]
#   Build a Tier 1 launchd_system entry with the given identity fields.
#   Everything else is stubbed to stable defaults.
_mk_entry_t1() {
  local p="$1" canon="$2"
  local raw="${3:-}"
  local content="${4:-}"
  local loaded="${5:-null}"
  local btm="${6:-null}"
  [ -n "$raw" ] || raw="r_${canon}"
  [ -n "$content" ] || content='{}'
  manifest_build_entry \
    --path "$p" \
    --tier 1 \
    --surface launchd_system \
    --format xml \
    --sha256-raw "$raw" \
    --sha256-canonical "$canon" \
    --content-json "$content" \
    --launchctl-loaded "$loaded" \
    --btm-registered "$btm"
}

# _mk_entry_t2 <path> <sha_canon> [<cfprefsd_match>] [<content_json>]
_mk_entry_t2() {
  local p="$1" canon="$2"
  local cf="${3:-true}"
  local content="${4:-}"
  [ -n "$content" ] || content='{}'
  manifest_build_entry \
    --path "$p" \
    --tier 2 \
    --surface preferences_system \
    --format xml \
    --sha256-raw "r_${canon}" \
    --sha256-canonical "$canon" \
    --content-json "$content" \
    --cfprefsd-match "$cf"
}

# _mk_injection <label> [<pid>] [<status>]
_mk_injection() {
  local label="$1" pid="${2:-123}" status="${3:-0}"
  local content
  content=$(jq -cn --arg l "$label" --argjson p "$pid" --argjson s "$status" \
    '{label:$l, pid:$p, status:$s}')
  manifest_build_entry \
    --path "launchctl://${label}" \
    --tier 1 \
    --surface injection \
    --format n/a \
    --sha256-raw "" \
    --sha256-canonical "" \
    --content-json "$content" \
    --launchctl-loaded true \
    --btm-registered null
}

# _write_manifest <out_path> <tier> <user_only> <entry1> [<entry2> ...]
_write_manifest() {
  local out="$1" tier="$2" useronly="$3"; shift 3
  local hdr
  hdr=$(manifest_build_header --tier "$tier" --user-only "$useronly")
  manifest_write_header "$out" "$hdr"
  local e
  for e in "$@"; do
    [ -n "$e" ] || continue
    manifest_write_entry "$out" "$e"
  done
}

# _stub_baseline_run_with <fixture_current_manifest>
#   Redefine baseline_run so any --output <path> invocation simply copies
#   the fixture manifest to the requested path. audit_run passes
#   --output <MACAUDIT_TMPDIR>/current.jsonl, so this is how we inject a
#   synthetic "current state" without running the real surface walk.
_stub_baseline_run_with() {
  local fixture="$1"
  export _AUDIT_BATS_FIXTURE="$fixture"
  baseline_run() {
    local out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --output) out="$2"; shift 2 ;;
        *)        shift 1 ;;
      esac
    done
    [ -n "$out" ] || return 1
    cp -- "$_AUDIT_BATS_FIXTURE" "$out"
    printf '%s\n' "$out"
    return 0
  }
}

# ---------------------------------------------------------------------------
# 1. Clean audit: baseline == current → exit 0, summary all zero
# ---------------------------------------------------------------------------

@test "audit_run: clean delta (identical baseline and current) exits 0" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e1=$(_mk_entry_t1 /Library/LaunchDaemons/com.a.plist abc)
  _write_manifest "$b" all false "$e1"
  _write_manifest "$c" all false "$e1"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 0 ]
  # stdout must be a single JSON object.
  printf '%s' "${output}" | jq -e . >/dev/null

  [ "$(printf '%s' "${output}" | jq -c '.summary.total')" = '{"added":0,"removed":0,"modified":0,"stale":0,"injections":0,"suspicious":0}' ]
  [ "$(printf '%s' "${output}" | jq -c '.tiers["1"].added')"    = "[]" ]
  [ "$(printf '%s' "${output}" | jq -c '.tiers["1"].removed')"  = "[]" ]
  [ "$(printf '%s' "${output}" | jq -c '.tiers["1"].modified')" = "[]" ]
}

# ---------------------------------------------------------------------------
# 2. Added
# ---------------------------------------------------------------------------

@test "audit_run: path present in current only lands in tier1.added" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  _write_manifest "$b" all false
  e1=$(_mk_entry_t1 /Library/LaunchDaemons/com.new.plist aaa)
  _write_manifest "$c" all false "$e1"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].added | length')" = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].added[0].path')" = "/Library/LaunchDaemons/com.new.plist" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier1.added')" = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.total.added')" = "1" ]
}

# ---------------------------------------------------------------------------
# 3. Removed
# ---------------------------------------------------------------------------

@test "audit_run: path present in baseline only lands in tier1.removed" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e1=$(_mk_entry_t1 /Library/LaunchDaemons/com.gone.plist aaa)
  _write_manifest "$b" all false "$e1"
  _write_manifest "$c" all false

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].removed | length')" = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].removed[0].path')" = "/Library/LaunchDaemons/com.gone.plist" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier1.removed')" = "1" ]
}

# ---------------------------------------------------------------------------
# 4. Modified — sha256_canonical changed
# ---------------------------------------------------------------------------

@test "audit_run: same path with different sha256_canonical lands in tier1.modified with changes listing the field" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_b=$(_mk_entry_t1 /Library/LaunchDaemons/com.mod.plist aaa)
  e_c=$(_mk_entry_t1 /Library/LaunchDaemons/com.mod.plist bbb)
  _write_manifest "$b" all false "$e_b"
  _write_manifest "$c" all false "$e_c"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].modified | length')" = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].modified[0].path')" = "/Library/LaunchDaemons/com.mod.plist" ]
  # The changes list must name sha256_canonical with before/after values.
  has=$(printf '%s' "${output}" \
    | jq -r '.tiers["1"].modified[0].changes[] | select(.field == "sha256_canonical") | "\(.before):\(.after)"')
  [ "${has}" = "aaa:bbb" ]
}

# ---------------------------------------------------------------------------
# 5. Modified — content changed even when hash is the same (contrived).
# ---------------------------------------------------------------------------

@test "audit_run: same path with different content object is reported as modified on the content field" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_b=$(_mk_entry_t1 /Library/LaunchDaemons/com.content.plist SAME '' '{"Label":"a"}')
  e_c=$(_mk_entry_t1 /Library/LaunchDaemons/com.content.plist SAME '' '{"Label":"b"}')
  _write_manifest "$b" all false "$e_b"
  _write_manifest "$c" all false "$e_c"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].modified | length')" = "1" ]
  fields=$(printf '%s' "${output}" | jq -r '.tiers["1"].modified[0].changes[].field' | sort -u)
  echo "${fields}" | grep -qx content
}

# ---------------------------------------------------------------------------
# 6. Stale — Tier 2 current entry with cfprefsd_match=false
# ---------------------------------------------------------------------------

@test "audit_run: tier 2 current entry with cfprefsd_match=false lands in tier2.stale" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_b=$(_mk_entry_t2 /Library/Preferences/com.apple.alf.plist hhh true)
  e_c=$(_mk_entry_t2 /Library/Preferences/com.apple.alf.plist hhh false)
  _write_manifest "$b" all false "$e_b"
  _write_manifest "$c" all false "$e_c"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  [ "$(printf '%s' "${output}" | jq -r '.tiers["2"].stale | length')" = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["2"].stale[0].path')" = "/Library/Preferences/com.apple.alf.plist" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier2.stale')" = "1" ]
  # Tier 1 stale is always empty.
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].stale | length')" = "0" ]
}

# ---------------------------------------------------------------------------
# 7. Injection — current entry with surface=injection
# ---------------------------------------------------------------------------

@test "audit_run: current entry with surface=injection lands in tier1.injections" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  _write_manifest "$b" all false
  e_c=$(_mk_injection com.example.injected 777 0)
  _write_manifest "$c" all false "$e_c"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].injections | length')" = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].injections[0].label')"  = "com.example.injected" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].injections[0].pid')"    = "777" ]
  [ "$(printf '%s' "${output}" | jq -r '.tiers["1"].injections[0].status')" = "0" ]
  # Tier 2 injections is always empty.
  [ "$(printf '%s' "${output}" | jq -r '.tiers["2"].injections | length')" = "0" ]
}

# ---------------------------------------------------------------------------
# 8. Missing baseline path
# ---------------------------------------------------------------------------

@test "audit_run: missing baseline path emits the baseline-not-found error and exits 2" {
  run audit_run "${FIXTURE_DIR}/does-not-exist.jsonl"
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "baseline not found"
}

# ---------------------------------------------------------------------------
# 9. Version mismatch
# ---------------------------------------------------------------------------

@test "audit_run: unsupported manifest_version emits the version-mismatch error and exits 2" {
  b="${FIXTURE_DIR}/b_oldversion.jsonl"
  # Hand-roll a header with an unsupported version. We cannot use
  # manifest_build_header directly because it hard-codes 1.0 / 1.1.
  printf '{"manifest_version":"0.9","tool":"macaudit","tier":"all","user_only":false,"skipped_paths":[]}\n' > "$b"

  run audit_run "$b"
  [ "${status}" -eq 2 ]
  echo "${output}" | grep -q "not supported by this tool"
  echo "${output}" | grep -q "0.9"
}

# ---------------------------------------------------------------------------
# 10. Summary totals match per-tier category counts
# ---------------------------------------------------------------------------

@test "audit_run: summary totals equal the sum of per-tier category counts" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  # Mix: one added tier1, one removed tier1, one modified tier2, one stale tier2.
  e_b_t1_remove=$(_mk_entry_t1 /Library/LaunchDaemons/com.removed.plist aaa)
  e_b_t2_mod=$(_mk_entry_t2    /Library/Preferences/com.modded.plist zzz true)
  e_b_t2_stale=$(_mk_entry_t2  /Library/Preferences/com.stale.plist sss true)

  e_c_t1_add=$(_mk_entry_t1    /Library/LaunchDaemons/com.added.plist bbb)
  e_c_t2_mod=$(_mk_entry_t2    /Library/Preferences/com.modded.plist ZZZ true)
  e_c_t2_stale=$(_mk_entry_t2  /Library/Preferences/com.stale.plist sss false)

  _write_manifest "$b" all false "$e_b_t1_remove" "$e_b_t2_mod" "$e_b_t2_stale"
  _write_manifest "$c" all false "$e_c_t1_add"    "$e_c_t2_mod" "$e_c_t2_stale"

  _stub_baseline_run_with "$c"

  run audit_run "$b"
  [ "${status}" -eq 1 ]

  # Per-tier totals.
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier1.added')"      = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier1.removed')"    = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier2.modified')"   = "1" ]
  [ "$(printf '%s' "${output}" | jq -r '.summary.tier2.stale')"      = "1" ]

  # summary.total equals the per-tier sums for each category.
  for cat in added removed modified stale injections suspicious; do
    sum=$(printf '%s' "${output}" | jq -r --arg k "$cat" '.summary.tier1[$k] + .summary.tier2[$k] + .summary.tier3[$k]')
    tot=$(printf '%s' "${output}" | jq -r --arg k "$cat" '.summary.total[$k]')
    [ "${tot}" = "${sum}" ]
  done
}

# ---------------------------------------------------------------------------
# 11. --output writes delta JSON to a file and stdout is silent
# ---------------------------------------------------------------------------

@test "audit_run: --output writes the delta JSON to a file and stdout stays empty" {
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e1=$(_mk_entry_t1 /Library/LaunchDaemons/com.a.plist abc)
  _write_manifest "$b" all false "$e1"
  _write_manifest "$c" all false "$e1"

  _stub_baseline_run_with "$c"

  out="${FIXTURE_DIR}/delta.json"
  run audit_run "$b" --output "$out"
  [ "${status}" -eq 0 ]

  # stdout holds no JSON body (only the stderr-routed info line, which
  # `run` captures into $output too — so we check the file instead of
  # asserting $output is empty).
  [ -f "$out" ]
  jq -e . < "$out" >/dev/null
  [ "$(jq -r '.summary.total.added' < "$out")" = "0" ]
}
