"""Property P7 — injection soundness.

**Property 7**: ``ℓ ∈ injections(on_disk, launchctl) ⟹ ℓ ∈ launchctl ∧ ℓ ∉ on_disk``.

Hypothesis generates two sets of labels, writes each to a tmp file (one
label per line), invokes ``persistence_detect_injections``, and asserts
every label the function emits is a member of the launchctl set AND is
NOT a member of the on-disk set. This is the soundness half of the
injection definition — whatever we report as an injection really is a
launchctl-only label.

**Validates: Requirements 4.5**
"""

from __future__ import annotations

from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import run_persistence


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
# Labels are printable ASCII excluding newline and tab (the newline would
# break the one-label-per-line input format; the tab would collide with
# the TSV schema downstream). Length 1..40 covers realistic launchd
# labels (e.g. `com.apple.coreservices.useractivityd.launchservices`) and
# plenty of synthetic variations without blowing up sort/comm runtime.
_label_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x21, max_codepoint=0x7E,
        blacklist_characters='\n\t',
    ),
    min_size=1, max_size=40,
)

# Bound the set sizes so each example runs in well under a second — the
# per-example work is O(n log n) on the input lines via sort+comm. The
# hypothesis budget of 20 examples keeps the whole file under ~10s.
_label_set = st.sets(_label_strategy, min_size=0, max_size=20)


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _write_labels(path: Path, labels: set[str]) -> None:
    """Write ``labels`` one-per-line to ``path``.

    Order is not meaningful to ``persistence_detect_injections`` (it
    sorts its inputs internally), but we iterate via ``sorted`` for
    reproducibility when debugging a failing example.
    """
    path.write_text("".join(f"{l}\n" for l in sorted(labels)))


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(on_disk=_label_set, launchctl=_label_set)
@_SETTINGS
def test_p7_every_reported_injection_is_launchctl_only(
    tmp_path_factory, on_disk: set[str], launchctl: set[str]
):
    """Every label in the output must be in launchctl and not on disk."""
    tmp_dir = tmp_path_factory.mktemp("p7")
    on_disk_path = Path(tmp_dir) / "on_disk.txt"
    launchctl_path = Path(tmp_dir) / "launchctl.txt"
    _write_labels(on_disk_path, on_disk)
    _write_labels(launchctl_path, launchctl)

    r = run_persistence(
        "persistence_detect_injections",
        str(on_disk_path),
        str(launchctl_path),
    )
    assert r.returncode == 0, (
        f"persistence_detect_injections failed: stderr={r.stderr!r}"
    )

    reported = {line for line in r.stdout.splitlines() if line}

    # Soundness: every reported injection is launchctl-only.
    for label in reported:
        assert label in launchctl, (
            f"reported injection {label!r} is not in the launchctl set "
            f"(on_disk={sorted(on_disk)}, launchctl={sorted(launchctl)}, "
            f"reported={sorted(reported)})"
        )
        assert label not in on_disk, (
            f"reported injection {label!r} is ALSO on disk — disjointness "
            f"violated (on_disk={sorted(on_disk)}, "
            f"launchctl={sorted(launchctl)}, reported={sorted(reported)})"
        )
