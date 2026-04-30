"""Property P11 — graceful degradation.

**Property 11**: For every permission set ``π`` the tool either
produces a manifest with ``skipped_paths`` recording every inaccessible
path or exits with code 2 — never silently omits data.

Hypothesis generates a fixture tree of ``N`` plists under a per-test
HOME and then chmods a random subset of them to ``000`` to simulate
permission-denied reads. We run ``baseline_run`` and assert, for every
fixture path, that either

  * the path appears as an entry in the manifest, OR
  * the path appears in ``header.skipped_paths``, OR
  * the tool exited with code 2.

No path may be silently omitted.

**Validates: Requirements 13.1, 13.2**
"""

from __future__ import annotations

import json
import os
import plistlib
import stat
import subprocess
from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR, _quote_args


# ---------------------------------------------------------------------------
# Strategies — plist count plus a mask of which plists to make unreadable.
# We deliberately keep the count small (≤ 5) so each example runs in a
# second or two; the property is linear in count and Hypothesis's
# shrinking finds minimal failures anyway.
# ---------------------------------------------------------------------------
_N = st.integers(min_value=1, max_value=5)


def _SETTINGS():
    return settings(
        max_examples=5,
        deadline=None,
        suppress_health_check=[
            HealthCheck.too_slow,
            HealthCheck.function_scoped_fixture,
        ],
    )


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------
def _build_fixture(home: Path, count: int) -> list[Path]:
    """Create ``count`` LaunchAgent plists under ``home``.

    Returns the absolute paths of the created plists in deterministic
    order so the caller can mask a stable subset.
    """
    la_dir = home / "Library" / "LaunchAgents"
    la_dir.mkdir(parents=True, exist_ok=True)
    created: list[Path] = []
    for i in range(count):
        path = la_dir / f"com.example.p11_{i:02d}.plist"
        path.write_bytes(plistlib.dumps(
            {
                "Label": f"com.example.p11_{i:02d}",
                "RunAtLoad": True,
                "ProgramArguments": ["/usr/bin/true"],
            },
            fmt=plistlib.FMT_XML,
        ))
        created.append(path)
    return created


def _install_shims(bin_dir: Path) -> None:
    bin_dir.mkdir(parents=True, exist_ok=True)
    for tool in ("launchctl", "defaults", "sfltool"):
        shim = bin_dir / tool
        shim.write_text(
            "#!/bin/bash\n"
            "exit 0\n"
        )
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _run_baseline(home: Path, bin_dir: Path, out_path: Path) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH','')}"
    env.pop("MACAUDIT_TMPDIR", None)
    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/surfaces.sh"; '
        f'source "{LIB_DIR}/manifest.sh"; '
        f'source "{LIB_DIR}/persistence.sh"; '
        f'source "{LIB_DIR}/cfprefsd.sh"; '
        f'source "{LIB_DIR}/baseline.sh"; '
        f'baseline_run --tier 1 --user-only --output {_quote_args([str(out_path)])}'
    )
    return subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )


def _manifest_paths(manifest_path: Path) -> tuple[set[str], set[str]]:
    """Return ``(entry_paths, skipped_paths)`` from a manifest."""
    entries: set[str] = set()
    skipped: set[str] = set()
    if not manifest_path.exists():
        return entries, skipped
    with manifest_path.open("r", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if i == 0:
                for sp in obj.get("skipped_paths", []) or []:
                    skipped.add(sp["path"])
                continue
            entries.add(obj["path"])
    return entries, skipped


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(data=st.data(), count=_N)
@_SETTINGS()
def test_p11_every_fixture_path_is_accounted_for(tmp_path_factory, data, count):
    """For every fixture plist, the tool either emits an entry, records a
    skip, or exits with code 2 — never silently drops the path."""
    work = Path(tmp_path_factory.mktemp("p11"))
    home = work / "home"
    home.mkdir(parents=True, exist_ok=True)
    bin_dir = work / "bin"
    _install_shims(bin_dir)

    created = _build_fixture(home, count)

    # Draw a random subset to chmod 000. ``booleans()`` over a length-N
    # index list is easier to shrink than a subset strategy.
    mask = data.draw(st.lists(st.booleans(), min_size=count, max_size=count))
    masked: list[Path] = []
    for path, drop in zip(created, mask):
        if drop:
            os.chmod(path, 0)
            masked.append(path)

    try:
        out_path = work / "baseline.jsonl"
        proc = _run_baseline(home, bin_dir, out_path)

        # Code 2 is a legitimate graceful-degradation outcome — the
        # library surfaced a hard error and refused to produce a
        # partial manifest. The invariant permits this.
        if proc.returncode == 2:
            return
        assert proc.returncode == 0, (
            f"baseline_run returned {proc.returncode}: "
            f"stdout={proc.stdout!r} stderr={proc.stderr!r}"
        )

        entries, skipped = _manifest_paths(out_path)

        # For each fixture path, either it landed in entries or in
        # skipped_paths.
        for path in created:
            sp = str(path)
            accounted = (sp in entries) or (sp in skipped)
            assert accounted, (
                f"fixture path silently omitted: {sp}\n"
                f"  entries: {sorted(entries)}\n"
                f"  skipped: {sorted(skipped)}\n"
                f"  masked: {[str(p) for p in masked]}\n"
            )
    finally:
        # Restore perms so tmp_path_factory can clean up the test dir.
        for path in masked:
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
