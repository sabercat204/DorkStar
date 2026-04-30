#!/usr/bin/env bats
# tests/bats/enumerate.bats — unit tests for lib/enumerate.sh.
#
# Strategy: enumerate_run reads real system directories (e.g.
# /Library/Preferences, $HOME/Library/LaunchAgents) for its counters,
# so the tests that must pin a specific count override $HOME to point
# at a scratch directory we control. Where the counter is driven by an
# external binary (`launchctl`, `sfltool`), we use the standard
# PATH-shim pattern: prepend ${FIXTURE_DIR}/bin to PATH in setup and
# write throwaway scripts there.
#
# OS_MAJOR_OVERRIDE is honoured by utils_os_major — we exploit it in
# the "BTM on macOS 12" test rather than shimming sw_vers.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib"
  # shellcheck source=/dev/null
  source "${LIB}/utils.sh"
  # shellcheck source=/dev/null
  source "${LIB}/surfaces.sh"
  # shellcheck source=/dev/null
  source "${LIB}/persistence.sh"
  # shellcheck source=/dev/null
  source "${LIB}/enumerate.sh"

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macaudit-bats-enumerate.XXXXXX")"
  mkdir -p "${FIXTURE_DIR}/bin"
  # Seed a per-test fake $HOME so user-scoped counters are predictable.
  FAKE_HOME="${FIXTURE_DIR}/home"
  mkdir -p "${FAKE_HOME}/Library/LaunchAgents"
  mkdir -p "${FAKE_HOME}/Library/Preferences"
  ORIG_HOME="${HOME}"
  HOME="${FAKE_HOME}"
  export HOME

  ORIG_PATH="${PATH}"
  PATH="${FIXTURE_DIR}/bin:${PATH}"
  export PATH
}

teardown() {
  PATH="${ORIG_PATH:-$PATH}"
  export PATH
  HOME="${ORIG_HOME:-$HOME}"
  export HOME
  unset OS_MAJOR_OVERRIDE
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "${FIXTURE_DIR}" ]; then
    rm -rf -- "${FIXTURE_DIR}" || true
  fi
}

# _install_shim <name> <exit_code> <stdout_body>
#   Write ${FIXTURE_DIR}/bin/<name> as a tiny bash script that cats a
#   sibling body file and exits with the given code.
_install_shim() {
  local name="$1" rc="$2" body="$3"
  local body_file="${FIXTURE_DIR}/${name}_body.txt"
  printf '%s' "$body" > "$body_file"
  cat > "${FIXTURE_DIR}/bin/${name}" <<SHIM
#!/bin/bash
cat "${body_file}"
exit ${rc}
SHIM
  chmod +x "${FIXTURE_DIR}/bin/${name}"
}

# ---------------------------------------------------------------------------
# 1. Non-root, --persistence, default state
# ---------------------------------------------------------------------------

