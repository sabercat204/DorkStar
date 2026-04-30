#!/usr/bin/env bats
# tests/bats/integrity.bats — unit tests for lib/integrity.sh.
#
# Strategy: build baseline "fixture" plists on disk, hash them using the
# same utils primitives the module uses, and then hand-roll a matching
# baseline manifest via manifest_build_header + manifest_build_entry so
# we can drive every classification branch deterministically.
#
# The re-capture step in integrity_run is intercepted the same way
# audit.bats intercepts it: we redefine `baseline_run` inside the bats
# shell to copy a fixture "current" manifest into the expected tmpdir
# location, so no real system I/O happens.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/manifest.sh"
  # shellcheck source=/dev/null
  source "${LIB}/integrity.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-integrity.XXXXXX")"
}

teardown() {
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    chmod -R u+rwX "${FIXTURE_DIR}" 2>/dev/null || true
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

# _write_xml_plist <path> <label>
#   Create a minimal valid XML plist at <path> whose Label key equals <label>.
_write_xml_plist() {
  local path="$1" label="$2"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
</dict>
</plist>
EOF
}

# _write_binary_plist <path> <label>
#   Create the same semantic plist as _write_xml_plist but stored as a
#   binary plist. Uses plutil -convert binary1 on a scratch XML file so
#   the result is a real binary1-magic plist, not a hand-forged fake.
_write_binary_plist() {
  local path="$1" label="$2"
  local scratch="${path}.xml.scratch"
  _write_xml_plist "$scratch" "$label"
  plutil -convert binary1 -o "$path" -- "$scratch"
  rm -f -- "$scratch"
}

# _hash_raw <path>
#   stdout: sha256 of the file bytes.
_hash_raw() { utils_sha256_file "$1"; }

# _hash_canon <path>
#   stdout: sha256 of the canonical JSON representation.
_hash_canon() { utils_plist_to_canonical_json "$1" | utils_sha256_stdin; }

# _mk_entry_t1 <path> <sha_raw> <sha_canon> [<fmt>]
_mk_entry_t1() {
  local p="$1" raw="$2" canon="$3" fmt="${4:-xml}"
  manifest_build_entry \
    --path "$p" \
    --tier 1 \
    --surface launchd_system \
    --format "$fmt" \
    --sha256-raw "$raw" \
    --sha256-canonical "$canon" \
    --content-json '{}' \
    --cfprefsd-match null \
    --launchctl-loaded null \
    --btm-registered null
}

# _mk_entry_t3 <path> <sha_raw> <sha_canon>
#   Build a Tier 3 entry so we can exercise the deferred-to-15J skip.
_mk_entry_t3() {
  local p="$1" raw="$2" canon="$3"
  manifest_build_entry \
    --path "$p" \
    --tier 3 \
    --surface tcc_system \
    --format sqlite \
    --sha256-raw "$raw" \
    --sha256-canonical "$canon" \
    --content-json '{}' \
    --sha256-checkpointed "$raw" \
    --wal-present false \
    --table-snapshots-json '{}' \
    --anomalies-json '[]'
}

# _write_manifest <out> <tier> <user_only> <entry1> [<entry2> ...]
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
#   <fixture_current_manifest> to the requested path. integrity_run passes
#   --output <MACAUDIT_TMPDIR>/current.jsonl, so this is how we inject a
#   synthetic "current state" manifest without running the real surface walk.
_stub_baseline_run_with() {
  local fixture="$1"
  export _INTEGRITY_BATS_FIXTURE="$fixture"
  baseline_run() {
    local out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --output) out="$2"; shift 2 ;;
        *)        shift 1 ;;
      esac
    done
    [ -n "$out" ] || return 1
    cp -- "$_INTEGRITY_BATS_FIXTURE" "$out"
    printf '%s\n' "$out"
    return 0
  }
}

# ---------------------------------------------------------------------------
# 1. All PASS — baseline hashes match on-disk bytes exactly.
# ---------------------------------------------------------------------------

