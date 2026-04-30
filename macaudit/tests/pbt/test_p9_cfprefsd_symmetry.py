"""Property P9 — cfprefsd symmetry.

**Property 9**: ``cfprefsd_match(d) = true ⟺ sha256_canonical(disk(d)) =
sha256_canonical(live(d))`` when both hashes are defined.

Hypothesis generates random preference-safe dicts, writes each one to disk
as an XML plist, installs a PATH-shim ``defaults`` that emits either the
same dict (predicts ``true``), a semantically-mutated variant (predicts
``false``), or empty output (predicts ``null``). We then invoke
``cfprefsd_cross_reference`` and assert the JSON ``match`` field agrees
with the prediction.

**Validates: Requirements 6.2, 6.3, 6.6**
"""

from __future__ import annotations

import copy
import json
import os
import plistlib
import stat
import subprocess
from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, assume, given, settings

from conftest import LIB_DIR, PROJECT_ROOT, _quote_args


# ---------------------------------------------------------------------------
# Strategies — mirror P2 / P3 (printable ASCII keys, bounded scalars) so
# plutil accepts every generated payload.
# ---------------------------------------------------------------------------
_safe_key = st.text(
    alphabet=st.characters(
        min_codepoint=0x30, max_codepoint=0x7A,
        whitelist_categories=("Ll", "Lu", "Nd"),
    ),
    min_size=1,
    max_size=12,
)
_printable_text = st.text(
    alphabet=st.characters(min_codepoint=0x20, max_codepoint=0x7E),
    min_size=0,
    max_size=32,
)
_safe_scalar = st.one_of(
    st.booleans(),
    st.integers(min_value=-(2**31), max_value=2**31 - 1),
    _printable_text,
)


def _safe_dict_strategy():
    return st.dictionaries(
        keys=_safe_key,
        values=st.one_of(_safe_scalar, st.lists(_safe_scalar, max_size=4)),
        min_size=1,  # at least one key so mutation strategies have something to work with
        max_size=5,
    )


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _install_defaults_shim(shim_dir: Path, body: bytes, rc: int = 0) -> None:
    """Write ``<shim_dir>/defaults`` as a bash script that emits ``body``.

    The body is written to a sibling file and ``cat``-ed by the shim so
    arbitrary bytes (XML, whitespace, empty) pass through without
    shell-escaping concerns.
    """
    shim_dir.mkdir(parents=True, exist_ok=True)
    body_file = shim_dir / "shim_body.bin"
    body_file.write_bytes(body)
    shim = shim_dir / "defaults"
    shim.write_text(
        "#!/bin/bash\n"
        f'cat "{body_file}"\n'
        f"exit {rc}\n"
    )
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def run_cfprefsd(func: str, *args, shim_dir: Path) -> subprocess.CompletedProcess:
    """Source utils.sh + cfprefsd.sh, PATH-prepend ``shim_dir``, invoke ``func``."""
    env = os.environ.copy()
    env["PATH"] = f"{shim_dir}{os.pathsep}{env.get('PATH', '')}"
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/cfprefsd.sh"; '
        f'{func} {_quote_args(args)}'
    )
    return subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def _disk_canonical_hash(plist_path: Path, shim_dir: Path) -> str:
    """Compute the disk canonical hash via the same pipeline the code uses.

    Uses a direct pipe ``utils_plist_to_canonical_json | utils_sha256_stdin``
    — not ``$(...)`` + ``printf '%s'`` — so jq's trailing newline is
    preserved, matching what ``cfprefsd_live_canonical`` computes
    internally. Any variation here re-introduces the disk/live drift
    this module exists to prevent.
    """
    env = os.environ.copy()
    env["PATH"] = f"{shim_dir}{os.pathsep}{env.get('PATH', '')}"
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'utils_plist_to_canonical_json "{plist_path}" | utils_sha256_stdin'
    )
    r = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def _mutate(payload: dict) -> dict:
    """Produce a semantically-different dict. Several mutation kinds."""
    mutated = copy.deepcopy(payload)
    # Prefer changing an existing value; fall back to adding a sentinel key
    # if the value change would no-op (e.g. payload is empty, which
    # _safe_dict_strategy forbids, but belt and braces).
    if mutated:
        k = next(iter(mutated))
        v = mutated[k]
        if isinstance(v, bool):
            mutated[k] = not v
        elif isinstance(v, int):
            mutated[k] = v + 1
        elif isinstance(v, str):
            mutated[k] = v + "_macaudit_mut"
        elif isinstance(v, list):
            mutated[k] = v + ["macaudit_mut"]
        else:
            mutated[k] = "macaudit_mut"
    else:
        mutated["__macaudit_mut__"] = "mut"
    return mutated


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(
    payload=_safe_dict_strategy(),
    mode=st.sampled_from(["identical", "mutated", "empty"]),
)
@_SETTINGS
def test_p9_cfprefsd_symmetry(tmp_path_factory, payload, mode):
    """cfprefsd_cross_reference match field agrees with the canonical-hash relation."""
    work = Path(tmp_path_factory.mktemp("p9"))
    shim_dir = work / "bin"
    shim_dir.mkdir(parents=True, exist_ok=True)

    # Write the disk-side plist. The path must be under
    # /Library/Preferences/... so cfprefsd_domain_from_path resolves the
    # domain. We build a fake absolute path whose *filename* controls the
    # domain (cross-reference never reads the disk file — the caller
    # already passed its hash) while keeping the real disk file under
    # tmp_path for canonical hashing.
    disk_file = work / "com.example.p9.plist"
    try:
        disk_file.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML))
    except Exception:
        # plistlib rejects e.g. certain key shapes — skip this example.
        assume(False)

    disk_hash = _disk_canonical_hash(disk_file, shim_dir)
    assert disk_hash, f"disk canonical hash must be non-empty for payload={payload!r}"

    # Build the shim body according to the mode under test.
    predicted: str  # "true" | "false" | "null"
    if mode == "identical":
        shim_body = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
        predicted = "true"
    elif mode == "mutated":
        mutated = _mutate(payload)
        # Reject degenerate mutations that happen to canonicalise the same.
        assume(json.dumps(mutated, sort_keys=True) != json.dumps(payload, sort_keys=True))
        try:
            shim_body = plistlib.dumps(mutated, fmt=plistlib.FMT_XML)
        except Exception:
            assume(False)
        predicted = "false"
    else:  # mode == "empty"
        shim_body = b""
        predicted = "null"

    _install_defaults_shim(shim_dir, shim_body, rc=0)

    pref_path = "/Library/Preferences/com.example.p9.plist"
    r = run_cfprefsd(
        "cfprefsd_cross_reference", pref_path, disk_hash,
        shim_dir=shim_dir,
    )
    assert r.returncode == 0, (r.stdout, r.stderr)
    out = r.stdout.strip()
    assert out, f"cfprefsd_cross_reference emitted no output (stderr={r.stderr!r})"
    obj = json.loads(out)
    assert set(obj.keys()) == {"match", "live"}, obj

    match = obj["match"]
    live = obj["live"]

    if predicted == "true":
        assert match is True, (
            f"expected match=true for identical payload; got match={match!r} "
            f"disk={disk_hash} live={live} payload={payload!r}"
        )
        # Both hashes defined and equal — P9's forward direction.
        assert live == disk_hash
    elif predicted == "false":
        assert match is False, (
            f"expected match=false for mutated payload; got match={match!r} "
            f"disk={disk_hash} live={live} payload={payload!r}"
        )
        assert live and live != disk_hash
    else:  # null
        assert match is None, (
            f"expected match=null for empty shim; got match={match!r}"
        )
        assert live == ""