@test "enumerate_run --persistence: non-root shows skip markers on system lines" {
  # Force the non-root gate. (In CI the tester is almost always
  # non-root anyway, but we override explicitly for determinism.)
  utils_has_sudo() { return 1; }

  run enumerate_run --persistence
  [ "${status}" -eq 0 ]

  # Tier 1 header present.
  echo "${output}" | grep -qx 'TIER 1 — PERSISTENCE (live)'

  # Every documented label present.
  for label in \
      'LaunchAgents (user):' \
      'LaunchAgents (system):' \
      'LaunchDaemons:' \
      'launchctl jobs (user):' \
      'launchctl jobs (system):' \
      'BTM records:' \
      'cron entries:' \
      'periodic (non-Apple):' \
      'login hooks:' \
      'auth plugins (non-Apple):' \
      'emond rules:' ; do
    echo "${output}" | grep -q "${label}"
  done

  # System-scoped lines must carry the no-sudo skip marker. We use
  # -F (fixed-string) matching here because several labels contain
  # literal parentheses (e.g. "auth plugins (non-Apple)") which would
  # need escaping under -E.
  for sys_label in \
      'LaunchAgents (system):' \
      'LaunchDaemons:' \
      'launchctl jobs (system):' \
      'cron entries:' \
      'auth plugins (non-Apple):' \
      'emond rules:' ; do
    echo "${output}" | grep -F "${sys_label}" | grep -qF -- '--- (skipped: no sudo)'
  done

  # User launchctl line is numeric (could be 0 or many).
  user_lctl=$(echo "${output}" | awk -F: '/^  launchctl jobs \(user\)/ { gsub(/[[:space:]]/, "", $2); print $2 }')
  [[ "${user_lctl}" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# 2. Shimmed launchctl — user launchctl jobs count = 3
# ---------------------------------------------------------------------------

@test "enumerate_run --persistence: shimmed launchctl yields user job count" {
  utils_has_sudo() { return 1; }

  body=$'PID\tStatus\tLabel\n1\t0\tcom.a\n2\t0\tcom.b\n-\t0\tcom.c\n'
  _install_shim launchctl 0 "$body"

  run enumerate_run --persistence
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -E "^  launchctl jobs \(user\):[[:space:]]+3$"
}

# ---------------------------------------------------------------------------
# 3. BTM skipped on macOS 12
# ---------------------------------------------------------------------------

@test "enumerate_run --persistence: BTM line reports 'macOS < 13' on OS 12" {
  OS_MAJOR_OVERRIDE=12
  export OS_MAJOR_OVERRIDE

  run enumerate_run --persistence
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -E '^  BTM records:[[:space:]]+--- \(skipped: macOS < 13\)$'
}

# ---------------------------------------------------------------------------
# 4. BTM skipped when sudo is missing
# ---------------------------------------------------------------------------

@test "enumerate_run --persistence: BTM line reports 'no sudo' on macOS 13+ without sudo" {
  utils_has_sudo() { return 1; }
  OS_MAJOR_OVERRIDE=13
  export OS_MAJOR_OVERRIDE

  run enumerate_run --persistence
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -E '^  BTM records:[[:space:]]+--- \(skipped: no sudo\)$'
}

# ---------------------------------------------------------------------------
# 5. --preferences in isolation
# ---------------------------------------------------------------------------

@test "enumerate_run --preferences: tier 2 only, system lines skipped" {
  utils_has_sudo() { return 1; }

  # Seed the user Preferences dir with a known number of plists.
  : > "${FAKE_HOME}/Library/Preferences/com.example.a.plist"
  : > "${FAKE_HOME}/Library/Preferences/com.example.b.plist"

  run enumerate_run --preferences
  [ "${status}" -eq 0 ]

  # Tier 2 header must be present.
  echo "${output}" | grep -qx 'TIER 2 — PREFERENCES (live)'

  # Tier 1 header must NOT be present.
  run_failed_grep=0
  echo "${output}" | grep -qx 'TIER 1 — PERSISTENCE (live)' || run_failed_grep=1
  [ "${run_failed_grep}" -eq 1 ]

  # System-scoped lines skipped.
  echo "${output}" | grep -E '^  /Library/Preferences:[[:space:]]+--- \(skipped: no sudo\)$'
  echo "${output}" | grep -E '^  /Library/Managed Preferences:[[:space:]]+--- \(skipped: no sudo\)$'

  # User line is numeric — at least 2 (we just seeded two plists).
  user_val=$(echo "${output}" | awk -F: '/^  ~\/Library\/Preferences/ { gsub(/[[:space:]]/, "", $2); print $2 }')
  [[ "${user_val}" =~ ^[0-9]+$ ]]
  [ "${user_val}" -ge 2 ]
}

# ---------------------------------------------------------------------------
# 6. --all (default with no flag) prints both headers
# ---------------------------------------------------------------------------

@test "enumerate_run (no flag): both tier headers are present" {
  utils_has_sudo() { return 1; }

  run enumerate_run
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -qx 'TIER 1 — PERSISTENCE (live)'
  echo "${output}" | grep -qx 'TIER 2 — PREFERENCES (live)'
}

# ---------------------------------------------------------------------------
# 7. --persistence + --preferences prints both headers
# ---------------------------------------------------------------------------

@test "enumerate_run --persistence --preferences: both tier headers are present" {
  utils_has_sudo() { return 1; }

  run enumerate_run --persistence --preferences
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -qx 'TIER 1 — PERSISTENCE (live)'
  echo "${output}" | grep -qx 'TIER 2 — PREFERENCES (live)'
}

# ---------------------------------------------------------------------------
# 8. Fixture LaunchAgents count (user)
# ---------------------------------------------------------------------------

@test "enumerate_run --persistence: counts *.plist files under \$HOME/Library/LaunchAgents" {
  utils_has_sudo() { return 1; }

  : > "${FAKE_HOME}/Library/LaunchAgents/com.a.plist"
  : > "${FAKE_HOME}/Library/LaunchAgents/com.b.plist"
  # A non-plist file must NOT be counted.
  : > "${FAKE_HOME}/Library/LaunchAgents/README"

  run enumerate_run --persistence
  [ "${status}" -eq 0 ]

  echo "${output}" | grep -E "^  LaunchAgents \(user\):[[:space:]]+2$"
}

# ---------------------------------------------------------------------------
# 9. Exit 0 on every successful run
# ---------------------------------------------------------------------------

@test "enumerate_run: exits 0 for --persistence" {
  utils_has_sudo() { return 1; }
  run enumerate_run --persistence
  [ "${status}" -eq 0 ]
}

@test "enumerate_run: exits 0 for --preferences" {
  utils_has_sudo() { return 1; }
  run enumerate_run --preferences
  [ "${status}" -eq 0 ]
}

@test "enumerate_run: exits 0 for --all" {
  utils_has_sudo() { return 1; }
  run enumerate_run --all
  [ "${status}" -eq 0 ]
}