@test "integrity_run: all-PASS baseline exits 0 and emits only PASS rows" {
  plist="${FIXTURE_DIR}/com.pass.plist"
  _write_xml_plist "$plist" com.pass

  raw=$(_hash_raw "$plist")
  canon=$(_hash_canon "$plist")
  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e=$(_mk_entry_t1 "$plist" "$raw" "$canon")
  _write_manifest "$b" all false "$e"
  _write_manifest "$c" all false "$e"

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 0 ]
  # One PASS line for the plist path.
  echo "$output" | grep -Eq "^PASS[[:space:]]+${plist}$"
  # No FAIL, MISSING, or NEW rows anywhere in the output.
  ! echo "$output" | grep -qE "^FAIL"
  ! echo "$output" | grep -qE "^MISSING"
  ! echo "$output" | grep -qE "^NEW"
  # Summary reflects the one PASS row.
  echo "$output" | grep -qE "PASS:[[:space:]]+1$"
  echo "$output" | grep -qE "FAIL:[[:space:]]+0$"
  echo "$output" | grep -qE "MISSING:[[:space:]]+0$"
  echo "$output" | grep -qE "NEW:[[:space:]]+0$"
  echo "$output" | grep -qE "TOTAL:[[:space:]]+1$"
}

# ---------------------------------------------------------------------------
# 2. FAIL[raw,canonical] — semantic drift, both channels changed.
# ---------------------------------------------------------------------------

@test "integrity_run: semantic drift emits FAIL[raw,canonical] and exits 1" {
  plist="${FIXTURE_DIR}/com.drift.plist"
  _write_xml_plist "$plist" com.drift.before

  raw_b=$(_hash_raw "$plist")
  canon_b=$(_hash_canon "$plist")

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_b=$(_mk_entry_t1 "$plist" "$raw_b" "$canon_b")
  _write_manifest "$b" all false "$e_b"
  # Current manifest is an empty entry list — only NEW detection reads it.
  _write_manifest "$c" all false

  # Now mutate the file in place so its hashes drift.
  _write_xml_plist "$plist" com.drift.after

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Eq "^FAIL\[raw,canonical\][[:space:]]+${plist}$"
  echo "$output" | grep -qE "FAIL:[[:space:]]+1$"
  echo "$output" | grep -qE "PASS:[[:space:]]+0$"
  echo "$output" | grep -qE "TOTAL:[[:space:]]+1$"
}

# ---------------------------------------------------------------------------
# 3. FAIL[raw] only — format re-encode (binary → xml) leaves canonical intact.
# ---------------------------------------------------------------------------

@test "integrity_run: binary→xml format change emits FAIL[raw] and exits 1" {
  plist="${FIXTURE_DIR}/com.format.plist"
  # Baseline: binary plist.
  _write_binary_plist "$plist" com.format
  raw_b=$(_hash_raw "$plist")
  canon_b=$(_hash_canon "$plist")

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_b=$(_mk_entry_t1 "$plist" "$raw_b" "$canon_b" binary)
  _write_manifest "$b" all false "$e_b"
  _write_manifest "$c" all false

  # Now rewrite the same semantic content as XML. Raw bytes differ;
  # canonical JSON is identical because utils_plist_to_canonical_json
  # normalises format into sorted compact JSON.
  _write_xml_plist "$plist" com.format

  # Sanity check on the fixture itself: the canonical hash must still
  # match. Without this, the test below would pass for the wrong reason
  # (both channels drifted).
  raw_now=$(_hash_raw "$plist")
  canon_now=$(_hash_canon "$plist")
  [ "$raw_now"   != "$raw_b"   ]
  [ "$canon_now" = "$canon_b" ]

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Eq "^FAIL\[raw\][[:space:]]+${plist}$"
  # The canonical channel must NOT appear in the emitted row.
  ! echo "$output" | grep -qE "FAIL\[raw,canonical\]"
  ! echo "$output" | grep -qE "FAIL\[canonical\]"
  echo "$output" | grep -qE "FAIL:[[:space:]]+1$"
}

# ---------------------------------------------------------------------------
# 4. MISSING — baseline path no longer on disk.
# ---------------------------------------------------------------------------

@test "integrity_run: missing on-disk file is classified MISSING and exits 1" {
  gone="${FIXTURE_DIR}/com.gone.plist"
  # We never create the file — `-e` should fail on it.

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e=$(_mk_entry_t1 "$gone" aaa bbb)
  _write_manifest "$b" all false "$e"
  _write_manifest "$c" all false

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Eq "^MISSING[[:space:]]+${gone}$"
  echo "$output" | grep -qE "MISSING:[[:space:]]+1$"
  echo "$output" | grep -qE "PASS:[[:space:]]+0$"
  echo "$output" | grep -qE "FAIL:[[:space:]]+0$"
}

