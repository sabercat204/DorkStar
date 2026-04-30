# Implementation Plan: macaudit Phase 2

## Overview

Phase 2 extends macaudit with three independent priorities: a compiled Swift helper for batch plist processing (Priority 1), real PPPC profile parsing in Bash (Priority 2), and a GitHub Actions CI pipeline (Priority 3). Each priority is a self-contained block that can be implemented without the others being complete. The existing 345-test suite must remain green throughout.

## Tasks

### Priority 1 — Swift Helper (`macaudit-helper`)

- [x] 1. Scaffold the Swift package structure
  - [x] 1.1 Create `macaudit/helper/Package.swift` targeting Swift 5.9+, macOS 13+, with executable target `macaudit-helper` and test target `macaudit-helperTests`
    - No external dependencies; only Apple platform frameworks (Foundation, CryptoKit)
    - Directory layout: `Sources/macaudit-helper/`, `Tests/macaudit-helperTests/`
    - _Requirements: 32.1, 32.4, 32.5_
  - [x] 1.2 Create `Sources/macaudit-helper/main.swift` with argument parsing for `--input <file>`, `--projection launch-keys|security-keys`, `--domain <domain>`, `--version`, `--help`
    - Read paths from stdin (one per line, UTF-8) or from `--input` file
    - Exit 0 on `--version`/`--help`, exit 1 on invalid arguments
    - _Requirements: 30.1, 30.2, 47.1, 47.5, 47.6, 46.2_
  - [x] 1.3 Create `Sources/macaudit-helper/JSONOutput.swift` with Codable output model matching the design schema (success shape and error shape)
    - Fields: `path`, `sha256_raw`, `sha256_canonical`, `format`, `size_bytes`, `mtime`, `xattrs`, `content`, `error`
    - Compact JSON serialization (no pretty-printing), one object per line
    - _Requirements: 30.3, 47.2_

