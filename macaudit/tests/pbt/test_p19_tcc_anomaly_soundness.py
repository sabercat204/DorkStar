"""Property P19 — TCC anomaly soundness.

**Property 19**: Every anomaly object emitted by ``tcc_detect_anomalies``
corresponds to at least one row in the input access-table array that
satisfies the anomaly rule's preconditions. No rule ever fires
"spuriously" on a row that does not match its predicate.

The four rules (Requirement 25) and their predicates:

  * ``tcc_override_policy``     — ``row.auth_reason == 7``.
  * ``tcc_av_unusual_reason``   — ``row.service ∈ {camera, mic}``
                                   AND ``row.auth_reason != 2``.
  * ``tcc_fda_unsigned``        — ``row.service == FDA_SERVICE``
                                   AND ``row.client_type == 1``
                                   AND ``codesign(row.client).valid == false``.
  * ``tcc_mdm_without_profile`` — ``row.auth_reason == 6``
                                   AND ``row.client NOT IN pppc_list``.

Hypothesis drives a codesign shim (a PATH-prepended fake ``codesign``
script) so we can fully predict which FDA clients count as "unsigned"
during each example — otherwise ``tcc_fda_unsigned`` would be
non-deterministic under the property tests.

**Validates: Requirements 25.5**
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path

import hypothesis.strategies as st
import pytest
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR


# ---------------------------------------------------------------------------
# Fixed service identifiers (mirror lib/tcc.sh).
# ---------------------------------------------------------------------------
FDA_SERVICE = "kTCCServiceSystemPolicyAllFiles"
CAMERA_SERVICE = "kTCCServiceCamera"
MIC_SERVICE = "kTCCServiceMicrophone"

# Pool of services used by the generator. Includes both the "sensitive"
# services (camera/mic/fda) and a mix of benign ones so the rule
# predicates see a realistic variety.
_SERVICE_POOL = [
    FDA_SERVICE,
    CAMERA_SERVICE,
    MIC_SERVICE,
    "kTCCServiceAddressBook",
    "kTCCServicePhotos",
    "kTCCServiceAppleEvents",
    "kTCCServiceReminders",
]

# auth_reason pool spans the interesting values: 2 (user consent),
# 6 (MDM policy-set), 7 (override policy) plus a few neutral ones.
_AUTH_REASON_POOL = [1, 2, 3, 4, 5, 6, 7, 8]


# ---------------------------------------------------------------------------
# Codesign shim
# ---------------------------------------------------------------------------
# The shim is a minimal bash script that returns 0 for paths NOT listed in
# an "unsigned" file and returns 1 with a canned stderr line for paths that
# ARE listed. Installing the shim under a per-test directory, prepended to
# PATH, makes the codesign outcome fully deterministic.
_CODESIGN_SHIM = r"""#!/bin/bash
# Fake codesign for PBT — reads the unsigned-paths list from
# $MACAUDIT_PBT_UNSIGNED_FILE and returns 1 when the target matches.
target=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *)  target="$arg" ;;
  esac
done
if [ -z "$target" ]; then
  exit 0
fi
if [ -n "${MACAUDIT_PBT_UNSIGNED_FILE:-}" ] \
    && [ -r "${MACAUDIT_PBT_UNSIGNED_FILE}" ] \
    && grep -Fxq -- "$target" "${MACAUDIT_PBT_UNSIGNED_FILE}"; then
  printf 'fake-codesign: %s: code object is not signed at all\n' "$target" 1>&2
  exit 1
fi
exit 0
"""


def _install_codesign_shim(tmp_path: Path, unsigned_paths: list[str]) -> tuple[Path, Path]:
    """Drop a fake ``codesign`` under ``tmp_path/bin`` and write the unsigned list.

    Returns ``(bin_dir, unsigned_file)``.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    shim = bin_dir / "codesign"
    shim.write_text(_CODESIGN_SHIM)
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    unsigned_file = tmp_path / "unsigned.txt"
    unsigned_file.write_text("\n".join(unsigned_paths) + ("\n" if unsigned_paths else ""))
    return bin_dir, unsigned_file


def _run_detect(rows: list[dict], pppc: list[str], tmp_path: Path) -> list[dict]:
    """Invoke ``tcc_detect_anomalies`` via a bash subshell and return the list.

    Uses the codesign shim installed under ``tmp_path/bin``.
    """
    bin_dir = tmp_path / "bin"
    unsigned_file = tmp_path / "unsigned.txt"
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
    env["MACAUDIT_PBT_UNSIGNED_FILE"] = str(unsigned_file)
    env["MACAUDIT_TMPDIR"] = str(tmp_path / "macaudit-tmp")
    (tmp_path / "macaudit-tmp").mkdir(parents=True, exist_ok=True)

    snippet = (
        f'set -e; '
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/sqlite.sh"; '
        f'source "{LIB_DIR}/tcc.sh"; '
        f'rows=$(cat "{tmp_path}/rows.json"); '
        f'pppc=$(cat "{tmp_path}/pppc.json"); '
        f'tcc_detect_anomalies "$rows" "$pppc"'
    )
    (tmp_path / "rows.json").write_text(json.dumps(rows))
    (tmp_path / "pppc.json").write_text(json.dumps(pppc))

    proc = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )
    assert proc.returncode == 0, (
        f"tcc_detect_anomalies failed: rc={proc.returncode} "
        f"stderr={proc.stderr!r}"
    )
    out = proc.stdout.strip()
    assert out, f"empty stdout, stderr={proc.stderr!r}"
    parsed = json.loads(out)
    assert isinstance(parsed, list), f"expected a list, got {parsed!r}"
    return parsed


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
_client_path_strategy = st.one_of(
    # Bundle-id style client (client_type=0 in TCC terms).
    st.builds(
        lambda parts: "com." + ".".join(parts),
        st.lists(
            st.text(
                alphabet=st.characters(
                    min_codepoint=0x61, max_codepoint=0x7A,  # a..z
                    whitelist_categories=("Ll",),
                ),
                min_size=2, max_size=6,
            ),
            min_size=1, max_size=3,
        ),
    ),
    # Absolute path style client (client_type=1 in TCC terms).
    st.builds(
        lambda parts: "/" + "/".join(parts),
        st.lists(
            st.text(
                alphabet=st.characters(
                    min_codepoint=0x61, max_codepoint=0x7A,
                    whitelist_categories=("Ll",),
                ),
                min_size=2, max_size=6,
            ),
            min_size=1, max_size=3,
        ),
    ),
)


