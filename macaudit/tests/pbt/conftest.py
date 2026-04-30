"""Shared fixtures and helpers for the hypothesis / pytest property tests.

All macaudit bash primitives are exercised by spawning a bash subshell that
sources ``lib/utils.sh`` (and, when needed, ``lib/manifest.sh``) and invokes
the requested function. We deliberately use ``check=False`` in
``subprocess.run`` so tests can assert on non-zero exit codes for the
validation-failure paths in manifest.sh.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest


# -------------------------------------------------------------------------
# Path resolution
# -------------------------------------------------------------------------
_THIS = Path(__file__).resolve()
PROJECT_ROOT: Path = _THIS.parent.parent.parent  # .../macaudit
LIB_DIR: Path = PROJECT_ROOT / "lib"


# -------------------------------------------------------------------------
# Subprocess helpers
# -------------------------------------------------------------------------
def _run_bash(snippet: str, *, env: dict | None = None) -> subprocess.CompletedProcess:
    """Run ``bash -c snippet`` and return the completed process."""
    cmd_env = os.environ.copy()
    if env:
        cmd_env.update(env)
    return subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True,
        text=True,
        check=False,
        env=cmd_env,
    )


def _quote_args(args) -> str:
    """Quote a list of arguments for safe inclusion in a bash -c snippet."""
    out = []
    for a in args:
        s = str(a)
        # Single-quote wrap, escaping any single quotes inside.
        out.append("'" + s.replace("'", "'\\''") + "'")
    return " ".join(out)


def run_utils(func: str, *args, env: dict | None = None) -> subprocess.CompletedProcess:
    """Source lib/utils.sh and invoke ``func`` with the supplied args.

    Returns the ``CompletedProcess`` so callers can inspect stdout/stderr/rc.
    """
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'{func} {_quote_args(args)}'
    )
    return _run_bash(snippet, env=env)


def run_manifest(func: str, *args, env: dict | None = None) -> subprocess.CompletedProcess:
    """Source lib/utils.sh + lib/manifest.sh and invoke ``func``."""
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/manifest.sh"; '
        f'{func} {_quote_args(args)}'
    )
    return _run_bash(snippet, env=env)


def run_persistence(func: str, *args, env: dict | None = None) -> subprocess.CompletedProcess:
    """Source lib/utils.sh + lib/persistence.sh and invoke ``func``.

    Used by the persistence property tests (P7, P8) to drive
    ``persistence_detect_injections`` against tmp-file inputs that
    Hypothesis constructs. Mirrors the ``run_manifest`` helper exactly —
    same subshell-with-sourced-libs pattern, same ``check=False`` so
    callers can inspect non-zero exit codes if they need to.
    """
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/persistence.sh"; '
        f'{func} {_quote_args(args)}'
    )
    return _run_bash(snippet, env=env)


def sha256_of_file(path: Path) -> str:
    """Invoke ``utils_sha256_file`` via bash and return the hex digest."""
    r = run_utils("utils_sha256_file", str(path))
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def canonical_json_of_plist(path: Path) -> str:
    """Invoke ``utils_plist_to_canonical_json`` via bash and return the JSON."""
    r = run_utils("utils_plist_to_canonical_json", str(path))
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def sha256_of_stdin(data: bytes) -> str:
    """Pipe ``data`` into ``utils_sha256_stdin`` and return the hex digest."""
    snippet = f'source "{LIB_DIR}/utils.sh"; utils_sha256_stdin'
    p = subprocess.run(
        ["bash", "-c", snippet],
        input=data,
        capture_output=True,
        check=False,
    )
    assert p.returncode == 0, p.stderr
    return p.stdout.decode().strip()


# -------------------------------------------------------------------------
# Pytest fixtures
# -------------------------------------------------------------------------
@pytest.fixture
def tmp_fixture_dir(tmp_path):
    """Return a dedicated tmp directory for per-test fixtures."""
    d = tmp_path / "macaudit-pbt"
    d.mkdir(parents=True, exist_ok=True)
    return d


@pytest.fixture
def write_plist_roundtrip(tmp_fixture_dir):
    """Return a helper that writes a dict as {binary, xml, json} plists.

    Usage::

        xml_path, bin_path, json_path = write_plist_roundtrip(my_dict, name="p")

    All three files contain the same semantic plist; only their on-disk
    encoding differs. The JSON representation is produced via
    ``plutil -convert json`` so it mirrors the code path that
    ``utils_plist_to_canonical_json`` exercises.
    """
    import plistlib

    def _write(obj: dict, *, name: str = "p"):
        xml_path = tmp_fixture_dir / f"{name}.xml.plist"
        bin_path = tmp_fixture_dir / f"{name}.bin.plist"
        json_path = tmp_fixture_dir / f"{name}.json.plist"

        xml_bytes = plistlib.dumps(obj, fmt=plistlib.FMT_XML)
        bin_bytes = plistlib.dumps(obj, fmt=plistlib.FMT_BINARY)

        xml_path.write_bytes(xml_bytes)
        bin_path.write_bytes(bin_bytes)
        # Produce JSON form via plutil so we exercise the same converter.
        r = subprocess.run(
            ["plutil", "-convert", "json", "-o", str(json_path), str(xml_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if r.returncode != 0:
            pytest.skip(f"plutil refused input dict: {r.stderr.strip()}")
        return xml_path, bin_path, json_path

    return _write
