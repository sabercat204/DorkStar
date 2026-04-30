"""Property P20 — TCC anomaly completeness.

**Property 20**: Every input access-table row that satisfies one of the
four TCC anomaly rule predicates produces a matching anomaly object in
``tcc_detect_anomalies``' output. No matching row is ever silently
dropped.

This is the completeness half of the soundness + completeness pair with
P19. Together P19+P20 prove the rules are a pure function: the
anomaly set is exactly the preimage of the rule predicates over the
input rows.

The rule predicates (see P19 for the full spec):

  * ``tcc_override_policy``     — ``auth_reason == 7``.
  * ``tcc_av_unusual_reason``   — service ∈ {camera, mic} ∧ reason ≠ 2.
  * ``tcc_fda_unsigned``        — FDA + client_type=1 + client ∈ unsigned set.
  * ``tcc_mdm_without_profile`` — reason == 6 ∧ client ∉ pppc.

As in P19, a PATH-prepended codesign shim makes the ``fda_unsigned``
predicate deterministic during the property run.

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


FDA_SERVICE = "kTCCServiceSystemPolicyAllFiles"
CAMERA_SERVICE = "kTCCServiceCamera"
MIC_SERVICE = "kTCCServiceMicrophone"

_SERVICE_POOL = [
    FDA_SERVICE,
    CAMERA_SERVICE,
    MIC_SERVICE,
    "kTCCServiceAddressBook",
    "kTCCServicePhotos",
    "kTCCServiceAppleEvents",
    "kTCCServiceReminders",
]

_AUTH_REASON_POOL = [1, 2, 3, 4, 5, 6, 7, 8]


_CODESIGN_SHIM = r"""#!/bin/bash
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


def _install_codesign_shim(tmp_path: Path, unsigned_paths: list[str]) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    shim = bin_dir / "codesign"
    shim.write_text(_CODESIGN_SHIM)
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    (tmp_path / "unsigned.txt").write_text(
        "\n".join(unsigned_paths) + ("\n" if unsigned_paths else "")
    )


def _run_detect(rows: list[dict], pppc: list[str], tmp_path: Path) -> list[dict]:
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
# Strategies — identical to P19 so both properties drive the same space.
# ---------------------------------------------------------------------------
_client_path_strategy = st.one_of(
    st.builds(
        lambda parts: "com." + ".".join(parts),
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
    return {
        "service": draw(st.sampled_from(_SERVICE_POOL)),
        "client": draw(_client_path_strategy),
        "client_type": draw(st.integers(min_value=0, max_value=1)),
        "auth_value": draw(st.integers(min_value=0, max_value=3)),
        "auth_reason": draw(st.sampled_from(_AUTH_REASON_POOL)),
        "auth_version": 1,
        "last_modified": draw(st.integers(min_value=1_000_000_000, max_value=2_000_000_000)),
    }


@st.composite
def _fixture_strategy(draw):
    rows = draw(st.lists(_row_strategy(), min_size=0, max_size=10))
    clients = list({r["client"] for r in rows}) if rows else []
    if clients:
        pppc = draw(st.lists(st.sampled_from(clients + [""]), min_size=0, max_size=len(clients)))
    else:
        pppc = []
    pppc = [p for p in pppc if p]
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
def test_p20_every_matching_row_produces_a_matching_anomaly(tmp_path_factory, fixture):
    """Every row that satisfies a rule predicate produces a matching anomaly."""
    work = Path(tmp_path_factory.mktemp("p20"))
    rows = fixture["rows"]
    pppc = fixture["pppc"]
    unsigned = fixture["unsigned"]

    _install_codesign_shim(work, unsigned)
    anomalies = _run_detect(rows, pppc, work)

    # Bucket the emitted anomalies by (rule, client). Each bucket is the
    # set of anomalies for that (rule, client) pair, so we can cheaply
    # ask "does an anomaly exist for this row under this rule?".
    by_rule_client: dict[tuple[str, str], list[dict]] = {}
    for a in anomalies:
        key = (a.get("rule", ""), _extract_client_from_detail(a.get("detail", "")))
        by_rule_client.setdefault(key, []).append(a)

    missing_reports: list[str] = []

    for r in rows:
        if r.get("auth_reason") == 7:
            if not _has_anomaly_for_row(anomalies, "tcc_override_policy", r):
                missing_reports.append(
                    f"missing tcc_override_policy for row={r!r}"
                )

        if (r.get("service") in (CAMERA_SERVICE, MIC_SERVICE)
                and r.get("auth_reason") != 2):
            if not _has_anomaly_for_row(anomalies, "tcc_av_unusual_reason", r):
                missing_reports.append(
                    f"missing tcc_av_unusual_reason for row={r!r}"
                )

        if (r.get("service") == FDA_SERVICE
                and r.get("client_type") == 1
                and r.get("client") in unsigned):
            if not _has_anomaly_for_row(anomalies, "tcc_fda_unsigned", r):
                missing_reports.append(
                    f"missing tcc_fda_unsigned for row={r!r}"
                )

        if r.get("auth_reason") == 6 and r.get("client") not in pppc:
            if not _has_anomaly_for_row(anomalies, "tcc_mdm_without_profile", r):
                missing_reports.append(
                    f"missing tcc_mdm_without_profile for row={r!r}"
                )

    assert not missing_reports, (
        "rules failed completeness:\n  " + "\n  ".join(missing_reports)
        + f"\nrows={rows!r}\npppc={pppc!r}\nunsigned={unsigned!r}\n"
        f"anomalies={anomalies!r}"
    )


def _has_anomaly_for_row(anomalies: list[dict], rule: str, row: dict) -> bool:
    """Return True when at least one anomaly under ``rule`` references
    the row's client (and service, where the detail embeds it)."""
    client = row.get("client", "")
    service = row.get("service", "")
    for a in anomalies:
        if a.get("rule") != rule:
            continue
        detail = a.get("detail", "")
        if client in detail and (not service or service in detail or rule == "tcc_fda_unsigned"):
            return True
    return False


def _extract_client_from_detail(detail: str) -> str:
    """Best-effort extractor, used only for bucket-keying diagnostics."""
    # Not strictly needed for correctness — the completeness check uses
    # `_has_anomaly_for_row` directly. Kept as a helper for future
    # diagnostic prints.
    return detail
