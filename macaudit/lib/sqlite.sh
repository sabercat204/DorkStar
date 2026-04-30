#!/bin/bash
# lib/sqlite.sh — SQLite WAL safe-copy protocol + read-only queries.
#
# This module is the foundation every Tier 3 surface (TCC.db, KextPolicy,
# ExecPolicy, SystemPolicy, LSQuarantineEvent, and any future SQLite-backed
# surface) builds on top of. Its single responsibility is to fold a live
# SQLite database with an in-flight WAL into a deterministic, read-only
# artefact WITHOUT ever writing to the originals.
#
# The protocol:
#   1. Copy `.db-shm`, `.db-wal`, and `.db` (sidecars FIRST, main last) via
#      `cp -p` into a per-database scratch subdirectory under
#      `MACAUDIT_TMPDIR` named `sqlite_<hash>` where `<hash>` is the first
#      16 hex chars of sha256(absolute db path STRING). Same path ⇒ same
#      scratch dir; different path ⇒ different scratch dir.
#   2. Run `PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;`
#      against the COPY only. This folds the WAL into the main db file and
#      switches the journal mode on the copy to a regular delete journal so
#      subsequent read-only opens do not spawn fresh WAL sidecars.
#   3. Remove any residual `.db-wal` / `.db-shm` files in the scratch dir
#      so `sqlite_checkpointed_hash` hashes exactly one well-defined file.
#   4. Every subsequent query goes through `sqlite3 -batch -readonly
#      "file:${copy}?mode=ro"` — belt-and-braces read-only.
#
# Every function is side-effect-free EXCEPT `sqlite_safe_copy`, which writes
# to `MACAUDIT_TMPDIR`. Nothing outside `MACAUDIT_TMPDIR` is ever opened for
# writing. Errors collapse to empty stdout and exit 0 — the caller decides
# whether to skip the surface or surface the failure.

# -----------------------------------------------------------------------------
# Section 1 — safe-copy / checkpoint / readonly probe
# -----------------------------------------------------------------------------

# _sqlite_scratch_basename <db_path>
#   stdout: basename of the per-db scratch subdir — `sqlite_<hash16>` where
#           `<hash16>` is the first 16 hex chars of sha256(db_path_string).
#           Empty on error.
#
# Hashing the PATH STRING (not the file bytes) is intentional: we want the
# scratch dir name to be stable across idempotent calls even when the
# underlying file mutates between invocations, and we want distinct paths
# to land in distinct subdirs so two Tier 3 surfaces never clobber each
# other's copies.
_sqlite_scratch_basename() {
  local db_path="$1"
  [ -n "$db_path" ] || return 0
  local hash
  hash=$(printf '%s' "$db_path" | utils_sha256_stdin 2>/dev/null)
  [ -n "$hash" ] || return 0
  printf 'sqlite_%s\n' "${hash:0:16}"
}

# sqlite_safe_copy <db_path>
#   stdout: absolute path to the checkpointed read-only COPY of the
#           database, or empty string on any error.
#   exit:   always 0.
#
# Procedure:
#   1. Verify `MACAUDIT_TMPDIR` is set and writable and that `<db_path>`
#      exists and is readable.
#   2. Compute the scratch subdir under `MACAUDIT_TMPDIR`; create it
#      (mkdir -p) so repeated calls reuse the same path.
#   3. Copy `.db-shm`, `.db-wal`, and `.db` (sidecars first) via `cp -p`.
#      Missing sidecars are fine — SQLite handles their absence cleanly.
#   4. Run `PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;`
#      against the COPY. The ONLY write-mode sqlite3 invocation in the
#      entire module.
#   5. Remove residual `.db-wal` / `.db-shm` in the scratch dir so the
#      checkpointed hash is over a single well-defined file.
#   6. Emit the copy's absolute path to stdout.
#
# Idempotent: same `<db_path>` within one run ⇒ same scratch-dir name. The
# file contents are re-copied on every call because the original may have
# changed since the last invocation.
sqlite_safe_copy() {
  local db_path="$1"
  [ -n "$db_path" ] || return 0

  # Refuse to proceed without a managed tmpdir — we MUST NOT scribble into
  # TMPDIR directly without the cleanup trap.
  if [ -z "${MACAUDIT_TMPDIR:-}" ] || [ ! -d "$MACAUDIT_TMPDIR" ]; then
    return 0
  fi

  # The source .db MUST exist and be readable. Sidecar absence is normal.
  if [ ! -r "$db_path" ]; then
    return 0
  fi

  local base
  base=$(_sqlite_scratch_basename "$db_path")
  [ -n "$base" ] || return 0

  local scratch="${MACAUDIT_TMPDIR}/${base}"
  mkdir -p -- "$scratch" 2>/dev/null || return 0

  local src_name
  src_name=$(basename -- "$db_path")
  [ -n "$src_name" ] || return 0
  local copy="${scratch}/${src_name}"

  # Clear any prior artefacts so the new copy is the only thing present.
  # The originals remain untouched — we only rm under MACAUDIT_TMPDIR.
  rm -f -- "$copy" "${copy}-wal" "${copy}-shm" 2>/dev/null

  # --- Copy sidecars FIRST, then main db.
  # Order matters so SQLite at checkpoint time sees every required byte.
  if [ -r "${db_path}-shm" ]; then
    cp -p -- "${db_path}-shm" "${copy}-shm" 2>/dev/null || return 0
  fi
  if [ -r "${db_path}-wal" ]; then
    cp -p -- "${db_path}-wal" "${copy}-wal" 2>/dev/null || return 0
  fi
  cp -p -- "$db_path" "$copy" 2>/dev/null || return 0

  # --- Checkpoint the WAL into the main copy. This is the ONLY
  # write-mode sqlite3 invocation in the module, operating on the copy.
  if ! sqlite3 -batch "$copy" \
      'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;' \
      >/dev/null 2>&1; then
    return 0
  fi

  # --- Remove any lingering sidecars so the copy is a single file.
  # PRAGMA journal_mode=DELETE normally deletes them, but some macOS
  # sqlite builds leave zero-byte stubs. Scrub either way.
  rm -f -- "${copy}-wal" "${copy}-shm" 2>/dev/null

  printf '%s\n' "$copy"
}

