"""Property P5 — delta partition disjointness.

**Property 5**: Within a single tier, ``added ∩ removed = ∅``,
``added ∩ modified = ∅``, and ``removed ∩ modified = ∅``.

Hypothesis generates pairs of baseline / current manifests whose
path sets may overlap, diverge, or fully coincide. For every run we
parse the emitted delta JSON, extract the set of paths that landed
in each of ``added``, ``removed``, ``modified`` per tier, and assert
the three pairwise intersections are empty.

**Validates: Requirements 7.8**
"""

from __future__ import annotations

from pathlib import Path

from hypothesis import HealthCheck, given, settings

from _audit_helpers import manifest_pair, run_audit, write_manifest


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


def _paths(items):
    """Extract the ``path`` field from a list of delta bucket objects."""
    return {item["path"] for item in items}


@given(pair=manifest_pair())
@_SETTINGS
def test_p5_delta_partition_disjoint(tmp_path_factory, pair):
    baseline, current = pair
    tmp_dir = Path(tmp_path_factory.mktemp("p5"))
    b_path = tmp_dir / "baseline.jsonl"
    c_path = tmp_dir / "current.jsonl"
    write_manifest(b_path, baseline)
    write_manifest(c_path, current)

    rc, delta = run_audit(b_path, c_path)
    # rc must be 0 or 1 — rc=2 would indicate a driver failure and is
    # out of scope for P5.
    assert rc in (0, 1), f"audit_run returned rc={rc} for pair={pair!r}"

    for tier in ("1", "2"):
        bucket = delta["tiers"][tier]
        added = _paths(bucket["added"])
        removed = _paths(bucket["removed"])
        modified = _paths(bucket["modified"])

        assert added.isdisjoint(removed), (
            f"tier {tier}: added ∩ removed = {sorted(added & removed)!r}\n"
            f"baseline={baseline!r}\ncurrent={current!r}"
        )
        assert added.isdisjoint(modified), (
            f"tier {tier}: added ∩ modified = {sorted(added & modified)!r}\n"
            f"baseline={baseline!r}\ncurrent={current!r}"
        )
        assert removed.isdisjoint(modified), (
            f"tier {tier}: removed ∩ modified = {sorted(removed & modified)!r}\n"
            f"baseline={baseline!r}\ncurrent={current!r}"
        )
