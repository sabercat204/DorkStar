"""Property P3 — canonical-hash semantic sensitivity.

**Property 3**: ``sha256_canonical(p) != sha256_canonical(mu(p))`` for any
semantic mutation ``mu`` drawn from ``{add_key, remove_key, change_value}``.

We generate a base dict, build a mutated variant, serialise both as XML
plists (to keep plutil happy), canonicalise both via
``utils_plist_to_canonical_json``, hash via ``utils_sha256_stdin``, and
assert the hashes differ. When the mutation would yield the same dict we
reject the example via ``hypothesis.assume``.

**Validates: Requirements 2.5**
"""

from __future__ import annotations

import copy
import plistlib
from pathlib import Path

import hypothesis
import hypothesis.strategies as st
from hypothesis import HealthCheck, assume, given, settings

from conftest import canonical_json_of_plist, sha256_of_stdin


# ---------------------------------------------------------------------------
# Strategies — mirror the P2 safe-dict strategy (printable keys, bounded
# scalars) so plutil accepts every generated payload.
# ---------------------------------------------------------------------------
_safe_key = st.text(
    alphabet=st.characters(min_codepoint=0x30, max_codepoint=0x7A,
                           whitelist_categories=("Ll", "Lu", "Nd")),
    min_size=1,
    max_size=12,
)
# Restrict value strings to printable ASCII. Control characters (< 0x20)
# are rejected by plistlib XML encoding, and non-ASCII would complicate
# plutil's JSON canonicalisation. This keeps the property focused on
# semantic sensitivity rather than encoding edge cases.
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
        min_size=1,  # require at least one key so remove/change work
        max_size=5,
    )


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


def _canonical_hash(path: Path) -> str:
    canon = canonical_json_of_plist(path)
    assert canon, "canonical JSON must be non-empty"
    return sha256_of_stdin(canon.encode())


def _write_xml_plist(payload, tmp_dir: Path, name: str) -> Path:
    p = tmp_dir / f"{name}.xml.plist"
    p.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML))
    return p


# ---------------------------------------------------------------------------
# add_key mutation
# ---------------------------------------------------------------------------
@given(
    base=_safe_dict_strategy(),
    new_key=_safe_key,
    new_value=_safe_scalar,
)
@_SETTINGS
def test_p3_add_key_changes_canonical_hash(tmp_path_factory, base, new_key, new_value):
    """Adding a new key to the dict must change the canonical hash."""
    assume(new_key not in base)
    mutated = copy.deepcopy(base)
    mutated[new_key] = new_value

    tmp_dir = Path(tmp_path_factory.mktemp("p3-add"))
    before = _canonical_hash(_write_xml_plist(base, tmp_dir, "before"))
    after = _canonical_hash(_write_xml_plist(mutated, tmp_dir, "after"))
    assert before != after, (
        f"canonical hash unchanged after add_key({new_key!r}={new_value!r}) "
        f"on base={base!r}"
    )


# ---------------------------------------------------------------------------
# remove_key mutation
# ---------------------------------------------------------------------------
@given(
    base=_safe_dict_strategy(),
    which_idx=st.integers(min_value=0, max_value=1000),
)
@_SETTINGS
def test_p3_remove_key_changes_canonical_hash(tmp_path_factory, base, which_idx):
    """Removing any key from a non-empty dict must change the canonical hash."""
    assume(len(base) >= 1)
    keys = list(base.keys())
    target = keys[which_idx % len(keys)]
    mutated = copy.deepcopy(base)
    del mutated[target]

    tmp_dir = Path(tmp_path_factory.mktemp("p3-rem"))
    before = _canonical_hash(_write_xml_plist(base, tmp_dir, "before"))
    after = _canonical_hash(_write_xml_plist(mutated, tmp_dir, "after"))
    assert before != after, (
        f"canonical hash unchanged after remove_key({target!r}) on base={base!r}"
    )


# ---------------------------------------------------------------------------
# change_value mutation
# ---------------------------------------------------------------------------
@given(
    base=_safe_dict_strategy(),
    which_idx=st.integers(min_value=0, max_value=1000),
    new_value=_safe_scalar,
)
@_SETTINGS
def test_p3_change_value_changes_canonical_hash(
    tmp_path_factory, base, which_idx, new_value
):
    """Replacing any key's value with a distinctly-different value must change the hash."""
    assume(len(base) >= 1)
    keys = list(base.keys())
    target = keys[which_idx % len(keys)]
    assume(base[target] != new_value)

    mutated = copy.deepcopy(base)
    mutated[target] = new_value

    tmp_dir = Path(tmp_path_factory.mktemp("p3-chg"))
    before = _canonical_hash(_write_xml_plist(base, tmp_dir, "before"))
    after = _canonical_hash(_write_xml_plist(mutated, tmp_dir, "after"))
    assert before != after, (
        f"canonical hash unchanged after change_value({target!r}) "
        f"from {base[target]!r} to {new_value!r}"
    )
