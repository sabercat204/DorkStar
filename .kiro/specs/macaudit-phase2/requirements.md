# Requirements Document — macaudit Phase 2

## Introduction

macaudit Phase 2 extends the macOS forensic system configuration auditor with three independent priorities that address the performance, accuracy, and reliability gaps identified during Phase 1 deployment. Phase 1 (29 requirements, 345 tests green) delivered a Bash prototype covering three audit tiers — persistence mechanisms, preference domains, and security databases — with five cross-surface correlation rules, anomaly detection, and a JSONL manifest format. Phase 2 does not alter any Phase 1 requirement (1–29); all Phase 1 acceptance criteria remain in force.

**Priority 1 — Compiled Swift helper (`macaudit-helper`):** Phase 1's per-plist fork overhead (~170ms/entry via `plutil` + `shasum` + `jq` + `xattr`) makes the 30-second target unreachable for machines with 3000+ plist entries. A compiled Swift binary replaces the per-file fork loop with a single invocation that computes dual hashes, detects plist format, extracts xattrs, and optionally projects launch keys or security-critical keys — emitting one JSON object per line on stdout. The Bash layer retains ownership of correlation, injection detection, and manifest assembly; the helper is a pure computation accelerator.

**Priority 2 — Real PPPC profile parsing:** Phase 1 stubs `_baseline_pppc_payloads_json` (returns `MACAUDIT_PPPC_JSON` or `[]`), causing the R1 correlation rule (`tcc_mdm_without_profile`) to fire on every `auth_reason=6` TCC row on MDM-managed devices. Phase 2 replaces the stub with a real parser that extracts `com.apple.TCC.configuration-profile-policy` payload identifiers from `profiles show -type configuration` output, making R1 production-ready.

**Priority 3 — CI pipeline:** Phase 1's test suite (311 bats + 34 pytest) runs locally but has no continuous integration. A GitHub Actions workflow on `macos-14` runners turns the suite into a regression gate on every push and PR.

All three priorities are independent and can be implemented in any order. The existing Phase 1 test suite must continue to pass with or without the Swift helper binary on PATH.

## Glossary (Phase 2 additions)

- **macaudit-helper**: A compiled Swift binary (universal arm64 + x86_64) that performs per-plist computation (dual-hash, format detection, xattr extraction, key projection) as a batch operation, replacing the per-file fork loop in `baseline.sh`.
- **Dual-hash batch**: The operation of computing `sha256_raw` and `sha256_canonical` for a list of plist paths in a single process invocation rather than forking `plutil` + `shasum` + `jq` per file.
- **Key projection**: Extracting a subset of keys from a plist's parsed content — either the Tier 1 launch-key set or the Tier 2 security-critical key set — as part of the helper's per-file output.
- **PPPC (Privacy Preferences Policy Control)**: The MDM payload type (`com.apple.TCC.configuration-profile-policy`) that pre-authorizes TCC access for managed applications.
- **PPPC profile payload identifier**: A bundle ID extracted from the `Identifier` field within a `Services` dict entry of a PPPC configuration profile payload.
- **Configuration profile**: An XML plist installed via MDM or `profiles install`, enumerable via `profiles show -type configuration`.
- **PROFILES_SHOW_OVERRIDE**: An environment variable that, when set to a file path, causes macaudit to read that file instead of invoking `profiles show -type configuration`. Follows the existing override pattern (e.g., `SPCTL_STATUS_OVERRIDE`).
- **CI pipeline**: A GitHub Actions workflow (`.github/workflows/test.yml`) that runs the full test suite on macOS runners as a regression gate.
- **Fallback mode**: The behavior where `baseline.sh` uses the existing per-fork plist processing loop when `macaudit-helper` is not found on PATH, preserving backward compatibility.

## Requirements

### Requirement 30: Swift Helper Binary — Batch Plist Processing

**User Story:** As an operator, I want a compiled Swift helper that processes a batch of plist paths in a single invocation, so that baseline capture completes within the 30-second target on machines with thousands of plists.

