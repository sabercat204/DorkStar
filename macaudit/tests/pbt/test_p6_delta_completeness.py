"""Property P6 — delta completeness.

**Property 6**: Every path in ``baseline_paths ∪ current_paths`` appears
in exactly one of ``{added, removed, modified, unchanged}`` per tier.

``unchanged`` is not emitted in the delta JSON — it is implicit. For
the property we derive it as ``(baseline ∩ current) \\ modified``.

Hypothesis generates baseline/current manifest pairs with overlapping
and disjoint path sets. For every path that belongs to a given tier
in either manifest we verify:

  * the path lands in exactly one of the four buckets, and
  * the bucket assignment agrees with the tier's baseline/current
    membership (e.g. a path in both manifests cannot appear as
    ``added`` even if the entry bodies differ).

Injection entries are excluded from the completeness check: they live
under a synthetic ``launchctl://`` path that exists only in the
current manifest and are specifically reported in the ``injections``
bucket, not in added/removed/modified/unchanged.

**Validates: Requirements 7.2, 7.3, 7.4, 7.5**
"""

from __future__ import annotations

from pathlib import Path

from hypothesis import HealthCheck, given, settings

from _audit_helpers import (
    manifest_pair,
    run_audit,
    write_manifest,
)


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


def _paths(items):
    return {item["path"] for item in items}


@given(pair=manifest_pair())
@_SETTINGS
def test_p6_delta_completeness(tmp_path_factory, pair):
    baseline, current = pair
    tmp_dir = Path(tmp_path_factory.mktemp("p6"))
    b_path = tmp_dir / "baseline.jsonl"
    c_path = tmp_dir / "current.jsonl"
    write_manifest(b_path, baseline)
    write_manifest(c_path, current)

    rc, delta = run_audit(b_path, c_path)
    assert rc in (0, 1), f"audit_run returned rc={rc} for pair={pair!r}"

    for tier_num, tier_key in ((1, "1"), (2, "2")):
        # Include every tier-N path, including injection entries —
        # the design places injection paths in both `added` and
        # `injections`, so the completeness check's universe must
        # include them to match the emitted `added` bucket.
        baseline_paths = {
            e["path"] for e in baseline if e["tier"] == tier_num
        }
        current_paths = {
            e["path"] for e in current if e["tier"] == tier_num
        }
        universe = baseline_paths | current_paths

        bucket = delta["tiers"][tier_key]
        added = _paths(bucket["added"])
        removed = _paths(bucket["removed"])
        modified = _paths(bucket["modified"])

        # unchanged is derived: paths in both manifests that are not
        # modified.
        in_both = baseline_paths & current_paths
        unchanged = in_both - modified

        # (1) Coverage — every path in the union lands somewhere.
        classified = added | removed | modified | unchanged
        missing = universe - classified
        assert not missing, (
            f"tier {tier_num}: {sorted(missing)!r} not classified\n"
            f"universe={sorted(universe)!r}\n"
            f"added={sorted(added)!r} removed={sorted(removed)!r} "
            f"modified={sorted(modified)!r} unchanged={sorted(unchanged)!r}"
        )

        # (2) Exclusivity — each path appears in exactly one bucket.
        pairs = [
            ("added", added),
            ("removed", removed),
            ("modified", modified),
            ("unchanged", unchanged),
        ]
        for i, (na, a) in enumerate(pairs):
            for nb, b in pairs[i + 1 :]:
                assert a.isdisjoint(b), (
                    f"tier {tier_num}: {na} ∩ {nb} = "
                    f"{sorted(a & b)!r}"
                )

        # (3) Semantic agreement — added paths are only in current,
        #     removed paths are only in baseline, modified+unchanged
        #     paths are in both.
        assert added <= (current_paths - baseline_paths), (
            f"tier {tier_num}: added leaks paths not exclusive to current"
        )
        assert removed <= (baseline_paths - current_paths), (
            f"tier {tier_num}: removed leaks paths not exclusive to baseline"
        )
        assert modified <= in_both, (
            f"tier {tier_num}: modified contains a path that is not in both manifests"
        )
        assert unchanged <= in_both, (
            f"tier {tier_num}: unchanged (derived) contains a path that is not in both manifests"
        )

        # (4) Buckets do not report paths from the other tier. We
        #     sanity-check by ensuring every classified path belongs
        #     to the universe for this tier.
        leaked = classified - universe
        assert not leaked, (
            f"tier {tier_num}: paths classified but outside tier universe: "
            f"{sorted(leaked)!r}"
        )
