"""Property P22/P23 — cross-surface correlation soundness + completeness.

**Property 22**: Every correlation entry emitted by ``baseline_correlate``
corresponds to at least one satisfied precondition in the input
(tier1_entries, tier3_entries, env) triple. The function never fires
"spuriously".

**Property 23**: Every input triple that satisfies a rule's preconditions
produces a matching correlation entry. No qualifying state is ever
silently dropped.

Together P22 + P23 prove the correlation pass is a pure function: the
set of emitted correlation entries is exactly the preimage of the R1,
R4, R5 rule predicates over the input. (R2 and R3 require filesystem
side effects — quarantine xattrs / codesign output — and are covered
by their own bats integration tests; this file exercises the rules
that are pure data transforms so the bijection can be asserted
without mocking the OS.)

Rule predicates (pure data transforms):

  * **R1 tcc_mdm_without_profile**
      Every row ``r ∈ tier3[surface ∈ {tcc_system, tcc_user}]
                      .table_snapshots.access.rows`` with
      ``r.auth_reason == 6`` AND ``r.client ∉ env.pppc_payloads``.

  * **R4 kext_user_approved_on_mdm** *(gated on env.mdm_managed == true)*
      Every row ``r ∈ tier3[surface == kextpolicy]
                      .table_snapshots.kext_policy.rows``
      whose ``(team_id, bundle_id)`` pair is NOT in
      ``tier3[surface == kextpolicy].table_snapshots.kext_policy_mdm.rows``.

  * **R5 authdb_missing_plugin**
      For every ``authdb_entry ∈ tier3[surface == authdb]``, every
      ``mech ∈ authdb_entry.content.mechanisms`` where
      ``classify(mech, env.plugin_dirs) == "missing"``.

**Validates: Requirements 27.5**
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import hypothesis.strategies as st
import pytest
from hypothesis import HealthCheck, given, settings

from conftest import LIB_DIR


# ---------------------------------------------------------------------------
# Subprocess harness
# ---------------------------------------------------------------------------
def _run_correlate(
    tier1_entries: list[dict],
    tier3_entries: list[dict],
    env: dict,
    workdir: Path,
) -> list[dict]:
    """Invoke ``baseline_correlate`` via a bash subshell and return its output.

    The three input files are materialised under ``workdir`` so the
    function can be driven exactly as ``baseline_run`` drives it in
    production. Returns the list of correlation entries (parsed JSONL).
    """
    tier1_file = workdir / "tier1.jsonl"
    tier3_file = workdir / "tier3.jsonl"
    env_file = workdir / "env.json"

    with tier1_file.open("w") as f:
        for e in tier1_entries:
            f.write(json.dumps(e) + "\n")
    with tier3_file.open("w") as f:
        for e in tier3_entries:
            f.write(json.dumps(e) + "\n")
    env_file.write_text(json.dumps(env))

    tmpdir = workdir / "macaudit-tmp"
    tmpdir.mkdir(parents=True, exist_ok=True)

    env_vars = os.environ.copy()
    env_vars["MACAUDIT_TMPDIR"] = str(tmpdir)
    # Pin plugin dir overrides to non-existent paths by default so
    # ``sysdb_plugin_dirs_listing`` produces an empty cache unless the
    # per-test fixture builds one explicitly under workdir.
    env_vars.setdefault("SYSTEM_PLUGIN_DIR_OVERRIDE",
                        str(workdir / "no-such-system"))
    env_vars.setdefault("THIRD_PARTY_PLUGIN_DIR_OVERRIDE",
                        str(workdir / "no-such-3p"))

    snippet = (
        f'set -e; '
        f'source "{LIB_DIR}/utils.sh"; '
        f'source "{LIB_DIR}/sqlite.sh"; '
        f'source "{LIB_DIR}/surfaces.sh"; '
        f'source "{LIB_DIR}/manifest.sh"; '
        f'source "{LIB_DIR}/persistence.sh"; '
        f'source "{LIB_DIR}/cfprefsd.sh"; '
        f'source "{LIB_DIR}/tcc.sh"; '
        f'source "{LIB_DIR}/sysdb.sh"; '
        f'source "{LIB_DIR}/quarantine.sh"; '
        f'source "{LIB_DIR}/xprotect.sh"; '
        f'source "{LIB_DIR}/baseline.sh"; '
        f'baseline_correlate '
        f'"{tier1_file}" "{tier3_file}" "{env_file}"'
    )
    proc = subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env_vars,
    )
    assert proc.returncode == 0, (
        f"baseline_correlate failed rc={proc.returncode}\n"
        f"stderr={proc.stderr!r}"
    )
    out = proc.stdout.strip()
    if not out:
        return []
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def _plugin_fixture(workdir: Path, system_names: list[str],
                    third_names: list[str]) -> tuple[Path, Path]:
    """Materialise system + third-party plugin directories under ``workdir``.

    Each supplied name produces a ``<name>.bundle`` directory (the
    layout ``sysdb_classify_mechanism`` expects). Returns ``(system_dir,
    third_party_dir)`` suitable for writing into the env JSON.
    """
    sys_dir = workdir / "plugins-system"
    third_dir = workdir / "plugins-3p"
    sys_dir.mkdir(parents=True, exist_ok=True)
    third_dir.mkdir(parents=True, exist_ok=True)
    for name in system_names:
        (sys_dir / f"{name}.bundle").mkdir(exist_ok=True)
    for name in third_names:
        (third_dir / f"{name}.bundle").mkdir(exist_ok=True)
    return sys_dir, third_dir


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[
        HealthCheck.too_slow,
        HealthCheck.function_scoped_fixture,
    ],
)


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
# Identifier alphabet: lowercase ASCII only so generated strings never
# need JSON escaping. That keeps both the fixture serialisation and
# the jq-side parsing deterministic.
_ident_alphabet = st.characters(
    min_codepoint=0x61, max_codepoint=0x7A, whitelist_categories=("Ll",)
)
_ident = st.text(alphabet=_ident_alphabet, min_size=2, max_size=6)


@st.composite
def _tcc_row(draw, clients: list[str]):
    """Generate one TCC access row with a client drawn from ``clients``."""
    return {
        "service": draw(st.sampled_from([
            "kTCCServiceSystemPolicyAllFiles",
            "kTCCServiceCamera",
            "kTCCServicePhotos",
            "kTCCServiceAppleEvents",
        ])),
        "client": draw(st.sampled_from(clients)),
        "client_type": draw(st.integers(min_value=0, max_value=1)),
        "auth_value": draw(st.integers(min_value=0, max_value=3)),
        # auth_reason spans both the interesting values (6 = MDM
        # policy-set) and unrelated ones so the generator naturally
        # produces rows that do / do not trigger R1.
        "auth_reason": draw(st.integers(min_value=1, max_value=8)),
        "auth_version": 1,
        "last_modified": draw(st.integers(
            min_value=1_000_000_000, max_value=2_000_000_000)),
    }


@st.composite
def _r1_fixture(draw):
    """Generate (tier3 TCC entries, env, pppc) with arbitrary R1 hits."""
    clients = draw(st.lists(_ident, min_size=1, max_size=4, unique=True))
    clients = [f"com.test.{c}" for c in clients]
    # PPPC: random subset of the client pool.
    pppc = draw(st.lists(st.sampled_from(clients),
                          min_size=0, max_size=len(clients), unique=True))
    # Generate 0–3 tier3 TCC entries, each with 0–3 rows.
    n_entries = draw(st.integers(min_value=0, max_value=3))
    entries = []
    for i in range(n_entries):
        surface = draw(st.sampled_from(["tcc_system", "tcc_user"]))
        n_rows = draw(st.integers(min_value=0, max_value=3))
        rows = [draw(_tcc_row(clients)) for _ in range(n_rows)]
        entries.append({
            "path": f"/fake/tcc_{i}.db",
            "tier": 3,
            "surface": surface,
            "format": "sqlite",
            "sha256_raw": "",
            "sha256_canonical": "",
            "table_snapshots": {
                "access": {
                    "row_count": len(rows),
                    "primary_key": ["service", "client", "client_type",
                                     "indirect_object_identifier"],
                    "content_hash": "",
                    "rows": rows,
                }
            },
            "anomalies": [],
        })
    return {"entries": entries, "pppc": pppc}


@st.composite
def _kextpolicy_fixture(draw):
    """Generate (tier3 kextpolicy entry, mdm_managed flag) for R4."""
    team_ids = draw(st.lists(_ident, min_size=1, max_size=3, unique=True))
    bundle_ids = draw(st.lists(_ident, min_size=1, max_size=3, unique=True))

    def _row():
        return {
            "team_id": draw(st.sampled_from(team_ids)),
            "bundle_id": f"com.test.{draw(st.sampled_from(bundle_ids))}",
            "allowed": draw(st.integers(min_value=0, max_value=1)),
            "developer_name": draw(_ident),
            "flags": draw(st.integers(min_value=0, max_value=7)),
        }

    n_user = draw(st.integers(min_value=0, max_value=3))
    n_mdm = draw(st.integers(min_value=0, max_value=3))
    user_rows = [_row() for _ in range(n_user)]
    mdm_rows = [_row() for _ in range(n_mdm)]
    mdm_managed = draw(st.booleans())
    entry = {
        "path": "/fake/KextPolicy",
        "tier": 3,
        "surface": "kextpolicy",
        "format": "sqlite",
        "sha256_raw": "",
        "sha256_canonical": "",
        "table_snapshots": {
            "kext_policy": {
                "row_count": len(user_rows),
                "rows": user_rows,
            },
            "kext_policy_mdm": {
                "row_count": len(mdm_rows),
                "rows": mdm_rows,
            },
        },
        "anomalies": [],
    }
    return {"entry": entry, "mdm_managed": mdm_managed}


@st.composite
def _authdb_fixture(draw, system_names: list[str], third_names: list[str]):
    """Generate (authdb entries, mechanism pool) for R5."""
    # The mechanism pool is a mix of:
    #   - builtin:<name>                (classifies to "builtin")
    #   - <sys>:<name>                  (classifies to "system-plugin")
    #   - <3p>:<name>                   (classifies to "third-party-plugin")
    #   - <unknown_prefix>:<name>       (classifies to "missing")
    #   - <malformed: no colon>         (classifies to "" / dropped)
    unknown_prefix_strat = _ident.filter(
        lambda s: s not in system_names and s not in third_names
                  and s != "builtin"
    )
    mech_strat = st.one_of(
        st.builds(lambda n: f"builtin:{n}", _ident),
        *([st.builds(lambda n, p=p: f"{p}:{n}", _ident)
           for p in system_names]
          if system_names else []),
        *([st.builds(lambda n, p=p: f"{p}:{n}", _ident)
           for p in third_names]
          if third_names else []),
        st.builds(lambda p, n: f"{p}:{n}", unknown_prefix_strat, _ident),
    )

    n_entries = draw(st.integers(min_value=0, max_value=3))
    entries = []
    for i in range(n_entries):
        mechs = draw(st.lists(mech_strat, min_size=0, max_size=4))
        entries.append({
            "path": f"security://authorizationdb/rule_{i}",
            "tier": 3,
            "surface": "authdb",
            "format": "plist",
            "sha256_raw": "",
            "sha256_canonical": "",
            "content": {"mechanisms": mechs, "class": "rule"},
            "anomalies": [],
        })
    return entries


# ---------------------------------------------------------------------------
# Classifier mirror (pure python) — matches sysdb_classify_mechanism
# ---------------------------------------------------------------------------
def _classify(mech: str, system_names: list[str],
              third_names: list[str]) -> str:
    if not mech or ":" not in mech:
        return ""
    prefix = mech.split(":", 1)[0]
    if not prefix:
        return ""
    if prefix == "builtin":
        return "builtin"
    if prefix in system_names:
        return "system-plugin"
    if prefix in third_names:
        return "third-party-plugin"
    return "missing"


# ---------------------------------------------------------------------------
# Properties — R1 in isolation
# ---------------------------------------------------------------------------
@given(fixture=_r1_fixture())
@_SETTINGS
def test_p22_r1_soundness_and_completeness(tmp_path_factory, fixture):
    """Every R1 correlation entry has a matching row; every qualifying
    row produces a matching R1 entry."""
    work = Path(tmp_path_factory.mktemp("p22r1"))
    tier3 = fixture["entries"]
    pppc = fixture["pppc"]
    env = {
        "pppc_profile_payload_identifiers": pppc,
        "mdm_managed": False,
        "plugin_dirs": [
            str(work / "no-such-system"),
            str(work / "no-such-3p"),
        ],
    }
    out = _run_correlate(tier1_entries=[], tier3_entries=tier3,
                          env=env, workdir=work)

    r1_out = [e for e in out if any(
        a["rule"] == "correlation:tcc_mdm_without_profile"
        for a in e.get("anomalies", []))]

    # Build the expected pre-image from the fixture.
    expected = []
    for entry in tier3:
        if entry["surface"] not in ("tcc_system", "tcc_user"):
            continue
        rows = entry.get("table_snapshots", {}).get("access", {}).get("rows", [])
        for r in rows:
            if r.get("auth_reason") == 6 and r.get("client") not in pppc:
                expected.append(r)

    # Soundness: every R1 anomaly's detail row satisfies the predicate.
    for e in r1_out:
        detail = e["anomalies"][0]["detail"]
        assert detail.get("auth_reason") == 6, (
            f"R1 entry has auth_reason != 6: {detail!r}"
        )
        assert detail.get("client") not in pppc, (
            f"R1 entry's client {detail.get('client')!r} is in pppc {pppc!r}"
        )

    # Completeness: exactly len(expected) R1 entries emitted.
    assert len(r1_out) == len(expected), (
        f"R1 count mismatch: got {len(r1_out)}, expected {len(expected)}.\n"
        f"  expected rows: {expected!r}\n"
        f"  got anomalies: {[e['anomalies'] for e in r1_out]!r}"
    )


# ---------------------------------------------------------------------------
# Properties — R4 in isolation
# ---------------------------------------------------------------------------
@given(fixture=_kextpolicy_fixture())
@_SETTINGS
def test_p22_r4_soundness_and_completeness(tmp_path_factory, fixture):
    """Every R4 correlation entry has a user row without a matching MDM
    row (on MDM-managed hosts); every qualifying row produces a matching
    entry. On non-MDM hosts the set of R4 entries is empty."""
    work = Path(tmp_path_factory.mktemp("p22r4"))
    entry = fixture["entry"]
    mdm_managed = fixture["mdm_managed"]
    env = {
        "pppc_profile_payload_identifiers": [],
        "mdm_managed": mdm_managed,
        "plugin_dirs": [
            str(work / "no-such-system"),
            str(work / "no-such-3p"),
        ],
    }
    out = _run_correlate(tier1_entries=[], tier3_entries=[entry],
                          env=env, workdir=work)
    r4_out = [e for e in out if any(
        a["rule"] == "correlation:kext_user_approved_on_mdm"
        for a in e.get("anomalies", []))]

    if not mdm_managed:
        assert r4_out == [], (
            f"R4 fired on non-MDM host: {r4_out!r}"
        )
        return

    user_rows = entry["table_snapshots"]["kext_policy"]["rows"]
    mdm_rows = entry["table_snapshots"]["kext_policy_mdm"]["rows"]
    mdm_keys = {(r["team_id"], r["bundle_id"]) for r in mdm_rows}
    expected = [r for r in user_rows
                if (r["team_id"], r["bundle_id"]) not in mdm_keys]

    # Soundness.
    for e in r4_out:
        detail = e["anomalies"][0]["detail"]
        key = (detail.get("team_id"), detail.get("bundle_id"))
        assert key not in mdm_keys, (
            f"R4 entry {detail!r} has a matching MDM row (should be suppressed)"
        )

    # Completeness.
    assert len(r4_out) == len(expected), (
        f"R4 count mismatch: got {len(r4_out)}, expected {len(expected)}.\n"
        f"  user_rows={user_rows!r}\n"
        f"  mdm_rows={mdm_rows!r}\n"
        f"  expected={expected!r}"
    )


# ---------------------------------------------------------------------------
# Properties — R5 in isolation
# ---------------------------------------------------------------------------
@st.composite
def _r5_fixture(draw):
    """Generate authdb entries + realised plugin directory names."""
    system_names = draw(st.lists(_ident, min_size=0, max_size=2, unique=True))
    third_names = draw(st.lists(_ident, min_size=0, max_size=2, unique=True))
    # Dedup across the two directory sets — system takes precedence in
    # the classifier, so including the same name in both would leak
    # ambiguity into the oracle. Strip collisions from the 3p list.
    third_names = [n for n in third_names if n not in system_names]
    entries = draw(_authdb_fixture(system_names, third_names))
    return {
        "entries": entries,
        "system_names": system_names,
        "third_names": third_names,
    }


@given(fixture=_r5_fixture())
@_SETTINGS
def test_p22_r5_soundness_and_completeness(tmp_path_factory, fixture):
    """Every R5 correlation entry references a mechanism whose
    classification is ``missing``; every such mechanism in the input
    produces a matching R5 entry."""
    work = Path(tmp_path_factory.mktemp("p22r5"))
    system_names = fixture["system_names"]
    third_names = fixture["third_names"]
    entries = fixture["entries"]

    sys_dir, third_dir = _plugin_fixture(work, system_names, third_names)
    env = {
        "pppc_profile_payload_identifiers": [],
        "mdm_managed": False,
        "plugin_dirs": [str(sys_dir), str(third_dir)],
    }

    # The R5 classifier inside sysdb_classify_mechanism reads
    # SYSTEM_PLUGIN_DIR_OVERRIDE / THIRD_PARTY_PLUGIN_DIR_OVERRIDE —
    # not env.plugin_dirs — so we push the same values into the
    # subshell's environment via a scoped override.
    old_sys = os.environ.get("SYSTEM_PLUGIN_DIR_OVERRIDE")
    old_3p = os.environ.get("THIRD_PARTY_PLUGIN_DIR_OVERRIDE")
    os.environ["SYSTEM_PLUGIN_DIR_OVERRIDE"] = str(sys_dir)
    os.environ["THIRD_PARTY_PLUGIN_DIR_OVERRIDE"] = str(third_dir)
    try:
        out = _run_correlate(tier1_entries=[], tier3_entries=entries,
                              env=env, workdir=work)
    finally:
        if old_sys is None:
            os.environ.pop("SYSTEM_PLUGIN_DIR_OVERRIDE", None)
        else:
            os.environ["SYSTEM_PLUGIN_DIR_OVERRIDE"] = old_sys
        if old_3p is None:
            os.environ.pop("THIRD_PARTY_PLUGIN_DIR_OVERRIDE", None)
        else:
            os.environ["THIRD_PARTY_PLUGIN_DIR_OVERRIDE"] = old_3p

    r5_out = [e for e in out if any(
        a["rule"] == "correlation:authdb_missing_plugin"
        for a in e.get("anomalies", []))]

    # Build the expected pre-image: every (entry_path, mech) where the
    # classifier returns "missing".
    expected: list[tuple[str, str]] = []
    for entry in entries:
        rule_path = entry["path"]
        for mech in entry["content"]["mechanisms"]:
            if _classify(mech, system_names, third_names) == "missing":
                expected.append((rule_path, mech))

    # Soundness: every R5 anomaly's detail references a (path, mech)
    # pair whose classification is "missing".
    for e in r5_out:
        detail = e["anomalies"][0]["detail"]
        rule_path = detail.get("rule_or_right")
        mech = detail.get("mechanism")
        assert _classify(mech, system_names, third_names) == "missing", (
            f"R5 entry {detail!r} mechanism classifies as "
            f"{_classify(mech, system_names, third_names)!r}, not missing"
        )
        assert (rule_path, mech) in expected, (
            f"R5 entry {detail!r} is not in the expected pre-image.\n"
            f"  expected={expected!r}"
        )

    # Completeness: every expected (path, mech) produces exactly one
    # entry. The rule is a pure filter so duplicates should not arise
    # from a single input entry.
    got_pairs = [
        (e["anomalies"][0]["detail"]["rule_or_right"],
         e["anomalies"][0]["detail"]["mechanism"])
        for e in r5_out
    ]
    assert sorted(got_pairs) == sorted(expected), (
        f"R5 pair mismatch.\n"
        f"  expected={sorted(expected)!r}\n"
        f"  got=     {sorted(got_pairs)!r}"
    )


# ---------------------------------------------------------------------------
# Properties — mixed (R1 + R4 + R5 in a single run)
# ---------------------------------------------------------------------------
@st.composite
def _mixed_fixture(draw):
    r1 = draw(_r1_fixture())
    k = draw(_kextpolicy_fixture())
    r5 = draw(_r5_fixture())
    return {
        "tier3_tcc_entries": r1["entries"],
        "pppc": r1["pppc"],
        "kext_entry": k["entry"],
        "mdm_managed": k["mdm_managed"],
        "authdb_entries": r5["entries"],
        "system_names": r5["system_names"],
        "third_names": r5["third_names"],
    }


@given(fixture=_mixed_fixture())
@_SETTINGS
def test_p23_mixed_soundness_and_completeness(tmp_path_factory, fixture):
    """With all three rules active, the total correlation output is the
    disjoint union of the R1, R4 and R5 pre-images."""
    work = Path(tmp_path_factory.mktemp("p23mixed"))
    system_names = fixture["system_names"]
    third_names = fixture["third_names"]

    sys_dir, third_dir = _plugin_fixture(work, system_names, third_names)

    tier3 = (fixture["tier3_tcc_entries"]
             + [fixture["kext_entry"]]
             + fixture["authdb_entries"])
    env = {
        "pppc_profile_payload_identifiers": fixture["pppc"],
        "mdm_managed": fixture["mdm_managed"],
        "plugin_dirs": [str(sys_dir), str(third_dir)],
    }

    old_sys = os.environ.get("SYSTEM_PLUGIN_DIR_OVERRIDE")
    old_3p = os.environ.get("THIRD_PARTY_PLUGIN_DIR_OVERRIDE")
    os.environ["SYSTEM_PLUGIN_DIR_OVERRIDE"] = str(sys_dir)
    os.environ["THIRD_PARTY_PLUGIN_DIR_OVERRIDE"] = str(third_dir)
    try:
        out = _run_correlate(tier1_entries=[], tier3_entries=tier3,
                              env=env, workdir=work)
    finally:
        if old_sys is None:
            os.environ.pop("SYSTEM_PLUGIN_DIR_OVERRIDE", None)
        else:
            os.environ["SYSTEM_PLUGIN_DIR_OVERRIDE"] = old_sys
        if old_3p is None:
            os.environ.pop("THIRD_PARTY_PLUGIN_DIR_OVERRIDE", None)
        else:
            os.environ["THIRD_PARTY_PLUGIN_DIR_OVERRIDE"] = old_3p

    # Split the output by rule id.
    r1_out = [e for e in out if any(
        a["rule"] == "correlation:tcc_mdm_without_profile"
        for a in e.get("anomalies", []))]
    r4_out = [e for e in out if any(
        a["rule"] == "correlation:kext_user_approved_on_mdm"
        for a in e.get("anomalies", []))]
    r5_out = [e for e in out if any(
        a["rule"] == "correlation:authdb_missing_plugin"
        for a in e.get("anomalies", []))]

    # Expected counts — mirrors the isolated-rule tests above.
    pppc = fixture["pppc"]
    r1_expected = [
        r
        for entry in fixture["tier3_tcc_entries"]
        for r in entry["table_snapshots"]["access"]["rows"]
        if r.get("auth_reason") == 6 and r.get("client") not in pppc
    ]

    if fixture["mdm_managed"]:
        kext_entry = fixture["kext_entry"]
        user_rows = kext_entry["table_snapshots"]["kext_policy"]["rows"]
        mdm_rows = kext_entry["table_snapshots"]["kext_policy_mdm"]["rows"]
        mdm_keys = {(r["team_id"], r["bundle_id"]) for r in mdm_rows}
        r4_expected = [r for r in user_rows
                       if (r["team_id"], r["bundle_id"]) not in mdm_keys]
    else:
        r4_expected = []

    r5_expected: list[tuple[str, str]] = []
    for entry in fixture["authdb_entries"]:
        for mech in entry["content"]["mechanisms"]:
            if _classify(mech, system_names, third_names) == "missing":
                r5_expected.append((entry["path"], mech))

    assert len(r1_out) == len(r1_expected), (
        f"mixed R1 count mismatch got {len(r1_out)} expected {len(r1_expected)}"
    )
    assert len(r4_out) == len(r4_expected), (
        f"mixed R4 count mismatch got {len(r4_out)} expected {len(r4_expected)}"
    )
    assert len(r5_out) == len(r5_expected), (
        f"mixed R5 count mismatch got {len(r5_out)} expected {len(r5_expected)}"
    )

    # And the partition is disjoint: total output = sum of the three.
    assert len(out) == len(r1_out) + len(r4_out) + len(r5_out), (
        f"mixed total count mismatch — rules overlap?\n"
        f"  total={len(out)}\n"
        f"  r1={len(r1_out)} r4={len(r4_out)} r5={len(r5_out)}"
    )