#### Acceptance Criteria

1. WHEN `macaudit-helper` is invoked with a list of plist paths on stdin (one path per line), THE macaudit-helper SHALL emit one JSON object per line on stdout, one for each input path.
2. WHEN `macaudit-helper` is invoked with `--input <file>`, THE macaudit-helper SHALL read plist paths from the specified file instead of stdin.
3. FOR ALL valid plist paths `p` in the input, THE macaudit-helper SHALL populate the output JSON with `path`, `sha256_raw`, `sha256_canonical`, `format`, `size_bytes`, `mtime`, and `xattrs`.
4. FOR ALL valid plist paths `p`, THE macaudit-helper SHALL compute `sha256_raw` as the lowercase 64-hex SHA-256 of the file bytes, identical to the value produced by Phase 1's `shasum -a 256` pipeline.
5. FOR ALL valid plist paths `p`, THE macaudit-helper SHALL compute `sha256_canonical` as the lowercase 64-hex SHA-256 of the canonical JSON representation produced by `JSONSerialization` with `.sortedKeys`, identical to the value produced by Phase 1's `plutil -convert json | jq -cS` pipeline.
6. FOR ALL valid plist paths `p`, THE macaudit-helper SHALL detect and report `format` as one of `binary`, `xml`, `json`, or `invalid`.
7. FOR ALL valid plist paths `p`, THE macaudit-helper SHALL extract all extended attributes and report them in `xattrs` as a JSON object mapping attribute names to base64-encoded values, identical to Phase 1's xattr extraction.
8. WHEN `--projection launch-keys` is specified, THE macaudit-helper SHALL include a `content` field containing only the Tier 1 launch-key subset (`Label`, `Program`, `ProgramArguments`, `RunAtLoad`, `KeepAlive`, `WatchPaths`, `StartInterval`, `StartCalendarInterval`, `MachServices`, `Sockets`, `UserName`, `GroupName`).
9. WHEN `--projection security-keys` is specified with `--domain <domain>`, THE macaudit-helper SHALL include a `content` field containing only the security-critical keys defined for that domain in the Security-Critical Key Map.
10. WHEN no `--projection` is specified, THE macaudit-helper SHALL omit the `content` field from the output.
11. IF a plist path does not exist or is unreadable, THEN THE macaudit-helper SHALL emit a JSON object with `path`, `error` set to a descriptive string, `sha256_raw` set to empty string, `sha256_canonical` set to empty string, and `format` set to `"invalid"`.
12. IF a file fails plist deserialization, THEN THE macaudit-helper SHALL emit a JSON object with `format: "invalid"`, `sha256_raw` populated from raw bytes, `sha256_canonical` set to empty string, and `content` set to an empty object.

### Requirement 31: Swift Helper — Hash Equivalence Invariant

**User Story:** As an operator, I want the Swift helper's hashes to be byte-identical to the Bash pipeline's hashes for every plist, so that switching to the helper does not invalidate existing baselines.

#### Acceptance Criteria

1. FOR ALL valid plist files `f`, THE macaudit-helper's `sha256_raw` output SHALL be byte-identical to the output of `shasum -a 256 < f | awk '{print $1}'`.
2. FOR ALL valid plist files `f` that pass `plutil -lint`, THE macaudit-helper's `sha256_canonical` output SHALL be byte-identical to the output of `plutil -convert json -o - f | jq -cS '.' | shasum -a 256 | awk '{print $1}'`.
3. FOR ALL valid plist files `f`, THE macaudit-helper's `format` output SHALL agree with Phase 1's format detection logic (binary plist magic bytes → `"binary"`, XML declaration → `"xml"`, JSON opening brace/bracket → `"json"`, otherwise → `"invalid"`).
4. FOR ALL valid plist files `f`, THE macaudit-helper's `xattrs` output SHALL be identical to Phase 1's `xattr -l` + base64 encoding pipeline.
5. FOR ALL plist files `f` processed by both the helper and the Bash fallback, the resulting manifest entry (after `baseline.sh` merges correlation fields) SHALL be identical regardless of which code path produced the per-file fields (round-trip equivalence).

