"""Shared helpers for the audit-delta property tests (P5, P6, P12).

All three tests drive the same pipeline:

1. Generate a pair of ``(baseline_entries, current_entries)`` lists
   whose entries are plausible Tier 1 / Tier 2 manifest records.
2. Serialise each list as a JSONL manifest (header + one entry per line)
   using ``manifest_build_header`` + ``manifest_build_entry``.
3. Invoke ``audit_run`` with the baseline path and a test-controlled
   shim for ``baseline_run`` that simply copies the synthetic "current"
   manifest into the expected ``${MACAUDIT_TMPDIR}/current.jsonl``
   location. This means the tests never hit the tester's real macOS
   state.
4. Parse the emitted delta JSON and expose it to the caller so the
   property-specific assertions can run against it.

Entries are generated with no duplicate paths within either list — the
manifest schema is path-keyed and duplicate paths within a single
manifest would violate pre-conditions the delta code assumes. Across
baseline and current, paths are free to overlap or be disjoint so the
four delta buckets (added / removed / modified / unchanged) all see
action.
"""

from __future__ import annotations

import json
import shlex
import subprocess
import textwrap
from pathlib import Path
from typing import List, Tuple

import hypothesis.strategies as st

from conftest import LIB_DIR, PROJECT_ROOT


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

# Paths: restricted to printable ASCII minus the chars that would confuse
# the bash command-line or jq (double quote and backslash). We also
# prepend a root prefix so paths are uniformly absolute.
_path_tail = st.text(
    alphabet=st.characters(
        min_codepoint=0x21, max_codepoint=0x7E,
        blacklist_characters='"\\',
    ),
    min_size=1, max_size=30,
)


def _path_strategy(prefix: str):
    return _path_tail.map(lambda s: f"{prefix}/{s}")


_hex = st.text(alphabet="0123456789abcdef", min_size=0, max_size=16)

_tri_bool = st.sampled_from(["true", "false", "null"])


@st.composite
def _tier1_entry(draw, path: str):
    """Build the flag dict for a Tier 1 manifest_build_entry invocation."""
    return {
        "tier": 1,
        "path": path,
        "surface": "launchd_system",
        "format": "xml",
        "sha256_raw": draw(_hex),
        "sha256_canonical": draw(_hex),
        "content": draw(
            st.sampled_from(['{}', '{"Label":"a"}', '{"Label":"b"}'])
        ),
        "cfprefsd_match": "null",
        "launchctl_loaded": draw(_tri_bool),
        "btm_registered": draw(_tri_bool),
        "surface_is_injection": False,
    }


@st.composite
def _tier2_entry(draw, path: str):
    return {
        "tier": 2,
        "path": path,
        "surface": "preferences_system",
        "format": "xml",
        "sha256_raw": draw(_hex),
        "sha256_canonical": draw(_hex),
        "content": draw(
            st.sampled_from(['{}', '{"x":1}', '{"x":2}'])
        ),
        "cfprefsd_match": draw(_tri_bool),
        "launchctl_loaded": "null",
        "btm_registered": "null",
        "surface_is_injection": False,
    }


@st.composite
def _injection_entry(draw, label: str):
    """Build the flag dict for a synthetic injection entry."""
    return {
        "tier": 1,
        "path": f"launchctl://{label}",
        "surface": "injection",
        "format": "n/a",
        "sha256_raw": "",
        "sha256_canonical": "",
        "content": json.dumps(
            {"label": label, "pid": draw(st.integers(0, 999999)), "status": 0}
        ),
        "cfprefsd_match": "null",
        "launchctl_loaded": "true",
        "btm_registered": "null",
        "surface_is_injection": True,
    }


@st.composite
def manifest_pair(draw):
    """Draw ``(baseline_entries, current_entries)``.

    We first draw a shared path pool of up to ``N`` Tier 1 / Tier 2
    paths, then independently pick a subset for each of the two
    manifests. Where a path appears in both, we draw independent
    entry bodies so the delta buckets are exercised naturally.
    Optional injection entries are sprinkled into the current manifest
    only (they have no matching baseline counterpart by convention).
    """
    # Small caps so Hypothesis shrinks quickly.
    tier1_paths = draw(
        st.lists(_path_strategy("/T1"), min_size=0, max_size=4,
                 unique=True)
    )
    tier2_paths = draw(
        st.lists(_path_strategy("/T2"), min_size=0, max_size=4,
                 unique=True)
    )
    all_paths = tier1_paths + tier2_paths

    def _pick(paths):
        # Pick which of the shared paths appears in this manifest.
        return [p for p in paths if draw(st.booleans())]

    b_paths = _pick(all_paths)
    c_paths = _pick(all_paths)

    def _entry_for(path):
        if path in tier1_paths:
            return draw(_tier1_entry(path))
        return draw(_tier2_entry(path))

    baseline = [_entry_for(p) for p in b_paths]
    current = [_entry_for(p) for p in c_paths]

    # Sprinkle at most 2 injections into current only. The injection
    # paths use the `launchctl://` pseudo-namespace so they never
    # collide with real Tier 1/2 paths.
    injection_labels = draw(
        st.lists(
            st.text(alphabet="abcdef0123456789", min_size=1, max_size=10),
            min_size=0, max_size=2, unique=True,
        )
    )
    for lbl in injection_labels:
        current.append(draw(_injection_entry(lbl)))

    return baseline, current


