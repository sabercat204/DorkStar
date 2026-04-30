"""Property P14 — tier partitioning.

**Property 14**: For every entry ``e``:
  * ``e.tier`` is one of ``{1, 2, 3}``,
  * ``e.surface`` belongs to the surface set for that tier, and
  * every Tier 1 / Tier 2 path that ``surfaces_tier_of`` classifies agrees
    with the emitted ``tier``.

The test also asserts ``manifest_build_entry`` REJECTS invalid combinations
(tier out of range, surface empty). We do not currently validate the
``(tier, surface)`` pair itself in the library (that is a caller concern),
so we only enforce the documented tier/surface set when the caller supplies
a known combination.

**Validates: Requirements 11.7**
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import hypothesis
import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR, run_manifest, run_utils


# ---------------------------------------------------------------------------
# Surface catalogue — mirrors the sets in lib/surfaces.sh
# ---------------------------------------------------------------------------
SURFACES_BY_TIER = {
    1: [
        "launchd_system", "launchd_user", "cron", "periodic",
        "login_hooks", "authplugin", "emond",
    ],
    2: [
        "preferences_system", "preferences_user", "preferences_managed",
    ],
    3: [
        "tcc_system", "tcc_user", "kextpolicy", "execpolicy",
        "systempolicy", "quarantine_events", "xprotect", "authdb",
        "correlation",
    ],
}

# Representative on-disk paths per Tier 1 / Tier 2 surface. Used to confirm
# surfaces_tier_of agrees with the emitted `tier`.
TIER1_PATHS = [
    "/Library/LaunchDaemons/com.foo.plist",
    "/Library/LaunchAgents/com.bar.plist",
    "/Users/tester/Library/LaunchAgents/com.baz.plist",
    "/etc/periodic/daily/0001.sample",
    "/etc/periodic/weekly/0002.sample",
    "/Library/Security/SecurityAgentPlugins/foo.bundle",
    "/etc/emond.d/rules/rule.plist",
    "/var/at/tabs/tester",
]
TIER2_PATHS = [
    "/Library/Preferences/com.foo.plist",
    "/Library/Managed Preferences/com.bar.plist",
    "/Users/tester/Library/Preferences/com.baz.plist",
]


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Invalid-tier rejection
# ---------------------------------------------------------------------------
@given(tier=st.integers(min_value=4, max_value=99))
@_SETTINGS
def test_p14_rejects_tier_out_of_range(tier: int):
    """Tiers outside {1, 2, 3} must be rejected with non-zero exit."""
    r = run_manifest(
        "manifest_build_entry",
        "--path", "/x", "--tier", str(tier), "--surface", "s",
        "--format", "xml", "--sha256-raw", "a", "--sha256-canonical", "b",
    )
    assert r.returncode != 0, (
        f"manifest_build_entry unexpectedly accepted tier={tier}: stdout={r.stdout!r}"
    )


# ---------------------------------------------------------------------------
# Empty surface rejection
# ---------------------------------------------------------------------------
@given(tier=st.sampled_from([1, 2, 3]))
@_SETTINGS
def test_p14_rejects_empty_surface(tier: int):
    """An empty surface must be rejected."""
    r = run_manifest(
        "manifest_build_entry",
        "--path", "/x", "--tier", str(tier), "--surface", "",
        "--format", "xml", "--sha256-raw", "a", "--sha256-canonical", "b",
    )
    assert r.returncode != 0, (
        f"manifest_build_entry unexpectedly accepted empty surface at tier={tier}"
    )


# ---------------------------------------------------------------------------
# Valid (tier, surface) pairs produce entries with matching tier + surface
# ---------------------------------------------------------------------------
@st.composite
def _valid_tier_surface(draw):
    tier = draw(st.sampled_from([1, 2, 3]))
    surface = draw(st.sampled_from(SURFACES_BY_TIER[tier]))
    return tier, surface


@given(ts=_valid_tier_surface())
@_SETTINGS
def test_p14_valid_pairs_round_trip_tier_and_surface(ts):
    """Every valid (tier, surface) pair yields an entry whose fields match."""
    tier, surface = ts
    # Tier 3 requires either an explicit --format or a surface with a known
    # default (sqlite/bundle/authdb/n/a). The defaults cover every surface
    # in SURFACES_BY_TIER[3], so we can omit --format for tier 3.
    args = [
        "--path", "/synthetic",
        "--tier", str(tier),
        "--surface", surface,
        "--sha256-raw", "a",
        "--sha256-canonical", "b",
    ]
    if tier != 3:
        args.extend(["--format", "xml"])

    r = run_manifest("manifest_build_entry", *args)
    assert r.returncode == 0, (
        f"manifest_build_entry rejected (tier={tier}, surface={surface}): {r.stderr}"
    )
    obj = json.loads(r.stdout.strip())
    assert obj["tier"] == tier
    assert obj["surface"] == surface
    # Tier is a JSON number in the manifest schema.
    assert isinstance(obj["tier"], int)


# ---------------------------------------------------------------------------
# surfaces_tier_of agrees with the emitted tier for every representative path
# ---------------------------------------------------------------------------
def _surfaces_tier_of(path: str) -> str:
    """Invoke surfaces_tier_of in a bash that sources lib/utils.sh + surfaces.sh."""
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/surfaces.sh"; '
        f'surfaces_tier_of "$1"'
    )
    r = subprocess.run(
        ["bash", "-c", snippet, "_", path],
        capture_output=True, text=True, check=False,
    )
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


@given(path=st.sampled_from(TIER1_PATHS))
@_SETTINGS
def test_p14_tier1_paths_classify_as_1(path):
    assert _surfaces_tier_of(path) == "1", f"expected tier=1 for {path}"


@given(path=st.sampled_from(TIER2_PATHS))
@_SETTINGS
def test_p14_tier2_paths_classify_as_2(path):
    assert _surfaces_tier_of(path) == "2", f"expected tier=2 for {path}"


# ---------------------------------------------------------------------------
# Totality: unrecognised paths produce empty stdout (no spurious tier)
# ---------------------------------------------------------------------------
@given(
    suffix=st.text(
        alphabet=st.characters(
            min_codepoint=0x41, max_codepoint=0x7A,
            whitelist_categories=("Ll", "Lu", "Nd"),
        ),
        min_size=1, max_size=30,
    ),
)
@_SETTINGS
def test_p14_unknown_paths_are_unclassified(suffix: str):
    """Paths that match none of the documented prefixes produce empty output."""
    path = f"/tmp/unknown-{suffix}"
    assert _surfaces_tier_of(path) == "", f"expected empty classification for {path}"
