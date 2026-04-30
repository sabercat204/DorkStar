"""Property P24 — suspicious well-definedness.

**Property 24**: ``delta.suspicious`` is a function of the *current*
manifest alone. For every tier ``t``, ``delta.tiers.t.suspicious`` is
exactly the set of current-state entries whose ``anomalies`` field is a
non-empty array — regardless of what the baseline contains.

Hypothesis generates an arbitrary baseline (simple and optionally empty)
plus a current manifest with 0–5 entries across tiers 1 / 2 / 3, each
carrying 0–3 anomaly objects. We drive ``audit_run`` against the pair,
parse the emitted delta JSON, and assert that for every tier the set of
paths in ``tiers.<t>.suspicious`` matches exactly the set of current-
state paths (within that tier) whose ``anomalies`` list is non-empty.

**Validates: Requirements 29.2**
"""

from __future__ import annotations

import json
import shlex
import subprocess
import textwrap
from pathlib import Path
from typing import List, Tuple

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
#
# We synthesise manifest entries as plain dicts that we serialise ourselves
# rather than going through ``manifest_build_entry``. That helper only
# accepts ``--anomalies-json`` when the SQLite- or XProtect-specific
# extension flags are set, but Property 24 is about "any current entry
# with a non-empty anomalies array becomes suspicious" — including Tier 1
# and Tier 2 entries that in practice wouldn't carry anomalies. Building
# the JSON by hand keeps the test focused on the `_audit_compute_delta`
# filter behaviour rather than on the manifest builder's validation.
#
# Paths are ASCII-safe (no quotes or backslashes) and prefixed by tier so
# the three tiers never collide.

_path_tail = st.text(
    alphabet=st.characters(
        min_codepoint=0x21, max_codepoint=0x7E,
        blacklist_characters='"\\',
    ),
    min_size=1, max_size=20,
)


def _path_strategy(tier: int):
    return _path_tail.map(lambda s, t=tier: f"/T{t}/{s}")


_anomaly = st.fixed_dictionaries(
    {
        "rule": st.sampled_from(
            ["gatekeeper_disabled", "xprotect_codesign_fail",
             "kext_user_approved_on_mdm", "authdb_missing_plugin"],
        ),
        "severity": st.sampled_from(["low", "medium", "high"]),
        "detail": st.text(
            alphabet=st.characters(
                min_codepoint=0x20, max_codepoint=0x7E,
                blacklist_characters='"\\',
            ),
            min_size=0, max_size=20,
        ),
    }
)


# Tier-specific surfaces we can plausibly tag. Tier 3 can be anything
# the spec recognises as a Tier 3 surface; the exact choice is irrelevant
# for Property 24 because only `anomalies` matters for suspicious
# classification.
_TIER_SURFACES = {
    1: "launchd_system",
    2: "preferences_system",
    3: "tcc_system",
}


@st.composite
def _entry_dict(draw, tier: int, path: str):
    """Draw a bare manifest entry dict with an arbitrary anomalies list."""
    anomalies = draw(st.lists(_anomaly, min_size=0, max_size=3))
    entry = {
        "path": path,
        "tier": tier,
        "surface": _TIER_SURFACES[tier],
        "format": "xml" if tier < 3 else "sqlite",
        "sha256_raw": "",
        "sha256_canonical": "",
        "size_bytes": None,
        "mtime": "",
        "xattrs": {},
        "content": {},
        "cfprefsd_match": None,
        "launchctl_loaded": None,
        "btm_registered": None,
        "anomalies": anomalies,
    }
    return entry


@st.composite
def _current_manifest(draw):
    """Draw 0–5 current-manifest entries spread across tiers 1 / 2 / 3."""
    # Cap at 5 so Hypothesis shrinks quickly.
    n = draw(st.integers(min_value=0, max_value=5))
    entries: List[dict] = []
    used_paths = set()
    for _ in range(n):
        tier = draw(st.integers(min_value=1, max_value=3))
        path = draw(_path_strategy(tier))
        # Avoid duplicate paths within a single manifest — the delta
        # filter path-keys entries and duplicates would violate that
        # pre-condition.
        if path in used_paths:
            continue
        used_paths.add(path)
        entries.append(draw(_entry_dict(tier, path)))
    return entries


@st.composite
def _baseline_manifest(draw):
    """Draw 0–3 baseline entries (kept small so the delta stays simple).

    Baseline entries never carry anomalies — the property under test is
    about the *current* manifest alone, so the baseline's contents should
    be irrelevant to ``delta.suspicious``. We still generate a non-trivial
    baseline sometimes so Hypothesis exercises the full classification
    pipeline (added / removed / modified) alongside suspicious detection.
    """
    n = draw(st.integers(min_value=0, max_value=3))
    entries: List[dict] = []
    used_paths = set()
    for _ in range(n):
        tier = draw(st.integers(min_value=1, max_value=3))
        path = draw(_path_strategy(tier))
        if path in used_paths:
            continue
        used_paths.add(path)
        e = {
            "path": path,
            "tier": tier,
            "surface": _TIER_SURFACES[tier],
            "format": "xml" if tier < 3 else "sqlite",
            "sha256_raw": "",
            "sha256_canonical": "",
            "size_bytes": None,
            "mtime": "",
            "xattrs": {},
            "content": {},
            "cfprefsd_match": None,
            "launchctl_loaded": None,
            "btm_registered": None,
        }
        entries.append(e)
    return entries


# ---------------------------------------------------------------------------
# Manifest serialisation
# ---------------------------------------------------------------------------

