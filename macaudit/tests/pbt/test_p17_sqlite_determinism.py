"""Property P17 — SQLite safe-copy / snapshot determinism.

**Property 17**: Two back-to-back runs of ``sqlite_safe_copy`` +
``sqlite_snapshot_table`` on the same fixture database yield equal
``sha256_checkpointed`` values and equal per-table ``content_hash``
values. This must hold whether or not the source had a non-empty WAL
on one of the two runs, because ``PRAGMA wal_checkpoint(TRUNCATE);
PRAGMA journal_mode=DELETE;`` collapses the WAL into the main DB on
the copy before the hash is taken.

Hypothesis generates random schemas (1-3 tables, 1-5 INTEGER/TEXT
columns each, 0-20 rows per table) and materialises them via Python's
``sqlite3`` stdlib. For each example the test:

  1. Builds the fixture database.
  2. Calls ``sqlite_safe_copy`` twice back-to-back, each time in a
     fresh ``MACAUDIT_TMPDIR`` so the second run cannot simply reuse
     scratch files from the first.
  3. Hashes each checkpointed copy via ``utils_sha256_file``.
  4. For each table declared by the schema: snapshots it twice (once
     per copy) and extracts the ``content_hash`` field.
  5. Asserts ``sha256_checkpointed_1 == sha256_checkpointed_2`` and
     ``content_hash_1 == content_hash_2`` per table.

**Validates: Requirements 22.4, 22.5**
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR, _quote_args


# ---------------------------------------------------------------------------
# Strategies — mirror the P16 generator so both property tests exercise
# the same shape of fixture. Kept local to this file rather than shared
# to keep each PBT file self-contained (matches the existing conventions).
# ---------------------------------------------------------------------------
_ident_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x61, max_codepoint=0x7A,
        whitelist_categories=("Ll",),
    ),
    min_size=3, max_size=10,
)
_col_type_strategy = st.sampled_from(["INTEGER", "TEXT"])


@st.composite
def _column_strategy(draw):
    return draw(_ident_strategy), draw(_col_type_strategy)


@st.composite
def _table_strategy(draw):
    name = draw(_ident_strategy)
    raw = draw(st.lists(_column_strategy(), min_size=1, max_size=5))
    seen = set()
    columns = []
    for n, t in raw:
        if n in seen:
            continue
        seen.add(n)
        columns.append((n, t))
    if not columns:
        columns = [(draw(_ident_strategy), draw(_col_type_strategy))]

    row_count = draw(st.integers(min_value=0, max_value=20))
    rows = []
    for _ in range(row_count):
        row = []
        for _, t in columns:
            if t == "INTEGER":
                row.append(draw(st.integers(min_value=-1_000_000, max_value=1_000_000)))
            else:
                row.append(draw(st.text(
                    alphabet=st.characters(
                        min_codepoint=0x20, max_codepoint=0x7E,
                        blacklist_characters="'\"\\",
                    ),
                    min_size=0, max_size=16,
                )))
        rows.append(row)
    return {"name": name, "columns": columns, "rows": rows}


@st.composite
def _schema_strategy(draw):
    raw = draw(st.lists(_table_strategy(), min_size=1, max_size=3))
    seen = set()
    tables = []
    for t in raw:
        if t["name"] in seen:
            continue
        seen.add(t["name"])
        tables.append(t)
    if not tables:
        tables = [draw(_table_strategy())]
    return {"tables": tables, "wal": draw(st.booleans())}


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Fixture + bash-bridge helpers
# ---------------------------------------------------------------------------
def _materialise(db_path: Path, schema: dict) -> None:
    conn = sqlite3.connect(str(db_path))
    try:
        if schema["wal"]:
            conn.execute("PRAGMA journal_mode=WAL;")
        cur = conn.cursor()
        for t in schema["tables"]:
            cols_sql = ", ".join(f'"{n}" {ty}' for n, ty in t["columns"])
            cur.execute(f'CREATE TABLE "{t["name"]}" ({cols_sql})')
            if t["rows"]:
                placeholders = ", ".join(["?"] * len(t["columns"]))
                cur.executemany(
                    f'INSERT INTO "{t["name"]}" VALUES ({placeholders})',
                    t["rows"],
                )
        conn.commit()
    finally:
        conn.close()


def _bash(snippet: str, tmpdir: Path) -> str:
    """Run a snippet with a fresh MACAUDIT_TMPDIR and return stripped stdout."""
    env = os.environ.copy()
    env["MACAUDIT_TMPDIR"] = str(tmpdir)
    tmpdir.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )
    assert r.returncode == 0, f"bash failed: stderr={r.stderr!r}"
    return r.stdout.strip()


def _safe_copy_and_hash(db_path: Path, tmpdir: Path) -> tuple[str, str]:
    """Run sqlite_safe_copy + sqlite_checkpointed_hash and return both."""
    snippet = (
        f'set -e; '
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/sqlite.sh"; '
        f'copy=$(sqlite_safe_copy {_quote_args([str(db_path)])}); '
        f'printf "%s\\n" "$copy"; '
        f'sqlite_checkpointed_hash "$copy"'
    )
    out = _bash(snippet, tmpdir)
    lines = out.splitlines()
    assert len(lines) >= 2, f"expected copy + hash lines, got {out!r}"
    return lines[0], lines[1]


def _snapshot_table(
    copy_path: str, table: str, pk_csv: str, columns_csv: str, tmpdir: Path
) -> str:
    """Run sqlite_snapshot_table and return raw one-line JSON output."""
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/sqlite.sh"; '
        f'sqlite_snapshot_table {_quote_args([copy_path, table, pk_csv, columns_csv])}'
    )
    return _bash(snippet, tmpdir)


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(schema=_schema_strategy())
@_SETTINGS
def test_p17_safe_copy_and_snapshot_are_deterministic(tmp_path_factory, schema):
    """Two back-to-back safe-copy + snapshot runs agree on every hash."""
    work = Path(tmp_path_factory.mktemp("p17"))
    db_path = work / "src.db"
    tmp1 = work / "tmp1"
    tmp2 = work / "tmp2"

    _materialise(db_path, schema)

    copy1, hash1 = _safe_copy_and_hash(db_path, tmp1)
    copy2, hash2 = _safe_copy_and_hash(db_path, tmp2)

    assert hash1, "checkpointed hash 1 was empty"
    assert hash2, "checkpointed hash 2 was empty"
    assert hash1 == hash2, (
        f"sha256_checkpointed drift across back-to-back runs:\n"
        f"  run1 copy={copy1!r} hash={hash1!r}\n"
        f"  run2 copy={copy2!r} hash={hash2!r}\n"
        f"  schema={schema!r}"
    )

    # Per-table content_hash determinism. We sort by every column in the
    # table to match the "pk_csv=all columns" convention when no explicit
    # primary key exists on the generated table. The module requires
    # pk_csv be non-empty, so we pass the full column list.
    for t in schema["tables"]:
        cols_csv = ",".join(n for n, _ in t["columns"])
        pk_csv = cols_csv  # sort key = every column

        snap1 = _snapshot_table(copy1, t["name"], pk_csv, cols_csv, tmp1)
        snap2 = _snapshot_table(copy2, t["name"], pk_csv, cols_csv, tmp2)

        obj1 = json.loads(snap1)
        obj2 = json.loads(snap2)

        ch1 = obj1["content_hash"]
        ch2 = obj2["content_hash"]

        assert ch1, f"content_hash 1 was empty for table {t['name']!r}"
        assert ch1 == ch2, (
            f"content_hash drift for table {t['name']!r}:\n"
            f"  run1={ch1!r}\n"
            f"  run2={ch2!r}\n"
            f"  rows={t['rows']!r}"
        )
