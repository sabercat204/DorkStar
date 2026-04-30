"""Property P15 — security-key extraction scope.

**Property 15**: ``keys(e.content) ⊆ security_key_map(domain_of(e.path))``
for every Tier 2 entry.

Hypothesis generates preference plists for each of the six documented
domains (``com.apple.loginwindow``, ``com.apple.screensaver``,
``com.apple.SoftwareUpdate``, ``com.apple.alf``, ``.GlobalPreferences``,
``com.apple.Safari``). Each generated plist contains a mix of
security-critical keys the spec expects to be captured AND extra keys
the spec says must never leak into the manifest. We run
``baseline_run`` and assert, for every Tier 2 entry, that the entry's
``content`` keys are a subset of the expected allow-list for the
resolved domain.

**Validates: Requirements 5.3**
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
# The hardcoded security-key allow-list, mirrored from lib/surfaces.sh.
# Keeping a second copy here is a deliberate redundancy — if surfaces.sh
# ever grows a key without this map being updated, the tests will fail
# on the new key and force a coordinated update.
# ---------------------------------------------------------------------------
SECURITY_KEYS = {
    "com.apple.loginwindow": [
        "LoginHook", "LogoutHook", "autoLoginUser",
        "SHOWFULLNAME", "DisableConsoleAccess",
    ],
    "com.apple.screensaver": [
        "askForPassword", "askForPasswordDelay", "idleTime",
    ],
    "com.apple.SoftwareUpdate": [
        "AutomaticCheckEnabled", "AutomaticDownload",
        "AutomaticallyInstallMacOSUpdates", "CriticalUpdateInstall",
    ],
    "com.apple.alf": [
        "globalstate", "allowsignedenabled", "stealthenabled", "loggingenabled",
    ],
    ".GlobalPreferences": [
        "com.apple.security.firewall.enable",
        "AppleShowAllExtensions",
        "NSQuitAlwaysKeepsWindows",
    ],
    "com.apple.Safari": [
        "AutoFillPasswords", "AutoOpenSafeDownloads", "WarnAboutFraudulentWebsites",
    ],
}


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------
_extra_key = st.text(
    alphabet=st.characters(
        min_codepoint=0x41, max_codepoint=0x7A,
        whitelist_categories=("Ll", "Lu", "Nd"),
    ),
    min_size=3, max_size=12,
).map(lambda s: "_leak_" + s)

_safe_value = st.one_of(
    st.booleans(),
    st.integers(min_value=0, max_value=10000),
    st.text(
        alphabet=st.characters(min_codepoint=0x20, max_codepoint=0x7E),
        min_size=0, max_size=12,
    ),
)


@st.composite
def _plist_for_domain(draw, domain: str):
    allowed = SECURITY_KEYS[domain]
    # Include each allowed key with 50% probability so the test
    # exercises entries whose content is a proper subset of the
    # allow-list (rather than always the full set). Never go below
    # one key so the entry is not trivially empty.
    keep = [k for k in allowed if draw(st.booleans())]
    if not keep:
        keep = [allowed[0]]

    payload = {}
    for k in keep:
        payload[k] = draw(_safe_value)
    # Sprinkle 1-3 "leak" keys that must NOT appear in the manifest
    # content. These are the adversarial input for P15.
    n_extra = draw(st.integers(min_value=1, max_value=3))
    for _ in range(n_extra):
        payload[draw(_extra_key)] = draw(_safe_value)
    return payload


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
def _write_pref_plist(home: Path, domain: str, payload: dict) -> Path:
    """Write ``payload`` as an XML plist under ``~/Library/Preferences``.

    The filename mirrors the domain exactly (e.g. ``com.apple.alf.plist``)
    because ``cfprefsd_domain_from_path`` resolves the domain from the
    filename stem. For ``.GlobalPreferences`` the file lives alongside
    the others and cfprefsd_domain_from_path maps it to
    ``NSGlobalDomain``; the security-key map accepts either
    identifier.
    """
    pref_dir = home / "Library" / "Preferences"
    pref_dir.mkdir(parents=True, exist_ok=True)
    path = pref_dir / f"{domain}.plist"
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML))
    return path


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
        f'baseline_run --tier 2 --user-only --output {_quote_args([str(out_path)])}'
    )
    return subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True, text=True, check=False, env=env,
    )


def _tier2_entries(manifest_path: Path):
    entries = []
    with manifest_path.open("r", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if i == 0:
                continue
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if obj.get("tier") == 2:
                entries.append(obj)
    return entries


def _domain_from_path(path: str) -> str:
    """Mirror ``cfprefsd_domain_from_path`` for the subset of paths this test uses."""
    stem = Path(path).stem  # strip .plist
    if stem == ".GlobalPreferences":
        return "NSGlobalDomain"
    return stem


def _allowed_keys_for(domain: str) -> set[str]:
    if domain == "NSGlobalDomain":
        return set(SECURITY_KEYS[".GlobalPreferences"])
    return set(SECURITY_KEYS.get(domain, []))


# ---------------------------------------------------------------------------
# Property
# ---------------------------------------------------------------------------
@given(data=st.data())
@_SETTINGS()
def test_p15_tier2_content_keys_are_always_within_allow_list(tmp_path_factory, data):
    """Every Tier 2 entry's ``content`` keys ⊆ security_key_map(domain)."""
    work = Path(tmp_path_factory.mktemp("p15"))
    home = work / "home"
    home.mkdir(parents=True, exist_ok=True)
    bin_dir = work / "bin"
    _install_shims(bin_dir)

    # Pick a random subset of domains (≥ 1) and generate a plist for each.
    chosen = data.draw(st.lists(
        st.sampled_from(list(SECURITY_KEYS.keys())),
        min_size=1, max_size=len(SECURITY_KEYS),
        unique=True,
    ))

    written: dict[str, Path] = {}
    extras_by_domain: dict[str, set[str]] = {}
    for domain in chosen:
        payload = data.draw(_plist_for_domain(domain))
        written[domain] = _write_pref_plist(home, domain, payload)
        # Remember which extra (leak-candidate) keys we sprinkled in so
        # we can explicitly assert they never appear in content.
        extras_by_domain[domain] = {
            k for k in payload.keys() if k.startswith("_leak_")
        }

    out_path = work / "p15.jsonl"
    proc = _run_baseline(home, bin_dir, out_path)
    assert proc.returncode == 0, (
        f"baseline_run failed: stdout={proc.stdout!r} stderr={proc.stderr!r}"
    )

    entries = _tier2_entries(out_path)
    # Every Tier 2 entry must have content keys ⊆ the domain allow-list.
    for entry in entries:
        path = entry["path"]
        content = entry.get("content") or {}
        domain = _domain_from_path(path)
        allowed = _allowed_keys_for(domain)

        content_keys = set(content.keys())
        forbidden = content_keys - allowed
        assert not forbidden, (
            f"P15 violated: entry for {path} leaked keys {sorted(forbidden)} "
            f"(domain={domain}, allowed={sorted(allowed)})"
        )

    # And for each domain we wrote, verify the extras never appear.
    for domain, path in written.items():
        matching = [e for e in entries if e["path"] == str(path)]
        # The entry might be missing if the domain is unknown to cfprefsd
        # from the path — but we only use documented domains, so an
        # entry must exist.
        assert matching, f"no manifest entry for written domain plist {path}"
        entry = matching[0]
        content_keys = set((entry.get("content") or {}).keys())
        assert not (content_keys & extras_by_domain[domain]), (
            f"P15 violated: extras leaked for {domain}: "
            f"content={sorted(content_keys)} extras={sorted(extras_by_domain[domain])}"
        )