- [x] 2. Implement core plist processing
  - [x] 2.1 Create `Sources/macaudit-helper/FormatDetector.swift` — detect plist format via magic bytes
    - Binary plist: `bplist` magic → `"binary"`
    - XML declaration `<?xml` → `"xml"`
    - JSON opening `{` or `[` → `"json"`
    - Otherwise → `"invalid"`
    - _Requirements: 30.6, 31.3_
  - [x] 2.2 Create `Sources/macaudit-helper/HashComputer.swift` — CryptoKit SHA-256 wrappers
    - `sha256_raw`: SHA-256 of raw file bytes, lowercase 64-hex
    - `sha256_canonical`: deserialize plist via `PropertyListSerialization`, re-serialize with `JSONSerialization(.sortedKeys)`, SHA-256 of that JSON
    - Zero-byte file: `sha256_raw` = `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, `sha256_canonical` = `""`
    - Failed deserialization: `sha256_canonical` = `""`
    - _Requirements: 30.4, 30.5, 31.1, 31.2, 46.5_
  - [x] 2.3 Create `Sources/macaudit-helper/XattrExtractor.swift` — read extended attributes via POSIX `listxattr`/`getxattr`
    - Return JSON object mapping attribute names to base64-encoded values
    - Empty object `{}` when no xattrs present
    - _Requirements: 30.7, 31.4_
  - [x] 2.4 Create `Sources/macaudit-helper/KeyProjection.swift` — filter plist keys for launch-keys and security-keys projections
    - Launch-key set: `Label`, `Program`, `ProgramArguments`, `RunAtLoad`, `KeepAlive`, `WatchPaths`, `StartInterval`, `StartCalendarInterval`, `MachServices`, `Sockets`, `UserName`, `GroupName`
    - Security-key set: loaded from the domain-specific key map (matching `lib/surfaces.sh`)
    - Omit `content` field entirely when no projection specified
    - _Requirements: 30.8, 30.9, 30.10_
  - [x] 2.5 Create `Sources/macaudit-helper/PlistProcessor.swift` — orchestrator that ties together format detection, hashing, xattr extraction, and key projection
    - Follow symlinks (process target file, report original path)
    - Handle per-file errors gracefully: emit error JSON, never crash
    - Preserve input order: Nth output corresponds to Nth input
    - _Requirements: 30.1, 30.11, 30.12, 46.1, 46.3, 46.4, 47.3_

- [x] 3. Verify Swift helper builds and passes basic smoke tests
  - [x] 3.1 Verify `swift build -c release` succeeds in `macaudit/helper/`
    - _Requirements: 32.2_
  - [x] 3.2 Create `Tests/macaudit-helperTests/PlistProcessorTests.swift` with XCTest cases covering: valid binary/XML/JSON plists, missing file, zero-byte file, symlink, special characters in path
    - _Requirements: 46.3, 46.4, 46.5_
  - [ ]* 3.3 Write property test `macaudit/tests/pbt/test_p25_hash_equivalence.py`
    - **Property 25: Helper hash equivalence**
    - Generate random plist content via `plistlib` (binary, XML, JSON formats). Invoke helper and Bash pipeline (`shasum -a 256`, `plutil -convert json | jq -cS | shasum -a 256`). Compare `sha256_raw`, `sha256_canonical`, `format`, and `xattrs` fields.
    - Use `max_examples=5`
    - **Validates: Requirements 30.4, 30.5, 30.6, 30.7, 31.1, 31.2, 31.3, 31.4**
  - [ ]* 3.4 Write property test `macaudit/tests/pbt/test_p26_schema_completeness.py`
    - **Property 26: Helper output schema completeness**
    - Generate random valid plists. Invoke helper. Assert all required fields present with correct types.
    - Use `max_examples=5`
    - **Validates: Requirements 30.3**
  - [ ]* 3.5 Write property test `macaudit/tests/pbt/test_p27_order_preservation.py`
    - **Property 27: Helper order and count preservation**
    - Generate random lists of plist paths (1–20 paths). Invoke helper. Assert `output[i].path == input[i]` and `len(output) == len(input)`.
    - Use `max_examples=5`
    - **Validates: Requirements 30.1, 47.3**
  - [ ]* 3.6 Write property test `macaudit/tests/pbt/test_p28_launch_key_projection.py`
    - **Property 28: Launch-key projection scope**
    - Generate plists with random keys including launch keys and non-launch keys. Invoke with `--projection launch-keys`. Assert `content` keys ⊆ launch key set.
    - Use `max_examples=5`
    - **Validates: Requirements 30.8**
  - [ ]* 3.7 Write property test `macaudit/tests/pbt/test_p29_security_key_projection.py`
    - **Property 29: Security-key projection scope**
    - Generate plists with random keys for each known domain. Invoke with `--projection security-keys --domain X`. Assert `content` keys ⊆ domain key set.
    - Use `max_examples=5`
    - **Validates: Requirements 30.9**
  - [ ]* 3.8 Write property test `macaudit/tests/pbt/test_p31_read_only.py`
    - **Property 31: Helper read-only invariant**
    - Generate random plists. Record SHA-256 before helper invocation. Invoke helper. Verify SHA-256 unchanged after.
    - Use `max_examples=5`
    - **Validates: Requirements 33.1, 33.4**
  - [ ]* 3.9 Write property test `macaudit/tests/pbt/test_p36_helper_robustness.py`
    - **Property 36: Helper robustness**
    - Generate random inputs: empty strings, paths with unicode/special chars, symlinks, zero-byte files, non-existent paths. Invoke helper. Assert no crash and valid JSON output on stdout.
    - Use `max_examples=5`
    - **Validates: Requirements 46.3**

- [x] 4. Integrate helper into `lib/baseline.sh`
  - [x] 4.1 Add `_baseline_helper_available` function to `lib/baseline.sh`
    - Check PATH first, then `macaudit/helper/.build/release/macaudit-helper`
    - Set `MACAUDIT_HELPER_PATH` on success, return 0; return 1 if not found
    - _Requirements: 34.1, 34.2_
  - [x] 4.2 Add `_baseline_process_via_helper` function to `lib/baseline.sh`
    - Pipe paths file to `macaudit-helper` with appropriate `--projection` and `--domain` flags
    - Write JSONL output to output file
    - Return 0 on success, 2 on fatal helper error (triggering fallback)
    - _Requirements: 34.1, 34.4_
  - [x] 4.3 Amend `_baseline_tier1_walk` and `_baseline_tier2_walk` to collect paths into a scratch file, dispatch to helper or fallback, and merge results with correlation fields
    - Log `[i] using macaudit-helper (compiled)` or `[i] using per-file fallback (no macaudit-helper on PATH)` at verbosity ≥ 1
    - On helper crash/non-zero exit: log warning, re-process via fallback
    - _Requirements: 34.1, 34.2, 34.3, 34.4, 34.5_
  - [x] 4.4 Add `helper_used` and `helper_version` fields to manifest header environment block when helper is used
    - Bump `manifest_version` to `"1.2"` when Phase 2-specific fields are present
    - _Requirements: 45.1, 45.2, 45.3, 45.4_
  - [ ]* 4.5 Write property test `macaudit/tests/pbt/test_p30_fallback_equivalence.py`
    - **Property 30: Fallback equivalence**
    - Generate random plists. Run baseline with helper on PATH and without. Compare manifest entries field-by-field after `jq -cS` normalization.
    - Use `max_examples=5`
    - **Validates: Requirements 31.5, 34.3**
  - [ ]* 4.6 Write bats tests `macaudit/tests/bats/helper_integration.bats`
    - Test helper discovery (PATH, local build path, not found)
    - Test fallback logging messages
    - Test helper invocation and error recovery (helper crash → fallback)
    - Test manifest header fields (`helper_used`, `helper_version`)
    - _Requirements: 34.1, 34.2, 34.4, 34.5, 34.6, 34.7_
  - [ ]* 4.7 Write bats tests `macaudit/tests/bats/helper_cli.bats`
    - Test `--version`, `--help`, `--input`, `--projection` flags
    - Test fatal error exit codes (invalid arguments, stdin read failure)
    - _Requirements: 47.5, 47.6, 46.2_

- [x] 5. Checkpoint — Verify existing test suite passes
  - Ensure all 345 existing tests pass with helper absent (fallback mode) and with helper present (accelerated mode). Ask the user if questions arise.
  - _Requirements: 34.6, 34.7_

- [ ] 6. Performance verification
  - [ ] 6.1 Create `macaudit/tests/perf/generate_synthetic_plists.sh` — generate 3000 synthetic plist files (mixed binary, XML, JSON; sizes 100B–50KB)
    - _Requirements: 35.1_
  - [ ] 6.2 Extend `macaudit/tests/perf/run.sh` to include helper-standalone benchmark (assert < 10s for 3000 entries) and end-to-end baseline benchmark with helper (assert < 30s)
    - Also run fallback mode (report time, no assertion)
    - _Requirements: 35.1, 35.2, 35.3_
  - [ ]* 6.3 Write bats tests `macaudit/tests/bats/manifest_version.bats`
    - Test version "1.0", "1.1", "1.2" acceptance/rejection
    - Test version bump logic when Phase 2 fields present
    - _Requirements: 45.1, 45.2, 45.3, 45.4_
  - [ ]* 6.4 Write property test `macaudit/tests/pbt/test_p35_version_compat.py`
    - **Property 35: Manifest version backward compatibility**
    - Generate random manifests with version "1.0" and "1.1". Pass to Phase 2 audit/integrity. Assert no error.
    - Use `max_examples=5`
    - **Validates: Requirements 45.1, 45.4**

- [x] 7. Checkpoint — Priority 1 complete
  - Ensure all tests pass (existing 345 + new helper tests). Ask the user if questions arise.

---

### Priority 2 — PPPC Profile Parsing

- [x] 8. Implement PPPC parser in `lib/baseline.sh`
  - [x] 8.1 Implement `_baseline_pppc_parse_profiles` function in `lib/baseline.sh`
    - Accept XML plist string from `profiles show -type configuration`
    - Pipe through `plutil -convert json -o - -` then `jq` to extract all `Identifier` values from PPPC payloads (`PayloadType == "com.apple.TCC.configuration-profile-policy"`)
    - Traverse both `_computerlevel` and `_userlevel` arrays
    - Output: deduplicated, sorted JSON array of identifier strings
    - Handle edge cases: empty input → `[]`, invalid XML → warning + `[]`, empty Services → zero identifiers, missing Identifier field → warning + skip
    - _Requirements: 36.1, 36.2, 36.3, 36.4, 37.1, 37.2, 37.3, 37.4, 37.5, 37.6_
  - [x] 8.2 Replace `_baseline_pppc_payloads_json` stub with real implementation
    - Override precedence: `MACAUDIT_PPPC_JSON` (highest) → `PROFILES_SHOW_OVERRIDE` (file path) → live `profiles show -type configuration` (lowest)
    - Skip parsing on non-MDM devices (`utils_mdm_managed` returns false)
    - Handle `PROFILES_SHOW_OVERRIDE` pointing to non-existent file: warning + empty array
    - _Requirements: 36.5, 36.6, 38.1, 38.2, 38.3, 38.4_
  - [x] 8.3 Implement `_baseline_pppc_pretty_print` function in `lib/baseline.sh`
    - Accept JSON array of `{"service": "...", "identifier": "..."}` objects
    - Output: valid XML plist fragment matching PPPC payload Services structure
    - Output must pass `plutil -lint` validation
    - _Requirements: 40.1, 40.2, 40.3_

- [x] 9. Wire PPPC identifiers into R1 correlation rule
  - [x] 9.1 Update the R1 correlation rule (`tcc_mdm_without_profile`) in `lib/tcc.sh` (or wherever it resides) to check `client` against `env.pppc_profile_payload_identifiers`
    - Emit finding only when `client ∉ pppc_profile_payload_identifiers`
    - Suppress finding when `client ∈ pppc_profile_payload_identifiers`
    - When identifier set is empty: fire for every `auth_reason=6` row (preserves Phase 1 behavior)
    - _Requirements: 39.1, 39.2, 39.3, 39.4_
  - [x] 9.2 Add `pppc_profile_payload_identifiers` to manifest header environment block
    - _Requirements: 36.4_

- [ ] 10. PPPC tests
  - [ ]* 10.1 Write property test `macaudit/tests/pbt/test_p32_pppc_round_trip.py`
    - **Property 32: PPPC round-trip**
    - Generate random lists of `(service_key, identifier)` pairs. Pretty-print to XML via `_baseline_pppc_pretty_print`. Parse back via `_baseline_pppc_parse_profiles`. Assert identifier set equality.
    - Use `max_examples=5`
    - **Validates: Requirements 40.1, 40.2, 40.3**
  - [ ]* 10.2 Write property test `macaudit/tests/pbt/test_p33_pppc_extraction.py`
    - **Property 33: PPPC extraction completeness**
    - Generate random profiles XML with varying PPPC payloads, service keys, and identifiers (including duplicates). Parse. Assert output == deduplicated union of input identifiers.
    - Use `max_examples=5`
    - **Validates: Requirements 36.2, 36.3, 36.4, 37.6**
  - [ ]* 10.3 Write property test `macaudit/tests/pbt/test_p34_r1_correlation.py`
    - **Property 34: R1 correlation accuracy**
    - Generate random TCC rows with `auth_reason=6` and random identifier sets. Run R1 rule. Assert finding emitted iff `client ∉ identifier_set`.
    - Use `max_examples=5`
    - **Validates: Requirements 39.1, 39.2, 39.3**
  - [ ]* 10.4 Write bats tests `macaudit/tests/bats/pppc_parser.bats`
    - Test edge cases: empty profiles, missing Identifier, empty Services, invalid XML, override precedence (`MACAUDIT_PPPC_JSON` > `PROFILES_SHOW_OVERRIDE` > live), non-MDM skip
    - _Requirements: 37.1, 37.2, 37.3, 37.4, 37.5, 38.1, 38.2, 38.3, 38.4_
  - [ ]* 10.5 Write bats tests `macaudit/tests/bats/pppc_pretty_print.bats`
    - Test pretty-printer output validity (`plutil -lint`), round-trip with parser
    - _Requirements: 40.1, 40.2, 40.3_

- [ ] 11. Checkpoint — Priority 2 complete
  - Ensure all tests pass (existing 345 + new PPPC tests). Verify R1 correlation rule no longer fires on MDM-granted rows when PPPC profiles are present. Ask the user if questions arise.

---

### Priority 3 — CI Pipeline

- [x] 12. Create GitHub Actions workflow
  - [x] 12.1 Create `.github/workflows/test.yml` with main test job
    - Trigger on push to `main`/`master` and PRs targeting `main`/`master`
    - Run on `macos-14` runner
    - Cache Homebrew downloads (`~/Library/Caches/Homebrew`) keyed on workflow file hash
    - Cache pip packages (`~/Library/Caches/pip`) keyed on workflow file hash
    - Install dependencies: `bats-core` and `jq` via Homebrew, `hypothesis` and `pytest` via pip3
    - Execute `bash macaudit/tests/run.sh`; fail workflow on non-zero exit
    - No secrets, API keys, or external services required
    - Include inline comments explaining each step
    - _Requirements: 41.1, 41.2, 41.3, 41.4, 41.5, 41.6, 41.7, 42.1, 42.2, 42.3, 44.1, 44.2, 44.3, 44.4_
  - [x] 12.2 Add optional performance job (`perf`) to the workflow
    - Depends on `test` job (runs only after test passes)
    - `continue-on-error: true` — does not block overall workflow
    - Runs `bash macaudit/tests/run.sh --perf` with `MACAUDIT_PERF_TARGET_SECONDS=60`
    - Install same dependencies (no cache sharing needed — separate job)
    - _Requirements: 43.1, 43.2, 43.3, 43.4_

- [x] 13. Checkpoint — Priority 3 complete
  - Verify workflow YAML is valid (use `actionlint` or manual review). Ensure no secrets or external dependencies are required. Ask the user if questions arise.

---

### Final Verification

- [ ] 14. Final checkpoint — Full regression
  - Run the complete test suite (`bash macaudit/tests/run.sh`) with helper absent (fallback mode) and with helper present (accelerated mode). Ensure all existing 345 tests plus all new Phase 2 tests pass. Ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each priority (1, 2, 3) is self-contained and can be implemented independently
- Property tests use `max_examples=5` per project convention from Phase 1
- The existing 345-test suite must remain green throughout all changes
- Property tests P25–P36 are placed adjacent to the module they validate
- Checkpoints ensure incremental validation at natural break points
