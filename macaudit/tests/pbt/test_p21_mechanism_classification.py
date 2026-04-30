"""Property P21 — Authorization mechanism classification completeness.

**Property 21**: ``sysdb_classify_mechanism`` is a total, deterministic
function. For every mechanism string it either emits exactly one of
the four tokens

    {"builtin", "system-plugin", "third-party-plugin", "missing"}

or — for malformed input (empty or no colon) — emits the empty string.
The result depends ONLY on the mechanism's prefix and the cached
plugin-directory listings. Running the classifier twice with the same
inputs yields byte-identical output.

Hypothesis generates random mechanism prefixes, two disjoint plugin
listings, and an optional suffix to form a full ``<prefix>:<name>``
mechanism. The test harness materialises the listings as fixture
directories, points the classifier at them via
``SYSTEM_PLUGIN_DIR_OVERRIDE`` and ``THIRD_PARTY_PLUGIN_DIR_OVERRIDE``,
and asserts:

  * ``builtin:*`` always yields ``builtin``, regardless of fixtures.
  * ``<p>:x`` where ``p.bundle`` is only under the system dir yields
    ``system-plugin``.
  * ``<p>:x`` where ``p.bundle`` is only under the third-party dir
    yields ``third-party-plugin``.
  * ``<p>:x`` where ``p.bundle`` exists in neither yields ``missing``.
  * ``<p>:x`` where ``p.bundle`` is in both yields ``system-plugin``
    (system precedence per the classification algorithm).
  * Determinism: two back-to-back calls with identical inputs produce
    identical outputs.

**Validates: Requirements 26.1**
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
# Prefixes are lowercase ASCII identifiers: safe for directory names,
# free of the colon that would otherwise be mis-parsed as a separator,
# and narrow enough to keep shrinking fast.
_prefix_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x61, max_codepoint=0x7A,  # a..z
        whitelist_categories=("Ll",),
    ),
    min_size=1, max_size=12,
)

_suffix_strategy = st.one_of(
    st.just(""),  # prefix-only is still a valid mechanism when combined with ":"
    st.text(
        alphabet=st.characters(
            min_codepoint=0x61, max_codepoint=0x7A,
            whitelist_categories=("Ll",),
        ),
        min_size=1, max_size=10,
    ),
)


@st.composite
def _scenario(draw):
    """Draw one (mechanism, system_plugins, third_party_plugins) scenario.

    Both listings are independent small sets of prefix strings. The
    mechanism's prefix is drawn independently so scenarios cover:
      * builtin prefix
      * prefix ∈ system only
      * prefix ∈ third-party only
      * prefix ∈ both (system precedence test)
      * prefix ∈ neither (missing)
    """
    mech_prefix = draw(st.one_of(st.just("builtin"), _prefix_strategy))
    suffix = draw(_suffix_strategy)
    system_plugins = draw(st.lists(_prefix_strategy, min_size=0, max_size=3, unique=True))
    third_party_plugins = draw(st.lists(_prefix_strategy, min_size=0, max_size=3, unique=True))
    # 20% of scenarios deliberately force the mechanism's prefix into both
    # dirs so we exercise system precedence.
    force_both = draw(st.booleans())
    if force_both and mech_prefix != "builtin":
        if mech_prefix not in system_plugins:
            system_plugins.append(mech_prefix)
        if mech_prefix not in third_party_plugins:
            third_party_plugins.append(mech_prefix)
    return {
        "mech": f"{mech_prefix}:{suffix}" if suffix else f"{mech_prefix}:x",
        "prefix": mech_prefix,
        "system": system_plugins,
        "third": third_party_plugins,
    }


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------
def _materialise_listings(root: Path, system: list[str], third: list[str]) -> tuple[Path, Path]:
    sys_dir = root / "sys"
    third_dir = root / "third"
    sys_dir.mkdir(parents=True, exist_ok=True)
    third_dir.mkdir(parents=True, exist_ok=True)
    for name in system:
        (sys_dir / f"{name}.bundle").mkdir(exist_ok=True)
    for name in third:
        (third_dir / f"{name}.bundle").mkdir(exist_ok=True)
    return sys_dir, third_dir


def _run_classify(mech: str, sys_dir: Path, third_dir: Path) -> str:
    """Invoke sysdb_classify_mechanism in a fresh bash subshell.

    We call ``sysdb_plugin_listing_reset`` before classification so the
    memoised listing for the subshell is derived from the current
    override directories rather than carried over from a prior run
    within the same Hypothesis session.
    """
    env = os.environ.copy()
    env["SYSTEM_PLUGIN_DIR_OVERRIDE"] = str(sys_dir)
    env["THIRD_PARTY_PLUGIN_DIR_OVERRIDE"] = str(third_dir)
    # Clear any inherited memo so the subshell rebuilds the listing.
    env.pop("MACAUDIT_PLUGIN_LISTING", None)

    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/sqlite.sh"; '
        f'source "{LIB_DIR}/manifest.sh"; '
        f'source "{LIB_DIR}/sysdb.sh"; '
        f'sysdb_plugin_listing_reset; '
        f'sysdb_classify_mechanism "$1"'
    )
    r = subprocess.run(
        ["bash", "-c", snippet, "bash", mech],
        capture_output=True, text=True, check=False, env=env,
    )
    assert r.returncode == 0, (
        f"sysdb_classify_mechanism failed: rc={r.returncode} "
        f"stdout={r.stdout!r} stderr={r.stderr!r}"
    )
    return r.stdout.strip()


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
_VALID = {"builtin", "system-plugin", "third-party-plugin", "missing"}


@given(scenario=_scenario())
@_SETTINGS
def test_p21_classify_totality_and_determinism(tmp_path_factory, scenario):
    """Every input lands in exactly one category, by the stated rule."""
    work = Path(tmp_path_factory.mktemp("p21"))
    sys_dir, third_dir = _materialise_listings(
        work, scenario["system"], scenario["third"]
    )
    mech = scenario["mech"]
    prefix = scenario["prefix"]

    got = _run_classify(mech, sys_dir, third_dir)

    # Totality: the output is always one of the four tokens (non-empty
    # input with a colon always classifies).
    assert got in _VALID, (
        f"classification outside valid set: {got!r} for mech={mech!r} "
        f"system={scenario['system']!r} third={scenario['third']!r}"
    )

    # Structural rule check per the design's classification algorithm.
    if prefix == "builtin":
        assert got == "builtin", (
            f"builtin prefix must classify as builtin, got {got!r} "
            f"for mech={mech!r}"
        )
    elif prefix in scenario["system"]:
        # System takes precedence over third-party regardless of
        # whether the same prefix also appears in the third-party dir.
        assert got == "system-plugin", (
            f"prefix present in system dir must classify as system-plugin, "
            f"got {got!r} for mech={mech!r} "
            f"system={scenario['system']!r} third={scenario['third']!r}"
        )
    elif prefix in scenario["third"]:
        assert got == "third-party-plugin", (
            f"prefix present only in third-party dir must classify as "
            f"third-party-plugin, got {got!r} for mech={mech!r} "
            f"third={scenario['third']!r}"
        )
    else:
        assert got == "missing", (
            f"prefix absent from both dirs must classify as missing, "
            f"got {got!r} for mech={mech!r} prefix={prefix!r} "
            f"system={scenario['system']!r} third={scenario['third']!r}"
        )

    # Determinism: a repeat classify call with the same inputs yields the
    # same output.
    again = _run_classify(mech, sys_dir, third_dir)
    assert again == got, (
        f"non-deterministic classification: first={got!r} second={again!r} "
        f"for mech={mech!r}"
    )


# ---------------------------------------------------------------------------
# Example-based edge cases: malformed input emits empty stdout.
# ---------------------------------------------------------------------------
def test_p21_empty_input_emits_empty(tmp_path_factory):
    """Empty string classifies to empty (not 'missing')."""
    work = Path(tmp_path_factory.mktemp("p21-empty"))
    sys_dir, third_dir = _materialise_listings(work, [], [])
    got = _run_classify("", sys_dir, third_dir)
    assert got == "", f"expected empty, got {got!r}"


def test_p21_no_colon_emits_empty(tmp_path_factory):
    """Input with no colon classifies to empty (malformed)."""
    work = Path(tmp_path_factory.mktemp("p21-nocolon"))
    sys_dir, third_dir = _materialise_listings(work, [], [])
    got = _run_classify("NoColonHere", sys_dir, third_dir)
    assert got == "", f"expected empty, got {got!r}"
