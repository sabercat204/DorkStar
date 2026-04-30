#!/bin/bash
# tests/perf/gen_fixture.sh — synthetic fixture generator for the
# performance harness (task 18.1).
#
# Populates a caller-supplied $FAKE_HOME tree with plists distributed
# across the two user-scope surfaces that `baseline --user-only` walks:
#
#   * $FAKE_HOME/Library/LaunchAgents/*.plist   (Tier 1, launchd_user)
#   * $FAKE_HOME/Library/Preferences/*.plist    (Tier 2, preferences_user)
#
# Split is ~2:1 between LaunchAgents and Preferences (the realistic
# skew on a developer laptop). Each plist is produced via
# `plutil -convert xml1` from a seed JSON document, so the walker sees
# real, parseable macOS plists — matching the style used by
# `_write_launch_agent` in tests/bats/test_integration_tier12.bats.
#
# Usage:
#   bash tests/perf/gen_fixture.sh --home DIR --count N
#
# Designed to be callable either standalone (for manual fixture
# inspection) or from run.sh (which sets --keep-fixture and then
# inspects the produced tree).
#
# Hard constraints:
#   * bash 3.2 compatible: no associative arrays, no mapfile, no `echo`.
#   * `set -e` only (not -euo pipefail) because the generator is
#     invoked as a subprocess by run.sh — a hard set -u here would
#     cause unrelated env differences to fail the fixture build.
#   * plutil + jq must be on PATH (both ship on every supported macOS).

set -e

# -----------------------------------------------------------------------------
# Flag parsing
# -----------------------------------------------------------------------------

_gf_fake_home=""
_gf_count=""

_gf_usage() {
  printf '%s\n' 'Usage: gen_fixture.sh --home DIR --count N' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --home)
      if [ $# -lt 2 ]; then _gf_usage; exit 2; fi
      _gf_fake_home="$2"; shift 2
      ;;
    --count)
      if [ $# -lt 2 ]; then _gf_usage; exit 2; fi
      _gf_count="$2"; shift 2
      ;;
    -h|--help)
      _gf_usage
      exit 0
      ;;
    *)
      printf 'gen_fixture.sh: unexpected argument: %s\n' "$1" >&2
      _gf_usage
      exit 2
      ;;
  esac
done

if [ -z "${_gf_fake_home}" ] || [ -z "${_gf_count}" ]; then
  _gf_usage
  exit 2
fi

case "${_gf_count}" in
  ''|*[!0-9]*)
    printf 'gen_fixture.sh: --count must be a positive integer (got %s)\n' \
      "${_gf_count}" >&2
    exit 2
    ;;
esac

if [ "${_gf_count}" -lt 2 ]; then
  printf 'gen_fixture.sh: --count must be >= 2 (got %s)\n' "${_gf_count}" >&2
  exit 2
fi

command -v plutil >/dev/null 2>&1 || {
  printf 'gen_fixture.sh: plutil not found on PATH\n' >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  printf 'gen_fixture.sh: jq not found on PATH\n' >&2
  exit 2
}

# -----------------------------------------------------------------------------
# Directory setup
# -----------------------------------------------------------------------------

_gf_la_dir="${_gf_fake_home}/Library/LaunchAgents"
_gf_pref_dir="${_gf_fake_home}/Library/Preferences"
mkdir -p -- "${_gf_la_dir}"
mkdir -p -- "${_gf_pref_dir}"

# ~2:1 split (LaunchAgents : Preferences).
_gf_la_count=$(( (_gf_count * 2) / 3 ))
_gf_pref_count=$(( _gf_count - _gf_la_count ))

# -----------------------------------------------------------------------------
# LaunchAgents
# -----------------------------------------------------------------------------
# Minimal valid LaunchAgent plist: Label + RunAtLoad + ProgramArguments.
# jq writes a one-line JSON seed, plutil converts to xml1 in place.

printf 'gen_fixture.sh: generating %d LaunchAgents...\n' "${_gf_la_count}" >&2

_gf_seed_json="${_gf_fake_home}/.macaudit-perf-seed.json"

_gf_i=0
while [ "${_gf_i}" -lt "${_gf_la_count}" ]; do
  _gf_label="com.perf.agent.${_gf_i}"
  jq -cn --arg L "${_gf_label}" \
    '{Label: $L, RunAtLoad: true, ProgramArguments: ["/usr/bin/true"]}' \
    > "${_gf_seed_json}"
  plutil -convert xml1 -o "${_gf_la_dir}/${_gf_label}.plist" "${_gf_seed_json}"
  _gf_i=$(( _gf_i + 1 ))
done

# -----------------------------------------------------------------------------
# Preferences
# -----------------------------------------------------------------------------
# Cycle through four rotating domains from
# `surfaces_security_keys_for_domain`, dropping one security-critical
# key per plist. Filename pattern `<domain>.<index>.plist` is
# deliberately NOT a real cfprefsd-served name — the walker still
# sees a real plist and content extraction fires, but
# `cfprefsd_compare` returns null cleanly because cfprefsd has no
# matching on-disk domain to read back.

printf 'gen_fixture.sh: generating %d preferences...\n' "${_gf_pref_count}" >&2

_gf_j=0
while [ "${_gf_j}" -lt "${_gf_pref_count}" ]; do
  _gf_idx=$(( _gf_j % 4 ))
  case "${_gf_idx}" in
    0) _gf_domain="com.apple.screensaver";    _gf_key="askForPassword";           _gf_value="true" ;;
    1) _gf_domain="com.apple.SoftwareUpdate"; _gf_key="AutomaticCheckEnabled";    _gf_value="true" ;;
    2) _gf_domain="com.apple.alf";            _gf_key="globalstate";              _gf_value="1" ;;
    3) _gf_domain="com.apple.Safari";         _gf_key="WarnAboutFraudulentWebsites"; _gf_value="true" ;;
  esac
  _gf_filename="${_gf_domain}.${_gf_j}.plist"

  jq -cn --arg k "${_gf_key}" --arg v "${_gf_value}" '{($k): $v}' \
    > "${_gf_seed_json}"
  plutil -convert xml1 -o "${_gf_pref_dir}/${_gf_filename}" "${_gf_seed_json}"
  _gf_j=$(( _gf_j + 1 ))
done

rm -f -- "${_gf_seed_json}"

# Report the actual counts so run.sh can record them.
printf 'launchagents=%d preferences=%d total=%d\n' \
  "${_gf_la_count}" "${_gf_pref_count}" "${_gf_count}"