# sqlite_checkpointed_hash <copy_path>
#   stdout: sha256 of the post-checkpoint copy. Empty on error.
#
# Delegates to `utils_sha256_file`. A deliberate one-liner wrapper so the
# Tier 3 modules and the P17 property test can refer to the concept by
# name rather than re-deriving the hash directly.
sqlite_checkpointed_hash() {
  local copy="$1"
  [ -n "$copy" ] || return 0
  [ -r "$copy" ] || return 0
  utils_sha256_file "$copy"
}

# sqlite_assert_readonly <copy_path>
#   exit 0 when `PRAGMA query_only` reports 1 under `sqlite3 -readonly
#   "file:${copy}?mode=ro"`; exit 1 otherwise.
#
# Belt-and-braces probe for the read-only promise. We set `query_only=1`
# and then ask SQLite to echo it back. The cli returns the value on its own
# line; we grep for `1` to avoid pattern-sensitivity on empty output.
sqlite_assert_readonly() {
  local copy="$1"
  [ -n "$copy" ] || return 1
  [ -r "$copy" ] || return 1
  local out
  out=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
      'PRAGMA query_only=1; PRAGMA query_only;' 2>/dev/null) || return 1
  [ "$out" = "1" ]
}

# -----------------------------------------------------------------------------
# Section 2 — read-only queries
# -----------------------------------------------------------------------------

# sqlite_query_tsv <copy_path> <sql>
#   stdout: header + tab-separated rows (the sqlite3 `-separator \t`
#           format) from running <sql> against <copy_path> in read-only
#           mode. Empty on error.
#
# Any query executed through this helper is guaranteed to be read-only:
# the `-readonly` flag AND the `file:...?mode=ro` URI together refuse any
# write pragma, any DDL, any DML. The caller never needs to worry about
# quoting.
sqlite_query_tsv() {
  local copy="$1"
  local sql="$2"
  [ -n "$copy" ] || return 0
  [ -n "$sql" ] || return 0
  [ -r "$copy" ] || return 0
  sqlite3 -batch -readonly -header -separator "$(printf '\t')" \
    "file:${copy}?mode=ro" "$sql" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Section 3 — table snapshot + content hash + wal sidecar info
# -----------------------------------------------------------------------------

# _sqlite_split_csv <csv>
#   stdout: one token per line (empty tokens filtered out).
#
# Used to split primary_key_csv / columns_csv into arrays consumable by
# jq. Keeping this as a string manipulation lets us stay bash-3.2 safe —
# no associative arrays, no namerefs.
_sqlite_split_csv() {
  local csv="$1"
  [ -n "$csv" ] || return 0
  printf '%s' "$csv" | tr ',' '\n' | sed '/^[[:space:]]*$/d' \
    | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}'
}

