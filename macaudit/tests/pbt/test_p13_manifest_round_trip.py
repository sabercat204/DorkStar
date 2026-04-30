"""Property P13 — manifest round-trip.

**Property 13**: ``parse(serialize(m)) == m`` — a manifest written via
``manifest_write_header`` + ``manifest_write_entry`` and then read back via
``manifest_header`` + ``manifest_entries`` parses to the same structural
value.

We generate a header + list of entries, call the bash serialisers to build
each line, write the JSONL file, then read it back and assert:
  * the header line parses to the same object we built, and
  * each entry line parses to the same object we built.

Structural equality is via ``jq -S`` (sort keys recursively) on both sides.

**Validates: Requirements 11.12**
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import hypothesis
import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR, run_manifest


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
_surface_by_tier = {
    1: ["launchd_system", "launchd_user", "cron", "periodic", "login_hooks",
        "authplugin", "emond"],
    2: ["preferences_system", "preferences_user", "preferences_managed"],
}

# Restrict to tiers 1 and 2 — Tier 3 entries have richer schema the generator
# would need to mirror exactly. Task 4.4 targets the round-trip for the
# base entry schema.
_tier_strategy = st.sampled_from([1, 2])

_path_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x21, max_codepoint=0x7E,
        blacklist_characters='"\\',
    ),
    min_size=1, max_size=40,
).map(lambda s: f"/{s}")

_hex_strategy = st.text(alphabet="0123456789abcdef", min_size=0, max_size=64)

_tri_bool = st.sampled_from(["true", "false", "null"])


@st.composite
def _entry_strategy(draw):
    """Generate a set of flags for manifest_build_entry."""
    tier = draw(_tier_strategy)
    surface = draw(st.sampled_from(_surface_by_tier[tier]))
    return {
        "path": draw(_path_strategy),
        "tier": tier,
        "surface": surface,
        "format": draw(st.sampled_from(["binary", "xml", "json", "invalid"])),
        "sha256_raw": draw(_hex_strategy),
        "sha256_canonical": draw(_hex_strategy),
        "size": draw(st.integers(min_value=0, max_value=1_000_000)),
        "mtime": "2026-04-27T10:00:00Z",
        "cfprefsd_match": draw(_tri_bool),
        "launchctl_loaded": draw(_tri_bool),
        "btm_registered": draw(_tri_bool),
    }


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


def _build_entry(flags: dict) -> str:
    r = run_manifest(
        "manifest_build_entry",
        "--path", flags["path"],
        "--tier", flags["tier"],
        "--surface", flags["surface"],
        "--format", flags["format"],
        "--sha256-raw", flags["sha256_raw"],
        "--sha256-canonical", flags["sha256_canonical"],
        "--size", flags["size"],
        "--mtime", flags["mtime"],
        "--cfprefsd-match", flags["cfprefsd_match"],
        "--launchctl-loaded", flags["launchctl_loaded"],
        "--btm-registered", flags["btm_registered"],
    )
    assert r.returncode == 0, f"manifest_build_entry rejected {flags!r}: {r.stderr}"
    return r.stdout.strip()


def _canonicalise(json_line: str) -> str:
    """Sort keys recursively via jq -S so comparison ignores key order."""
    r = subprocess.run(
        ["jq", "-Sc", "."],
        input=json_line,
        capture_output=True,
        text=True,
        check=False,
    )
    assert r.returncode == 0, f"jq -S rejected: {json_line!r}\n{r.stderr}"
    return r.stdout.strip()


@given(entries=st.lists(_entry_strategy(), min_size=0, max_size=5))
@_SETTINGS
def test_p13_manifest_round_trip(tmp_path_factory, entries):
    """Writing then reading a manifest yields structurally-identical lines."""
    tmp_dir = Path(tmp_path_factory.mktemp("p13"))
    out = tmp_dir / "m.jsonl"

    # Build the header.
    r = run_manifest(
        "manifest_build_header",
        "--tier", "all",
        "--user-only", "false",
    )
    assert r.returncode == 0, r.stderr
    header_json = r.stdout.strip()

    # Build each entry.
    entry_jsons = [_build_entry(e) for e in entries]

    # Write the manifest.
    r = run_manifest("manifest_write_header", str(out), header_json)
    assert r.returncode == 0, r.stderr
    for e in entry_jsons:
        r = run_manifest("manifest_write_entry", str(out), e)
        assert r.returncode == 0, r.stderr

    # Read the manifest back.
    r = run_manifest("manifest_header", str(out))
    assert r.returncode == 0, r.stderr
    read_header = r.stdout.strip()

    r = run_manifest("manifest_entries", str(out))
    assert r.returncode == 0, r.stderr
    read_entries = [l for l in r.stdout.splitlines() if l.strip()]

    # Structural equality on the header.
    assert _canonicalise(header_json) == _canonicalise(read_header), (
        f"header round-trip failed:\n"
        f"  wrote: {header_json!r}\n"
        f"  read : {read_header!r}"
    )

    # Structural equality on each entry, preserving order.
    assert len(read_entries) == len(entry_jsons), (
        f"entry count mismatch: wrote {len(entry_jsons)}, read {len(read_entries)}"
    )
    for i, (w, r_line) in enumerate(zip(entry_jsons, read_entries)):
        assert _canonicalise(w) == _canonicalise(r_line), (
            f"entry {i} round-trip failed:\n"
            f"  wrote: {w!r}\n"
            f"  read : {r_line!r}"
        )