### Requirement 32: Swift Helper — Build and Distribution

**User Story:** As an operator, I want the Swift helper to build from source via `swift build` or ship as a pre-built universal binary, so that I can use it on both Apple Silicon and Intel Macs without a separate toolchain.

#### Acceptance Criteria

1. THE macaudit-helper source SHALL reside under `macaudit/helper/` with a `Package.swift` targeting Swift 5.9+ and macOS 13+.
2. WHEN `swift build -c release` is invoked in the `macaudit/helper/` directory, THE build system SHALL produce a `macaudit-helper` binary.
3. THE macaudit-helper binary SHALL be buildable as a universal binary (arm64 + x86_64) via `swift build -c release --arch arm64 --arch x86_64`.
4. THE macaudit-helper SHALL depend only on Apple platform frameworks (Foundation, CryptoKit, System) and SHALL NOT introduce any third-party Swift package dependencies.
5. THE macaudit-helper SHALL target macOS 13+ (Ventura), matching Phase 1's platform requirement.

### Requirement 33: Swift Helper — Read-Only Invariant

**User Story:** As an operator, I want the Swift helper to uphold the same read-only guarantee as the Bash tool, so that it is safe to run on production and evidence systems.

#### Acceptance Criteria

1. FOR ALL input paths `p`, THE macaudit-helper SHALL open `p` in read-only mode and SHALL NOT modify, rename, move, or delete `p`.
2. THE macaudit-helper SHALL NOT write to any path other than stdout and stderr.
3. THE macaudit-helper SHALL NOT open any network connection.
4. FOR ALL input paths `p`, the byte content of `p` SHALL be identical before and after the macaudit-helper processes it.

### Requirement 34: Swift Helper — Bash Integration and Fallback

**User Story:** As an operator, I want `baseline.sh` to use the Swift helper when available and fall back to the existing per-fork loop when it is not, so that the tool works on systems without the compiled binary.

#### Acceptance Criteria

1. WHEN `macaudit-helper` is found on PATH or at `macaudit/helper/.build/release/macaudit-helper`, THE baseline module SHALL invoke it as a single fork to process all plist paths for the current tier, replacing the per-file loop.
2. WHEN `macaudit-helper` is not found on PATH and not at the local build path, THE baseline module SHALL fall back to the existing per-file fork loop with no change in output.
3. FOR ALL baseline runs, THE manifest output SHALL be identical regardless of whether the helper or the fallback path was used (modulo JSON key ordering within each entry, which is normalized by `jq -cS`).
4. WHEN the helper is used, THE baseline module SHALL log `[i] using macaudit-helper (compiled)` to stderr at verbosity level 1 or higher.
5. WHEN the fallback is used, THE baseline module SHALL log `[i] using per-file fallback (no macaudit-helper on PATH)` to stderr at verbosity level 1 or higher.
6. THE existing bats test suite (311 tests) SHALL pass with the helper absent from PATH (fallback mode).
7. THE existing bats test suite SHALL pass with the helper present on PATH (accelerated mode).

### Requirement 35: Swift Helper — Performance Target

**User Story:** As an operator, I want the helper to process 3000 plist entries in under 30 seconds, so that real-world baseline capture is practical on large fleets.

#### Acceptance Criteria

1. WHEN processing 3000 synthetic plist files (mixed binary, XML, and JSON formats, sizes 100B–50KB), THE macaudit-helper SHALL complete in under 10 seconds of wall-clock time on an Apple M1 or later.
2. WHEN `baseline.sh` uses the helper to capture a `--tier all --user-only` baseline over 3000 synthetic entries, THE end-to-end wall-clock time SHALL be under 30 seconds on an Apple M1 or later.
3. THE macaudit-helper SHALL process each plist path with amortized cost under 10ms per entry when processing batches of 1000 or more paths.