def _write_manifest_raw(path: Path, entries: List[dict]) -> None:
    """Write a minimal JSONL manifest at ``path``.

    The header is a hand-built dict that passes ``manifest_version`` /
    ``tier`` / ``user_only`` validation in ``audit_run``. Entries are
    emitted verbatim — we deliberately skip ``manifest_build_entry`` so
    Tier 1 / Tier 2 entries can carry an ``anomalies`` array.
    """
    header = {
        "manifest_version": "1.1",
        "tool": "macaudit",
        "tool_version": "0.1.0-phase1-tier3",
        "timestamp": "2026-04-28T00:00:00Z",
        "hostname": "pbt-host",
        "os_version": "14.0",
        "os_major": 14,
        "sip_status": "enabled",
        "ssv_status": "enabled",
        "tier": "all",
        "user_only": False,
        "fda_available": True,
        "environment": {},
        "skipped_paths": [],
    }
    lines = [json.dumps(header, separators=(",", ":"))]
    for e in entries:
        lines.append(json.dumps(e, separators=(",", ":")))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# audit_run invocation
# ---------------------------------------------------------------------------

def _q(s) -> str:
    return shlex.quote(str(s))


def _run_audit(baseline_path: Path, current_path: Path) -> Tuple[int, dict]:
    """Source audit.sh with a stubbed ``baseline_run`` and run it."""
    snippet = textwrap.dedent(
        f"""
        source "{LIB_DIR}/utils.sh"
        source "{LIB_DIR}/manifest.sh"
        source "{LIB_DIR}/audit.sh"

        baseline_run() {{
          local out=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --output) out="$2"; shift 2 ;;
              *)        shift 1 ;;
            esac
          done
          [ -n "$out" ] || return 1
          cp -- {_q(str(current_path))} "$out"
          printf '%s\\n' "$out"
          return 0
        }}

        audit_run {_q(str(baseline_path))}
        """
    )
    r = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False,
    )
    # rc=3 is new (suspicious + non-empty delta). 0/1/3 are all valid
    # outcomes for a well-formed manifest pair.
    if r.returncode not in (0, 1, 3):
        raise AssertionError(
            f"audit_run exited with unexpected rc={r.returncode}\n"
            f"stdout={r.stdout!r}\nstderr={r.stderr!r}"
        )
    delta = json.loads(r.stdout.strip().splitlines()[-1])
    return r.returncode, delta


# ---------------------------------------------------------------------------
# Property 24
# ---------------------------------------------------------------------------

@given(baseline=_baseline_manifest(), current=_current_manifest())
@_SETTINGS
def test_p24_suspicious_is_function_of_current_manifest(
    tmp_path_factory, baseline, current,
):
    tmp_dir = Path(tmp_path_factory.mktemp("p24"))
    b_path = tmp_dir / "baseline.jsonl"
    c_path = tmp_dir / "current.jsonl"
    _write_manifest_raw(b_path, baseline)
    _write_manifest_raw(c_path, current)

    rc, delta = _run_audit(b_path, c_path)

    # Build the ground-truth suspicious set from the current manifest
    # alone. Per Requirement 29.2: an entry is suspicious iff its
    # `anomalies` array is non-empty.
    expected_by_tier = {1: set(), 2: set(), 3: set()}
    for e in current:
        if len(e.get("anomalies") or []) > 0:
            expected_by_tier[e["tier"]].add(e["path"])

    for tier in (1, 2, 3):
        bucket = delta["tiers"][str(tier)]["suspicious"]
        observed = {item["path"] for item in bucket}
        assert observed == expected_by_tier[tier], (
            f"tier {tier}: suspicious mismatch\n"
            f"  expected: {sorted(expected_by_tier[tier])!r}\n"
            f"  observed: {sorted(observed)!r}\n"
            f"  baseline: {baseline!r}\n"
            f"  current:  {current!r}"
        )

        # Every suspicious item must carry the current entry's anomalies
        # array verbatim — the delta shouldn't re-order or mutate it.
        for item in bucket:
            matches = [e for e in current
                       if e["path"] == item["path"] and e["tier"] == tier]
            assert matches, (
                f"tier {tier}: observed suspicious path {item['path']!r} "
                f"has no matching current-state entry"
            )
            assert item["anomalies"] == matches[0]["anomalies"], (
                f"tier {tier}: anomalies for path {item['path']!r} "
                f"differ between current entry and delta output"
            )

    # Cross-check the per-tier summary counts.
    for tier in (1, 2, 3):
        assert (
            delta["summary"][f"tier{tier}"]["suspicious"]
            == len(expected_by_tier[tier])
        ), f"tier {tier}: summary.suspicious count mismatch"
    assert (
        delta["summary"]["total"]["suspicious"]
        == sum(len(v) for v in expected_by_tier.values())
    ), "summary.total.suspicious mismatch"

    # rc sanity: if any category is non-empty AND suspicious > 0, rc must
    # be 3; if any is non-empty AND suspicious == 0, rc must be 1;
    # otherwise rc must be 0. This also indirectly validates the exit
    # code 3 plumbing added in 15G.2.
    tot = delta["summary"]["total"]
    any_nonempty = any(
        tot[k] > 0
        for k in ("added", "removed", "modified", "stale",
                  "injections", "suspicious")
    )
    if not any_nonempty:
        assert rc == 0, f"empty delta but rc={rc}"
    elif tot["suspicious"] > 0:
        assert rc == 3, f"delta non-empty with suspicious>0 but rc={rc}"
    else:
        assert rc == 1, f"delta non-empty with no suspicious but rc={rc}"
