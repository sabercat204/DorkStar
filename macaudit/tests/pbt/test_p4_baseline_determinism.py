"""Property P4 — baseline determinism.

**Property 4**: For system state ``S`` unchanged between two runs ``r1``
and ``r2``, every ``(path, sha256_canonical)`` pair is preserved across
the two runs.

Hypothesis generates a fixture tree of LaunchAgents and preference
plists under a per-test HOME, runs ``baseline_run`` twice back-to-back
with no mutation between the two runs, and asserts that the set of
``(path, sha256_canonical)`` pairs is identical across the two
manifests. Manifest JSONL line order is NOT part of the invariant —
shell globbing order is not guaranteed to be stable across runs on
every macOS release, but the set of hashes we emit must be.

**Validates: Requirements 1.7**
"""

from __future__ import annotations

import json
import os
import plistlib
import stat
import subprocess
from pathlib import Path

import hypothesis.strategies as st
from hypothesis import HealthCheck, assume, given, settings

from conftest import LIB_DIR, PROJECT_ROOT, _quote_args


# ---------------------------------------------------------------------------
# Strategies — mirror the P2/P3/P9 conventions so plutil accepts every
# generated fixture. Values stay printable ASCII and keys stay inside the
# launch-key / security-key allow-lists.
# ---------------------------------------------------------------------------
_label_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x61, max_codepoint=0x7A,  # a..z
        whitelist_categories=("Ll", "Lu", "Nd"),
    ),
    min_size=3, max_size=20,
)
_agent_name_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x61, max_codepoint=0x7A,
        whitelist_categories=("Ll", "Lu", "Nd"),
    ),
    min_size=3, max_size=20,
)
_int_strategy = st.integers(min_value=0, max_value=1000)


@st.composite
def _launch_agent(draw):
    return {
        "name": draw(_agent_name_strategy),
        "Label": "com.example." + draw(_label_strategy),
        "RunAtLoad": draw(st.booleans()),
        "KeepAlive": draw(st.booleans()),
        "ProgramArguments": ["/usr/bin/true"],
    }


@st.composite
def _preference_plist(draw):
    # Safari keys are a simple single-domain case — the security-key
    # allow-list has three Boolean fields. We mix in a no-op extra field
    # per run to exercise the determinism property under content the
    # manifest intentionally drops.
    extra_text = draw(st.text(
        alphabet=st.characters(min_codepoint=0x20, max_codepoint=0x7E),
        min_size=0, max_size=5,
    ))
    return {
        "name": "com.apple.Safari",
        "AutoFillPasswords": draw(st.booleans()),
        "AutoOpenSafeDownloads": draw(st.booleans()),
        "WarnAboutFraudulentWebsites": draw(st.booleans()),
        "IgnoredExtraKey": extra_text,
    }


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------
def _make_fixture_home(work: Path, agents: list, prefs: list) -> Path:
    home = work / "home"
    (home / "Library" / "LaunchAgents").mkdir(parents=True, exist_ok=True)
    (home / "Library" / "Preferences").mkdir(parents=True, exist_ok=True)

    used_agent_names = set()
    for a in agents:
        n = a["name"]
        # Guarantee unique filenames so one test run doesn't clobber a
        # previous agent's bytes.
        while n in used_agent_names:
            n += "_"
        used_agent_names.add(n)
        path = home / "Library" / "LaunchAgents" / f"{n}.plist"
        path.write_bytes(plistlib.dumps(
            {k: v for k, v in a.items() if k != "name"},
            fmt=plistlib.FMT_XML,
        ))

    used_pref_names = set()
    for p in prefs:
        n = p["name"]
        while n in used_pref_names:
            n += "_"
        used_pref_names.add(n)
        path = home / "Library" / "Preferences" / f"{n}.plist"
        path.write_bytes(plistlib.dumps(
            {k: v for k, v in p.items() if k != "name"},
            fmt=plistlib.FMT_XML,
        ))

    return home


def _install_shims(bin_dir: Path) -> None:
    """PATH-shim launchctl, defaults, and sfltool to emit empty output.

    Without these the tester's real macOS state would seep into the
    manifest and determinism would still hold (both runs see the same
    live state), but we stay defensive: identical empty shim output
    makes the determinism assertion independent of whatever happens to
    be running on the test machine.
    """
    bin_dir.mkdir(parents=True, exist_ok=True)
    for tool in ("launchctl", "defaults", "sfltool"):
        shim = bin_dir / tool
        shim.write_text(
            "#!/bin/bash\n"
            "exit 0\n"
        )
        shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _run_baseline(home: Path, bin_dir: Path, out_path: Path) -> None:
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH','')}"
    # Force a fresh MACAUDIT_TMPDIR per invocation so the second run
    # cannot inherit scratch files from the first.
    env.pop("MACAUDIT_TMPDIR", None)

    snippet = (
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/surfaces.sh"; '
        f'source "{LIB_DIR}/manifest.sh"; '
        f'source "{LIB_DIR}/persistence.sh"; '
        f'source "{LIB_DIR}/cfprefsd.sh"; '
        f'source "{LIB_DIR}/baseline.sh"; '
        f'baseline_run --tier all --user-only --output {_quote_args([str(out_path)])}'
    )
    r = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )
    assert r.returncode == 0, (
        f"baseline_run failed: stdout={r.stdout!r} stderr={r.stderr!r}"
    )


def _extract_pairs(manifest_path: Path) -> set[tuple[str, str]]:
    """Return the set of ``(path, sha256_canonical)`` pairs in a manifest."""
    pairs: set[tuple[str, str]] = set()
    with manifest_path.open("r", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if i == 0:
                continue  # header
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            pairs.add((obj["path"], obj["sha256_canonical"]))
    return pairs


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(
    agents=st.lists(_launch_agent(), min_size=0, max_size=3),
    prefs=st.lists(_preference_plist(), min_size=0, max_size=2),
)
@_SETTINGS
def test_p4_back_to_back_baseline_preserves_path_hash_pairs(
    tmp_path_factory, agents, prefs
):
    """Two back-to-back baselines on the same fixture tree produce the same
    ``(path, sha256_canonical)`` pair set."""
    work = Path(tmp_path_factory.mktemp("p4"))
    home = _make_fixture_home(work, agents, prefs)
    bin_dir = work / "bin"
    _install_shims(bin_dir)

    out1 = work / "r1.jsonl"
    out2 = work / "r2.jsonl"
    _run_baseline(home, bin_dir, out1)
    _run_baseline(home, bin_dir, out2)

    pairs1 = _extract_pairs(out1)
    pairs2 = _extract_pairs(out2)

    # The determinism invariant: the set of (path, sha256_canonical)
    # pairs must be identical. Line order, entry ordering within the
    # JSONL file, and mtime fields are NOT part of the invariant — only
    # the pair set.
    assert pairs1 == pairs2, (
        f"baseline determinism violated:\n"
        f"  only in r1: {pairs1 - pairs2}\n"
        f"  only in r2: {pairs2 - pairs1}\n"
        f"  agents={agents!r}\n"
        f"  prefs={prefs!r}"
    )
