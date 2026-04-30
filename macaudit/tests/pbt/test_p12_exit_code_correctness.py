"""Property P12 — exit code correctness (Task 10 scope).

**Property 12 (task 10 slice)**:

  * ``exit_code == 0 ⟺ every delta category empty``
  * ``exit_code == 1 ⟺ at least one delta category non-empty``

Exit codes 2 (unrecoverable error before comparison) and 3 (suspicious
anomalies) are out of scope for task 10 — task 15G handles the
``suspicious`` category and the exit-3 semantics once Tier 3 lands.

Hypothesis generates fixture baseline and current manifests, drives
them through ``audit_run``, and asserts the process exit status
matches the disjunction of the five delta summary counters.

**Validates: Requirements 7.10, 7.11, 14.1, 14.2, 14.4**
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


def _any_category_nonempty(delta: dict) -> bool:
    tot = delta["summary"]["total"]
    return any(
        tot[k] > 0
        for k in ("added", "removed", "modified", "stale", "injections")
    )


@given(pair=manifest_pair())
@_SETTINGS
def test_p12_exit_code_agrees_with_delta_emptiness(tmp_path_factory, pair):
    baseline, current = pair
    tmp_dir = Path(tmp_path_factory.mktemp("p12"))
    b_path = tmp_dir / "baseline.jsonl"
    c_path = tmp_dir / "current.jsonl"
    write_manifest(b_path, baseline)
    write_manifest(c_path, current)

    rc, delta = run_audit(b_path, c_path)

    # rc=2 is only produced on unrecoverable errors before the compare
    # runs. Any pair manifest_pair() generates is valid, so rc must be
    # either 0 or 1.
    assert rc in (0, 1), (
        f"audit_run returned rc={rc} for valid pair — expected 0 or 1\n"
        f"pair={pair!r}"
    )

    nonempty = _any_category_nonempty(delta)
    if nonempty:
        assert rc == 1, (
            f"delta has non-empty category but audit_run exited {rc}\n"
            f"summary.total={delta['summary']['total']!r}"
        )
    else:
        assert rc == 0, (
            f"delta is entirely empty but audit_run exited {rc}\n"
            f"summary.total={delta['summary']['total']!r}"
        )