# ---------------------------------------------------------------------------
# 5. NEW — current has a path absent from baseline.
# ---------------------------------------------------------------------------

@test "integrity_run: current-only path is classified NEW and exits 1" {
  new_path="${FIXTURE_DIR}/com.new.plist"
  _write_xml_plist "$new_path" com.new
  raw=$(_hash_raw "$new_path")
  canon=$(_hash_canon "$new_path")

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  _write_manifest "$b" all false
  e_c=$(_mk_entry_t1 "$new_path" "$raw" "$canon")
  _write_manifest "$c" all false "$e_c"

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 1 ]
  echo "$output" | grep -Eq "^NEW[[:space:]]+${new_path}$"
  echo "$output" | grep -qE "NEW:[[:space:]]+1$"
  echo "$output" | grep -qE "TOTAL:[[:space:]]+1$"
}

# ---------------------------------------------------------------------------
# 6. Mixed PASS / FAIL / MISSING / NEW — summary counts align.
# ---------------------------------------------------------------------------

@test "integrity_run: mixed classifications yield accurate summary totals" {
  pass_p="${FIXTURE_DIR}/com.pass.plist"
  fail_p="${FIXTURE_DIR}/com.fail.plist"
  miss_p="${FIXTURE_DIR}/com.missing.plist"
  new_p="${FIXTURE_DIR}/com.new.plist"

  _write_xml_plist "$pass_p" com.pass
  _write_xml_plist "$fail_p" com.fail.before

  raw_pass=$(_hash_raw  "$pass_p"); canon_pass=$(_hash_canon "$pass_p")
  raw_fail=$(_hash_raw  "$fail_p"); canon_fail=$(_hash_canon "$fail_p")

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_pass=$(_mk_entry_t1 "$pass_p" "$raw_pass" "$canon_pass")
  e_fail=$(_mk_entry_t1 "$fail_p" "$raw_fail" "$canon_fail")
  e_miss=$(_mk_entry_t1 "$miss_p" aaa bbb)
  _write_manifest "$b" all false "$e_pass" "$e_fail" "$e_miss"

  # Current manifest: PASS + FAIL paths still present, plus a NEW path.
  # MISSING is absent from current too (deleted), which is fine — it only
  # surfaces via the baseline loop.
  _write_xml_plist "$new_p" com.new
  raw_new=$(_hash_raw "$new_p"); canon_new=$(_hash_canon "$new_p")
  e_pass_c=$(_mk_entry_t1 "$pass_p" "$raw_pass" "$canon_pass")
  e_fail_c=$(_mk_entry_t1 "$fail_p" "$raw_fail" "$canon_fail")
  e_new_c=$(_mk_entry_t1 "$new_p"  "$raw_new"  "$canon_new")
  _write_manifest "$c" all false "$e_pass_c" "$e_fail_c" "$e_new_c"

  # Mutate the FAIL target AFTER we've hashed + seeded the current
  # manifest so only the on-disk bytes drift at integrity_run time.
  _write_xml_plist "$fail_p" com.fail.after

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 1 ]

  # Extract the four counts from the SUMMARY block and compare.
  p=$(echo "$output" | awk '/^  PASS:/    {print $2}')
  f=$(echo "$output" | awk '/^  FAIL:/    {print $2}')
  m=$(echo "$output" | awk '/^  MISSING:/ {print $2}')
  n=$(echo "$output" | awk '/^  NEW:/     {print $2}')
  t=$(echo "$output" | awk '/^  TOTAL:/   {print $2}')
  [ "$p" = "1" ]
  [ "$f" = "1" ]
  [ "$m" = "1" ]
  [ "$n" = "1" ]
  [ "$t" = "4" ]

  # And each classification row is present.
  echo "$output" | grep -Eq "^PASS[[:space:]]+${pass_p}$"
  echo "$output" | grep -Eq "^FAIL\[raw,canonical\][[:space:]]+${fail_p}$"
  echo "$output" | grep -Eq "^MISSING[[:space:]]+${miss_p}$"
  echo "$output" | grep -Eq "^NEW[[:space:]]+${new_p}$"
}

# ---------------------------------------------------------------------------
# 7. Missing baseline file.
# ---------------------------------------------------------------------------