# _sqlite_table_exists <copy_path> <table>
#   exit 0 if the table is present in sqlite_master, exit 1 otherwise.
_sqlite_table_exists() {
  local copy="$1"
  local table="$2"
  [ -n "$copy" ] || return 1
  [ -n "$table" ] || return 1
  local out
  out=$(sqlite3 -batch -readonly "file:${copy}?mode=ro" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name='${table}' LIMIT 1;" \
    2>/dev/null) || return 1
  [ -n "$out" ]
}

# sqlite_snapshot_table <copy_path> <table> <primary_key_csv> <columns_csv>
#   stdout: one-line JSON object
#     { "row_count": N,
#       "primary_key": ["col1", "col2", ...],
#       "content_hash": "<sha256>",
#       "rows": [ {"col1": ..., "col2": ...}, ... ] }
#   Empty on error (missing table, sqlite failure, empty inputs).
#
# The rows array is sorted by the declared primary-key columns so two
# runs over identical row content produce byte-identical JSON regardless
# of SQLite's storage order. `content_hash` is SHA-256 of the sorted
# rows array serialised with `jq -cS`.
#
# Caller invariant: <primary_key_csv> and <columns_csv> are SQL-safe
# identifier lists (always hard-coded in the Tier 3 surface modules,
# never operator input). The function does not quote them itself.
sqlite_snapshot_table() {
  local copy="$1"
  local table="$2"
  local pk_csv="$3"
  local columns_csv="$4"

  [ -n "$copy" ] || return 0
  [ -n "$table" ] || return 0
  [ -n "$pk_csv" ] || return 0
  [ -n "$columns_csv" ] || return 0
  [ -r "$copy" ] || return 0

  if ! _sqlite_table_exists "$copy" "$table"; then
    return 0
  fi

  # Convert the PK / column CSVs into JSON arrays of strings.
  local pk_json columns_json
  pk_json=$(_sqlite_split_csv "$pk_csv" | jq -R . 2>/dev/null | jq -cs . 2>/dev/null)
  columns_json=$(_sqlite_split_csv "$columns_csv" | jq -R . 2>/dev/null | jq -cs . 2>/dev/null)
  [ -n "$pk_json" ] || return 0
  [ -n "$columns_json" ] || return 0

  # Pull every row as a JSON array of objects. `sqlite3 -json` emits
  # `[]` for empty tables and `[{...}, ...]` otherwise.
  local rows_raw
  rows_raw=$(sqlite3 -batch -readonly -json "file:${copy}?mode=ro" \
    "SELECT ${columns_csv} FROM ${table};" 2>/dev/null)

  # `sqlite3 -json` emits literally nothing when the query returns zero
  # rows on some macOS sqlite builds; normalise to `[]`.
  if [ -z "$rows_raw" ]; then
    rows_raw='[]'
  fi

  # Validate the JSON before handing it to jq for sorting.
  if ! printf '%s' "$rows_raw" | jq -e . >/dev/null 2>&1; then
    return 0
  fi

  # Sort by the declared PK columns, canonical-compact form.
  local sorted
  sorted=$(printf '%s' "$rows_raw" | jq -cS \
    --argjson pk "$pk_json" \
    'sort_by([ .[ $pk[] ] ])' 2>/dev/null)
  [ -n "$sorted" ] || return 0

  # content_hash — sha256 over the sorted rows canonical JSON exactly as
  # we pipe it to stdout (jq -cS appends a newline, which is what the
  # hasher sees).
  local content_hash
  content_hash=$(printf '%s\n' "$sorted" | utils_sha256_stdin)
  [ -n "$content_hash" ] || return 0

  local row_count
  row_count=$(printf '%s' "$sorted" | jq -r 'length' 2>/dev/null)
  [ -n "$row_count" ] || row_count=0

  jq -cn \
    --argjson pk "$pk_json" \
    --argjson rows "$sorted" \
    --arg content_hash "$content_hash" \
    --argjson row_count "$row_count" \
    '{row_count: $row_count, primary_key: $pk, content_hash: $content_hash, rows: $rows}' \
    2>/dev/null
}

# sqlite_content_hash <copy_path> <table> <primary_key_csv> <columns_csv>
#   stdout: just the content_hash field from the corresponding
#           sqlite_snapshot_table call. Empty on error.
#
# Lets callers skip the full row dump when only the hash matters (e.g.
# the baseline-to-audit delta pass).
sqlite_content_hash() {
  local snapshot
  snapshot=$(sqlite_snapshot_table "$@")
  [ -n "$snapshot" ] || return 0
  printf '%s' "$snapshot" | jq -r '.content_hash' 2>/dev/null
}

# sqlite_wal_sidecar_info <db_path>
#   stdout: one-line JSON object
#     {"wal_present": true|false, "wal_sha256": "<sha256>" | ""}
#   computed from the SOURCE `<db_path>-wal` bytes (NOT the scratch copy).
#
# `wal_sha256` is the empty string when the sidecar is absent or
# unreadable. `wal_present` is strictly a boolean — callers use this field
# as the Tier 3 entry's `wal_present`.
sqlite_wal_sidecar_info() {
  local db_path="$1"
  local wal_path="${db_path}-wal"
  local present=false
  local wal_hash=""

  if [ -n "$db_path" ] && [ -e "$wal_path" ]; then
    present=true
    wal_hash=$(utils_sha256_file "$wal_path")
    # Failure to hash (unreadable) ⇒ empty hash but wal_present stays true
    # because the file EXISTS on disk; the absence of the hash is surfaced
    # via the empty string per the declared contract.
  fi

  jq -cn \
    --argjson present "$present" \
    --arg wal_hash "$wal_hash" \
    '{wal_present: $present, wal_sha256: $wal_hash}' 2>/dev/null
}