@st.composite
def _row_strategy(draw):
    """Generate one access-table row.

    Client_type is drawn independently of the client shape so the
    generator can produce "absolute path with client_type=0" oddities
    (which should NOT trigger tcc_fda_unsigned) alongside the standard
    cases.
    """
    service = draw(st.sampled_from(_SERVICE_POOL))
    client = draw(_client_path_strategy)
    client_type = draw(st.integers(min_value=0, max_value=1))
    auth_reason = draw(st.sampled_from(_AUTH_REASON_POOL))
    auth_value = draw(st.integers(min_value=0, max_value=3))
    last_modified = draw(st.integers(min_value=1_000_000_000, max_value=2_000_000_000))
    return {
        "service": service,
        "client": client,
        "client_type": client_type,
        "auth_value": auth_value,
        "auth_reason": auth_reason,
        "auth_version": 1,
        "last_modified": last_modified,
    }


@st.composite
def _fixture_strategy(draw):
    """Generate rows + pppc list + the subset of clients flagged unsigned."""
    rows = draw(st.lists(_row_strategy(), min_size=0, max_size=10))
    # PPPC list: a random subset of the clients plus (maybe) some noise.
    clients = list({r["client"] for r in rows}) if rows else []
    if clients:
        pppc = draw(st.lists(st.sampled_from(clients + [""]), min_size=0, max_size=len(clients)))
    else:
        pppc = []
    pppc = [p for p in pppc if p]
    # Unsigned set: a random subset of absolute-path clients (a client
    # that is a bundle id will never hit codesign anyway, but we leave
    # the set free-form to exercise the filter too).
    abs_clients = [r["client"] for r in rows
                   if r["client"].startswith("/") and r["client_type"] == 1]
    if abs_clients:
        unsigned = draw(st.lists(st.sampled_from(abs_clients), min_size=0, max_size=len(abs_clients)))
    else:
        unsigned = []
    unsigned = list(set(unsigned))
    return {"rows": rows, "pppc": pppc, "unsigned": unsigned}


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(fixture=_fixture_strategy())
@_SETTINGS
def test_p19_every_emitted_anomaly_has_a_matching_row(tmp_path_factory, fixture):
    """Every anomaly emitted by ``tcc_detect_anomalies`` satisfies its
    rule's preconditions on at least one input row."""
    work = Path(tmp_path_factory.mktemp("p19"))
    rows = fixture["rows"]
    pppc = fixture["pppc"]
    unsigned = fixture["unsigned"]

    _install_codesign_shim(work, unsigned)
    anomalies = _run_detect(rows, pppc, work)

    # Helper predicates mirroring lib/tcc.sh exactly.
    def row_matches_override(r):
        return r.get("auth_reason") == 7

    def row_matches_av(r):
        return (
            r.get("service") in (CAMERA_SERVICE, MIC_SERVICE)
            and r.get("auth_reason") != 2
        )

    def row_matches_fda_unsigned(r):
        return (
            r.get("service") == FDA_SERVICE
            and r.get("client_type") == 1
            and r.get("client") in unsigned
        )

    def row_matches_mdm(r):
        return (
            r.get("auth_reason") == 6
            and r.get("client") not in pppc
        )

    for anomaly in anomalies:
        rule = anomaly.get("rule")
        assert rule, f"anomaly missing rule: {anomaly!r}"
        if rule == "tcc_override_policy":
            preimage = [r for r in rows if row_matches_override(r)]
        elif rule == "tcc_av_unusual_reason":
            preimage = [r for r in rows if row_matches_av(r)]
        elif rule == "tcc_fda_unsigned":
            preimage = [r for r in rows if row_matches_fda_unsigned(r)]
        elif rule == "tcc_mdm_without_profile":
            preimage = [r for r in rows if row_matches_mdm(r)]
        else:
            pytest.fail(f"unknown rule id: {rule!r}")
        assert preimage, (
            f"anomaly {anomaly!r} has no matching row in input.\n"
            f"  rows={rows!r}\n  pppc={pppc!r}\n  unsigned={unsigned!r}"
        )
        # The anomaly's detail field must embed the row's client and
        # (where applicable) service strings, so the operator can tie
        # the finding back to a TCC row.
        detail = anomaly.get("detail", "")
        assert any(r.get("client", "") in detail for r in preimage), (
            f"anomaly detail must embed a matching row's client: "
            f"anomaly={anomaly!r} preimage_clients={[r['client'] for r in preimage]!r}"
        )