@test "integrity_run: missing baseline path emits 'baseline not found' and exits 2" {
  run integrity_run "${FIXTURE_DIR}/does-not-exist.jsonl"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "baseline not found"
}

# ---------------------------------------------------------------------------
# 8. Version mismatch — header manifest_version is neither 1.0 nor 1.1.
# ---------------------------------------------------------------------------

@test "integrity_run: unsupported manifest_version emits version-mismatch and exits 2" {
  b="${FIXTURE_DIR}/b_oldversion.jsonl"
  # Hand-roll the header with an unsupported version.
  printf '{"manifest_version":"0.9","tool":"macaudit","tier":"all","user_only":false,"skipped_paths":[]}\n' > "$b"

  run integrity_run "$b"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "not supported by this tool"
  echo "$output" | grep -q "0.9"
}

# ---------------------------------------------------------------------------
# 9. Tier 3 entries classified via 15J hash channels (no longer deferred).
# ---------------------------------------------------------------------------

@test "integrity_run: tier-3 entries are classified by sha256_checkpointed" {
  # One Tier 1 PASS entry + one Tier 3 entry whose checkpointed hash is
  # identical in baseline and current — should PASS.
  plist="${FIXTURE_DIR}/com.pass.plist"
  _write_xml_plist "$plist" com.pass
  raw=$(_hash_raw "$plist"); canon=$(_hash_canon "$plist")

  db_path="${FIXTURE_DIR}/fake_tcc.db"
  e_t1=$(_mk_entry_t1 "$plist"   "$raw" "$canon")
  e_t3=$(_mk_entry_t3 "$db_path" "deadbeef" "feedface")

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  _write_manifest "$b" all false "$e_t1" "$e_t3"
  # Current manifest carries the same Tier 3 entry so the checkpointed
  # hash matches and the row classifies as PASS.
  _write_manifest "$c" all false "$e_t1" "$e_t3"

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 0 ]

  # Tier 1 and Tier 3 entries both PASS.
  echo "$output" | grep -Eq "^PASS[[:space:]]+${plist}$"
  echo "$output" | grep -Eq "^PASS[[:space:]]+${db_path}$"
  echo "$output" | grep -qE "PASS:[[:space:]]+2$"
  echo "$output" | grep -qE "TOTAL:[[:space:]]+2$"
}

# ---------------------------------------------------------------------------
# 10. Sum of categories equals TOTAL (invariant reinforced on a clean mix).
# ---------------------------------------------------------------------------

@test "integrity_run: TOTAL equals PASS + FAIL + MISSING + NEW across any mix" {
  pass_p="${FIXTURE_DIR}/com.pass.plist"
  _write_xml_plist "$pass_p" com.pass
  raw=$(_hash_raw "$pass_p"); canon=$(_hash_canon "$pass_p")

  miss_p="${FIXTURE_DIR}/com.gone.plist"
  new_p="${FIXTURE_DIR}/com.new.plist"
  _write_xml_plist "$new_p" com.new
  raw_n=$(_hash_raw "$new_p"); canon_n=$(_hash_canon "$new_p")

  b="${FIXTURE_DIR}/b.jsonl"
  c="${FIXTURE_DIR}/c.jsonl"
  e_pass=$(_mk_entry_t1 "$pass_p" "$raw" "$canon")
  e_miss=$(_mk_entry_t1 "$miss_p" aaa bbb)
  _write_manifest "$b" all false "$e_pass" "$e_miss"
  e_pass_c=$(_mk_entry_t1 "$pass_p" "$raw" "$canon")
  e_new_c=$(_mk_entry_t1 "$new_p"  "$raw_n" "$canon_n")
  _write_manifest "$c" all false "$e_pass_c" "$e_new_c"

  _stub_baseline_run_with "$c"

  run integrity_run "$b"
  [ "$status" -eq 1 ]

  p=$(echo "$output" | awk '/^  PASS:/    {print $2}')
  f=$(echo "$output" | awk '/^  FAIL:/    {print $2}')
  m=$(echo "$output" | awk '/^  MISSING:/ {print $2}')
  n=$(echo "$output" | awk '/^  NEW:/     {print $2}')
  t=$(echo "$output" | awk '/^  TOTAL:/   {print $2}')
  sum=$(( p + f + m + n ))
  [ "$t" = "$sum" ]
}
