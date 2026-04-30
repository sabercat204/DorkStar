"""Property P8 — injection completeness.

**Property 8**: ``ℓ ∈ launchctl ∧ ℓ ∉ on_disk ⟹ ℓ ∈ injections(on_disk, launchctl)``.

Hypothesis generates two sets of labels, writes each to a tmp file,
invokes ``persistence_detect_injections``, and asserts every label in
the Python-computed set difference ``launchctl - on_disk`` appears in
the function's output. This is the completeness half of the injection
definition — no real injection is silently dropped.

**Validates: Requirements 4.4**
"""

from __future__ import annotations

from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import run_persistence


# ---------------------------------------------------------------------------
# Strategies — identical shape to P7 so soundness and completeness are
# exercised over the same input distribution. Any divergence between
# `persistence_detect_injections` and the Python ground truth has to
# show up in either P7 or P8 (usually both).
# ---------------------------------------------------------------------------
_label_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x21, max_codepoint=0x7E,
        blacklist_characters='\n\t',
    ),
    min_size=1, max_size=40,
)
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
    """Write ``labels`` one-per-line to ``path`` (sorted for reproducibility)."""
    path.write_text("".join(f"{l}\n" for l in sorted(labels)))


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(on_disk=_label_set, launchctl=_label_set)
@_SETTINGS
def test_p8_every_launchctl_only_label_is_reported(
    tmp_path_factory, on_disk: set[str], launchctl: set[str]
):
    """Every label in ``launchctl - on_disk`` must appear in the output."""
    tmp_dir = tmp_path_factory.mktemp("p8")
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
    expected = launchctl - on_disk

    # Completeness: every label in the Python set difference is reported.
    missing = expected - reported
    assert not missing, (
        f"persistence_detect_injections missed injection labels: {sorted(missing)} "
        f"(on_disk={sorted(on_disk)}, launchctl={sorted(launchctl)}, "
        f"reported={sorted(reported)})"
    )
