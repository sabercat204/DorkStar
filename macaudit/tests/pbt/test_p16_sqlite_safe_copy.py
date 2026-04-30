"""Property P16 — SQLite safe-copy soundness.

**Property 16**: For every SQLite source database ``S`` captured by
``sqlite_safe_copy``, the byte contents of ``S.db``, ``S.db-wal`` and
``S.db-shm`` are identical before and after the call.

Hypothesis generates random schemas (1-3 tables, 1-5 INTEGER/TEXT
columns each, 0-20 rows per table) and materialises them via Python's
``sqlite3`` stdlib. For each example the test:

  1. Builds the fixture database, optionally in WAL mode (drawn as a
     boolean so we exercise both the rollback-journal and WAL code
     paths).
  2. SHA-256 hashes the source ``.db``, ``.db-wal`` (when present) and
     ``.db-shm`` (when present) BEFORE the safe-copy call.
  3. Runs ``sqlite_safe_copy`` via a bash subshell that sources
     ``lib/utils.sh`` + ``lib/sqlite.sh``. The call writes only into
     ``MACAUDIT_TMPDIR``; originals are never opened for writing.
  4. SHA-256 hashes the same three source files AFTER the call.
  5. Asserts every present-before hash equals the present-after hash.

**Validates: Requirements 12.5, 23.7**
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import subprocess
from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR, _quote_args


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
_ident_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x61, max_codepoint=0x7A,  # a..z
        whitelist_categories=("Ll",),
    ),
    min_size=3, max_size=10,
)

_col_type_strategy = st.sampled_from(["INTEGER", "TEXT"])


@st.composite
def _column_strategy(draw):
    """One column spec: ``(name, type)``."""
    return draw(_ident_strategy), draw(_col_type_strategy)


@st.composite
def _table_strategy(draw):
    """One table spec: ``{name, columns, rows}``.

    ``columns`` is a list of ``(name, type)`` with unique names. Row
    values match the declared types and stay inside ranges Python's
    sqlite3 can serialise without loss.
    """
    name = draw(_ident_strategy)
    # 1..5 columns with unique names.
    raw = draw(st.lists(_column_strategy(), min_size=1, max_size=5))
    seen = set()
    columns = []
    for n, t in raw:
        if n in seen:
            continue
        seen.add(n)
        columns.append((n, t))
    # Guarantee at least one column after deduplication.
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
    """One fixture schema: 1..3 uniquely-named tables and a WAL toggle."""
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
# Fixture + hashing helpers
# ---------------------------------------------------------------------------
def _materialise(db_path: Path, schema: dict) -> None:
    """Create the fixture database from the generated schema."""
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


def _sha256(path: Path) -> str | None:
    """Hash a file. Return ``None`` if the file does not exist."""
    if not path.exists():
        return None
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _run_safe_copy(db_path: Path, tmpdir: Path) -> str:
    """Invoke ``sqlite_safe_copy`` in a fresh bash subshell."""
    env = os.environ.copy()
    env["MACAUDIT_TMPDIR"] = str(tmpdir)
    tmpdir.mkdir(parents=True, exist_ok=True)

    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/sqlite.sh"; '
        f'sqlite_safe_copy {_quote_args([str(db_path)])}'
    )
    r = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )
    assert r.returncode == 0, f"sqlite_safe_copy failed: {r.stderr!r}"
    return r.stdout.strip()


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(schema=_schema_strategy())
@_SETTINGS
def test_p16_safe_copy_preserves_originals(tmp_path_factory, schema):
    """Originals .db / .db-wal / .db-shm are byte-identical before/after
    sqlite_safe_copy."""
    work = Path(tmp_path_factory.mktemp("p16"))
    db_path = work / "src.db"
    wal_path = work / "src.db-wal"
    shm_path = work / "src.db-shm"
    tmpdir = work / "tmp"

    _materialise(db_path, schema)

    pre_db = _sha256(db_path)
    pre_wal = _sha256(wal_path)
    pre_shm = _sha256(shm_path)

    # The main db MUST exist — everything else is optional depending on
    # whether the WAL has been checkpointed between open() and this
    # line.
    assert pre_db is not None, "fixture .db missing"

    copy = _run_safe_copy(db_path, tmpdir)
    assert copy, "sqlite_safe_copy returned empty stdout"
    assert Path(copy).is_file(), f"safe-copy path {copy!r} does not exist"
    assert Path(copy) != db_path, "safe-copy aliased the source file"

    post_db = _sha256(db_path)
    post_wal = _sha256(wal_path)
    post_shm = _sha256(shm_path)

    assert post_db == pre_db, (
        f".db changed across safe-copy: pre={pre_db!r} post={post_db!r} "
        f"schema={schema!r}"
    )
    # For the sidecars we assert presence-preservation AND hash
    # preservation. If the WAL/SHM didn't exist before, it must not
    # have been materialised afterwards by the copy either (sqlite
    # does not spawn sidecars on a read of an already-checkpointed
    # DB, but we check defensively).
    assert post_wal == pre_wal, (
        f".db-wal changed across safe-copy: pre={pre_wal!r} post={post_wal!r} "
        f"schema={schema!r}"
    )
    assert post_shm == pre_shm, (
        f".db-shm changed across safe-copy: pre={pre_shm!r} post={post_shm!r} "
        f"schema={schema!r}"
    )