### Requirement 36: PPPC Profile Parsing — Payload Extraction

**User Story:** As an operator, I want macaudit to parse real PPPC configuration profiles from `profiles show -type configuration`, so that the R1 correlation rule only fires when a TCC `auth_reason=6` entry genuinely lacks a matching MDM profile — not on every MDM-granted row.

#### Acceptance Criteria

1. WHEN macaudit runs on an MDM-managed device with Tier 3 enabled, THE macaudit SHALL invoke `profiles show -type configuration` and parse the XML plist output.
2. WHEN parsing the profiles output, THE macaudit SHALL extract every payload whose `PayloadType` equals `"com.apple.TCC.configuration-profile-policy"`.
3. FOR ALL extracted PPPC payloads, THE macaudit SHALL extract the `Services` dictionary and, for each service key, collect the `Identifier` value from every entry in that service's array.
4. THE macaudit SHALL populate `env.pppc_profile_payload_identifiers` with the union (deduplicated) of all extracted identifiers across all PPPC payloads and all service keys.
5. WHEN the device is not MDM-managed (as reported by `utils_mdm_managed`), THE macaudit SHALL skip profile parsing and set `env.pppc_profile_payload_identifiers` to an empty array.
6. THE macaudit SHALL replace the existing `_baseline_pppc_payloads_json` stub with the real implementation while preserving the `MACAUDIT_PPPC_JSON` override for test harnesses.

### Requirement 37: PPPC Profile Parsing — Edge Cases

**User Story:** As an operator, I want PPPC parsing to handle every edge case gracefully, so that macaudit never crashes or produces false positives due to unexpected profile state.

#### Acceptance Criteria

1. IF no configuration profiles are installed on the device, THEN THE macaudit SHALL set `env.pppc_profile_payload_identifiers` to an empty array and SHALL NOT emit an error.
2. IF the `profiles` command is unavailable or exits non-zero, THEN THE macaudit SHALL log a warning to stderr, set `env.pppc_profile_payload_identifiers` to an empty array, and continue.
3. IF the `profiles show -type configuration` output is not valid XML plist, THEN THE macaudit SHALL log a warning to stderr, set `env.pppc_profile_payload_identifiers` to an empty array, and continue.
4. IF a PPPC payload contains an empty `Services` dictionary, THEN THE macaudit SHALL contribute zero identifiers from that payload and SHALL NOT emit an error.
5. IF a service entry within a PPPC payload lacks an `Identifier` field, THEN THE macaudit SHALL skip that entry and log a warning to stderr.
6. IF multiple PPPC payloads across different profiles contain the same `Identifier`, THE macaudit SHALL include that identifier exactly once in the union set (deduplication).

### Requirement 38: PPPC Profile Parsing — Test Override

**User Story:** As an operator or test author, I want to inject synthetic `profiles show` output via an environment variable, so that the PPPC parser is testable without MDM enrollment.

#### Acceptance Criteria

1. WHEN the `PROFILES_SHOW_OVERRIDE` environment variable is set to a file path, THE macaudit SHALL read that file instead of invoking `profiles show -type configuration`.
2. WHEN `PROFILES_SHOW_OVERRIDE` is set to a file that does not exist, THE macaudit SHALL log a warning and fall back to an empty identifier array.
3. WHEN `MACAUDIT_PPPC_JSON` is set (the Phase 1 override), THE macaudit SHALL use its value directly as the identifier array, bypassing both the real parser and `PROFILES_SHOW_OVERRIDE`.
4. THE override precedence SHALL be: `MACAUDIT_PPPC_JSON` (highest) → `PROFILES_SHOW_OVERRIDE` → live `profiles show` invocation (lowest).

### Requirement 39: PPPC Profile Parsing — R1 Correlation Accuracy

**User Story:** As an operator, I want the R1 correlation rule to use the real PPPC identifier set, so that `tcc_mdm_without_profile` findings are genuine indicators of MDM policy gaps rather than noise from an empty stub.

#### Acceptance Criteria