# ---------------------------------------------------------------------------
# Manifest serialisation
# ---------------------------------------------------------------------------

def _q(s) -> str:
    """Shell-quote a single argument."""
    return shlex.quote(str(s))


def _build_entry_snippet(entry: dict) -> str:
    """Return a bash command that appends one entry to a manifest file.

    The caller builds the header line first and then feeds each snippet
    into a `while` loop that shares the target path variable.
    """
    args = [
        "--path", _q(entry["path"]),
        "--tier", _q(entry["tier"]),
        "--surface", _q(entry["surface"]),
        "--format", _q(entry["format"]),
        "--sha256-raw", _q(entry["sha256_raw"]),
        "--sha256-canonical", _q(entry["sha256_canonical"]),
        "--content-json", _q(entry["content"]),
        "--cfprefsd-match", _q(entry["cfprefsd_match"]),
        "--launchctl-loaded", _q(entry["launchctl_loaded"]),
        "--btm-registered", _q(entry["btm_registered"]),
    ]
    return "manifest_build_entry " + " ".join(args)


def write_manifest(path: Path, entries: List[dict]) -> None:
    """Materialise a JSONL manifest at ``path`` containing ``entries``."""
    # Build the header.
    snippet = textwrap.dedent(
        f"""
        source "{LIB_DIR}/utils.sh"
        source "{LIB_DIR}/manifest.sh"
        hdr=$(manifest_build_header --tier all --user-only false) || exit 2
        manifest_write_header {_q(str(path))} "$hdr" || exit 2
        """
    )
    for e in entries:
        snippet += (
            f'entry=$({_build_entry_snippet(e)}) || exit 2\n'
            f'manifest_write_entry {_q(str(path))} "$entry" || exit 2\n'
        )
    r = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False,
    )
    if r.returncode != 0:
        raise AssertionError(
            f"failed to materialise manifest at {path}:\n"
            f"stdout={r.stdout!r}\nstderr={r.stderr!r}"
        )


# ---------------------------------------------------------------------------
# audit_run invocation
# ---------------------------------------------------------------------------

def run_audit(baseline_path: Path, current_path: Path) -> Tuple[int, dict]:
    """Source lib/audit.sh, stub baseline_run, call audit_run, return (rc, delta).

    The shim for ``baseline_run`` reads whatever ``--output`` path the
    audit caller requested and copies the synthetic current manifest
    into it. This exactly matches the contract ``audit_run`` expects
    from the real ``baseline_run``: write a JSONL manifest to the
    requested path and exit 0.
    """
    # The shim needs to be defined BEFORE we source lib/audit.sh, because
    # the sourcing would otherwise bring in the real baseline_run from
    # lib/baseline.sh (we deliberately do NOT source that file). Since
    # lib/audit.sh itself does not source baseline.sh, we can source the
    # minimal set (utils + manifest + audit) and then supply our own
    # baseline_run directly.
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
    if r.returncode not in (0, 1, 2):
        raise AssertionError(
            f"audit_run exited with unexpected rc={r.returncode}\n"
            f"stdout={r.stdout!r}\nstderr={r.stderr!r}"
        )
    # For rc=0/1 we expect a JSON document on stdout. rc=2 is an error
    # path and the caller decides how to interpret it.
    delta = {}
    if r.returncode in (0, 1) and r.stdout.strip():
        try:
            delta = json.loads(r.stdout.strip().splitlines()[-1])
        except json.JSONDecodeError as exc:
            raise AssertionError(
                f"audit_run emitted non-JSON stdout (rc={r.returncode}):\n"
                f"stdout={r.stdout!r}\nstderr={r.stderr!r}"
            ) from exc
    return r.returncode, delta


def paths_in(entries: List[dict], tier: int) -> set:
    """Return the set of paths in ``entries`` with the requested tier.

    Injection entries are counted for tier 1 since they carry tier=1,
    surface=injection. Other tests may need to further-filter by surface.
    """
    return {e["path"] for e in entries if e["tier"] == tier}


def non_injection_paths_in(entries: List[dict], tier: int) -> set:
    """Return the set of tier-matched paths excluding injection entries."""
    return {
        e["path"]
        for e in entries
        if e["tier"] == tier and not e.get("surface_is_injection", False)
    }