# ---------------------------------------------------------------------------
# Explicit invariant: match is true ⟺ disk hash equals live hash
# ---------------------------------------------------------------------------
@given(payload=_safe_dict_strategy())
@_SETTINGS
def test_p9_biconditional(tmp_path_factory, payload):
    """Exhaustively check both directions of the biconditional on a single payload.

    For the same payload we run the cross-reference against (a) an
    identical shim body and (b) a mutated shim body. We then assert the
    pair ``(match_a == true, disk_hash == live_hash_a)`` agree, and the
    pair ``(match_b == false, disk_hash != live_hash_b)`` agree.
    """
    work = Path(tmp_path_factory.mktemp("p9bi"))
    shim_dir = work / "bin"
    shim_dir.mkdir(parents=True, exist_ok=True)

    disk_file = work / "com.example.p9.plist"
    try:
        disk_file.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML))
    except Exception:
        assume(False)
    disk_hash = _disk_canonical_hash(disk_file, shim_dir)
    assert disk_hash

    # (a) identical
    _install_defaults_shim(
        shim_dir, plistlib.dumps(payload, fmt=plistlib.FMT_XML), rc=0,
    )
    r_a = run_cfprefsd(
        "cfprefsd_cross_reference",
        "/Library/Preferences/com.example.p9.plist", disk_hash,
        shim_dir=shim_dir,
    )
    obj_a = json.loads(r_a.stdout.strip())
    # Biconditional: match==true ⟺ disk==live
    assert (obj_a["match"] is True) == (obj_a["live"] == disk_hash)

    # (b) mutated
    mutated = _mutate(payload)
    assume(json.dumps(mutated, sort_keys=True) != json.dumps(payload, sort_keys=True))
    try:
        mutated_bytes = plistlib.dumps(mutated, fmt=plistlib.FMT_XML)
    except Exception:
        assume(False)
    _install_defaults_shim(shim_dir, mutated_bytes, rc=0)
    r_b = run_cfprefsd(
        "cfprefsd_cross_reference",
        "/Library/Preferences/com.example.p9.plist", disk_hash,
        shim_dir=shim_dir,
    )
    obj_b = json.loads(r_b.stdout.strip())
    # With both hashes defined but unequal, match must be false.
    assert obj_b["live"]  # live side succeeded
    assert (obj_b["match"] is True) == (obj_b["live"] == disk_hash)
    # And specifically, since they differ, match must be false here.
    assert obj_b["match"] is False