1. WHEN the R1 correlation rule evaluates a TCC `access` row with `auth_reason = 6`, THE macaudit SHALL check the row's `client` field against the `env.pppc_profile_payload_identifiers` set populated by the real PPPC parser (or override).
2. FOR ALL TCC rows with `auth_reason = 6` whose `client` IS present in `env.pppc_profile_payload_identifiers`, THE macaudit SHALL NOT emit a `tcc_mdm_without_profile` finding for that row.
3. FOR ALL TCC rows with `auth_reason = 6` whose `client` IS NOT present in `env.pppc_profile_payload_identifiers`, THE macaudit SHALL emit a `tcc_mdm_without_profile` finding for that row.
4. WHEN `env.pppc_profile_payload_identifiers` is empty (no profiles, non-MDM device, or parse failure), THE R1 rule SHALL fire for every `auth_reason = 6` row (preserving Phase 1 behavior for the degenerate case).

### Requirement 40: PPPC Profile Parsing — Pretty Printer

**User Story:** As a developer, I want a pretty-printer that serializes a PPPC identifier set back into a valid `profiles show -type configuration` XML plist fragment, so that round-trip property tests can verify the parser.

#### Acceptance Criteria

1. THE macaudit SHALL include a function (or helper) that accepts a list of `(service_key, identifier)` pairs and produces a valid XML plist fragment matching the structure of a `com.apple.TCC.configuration-profile-policy` payload's `Services` dictionary.
2. FOR ALL lists of `(service_key, identifier)` pairs `L`, parsing the pretty-printed XML fragment and extracting identifiers SHALL produce a set equal to the identifiers in `L` (round-trip property).
3. THE pretty-printer SHALL produce well-formed XML that passes `plutil -lint` validation.

### Requirement 41: CI Pipeline — GitHub Actions Workflow

**User Story:** As a developer, I want a GitHub Actions workflow that runs the full test suite on every push and PR, so that regressions are caught before merge.

#### Acceptance Criteria

1. THE macaudit repository SHALL include a `.github/workflows/test.yml` workflow file.
2. WHEN a push to `main` or `master` occurs, THE workflow SHALL trigger and run the test suite.
3. WHEN a pull request targeting `main` or `master` is opened or updated, THE workflow SHALL trigger and run the test suite.
4. THE workflow SHALL run on a `macos-14` (or later) GitHub Actions runner.
5. THE workflow SHALL install dependencies: `bats-core` and `jq` via Homebrew, and `hypothesis` and `pytest` via pip3.
6. THE workflow SHALL execute `bash tests/run.sh` and SHALL fail the workflow if any test fails (non-zero exit code).
7. THE workflow SHALL NOT require any secrets, API keys, or external services beyond GitHub Actions.

### Requirement 42: CI Pipeline — Dependency Caching

**User Story:** As a developer, I want CI dependencies cached across runs, so that the workflow completes faster on repeat runs.

#### Acceptance Criteria

1. THE workflow SHALL cache Homebrew downloads and pip packages between runs using GitHub Actions cache.
2. WHEN the cache is warm, THE dependency installation step SHALL complete faster than a cold install.
3. THE cache key SHALL include a hash of the dependency specification so that cache invalidation occurs when dependencies change.

### Requirement 43: CI Pipeline — Optional Performance Job

**User Story:** As a developer, I want an optional CI job that runs the performance harness, so that I can detect performance regressions without blocking the main test gate.

#### Acceptance Criteria

1. THE workflow SHALL include a separate job (or step) that runs `bash tests/run.sh --perf` after the main test suite passes.
2. THE performance job SHALL use a relaxed target (configurable via environment variable, defaulting to 60 seconds) to account for CI runner variability.
3. IF the performance job fails, THE workflow SHALL report the failure but SHALL NOT block the overall workflow status (the perf job SHALL be marked `continue-on-error`).
4. THE performance job SHALL only run when the main test suite passes.

### Requirement 44: CI Pipeline — Self-Contained Execution

**User Story:** As a developer, I want the CI pipeline to be fully self-contained, so that any contributor can fork the repo and get CI running without additional setup.

#### Acceptance Criteria

1. THE workflow SHALL NOT depend on any repository secrets or environment variables beyond those provided by GitHub Actions by default.
2. THE workflow SHALL NOT make outbound network calls beyond package manager downloads (Homebrew, pip).
3. THE workflow SHALL NOT require manual approval steps or external webhook triggers.
4. THE workflow SHALL include inline comments explaining each step for contributor onboarding.

### Requirement 45: Manifest Version Compatibility

**User Story:** As an operator, I want Phase 2 baselines to remain compatible with Phase 1 tooling, so that upgrading to Phase 2 does not invalidate existing baselines or break the audit/integrity subcommands.

#### Acceptance Criteria

1. THE macaudit SHALL continue to accept baselines with `manifest_version: "1.0"` and `manifest_version: "1.1"` on input to `audit` and `integrity`.
2. WHEN Phase 2 introduces new manifest fields (if any), THE macaudit SHALL set `manifest_version` to `"1.2"` for baselines that include Phase 2-specific data.
3. WHEN a `manifest_version: "1.2"` baseline is passed to a Phase 1 tool, THE Phase 1 tool SHALL reject it with a clear version-mismatch error (per Requirement 18.2).
4. WHEN a `manifest_version: "1.0"` or `"1.1"` baseline is passed to the Phase 2 tool, THE Phase 2 tool SHALL process it without error, treating absent Phase 2 fields as their default values.

### Requirement 46: Swift Helper — Error Reporting

**User Story:** As an operator, I want the Swift helper to report errors as structured JSON on stdout (not stderr crashes), so that `baseline.sh` can handle failures per-file without aborting the entire batch.

#### Acceptance Criteria

1. WHEN the helper encounters a per-file error (unreadable, corrupt, permission denied), THE macaudit-helper SHALL emit a JSON object on stdout with `path`, `error` (descriptive string), and default empty values for hash fields.
2. WHEN the helper encounters a fatal error (invalid arguments, stdin read failure), THE macaudit-helper SHALL print a diagnostic to stderr and exit with a non-zero exit code.
3. THE macaudit-helper SHALL NOT crash (segfault, unhandled exception) on any well-formed input, including empty input, paths containing special characters, symlinks, and zero-byte files.
4. WHEN processing a symlink, THE macaudit-helper SHALL follow the symlink and process the target file (matching Phase 1 behavior).
5. WHEN processing a zero-byte file, THE macaudit-helper SHALL emit a JSON object with `sha256_raw` set to the SHA-256 of empty input (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`), `sha256_canonical` set to empty string, and `format` set to `"invalid"`.

### Requirement 47: Swift Helper — Stdin/Stdout Protocol

**User Story:** As a developer integrating the helper into `baseline.sh`, I want a clear, documented stdin/stdout protocol, so that the Bash layer can pipe paths in and parse results out reliably.

#### Acceptance Criteria

1. THE macaudit-helper SHALL read input as UTF-8 text with one absolute file path per line, terminated by newline (`\n`).
2. THE macaudit-helper SHALL emit output as UTF-8 JSONL with one compact JSON object per line, terminated by newline (`\n`).
3. THE macaudit-helper SHALL preserve input order: the Nth output line SHALL correspond to the Nth input line.
4. WHEN stdin reaches EOF, THE macaudit-helper SHALL flush all remaining output and exit with code 0 (unless a fatal error occurred).
5. THE macaudit-helper SHALL emit a `--version` flag that prints the version string and exits with code 0.
6. THE macaudit-helper SHALL emit a `--help` flag that prints usage information and exits with code 0.

## Phase 1 Requirements (1–29) — Unchanged

All requirements from Phase 1 (Requirements 1–29 in `.kiro/specs/macaudit/requirements.md`) remain in full force. Phase 2 requirements are additive and do not modify, relax, or supersede any Phase 1 acceptance criterion.
