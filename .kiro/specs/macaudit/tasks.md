# Implementation Plan: macaudit (Phase 1)

## Overview

This plan decomposes the macaudit Bash prototype into incremental, test-first buildable steps. Work proceeds bottom-up through the `lib/*.sh` module layout defined in the design: primitives first (`utils`, `surfaces`, `manifest`), then data-source wrappers (`cfprefsd`, `persistence`), then subcommand orchestrators (`baseline`, `audit`, `integrity`, `enumerate`), then rendering (`report`), and finally the `macaudit.sh` CLI entry point that wires them together.

**Tier 3 extension**: tasks 15A–15L add the security-database layer (`sqlite`, `tcc`, `sysdb`, `quarantine`, `xprotect`), the SQLite WAL safe-copy protocol, the TCC / authorization / Gatekeeper anomaly rules, the five cross-surface correlation rules, the `[⚑] SUSPICIOUS` delta category, and exit code 3. These tasks extend rather than replace the Tier 1 / Tier 2 modules — the existing algorithms and manifest schema remain in force; new fields (`sha256_checkpointed`, `wal_present`, `wal_sha256`, `table_snapshots`, `anomalies`) appear on Tier 3 entries only, and `manifest_version` bumps to `"1.1"` when Tier 3 is included.

Each task ends with an integration point into a previously-built module — no orphaned code. Property-based tests (P1–P25 from the design's Correctness Properties and its Amended Correctness Properties sections) are placed adjacent to the module they validate so defects surface early. Checkpoints split the work into verifiable milestones.

Testing harness: `bats-core` for unit and integration scenarios; Python 3 + `hypothesis` + `plistlib` (and `sqlite3` stdlib) for plist and SQLite fixture generation driving the property-based tests. Both are development-time only; the shipped tool depends only on macOS built-ins plus `jq`.

Tasks marked with `*` are optional and may be skipped for a faster MVP.

## Tasks

- [x] 1. Project scaffolding and test harness
  - Create `macaudit.sh` stub with `set -euo pipefail`, executable bit, and a placeholder `main` that prints usage and exits 2.
  - Create `lib/` with empty `utils.sh`, `surfaces.sh`, `manifest.sh`, `cfprefsd.sh`, `persistence.sh`, `baseline.sh`, `audit.sh`, `integrity.sh`, `enumerate.sh`, `report.sh`.
  - Create `tests/` with `tests/bats/`, `tests/fixtures/plists/`, `tests/fixtures/launchctl/`, `tests/bin/` (for PATH-shim stubs of `defaults`, `launchctl`, `sfltool`), `tests/pbt/` (Python hypothesis harness).
  - Add `manifests/` and `reports/` to `.gitignore`.
  - Add a `Makefile` or `tests/run.sh` that runs `bats tests/bats` and `python3 -m pytest tests/pbt` (or equivalent hypothesis runner).
  - _Requirements: 15.6_

  - [ ]* 1.1 Wire bats-core and hypothesis into CI
    - Document local install: `brew install bats-core jq`, `pip install hypothesis`.
    - Add a GitHub Actions workflow on `macos-14` that installs jq + bats + hypothesis and runs `tests/run.sh`.
    - _Requirements: 15.6_

- [x] 2. Implement `lib/utils.sh` primitives
  - [x] 2.1 Hashing, plist format, canonicalization
    - Implement `utils_sha256_file`, `utils_sha256_stdin` (both using `shasum -a 256 | awk '{print $1}'`, lowercase 64-hex or empty string on error).
    - Implement `utils_plist_format` (calls `plutil -lint` and `plutil -convert json -o -` probes; returns `binary|xml|json|invalid`).
    - Implement `utils_plist_valid` (exit 0/1 wrapper around `plutil -lint`).
    - Implement `utils_plist_to_canonical_json` using `plutil -convert json -o - -- "$path" | jq -cS '.'`.
    - _Requirements: 2.1, 2.2, 2.6, 2.7_

  - [x] 2.2 File metadata, xattrs, environment
    - Implement `utils_file_size`, `utils_file_mtime_iso`.
    - Implement `utils_xattrs_json` producing `{xattr_name: base64_value}` via `xattr -l`/`xattr -px` piped through `jq -Rn`; empty object when no xattrs.
    - Implement `utils_os_version`, `utils_os_major` (from `sw_vers`), `utils_sip_status` (from `csrutil status`), `utils_ssv_status`, `utils_hostname`, `utils_iso_now`.
    - Implement `utils_has_sudo` (checks effective uid 0).
    - Implement `utils_require_bash` aborting with exit 2 if `BASH_VERSINFO` < 3.2.
    - _Requirements: 15.3, 15.4, 15.5, 20.1, 20.2, 20.3, 20.4, 21.1, 21.2_

  - [x] 2.3 Logging, tty/color, temp-dir lifecycle
    - Implement `utils_log_info/warn/err/skip` writing to stderr with `[i]`, `[!]`, `[x]`, `[skip]` prefixes.
    - Implement `utils_tty_supports_color` (guarded by `[ -t 1 ]` and `tput colors` >= 8).
    - Implement `utils_color` returning `tput` sequences for `red|green|yellow|reset|bold` (empty string when tty does not support color).
    - Implement `utils_tmpdir_init`/`utils_tmpdir_path`/`utils_tmpdir_cleanup` with an `EXIT` + `INT` trap that removes the tmpdir.
    - _Requirements: 8.4, 19.1, 19.2_

  - [x]* 2.4 Unit tests for utils.sh
    - Verify `utils_sha256_file` on fixtures with known SHA-256 values.
    - Verify `utils_plist_format` returns `binary`, `xml`, `json`, `invalid` for the four corresponding fixture plists.
    - Verify `utils_xattrs_json` on a fixture with `com.apple.quarantine` attached.
    - Verify tmpdir is removed after EXIT and after SIGINT in a subshell.
    - _Requirements: 2.1, 2.2, 2.6, 19.1, 21.1, 21.2_

  - [x]* 2.5 Property test P1: raw-hash sensitivity
    - **Property 1: `sha256_raw(f) ≠ sha256_raw(m(f))` for any byte-level mutation m.**
    - Hypothesis strategy generates random plist bytes; for each, flip a random byte and assert `utils_sha256_file` produces a different value.
    - **Validates: Requirements 2.1, 2.3**

  - [x]* 2.6 Property test P2: canonical-hash format invariance
    - **Property 2: `sha256_canonical(p) = sha256_canonical(c(p))` for every valid format conversion c ∈ {binary↔xml, xml↔json, binary↔json}.**
    - Hypothesis generates a dict, serialises it to binary/xml/json via `plistlib`, and asserts `utils_plist_to_canonical_json | sha256` is equal across all three encodings.
    - **Validates: Requirements 2.2, 2.4, 6.6**

  - [x]* 2.7 Property test P3: canonical-hash semantic sensitivity
    - **Property 3: `sha256_canonical(p) ≠ sha256_canonical(μ(p))` for any semantic mutation μ (key add, key remove, value change).**
    - Hypothesis generates plist dicts and a mutation drawn from `{add_key, remove_key, change_value}`; asserts the canonical hash changes.
    - **Validates: Requirements 2.5**

- [x] 3. Implement `lib/surfaces.sh` — canonical path and key tables
  - [x] 3.1 Path enumerators
    - Implement `surfaces_tier1_system_paths` (LaunchDaemons, system LaunchAgents, cron spool, periodic dirs, login hooks, authorization plugins, emond rules).
    - Implement `surfaces_tier1_user_paths` (`~/Library/LaunchAgents`, user crontab).
    - Implement `surfaces_tier2_system_paths` (`/Library/Preferences`).
    - Implement `surfaces_tier2_user_paths` (`~/Library/Preferences`).
    - Implement `surfaces_tier2_managed_paths` (`/Library/Managed Preferences`).
    - Each function outputs newline-separated absolute globs.
    - _Requirements: 3.1, 5.1_

  - [x] 3.2 Key extraction tables and predicates
    - Implement `surfaces_launch_keys` emitting the exact launch-key set from the design (`Label Program ProgramArguments RunAtLoad KeepAlive WatchPaths StartInterval StartCalendarInterval MachServices Sockets UserName GroupName`).
    - Implement `surfaces_security_keys_for_domain` with the hardcoded Security-Critical Key Map for at least `com.apple.loginwindow`, `com.apple.screensaver`, `com.apple.SoftwareUpdate`, `com.apple.alf`, `.GlobalPreferences`, `com.apple.Safari`.
    - Implement `surfaces_tier_of "$path"` returning `1`, `2`, or empty.
    - Implement `surfaces_is_apple_signed_parent "$path"` (prefix heuristic).
    - _Requirements: 3.2, 5.2, 5.6_

  - [x]* 3.3 Unit tests for surfaces.sh
    - Assert `surfaces_tier_of` maps every path in a fixture set to exactly one tier (or empty for unrecognized paths).
    - Assert `surfaces_security_keys_for_domain` returns a non-empty list for each of the six required domains and an empty list for an unknown domain.
    - Assert `surfaces_launch_keys` emits exactly the 12 launch keys listed in the design.
    - _Requirements: 3.2, 5.2, 5.6, 11.7_

- [x] 4. Implement `lib/manifest.sh` — JSONL read/write
  - [x] 4.1 Header and entry serialisation
    - Implement `manifest_write_header` writing a compact one-line JSON header via `jq -cn --arg`/`--argjson`.
    - Implement `manifest_build_entry` using flag-based argument parsing (`--path`, `--tier`, `--surface`, `--format`, `--sha256-raw`, `--sha256-canonical`, `--size`, `--mtime`, `--xattrs-json`, `--content-json`, `--cfprefsd-match`, `--launchctl-loaded`, `--btm-registered`) emitting exactly one line of JSON through `jq -cn`.
    - Implement `manifest_write_entry` appending one line to an open file descriptor.
    - Ensure `cfprefsd_match`, `launchctl_loaded`, `btm_registered` accept literal `true`, `false`, or `null` and are emitted as JSON booleans/null (not strings).
    - _Requirements: 11.1, 11.7, 11.8, 11.9, 11.10, 11.11_

  - [x] 4.2 Manifest loading and path-keyed lookup
    - Implement `manifest_header "$path"` (first line) and `manifest_entries "$path"` (tail, streaming).
    - Implement `manifest_load "$path"` setting `MACAUDIT_MANIFEST_HEADER` and `MACAUDIT_MANIFEST_ENTRIES_FILE` (a scratch file for streaming lookups — never the full manifest in a bash variable).
    - Implement `manifest_entry_by_path "$path" "$wanted_path"` using `jq -c 'select(.path==$p)'` streaming over the scratch file.
    - _Requirements: 11.1, 11.7_

  - [x]* 4.3 Unit tests for manifest.sh
    - Assert `manifest_build_entry` output parses through `jq .` without error.
    - Assert required fields are present with correct JSON types (boolean, string, array, object, null).
    - Assert `cfprefsd_match=null` and `launchctl_loaded=null` emit literal JSON `null`, not the string `"null"`.
    - _Requirements: 11.10, 11.11_

  - [x]* 4.4 Property test P13: manifest round-trip
    - **Property 13: `parse(serialize(m)) = m` — JSONL write followed by JSONL read produces an equal manifest.**
    - Hypothesis generates a header + list of entries conforming to the schema, serialises via `manifest_write_header`/`manifest_write_entry`, reads via `manifest_header`/`manifest_entries`, and asserts structural equality via `jq -S`.
    - **Validates: Requirements 11.12**

  - [x]* 4.5 Property test P14: tier partitioning
    - **Property 14: `∀ e : e.tier ∈ {1, 2} ∧ e.surface ∈ surfaces_of(e.tier)`.**
    - Hypothesis generates entries over arbitrary surface strings; the property asserts that any entry produced by `manifest_build_entry` via valid inputs satisfies the predicate and that `manifest_build_entry` rejects invalid combinations (returns non-zero / empty).
    - **Validates: Requirements 11.7**

- [x] 5. Checkpoint — primitives ready
  - Ensure all tests pass, ask the user if questions arise.

- [x] 6. Implement `lib/cfprefsd.sh` — disk vs live preference cross-reference
  - [x] 6.1 Domain resolution and live export
    - Implement `cfprefsd_domain_from_path` mapping `/Library/Preferences/com.foo.plist` → `com.foo`, `~/Library/Preferences/.GlobalPreferences.plist` → `NSGlobalDomain`, and `/Library/Managed Preferences/<user>/com.foo.plist` → `com.foo`.
    - Implement `cfprefsd_live_canonical "$domain" ["$user"]` invoking `defaults export "$domain" -` and routing the output through the same `plutil -convert json | jq -cS` pipeline as the disk side, returning the lowercase 64-hex canonical hash, or empty string when export fails / is empty / is `{}`.
    - Implement `cfprefsd_available` exit-0/1 probe.
    - _Requirements: 6.1, 6.6_

  - [x] 6.2 Compare and classify
    - Implement `cfprefsd_compare` returning `true`, `false`, or `null` per the design's truth table.
    - Unknown/empty domain → `null`. Empty live export → `null`. Both defined and equal → `true`. Both defined and differ → `false`.
    - _Requirements: 6.2, 6.3, 6.4, 6.5_

  - [x]* 6.3 Unit tests for cfprefsd.sh using PATH-shim `defaults`
    - Place `tests/bin/defaults` shim on `PATH`; assert `cfprefsd_live_canonical` returns empty when shim exits non-zero, when output is empty, and when output is `{}`.
    - Assert `cfprefsd_compare` returns `true` / `false` / `null` for the nine cells of the (disk, live) hash-defined/undefined/equal/unequal matrix.
    - _Requirements: 6.2, 6.3, 6.4, 6.5_

  - [x]* 6.4 Property test P9: cfprefsd symmetry
    - **Property 9: `cfprefsd_match(d) = true ⟺ sha256_canonical(disk(d)) = sha256_canonical(live(d))` when both hashes are defined.**
    - Hypothesis generates random preference dicts, writes them to disk and into the `defaults` shim; asserts `cfprefsd_compare` returns `true` iff the dicts are semantically identical.
    - **Validates: Requirements 6.2, 6.3, 6.6**

- [x] 7. Implement `lib/persistence.sh` — three-view correlation and injection detection
  - [x] 7.1 Snapshot collectors
    - Implement `persistence_collect_launchctl_user` emitting TSV `label\tpid\tstatus` (parsed from `launchctl list`).
    - Implement `persistence_collect_launchctl_system` gated on sudo; emits the same TSV schema.
    - Implement `persistence_collect_btm` invoking `sfltool dumpbtm` on macOS 13+, emitting JSONL BTM records; returns empty on macOS < 13.
    - Each collector runs exactly once per baseline invocation; callers pass the cached snapshot file path onward.
    - _Requirements: 3.7, 15.5_

  - [x] 7.2 Label extraction and correlation
    - Implement `persistence_extract_label "$plist"` returning the `Label` field via `plutil -extract Label raw -o - --` (empty on absent).
    - Implement `persistence_correlate "$label" "$launchctl_tsv" "$btm_jsonl"` returning `{launchctl_loaded, btm_registered}` JSON, with `btm_registered: null` on macOS < 13.
    - _Requirements: 3.3, 3.4, 3.5_

  - [x] 7.3 Injection detection via set difference
    - Implement `persistence_detect_injections "$on_disk_labels_file" "$launchctl_labels_file"` as `comm -23 <(sort -u launchctl) <(sort -u on_disk)` — the labels in launchctl but not on disk.
    - Must guarantee disjoint output from `on_disk_labels`.
    - _Requirements: 4.1, 4.3, 4.4, 4.5_

  - [ ]* 7.4 Unit tests for persistence.sh
    - Assert `persistence_detect_injections` on three fixtures: identical sets → empty output; disjoint sets → full launchctl set; overlapping sets → just the launchctl-only elements.
    - Assert `persistence_correlate` emits `btm_registered: null` when `OS_MAJOR_OVERRIDE=12`.
    - _Requirements: 3.5, 4.3_

  - [x]* 7.5 Property test P7: injection soundness
    - **Property 7: `ℓ ∈ injections(S)` ⟹ `ℓ ∈ launchctl_labels(S) ∧ ℓ ∉ on_disk_labels(S)`.**
    - Hypothesis generates two sets of labels (on_disk, launchctl); asserts every label in `persistence_detect_injections` output is in launchctl and not in on_disk.
    - **Validates: Requirements 4.5**

  - [x]* 7.6 Property test P8: injection completeness
    - **Property 8: `ℓ ∈ launchctl_labels(S) ∧ ℓ ∉ on_disk_labels(S)` ⟹ `ℓ ∈ injections(S)`.**
    - Hypothesis generates the same sets; asserts every label in `launchctl \ on_disk` appears in the injections output.
    - **Validates: Requirements 4.4**

- [x] 8. Implement `lib/baseline.sh` — capture orchestrator
  - [x] 8.1 Tier 1 plist walk
    - Implement `baseline_run --tier --user-only --output` dispatch.
    - Snapshot `launchctl` (user + system-when-sudo) and BTM (when sudo and macOS ≥ 13) once per run.
    - Walk every Tier 1 path; for each readable plist compute `dual_hash`, extract launch keys via `surfaces_launch_keys`, read xattrs, derive `launchctl_loaded` / `btm_registered`, and write a scratch entry via `manifest_build_entry` with `cfprefsd_match=null`.
    - For unreadable paths, append `{path, reason: "permission-denied"}` to the skipped list.
    - When `--user-only` is set, skip system paths without recording them; when sudo is unavailable and `--user-only` is not set, record each system-root surface with `reason: "no-sudo"`.
    - _Requirements: 1.1, 1.3, 1.6, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 13.1, 13.3, 13.4, 17.1, 17.2, 21.1, 21.2_

  - [x] 8.2 Cron, periodic, login hooks, authplugins, emond
    - Emit one manifest entry per cron entry (user + root crontabs), per non-Apple periodic script, per login hook plist, per non-Apple authorization plugin, per emond rule — each with `tier=1` and the matching `surface` value.
    - Surface code paths that require sudo behave the same as §8.1 when sudo is absent.
    - _Requirements: 3.1_

  - [x] 8.3 Injection entries
    - After the Tier 1 walk, compute `persistence_detect_injections` over the accumulated on-disk labels vs the cached launchctl snapshot.
    - For each injection label emit one entry with `surface="injection"`, `format="n/a"`, empty hashes, `content={label, pid, status}`, `cfprefsd_match=null`, `launchctl_loaded=true`, and `btm_registered` set per the BTM cache (or `null` on macOS < 13).
    - _Requirements: 4.1, 4.2_

  - [x] 8.4 Tier 2 walk with cfprefsd cross-reference
    - Walk Tier 2 system, user, and managed paths per the `--user-only` / sudo rules.
    - For each readable plist compute `dual_hash`, read xattrs, extract only `surfaces_security_keys_for_domain` keys for `content`, and call `cfprefsd_compare` against the disk canonical hash to populate `cfprefsd_match`.
    - Set `launchctl_loaded=null` and `btm_registered=null` for all Tier 2 entries.
    - _Requirements: 1.4, 5.1, 5.2, 5.3, 5.4, 5.5, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6_

  - [x] 8.5 Header finalization and atomic write
    - Accumulate all entries into a scratch file in the managed tmpdir.
    - After both tiers complete, build the header with fully populated `skipped_paths` and write it as the first line of the output manifest, then concatenate the scratch entries, then `fsync`.
    - Default output path: `manifests/baseline_<YYYYmmdd_HHMMSS>.jsonl`; print the final path to stdout.
    - On SIGINT mid-run, the EXIT trap removes the partial output file so no half-written baseline is left on disk.
    - _Requirements: 1.1, 1.2, 1.5, 1.8, 1.9, 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 13.2, 19.1, 19.2, 19.3, 20.5_

  - [x]* 8.6 Unit tests for baseline.sh orchestration
    - Run baseline against a fixture home with two LaunchAgents, one cron entry, one preference plist, and one `defaults` shim-reported live divergence; assert the resulting manifest has the expected line count and that required fields are populated.
    - Force a read-denied path and assert it appears in `header.skipped_paths`.
    - Force `--user-only` and assert no system paths appear in entries or `skipped_paths`.
    - _Requirements: 1.3, 1.4, 1.5, 1.6, 13.1, 13.3, 13.4_

  - [x]* 8.7 Property test P4: baseline determinism
    - **Property 4: For system state S unchanged between two runs r1 and r2, every `(path, sha256_canonical)` pair is preserved across runs.**
    - Hypothesis generates a fixture tree, takes two baselines back-to-back with no mutation in between, and asserts the set of `(path, sha256_canonical)` pairs is identical (JSONL line order may differ).
    - **Validates: Requirements 1.7**

  - [x]* 8.8 Property test P11: graceful degradation
    - **Property 11: For every permission set π the tool either produces a manifest with `skipped_paths` recording every inaccessible path or exits with code 2 — never silently omits data.**
    - Hypothesis-parameterised test runs baseline under a selection of simulated permission masks (drop read on random subset of fixture paths); asserts that the set of absent-from-entries paths is exactly the set recorded in `skipped_paths`, or that the run exited with code 2.
    - **Validates: Requirements 13.1, 13.2**

  - [x]* 8.9 Property test P15: security-key extraction scope
    - **Property 15: `keys(e.content) ⊆ security_key_map(domain_of(e.path))` for every Tier 2 entry.**
    - Hypothesis generates preference plists containing a mix of security-critical and non-security-critical keys; asserts every emitted Tier 2 entry's `content` keys are a subset of the expected domain map.
    - **Validates: Requirements 5.3**

- [x] 9. Checkpoint — baseline capture end-to-end
  - Ensure all tests pass, ask the user if questions arise.

- [x] 10. Implement `lib/audit.sh` — delta computation
  - [x] 10.1 Re-capture and load
    - Implement `audit_run "$baseline_path" [--output PATH] [--json]`.
    - Validate baseline existence (exit 2 with `[x] baseline not found: ...` when missing) and `manifest_version == "1.0"` (exit 2 with the version-mismatch message otherwise).
    - Re-invoke `baseline_run` with the baseline header's `tier` and `user_only` into a tmpdir-scoped `current.jsonl`.
    - Load both manifests via `manifest_load` and build path → entry lookups streamed through `jq`.
    - _Requirements: 7.1, 18.1, 18.2_

  - [x] 10.2 Delta classification
    - Compute `added`, `removed`, `modified`, `stale`, `injections` per tier following the design's `audit_run` pseudocode and the requirements' exact definitions.
    - `modified` triggers when `sha256_canonical`, `content`, `launchctl_loaded`, or `btm_registered` differ; include a field-level `changes` list.
    - `stale` is populated from Tier 2 current entries with `cfprefsd_match == false`.
    - `injections` is populated from current entries with `surface == "injection"`.
    - Build a `summary` object whose per-tier and total counts equal the sum of category sizes.
    - Enforce disjointness between `added`, `removed`, `modified` within a tier.
    - _Requirements: 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9_

  - [x] 10.3 Exit code semantics
    - Exit 0 when every delta category is empty; exit 1 when any is non-empty; exit 2 on unrecoverable error before comparison; exit 130 on SIGINT (via the shared EXIT/INT trap).
    - _Requirements: 7.10, 7.11, 14.1, 14.2, 14.4, 14.5_

  - [x]* 10.4 Unit tests for audit.sh classification matrix
    - Build a 16-row table over (present-in-baseline × present-in-current × hash-equal × cfprefsd-match) and assert each row lands in exactly the expected category.
    - Assert `summary.total` equals the sum of per-category counts.
    - _Requirements: 7.2, 7.5, 7.8, 7.9_

  - [x]* 10.5 Property test P5: delta partition disjointness
    - **Property 5: Within a single tier, `added ∩ removed = ∅ ∧ added ∩ modified = ∅ ∧ removed ∩ modified = ∅`.**
    - Hypothesis generates baseline and current manifests; asserts pairwise disjointness in every computed delta.
    - **Validates: Requirements 7.8**

  - [x]* 10.6 Property test P6: delta completeness
    - **Property 6: Every path in `B ∪ C` falls into exactly one of `{added, removed, modified, unchanged}`.**
    - Hypothesis generates baseline/current manifests with overlapping and disjoint path sets; asserts coverage and exclusivity.
    - **Validates: Requirements 7.2, 7.3, 7.4, 7.5**

  - [x]* 10.7 Property test P12: exit code correctness
    - **Property 12: `exit_code = 0 ⟺ every category empty; exit_code = 1 ⟺ any non-empty; exit_code = 2 ⟺ unrecoverable error before comparison`.**
    - Hypothesis generates deltas and drives the tool's exit code; asserts the exit status matches the predicate.
    - **Validates: Requirements 7.10, 7.11, 14.1, 14.2, 14.4**

- [x] 11. Implement `lib/integrity.sh` — re-hash and classify
  - [x] 11.1 PASS / FAIL / MISSING / NEW loop
    - Implement `integrity_run "$baseline_path"`.
    - Validate baseline existence and version as in §10.1.
    - For every non-injection baseline entry, compute current `dual_hash`; classify `PASS` iff both `sha256_raw` and `sha256_canonical` match; `FAIL[raw,canonical]` otherwise (reporting which channels changed); `MISSING` when the path no longer exists.
    - Re-capture current state per the baseline's tier/user_only; any current path not in the baseline is classified `NEW`.
    - Print a summary block with per-classification totals and exit 0 when only PASS is present, exit 1 otherwise.
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8, 14.1, 14.3_

  - [x]* 11.2 Unit tests for integrity.sh
    - Run integrity against a baseline whose paths match exactly → every line PASS, exit 0.
    - Mutate one file's bytes → expect `FAIL[raw]` when canonical content is unchanged (e.g., binary↔xml of the same content) and `FAIL[raw,canonical]` when semantics changed.
    - Delete one baselined file → `MISSING`; add a new file to the fixture tree → `NEW`.
    - _Requirements: 10.2, 10.3, 10.4, 10.5, 10.6, 10.7_

- [x] 12. Implement `lib/enumerate.sh` — one-shot live summary
  - [x] 12.1 Persistence and preference counters
    - Implement `enumerate_run [--persistence] [--preferences] [--all]` producing a human summary with counts of LaunchAgents (user, system), LaunchDaemons, launchctl jobs, BTM records, cron entries, non-Apple periodic entries, login hooks, non-Apple authorization plugins, and emond rules (`--persistence`), plus a preference summary (`--preferences`).
    - Unavailable sources (no sudo, macOS < 13) render as `---` with a parenthetical reason.
    - Exit 0 on success.
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x]* 12.2 Unit tests for enumerate.sh
    - Run `enumerate --persistence` under a fixture with shimmed `launchctl` and `sfltool`; assert counts match the fixture.
    - Run without sudo; assert system-scoped lines show `--- (skipped: no sudo)`.
    - Force `OS_MAJOR_OVERRIDE=12`; assert the BTM line shows `--- (skipped: macOS < 13)`.
    - _Requirements: 9.4_

- [x] 13. Implement `lib/report.sh` — terminal and JSON rendering
  - [x] 13.1 Symbol and color rendering
    - Implement `report_symbol` mapping `added → [+]`, `removed → [-]`, `modified → [~]`, `injection → [!]`, `stale → [?]`.
    - Implement `report_color` returning `utils_color` sequences (empty when tty does not support color).
    - _Requirements: 8.1, 8.4_

  - [x] 13.2 Human mode delta rendering
    - Implement `report_render_delta "$delta_json" "$baseline_header" "$current_header" human` printing the per-tier sections, per-entry details with field-level changes, the baseline timestamp and elapsed time since capture, and a summary block.
    - Every field value passes through `jq -Rr`/format strings; no field is ever eval'd or interpolated into a shell command.
    - _Requirements: 8.1, 8.3, 8.5_

  - [x] 13.3 JSON mode and enumerate rendering
    - Implement `report_render_delta ... json` emitting the delta as a single JSON document matching the schema.
    - Implement `report_render_enumeration` for human and JSON modes.
    - _Requirements: 8.2_

  - [x]* 13.4 Unit tests for report.sh
    - Snapshot-test human output against a fixture delta for a known baseline/current pair.
    - Assert `TERM=dumb` and non-tty stdout produce no ANSI escape sequences.
    - Assert JSON mode output parses through `jq .` and matches the delta schema.
    - _Requirements: 8.1, 8.2, 8.4_

- [x] 14. Implement `macaudit.sh` — CLI entry point and wiring
  - [x] 14.1 Preconditions and dispatch
    - Source every `lib/*.sh` exactly once.
    - Call `utils_require_bash` (exit 2 with `[x] macaudit requires bash 3.2 or later. Current: $BASH_VERSION`).
    - Check `jq` on PATH (exit 2 with `[x] macaudit requires jq. Install via: brew install jq`).
    - Log `[!] macOS < 13 — BTM enumeration skipped. Three-view correlation limited to two views.` when `utils_os_major` < 13.
    - Implement the argv dispatcher: `baseline` → `cmd_baseline` → `baseline_run`; `audit` → `cmd_audit` → `audit_run`; `enumerate` → `cmd_enumerate` → `enumerate_run`; `integrity` → `cmd_integrity` → `integrity_run`.
    - Implement `print_usage` and `print_version` (`macaudit 0.1.0-phase1`).
    - Install the global EXIT/INT trap that routes to `utils_tmpdir_cleanup` and returns exit 130 on SIGINT.
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 19.1, 19.2, 19.3_

  - [x] 14.2 Subcommand flag parsing
    - Parse `baseline [--output PATH] [--tier 1|2|all] [--user-only]`, defaulting `--tier all` and `--output manifests/baseline_<ts>.jsonl`.
    - Parse `audit <baseline> [--output PATH] [--json]`.
    - Parse `enumerate [--persistence] [--preferences] [--all]`.
    - Parse `integrity <baseline>`.
    - Reject unknown flags with a usage message and exit 2.
    - _Requirements: 1.3, 1.4, 1.5, 1.6, 1.9, 8.2, 9.1, 9.2, 9.3_

  - [x]* 14.3 Unit tests for macaudit.sh dispatch
    - Assert `macaudit.sh --version` prints `macaudit 0.1.0-phase1` and exits 0.
    - Assert `macaudit.sh` with no arguments prints usage to stderr and exits 2.
    - Assert `macaudit.sh audit /does/not/exist` prints `[x] baseline not found: /does/not/exist` and exits 2.
    - Assert that a fixture baseline with `manifest_version: "0.9"` triggers `[x] baseline version 0.9 not supported by this tool (expected 1.0)` and exit 2.
    - Assert a fixture environment without `jq` (PATH-shim) prints the jq error and exits 2.
    - _Requirements: 15.2, 18.1, 18.2_

- [x] 15. Checkpoint — end-to-end wired (Tier 1 + Tier 2)
  - Ensure all tests pass, ask the user if questions arise.

- [x] 15A. Implement `lib/sqlite.sh` — SQLite WAL safe-copy protocol
  - [x] 15A.1 Safe-copy and checkpoint primitives
    - Implement `sqlite_safe_copy "$db_path"`: copy `.db-shm`, `.db-wal`, then `.db` (in that order) via `cp -p` into a scratch subdir under `MACAUDIT_TMPDIR` named `sqlite_<sha256(db_path)[0..16]>`; run `sqlite3 "<copy>" "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;"` against the copy only.
    - Implement `sqlite_checkpointed_hash "$copy"` via `utils_sha256_file`.
    - Implement `sqlite_query_tsv "$copy" "$sql"` using `sqlite3 -readonly "file:${copy}?mode=ro" -header -separator $'\t' "$sql"`.
    - Implement `sqlite_assert_readonly "$copy"` as a `PRAGMA query_only=1; SELECT 1;` check.
    - _Requirements: 22.5, 23.1, 23.2, 23.3, 23.4, 23.5, 23.7_

  - [x] 15A.2 Table snapshot serialisation and content hashing
    - Implement `sqlite_snapshot_table "$copy" "$table" "$pk_csv" "$columns_csv"` returning a one-line JSON `{row_count, primary_key, content_hash, rows}` object. Rows SHALL be sorted by the declared primary key before serialisation; serialisation uses `jq -cS`.
    - Implement `sqlite_content_hash` as SHA-256 over the canonical JSON of the sorted rows array.
    - Implement `sqlite_wal_sidecar_info "$db_path"` returning `{wal_present: bool, wal_sha256: "..."}` computed from the source `-wal` bytes (empty when absent).
    - _Requirements: 11.13, 11.14, 22.4_

  - [x]* 15A.3 Unit tests for sqlite.sh
    - Build a fixture `.db` + `-wal` pair; assert `sqlite_safe_copy` leaves originals byte-identical (hash before/after).
    - Run `sqlite_safe_copy` twice on the same source; assert the two checkpointed copies produce equal `sha256_checkpointed`.
    - Assert `sqlite_snapshot_table` emits rows sorted by primary key and that `content_hash` is stable across two runs.
    - _Requirements: 23.7, 22.4, 22.5_

  - [x]* 15A.4 Property test P16: SQLite safe-copy soundness
    - **Property 16: Originals `.db`, `.db-wal`, `.db-shm` are byte-identical across the tool run.**
    - Hypothesis generates random fixture databases (via Python's `sqlite3` + `hypothesis.strategies`); asserts `sha256` of every source file before == after `sqlite_safe_copy`.
    - **Validates: Requirements 12.5, 23.7**

  - [x]* 15A.5 Property test P17: SQLite determinism
    - **Property 17: Unchanged row content ⟹ equal `sha256_checkpointed` and equal per-table `content_hash` across runs.**
    - Hypothesis generates a database, runs the safe-copy pipeline twice, asserts equality.
    - **Validates: Requirements 22.4, 22.5**

- [x] 15B. Implement `lib/tcc.sh` — TCC capture + anomaly rules
  - [x] 15B.1 FDA probe and paths
    - Implement `utils_fda_probe` in `lib/utils.sh` (since other modules need it): run `sqlite_safe_copy /Library/Application Support/com.apple.TCC/TCC.db`; invoke `SELECT COUNT(*) FROM access` in read-only mode on the copy; exit 0 iff the query succeeds AND returns a decimal integer.
    - Memoise the probe result in `MACAUDIT_FDA_AVAILABLE` (set once per run).
    - Implement `tcc_system_path` and `tcc_user_path "$home"`.
    - _Requirements: 15.7, 24.1, 24.2, 24.3, 24.5_

  - [x] 15B.2 `access` table capture
    - Implement `tcc_capture_system "$scratch"` and `tcc_capture_user "$home" "$scratch"` emitting one JSONL manifest entry each.
    - Use the query `SELECT service, client, client_type, auth_value, auth_reason, auth_version, last_modified FROM access ORDER BY service, client, client_type, indirect_object_identifier;`.
    - Populate `surface`, `sha256_checkpointed`, `wal_present`, `wal_sha256`, `table_snapshots.access`, `anomalies`.
    - _Requirements: 11.7, 11.13, 11.14, 22.1, 22.3, 22.4, 22.5_

  - [x] 15B.3 TCC anomaly detection
    - Implement `tcc_detect_anomalies "$entry_json" "$pppc_profile_payloads"`:
      - `tcc_override_policy` for every row with `auth_reason = 7` (severity: high).
      - `tcc_av_unusual_reason` for rows where `service ∈ {kTCCServiceCamera, kTCCServiceMicrophone}` and `auth_reason ≠ 2` (severity: warn).
      - `tcc_fda_unsigned` for rows with `service = kTCCServiceSystemPolicyAllFiles`, `client_type = 1`, and `utils_codesign_verify(client).valid = false` (severity: high).
      - `tcc_mdm_without_profile` for rows with `auth_reason = 6` whose `client` is not in the supplied PPPC payloads list (severity: high).
    - Each anomaly is emitted as `{rule, severity, detail}`.
    - _Requirements: 25.1, 25.2, 25.3, 25.4, 25.5_

  - [x]* 15B.4 Unit tests for tcc.sh
    - Seed a fixture TCC.db with one row per anomaly rule; assert each rule fires exactly once.
    - Seed a TCC.db with all clean rows; assert `anomalies` is empty.
    - Seed a TCC.db with `auth_reason=6` and include the `client` in the PPPC fixture; assert the rule does NOT fire.
    - _Requirements: 25.1, 25.2, 25.3, 25.4_

  - [x]* 15B.5 Property test P19: TCC anomaly soundness
    - **Property 19: Every anomaly emitted has a row in `table_snapshots.access` satisfying the rule's preconditions.**
    - Hypothesis generates fixture `access` tables and runs `tcc_detect_anomalies`; asserts each anomaly maps back to a qualifying row.
    - **Validates: Requirements 25.5**

  - [x]* 15B.6 Property test P20: TCC anomaly completeness
    - **Property 20: Every row satisfying a rule's preconditions produces a matching anomaly object.**
    - Hypothesis generates fixture tables deterministically inducing rule hits; asserts bijection.
    - **Validates: Requirements 25.5**

- [x] 15C. Implement `lib/sysdb.sh` — KextPolicy, ExecPolicy, SystemPolicy, AuthDB, Gatekeeper
  - [x] 15C.1 KextPolicy capture
    - Implement `sysdb_capture_kextpolicy "$scratch"` emitting one entry (`surface: "kextpolicy"`) snapshotting both `kext_policy` and `kext_policy_mdm` tables with primary key `(team_id, bundle_id)`.
    - Fires anomaly `kext_user_approved_on_mdm` on MDM-managed devices when a `kext_policy` row has no matching `kext_policy_mdm` row.
    - Gated on FDA availability.
    - _Requirements: 22.1, 22.3, 28.1, 28.7_

  - [x] 15C.2 ExecPolicy capture
    - Implement `sysdb_capture_execpolicy "$scratch"` snapshotting whichever subset of `legacy_exec_history_v4`, `policy_scan_cache`, `provisional_policy` tables exists (use `SELECT name FROM sqlite_master WHERE type='table'` on the checkpointed copy).
    - Emit one entry with `surface: "execpolicy"`.
    - Gated on FDA availability.
    - _Requirements: 22.1, 22.3, 28.2_

  - [x] 15C.3 SystemPolicy + Gatekeeper capture
    - Implement `sysdb_capture_systempolicy "$scratch"` snapshotting `authority` and `bookmarkhints` tables; capture `spctl --status` and `spctl --test-devid-status` into a top-level `gatekeeper` field on the entry.
    - Fires `gatekeeper_disabled` anomaly when `spctl --status` reports `assessments disabled`.
    - _Requirements: 22.1, 22.3, 28.3, 28.5_

  - [x] 15C.4 Authorization DB capture
    - Implement `sysdb_authdb_rule_names` and `sysdb_authdb_right_names` returning the curated set to snapshot (at minimum: `system.login.console`, `system.privilege.admin`, `system.preferences`, `system.install.apple-software`, `com.apple.ServiceManagement`).
    - Implement `sysdb_capture_authdb "$scratch"` invoking `security authorizationdb read <name>` per rule/right, piping through `plutil -convert json -o -`, and emitting one entry per name with `surface: "authdb"`, `format: "authdb"`, `sha256_canonical` of the canonicalised JSON, and `content.mechanisms`, `content.class`, `content.shared`, `content.timeout`, `content.tries` where present.
    - _Requirements: 11.7, 22.1, 22.3, 22.7_

  - [x] 15C.5 Authorization mechanism classification
    - Implement `sysdb_classify_mechanism "$mech"` returning one of `builtin`, `system-plugin`, `third-party-plugin`, `missing` per the design's classification algorithm, using a cached listing of `/System/Library/CoreServices/SecurityAgentPlugins/` and `/Library/Security/SecurityAgentPlugins/`.
    - Fire `authdb_third_party_plugin` (warn) and `authdb_missing_plugin` (high) anomalies on the owning authdb entry.
    - _Requirements: 26.1, 26.2, 26.3, 26.4, 26.5_

  - [x] 15C.6 MDM enrolment probe
    - Implement `utils_mdm_managed` invoking `profiles status -type enrollment 2>/dev/null` and matching the output for `MDM enrollment: Yes` (case-insensitive). Exit 0 iff managed.
    - On pre-10.15 macOS where `profiles` is unavailable, return non-zero and log an informational message.
    - _Requirements: 15.6, 27.1 (R4 gating)_

  - [x]* 15C.7 Unit tests for sysdb.sh
    - Stub `security` and `profiles` via `tests/bin/` shims; assert `sysdb_capture_authdb` output parses through `jq .`.
    - Assert `sysdb_classify_mechanism` returns `builtin` for `builtin:policy-banner`, `system-plugin` for `loginwindow:login` when the fixture bundle is present, `missing` for `MyEvilPlugin:invoke`, `third-party-plugin` when the fixture bundle sits under `/Library/Security/SecurityAgentPlugins/`.
    - Assert `gatekeeper_disabled` anomaly fires when the `spctl` shim reports `assessments disabled`.
    - _Requirements: 26.1, 28.5_

  - [x]* 15C.8 Property test P21: mechanism classification completeness
    - **Property 21: `classify_mechanism` returns exactly one of the four categories and depends only on prefix + plugin listings.**
    - Hypothesis generates mechanism strings + plugin-dir listings; asserts totality and determinism.
    - **Validates: Requirements 26.1**

- [x] 15D. Implement `lib/quarantine.sh` — LSQuarantineEvent capture + xattr decoding
  - [x] 15D.1 LSQuarantineEvent capture
    - Implement `quarantine_capture_user "$home" "$scratch"` emitting one entry with `surface: "quarantine_events"`.
    - Snapshot the `LSQuarantineEvent` table with columns `LSQuarantineEventIdentifier`, `LSQuarantineTimeStamp`, `LSQuarantineAgentBundleIdentifier`, `LSQuarantineAgentName`, `LSQuarantineDataURLString`, `LSQuarantineOriginURLString`, `LSQuarantineTypeNumber`, ordered by `LSQuarantineTimeStamp DESC`.
    - _Requirements: 22.1, 22.3_

  - [x] 15D.2 Quarantine xattr UUID helpers
    - Implement `quarantine_xattr_uuid "$path"` parsing `com.apple.quarantine` as `flag;epochhex;agentname;UUID` and returning the UUID component (empty on absence).
    - Implement `quarantine_lookup_uuid "$checkpointed_copy" "$uuid"` returning exit 0 iff the UUID exists in `LSQuarantineEvent` on the checkpointed copy.
    - _Requirements: 27.1 (R2)_

  - [x]* 15D.3 Unit tests for quarantine.sh
    - Fixture quarantine xattr with known UUID; assert parser returns the correct UUID.
    - Fixture LSQuarantineEvent.db with two rows; assert `quarantine_lookup_uuid` returns 0 for a matching UUID and 1 for an unknown one.

- [x] 15E. Implement `lib/xprotect.sh` — XProtect bundle capture
  - [ ] 15E.1 Bundle traversal and per-file hashing
    - Implement `xprotect_bundle_path` returning `/Library/Apple/System/Library/CoreServices/XProtect.bundle`.
    - Implement `xprotect_version "$bundle"` reading `CFBundleShortVersionString` via `plutil -extract CFBundleShortVersionString raw -o -`.
    - Implement `xprotect_capture "$bundle" "$scratch"` emitting one entry with `surface: "xprotect"`, `format: "bundle"`, per-file `sha256_raw` for every file inside the bundle, and a `codesign` subobject from `utils_codesign_verify`.
    - _Requirements: 22.6, 28.4_

  - [ ] 15E.2 Codesign check and anomaly
    - Implement `utils_codesign_verify "$path"` in `lib/utils.sh` returning JSON `{valid, exit_code, stderr_first_line}` from `codesign --verify --deep --strict -- "$path"`.
    - Fire `xprotect_codesign_fail` (severity: high) when the bundle fails codesign.
    - _Requirements: 28.6_

  - [ ]* 15E.3 Unit tests for xprotect.sh
    - Point `XPROTECT_BUNDLE_OVERRIDE` (test hook) at a fixture bundle; assert per-file hashes match known values.
    - Stub `codesign` to return non-zero; assert `xprotect_codesign_fail` fires.

- [x] 15F. Extend `lib/baseline.sh` with Tier 3 walk and cross-surface correlation
  - [x] 15F.1 Tier 3 block integration
    - Add `baseline_run_tier3 "$scratch" "$has_sudo" "$fda_available"` orchestrating TCC system + per-user, KextPolicy, ExecPolicy, SystemPolicy, AuthDB, XProtect, per-user quarantine captures.
    - Gate FDA-protected surfaces (system TCC, KextPolicy, ExecPolicy) on `$fda_available`; gate system SystemPolicy on `$has_sudo`.
    - Record skipped surfaces with the correct `reason` (`fda-unavailable`, `no-sudo`, `macos-too-old`, `permission-denied`).
    - _Requirements: 1.5, 13.5, 15.7, 22.1, 22.2, 24.1, 24.3, 24.4, 24.5, 24.6_

  - [x] 15F.2 Cross-surface correlation pass (R1–R5)
    - Implement `baseline_correlate "$tier1_entries_file" "$tier3_entries_file" "$env_file"` implementing R1–R5 per the design's `cross_surface_correlate` algorithm.
    - Emit correlation entries with `surface: "correlation"`, `path: "correlation://<rule_id>:<rule_name>"`, and `anomalies` populated with one object per rule hit.
    - Cache the plugin-directory listing once per run.
    - _Requirements: 27.1, 27.2, 27.3, 27.4, 27.5_

  - [x] 15F.3 Header upgrade to `manifest_version: "1.1"` and environment block
    - Populate `header.manifest_version` with `"1.1"` whenever Tier 3 entries are included.
    - Populate `header.fda_available` and `header.environment = {fda_available, has_sudo, gatekeeper_enabled, mdm_managed, xprotect_version}` from the probes.
    - _Requirements: 11.2, 11.3, 20.6, 20.7_

  - [ ]* 15F.4 Unit tests for Tier 3 orchestration
    - Run `baseline_run_tier3` with a fixture scratch directory and shimmed `sqlite3`/`security`/`profiles`/`spctl`/`codesign`; assert every expected entry type is emitted.
    - Run without FDA; assert `fda-unavailable` entries appear in `skipped_paths` and no FDA-protected entries are present in the body.
    - _Requirements: 13.5, 24.3, 24.4_

  - [x]* 15F.5 Property test P22/P23: correlation soundness + completeness
    - **Property 22/23: Every correlation entry matches its rule's preconditions; every qualifying state produces at least one correlation entry.**
    - Hypothesis generates `(tier1_entries, tier3_entries, env)` triples with known rule hits; asserts bijection between preconditions and emitted correlation entries.
    - **Validates: Requirements 27.5**

- [x] 15G. Extend `lib/audit.sh` — suspicious category + exit code 3
  - [x] 15G.1 Suspicious classification
    - Add `delta.tiers.<t>.suspicious` arrays populated from current-state entries with non-empty `anomalies`.
    - Enforce: `e ∈ delta.suspicious ⟺ e.anomalies ≠ ∅` in the current state.
    - Update `summary.<tier>.suspicious` and `summary.total.suspicious`.
    - _Requirements: 29.1, 29.2, 29.4_

  - [x] 15G.2 Exit code 3 plumbing
    - Exit 3 when any delta category is non-empty AND `|suspicious| > 0`.
    - Exit 1 when any delta category is non-empty AND `|suspicious| = 0`.
    - Exit 0 when every delta category is empty (including suspicious).
    - _Requirements: 7.12, 14.5_

  - [x]* 15G.3 Property test P24: suspicious well-definedness
    - **Property 24: `delta.suspicious` is a function of the current manifest alone.**
    - Hypothesis generates current manifests with arbitrary `anomalies` fields; asserts `delta.suspicious` is exactly the entries with non-empty `anomalies`.
    - **Validates: Requirements 29.2**

- [x] 15H. Extend `lib/report.sh` — `[⚑] SUSPICIOUS` section
  - [x] 15H.1 Suspicious symbol, color, section header
    - Extend `report_symbol` with `suspicious → [⚑]`.
    - Extend `report_color` with `suspicious → magenta` (`tput setaf 5`); empty when tty does not support color.
    - _Requirements: 8.6, 29.3_

  - [x] 15H.2 Suspicious section rendering
    - Add a `TIER <n> SUSPICIOUS` subsection per tier (and a top-level `[⚑] CROSS-SURFACE CORRELATION` block for surface `correlation`) before the summary.
    - Render each finding with `path`, `rule`, `severity`, and `detail`.
    - Update the summary block to include `suspicious: <count>` per tier and in the total line.
    - _Requirements: 8.6, 29.3, 29.4_

  - [x]* 15H.3 Unit tests for report.sh suspicious rendering
    - Snapshot-test human output on a fixture delta with one anomaly per tier; assert the `[⚑]` section is rendered before the summary and magenta escape sequences are absent on `TERM=dumb`.
    - Assert the summary line includes `suspicious: N`.
    - _Requirements: 8.6, 29.3_

- [x] 15I. Extend `lib/enumerate.sh` with `--databases`
  - [x] 15I.1 Tier 3 live summary
    - Add a `--databases` mode printing live counts for: system TCC row count, per-user TCC row counts, KextPolicy + KextPolicyMDM row counts, ExecPolicy row counts per captured table, SystemPolicy `authority` row count, quarantine-event count per home, authorization rule/right counts, XProtect bundle version.
    - Rows unavailable due to FDA or sudo render as `--- (skipped: <reason>)`.
    - _Requirements: 9.3, 9.5_

  - [x]* 15I.2 Unit tests for enumerate --databases
    - Run against a shimmed `sqlite3` fixture; assert counts match.
    - Run without FDA; assert FDA-protected lines show `--- (skipped: fda-unavailable)`.
    - _Requirements: 9.5_

- [x] 15J. Extend `lib/integrity.sh` with Tier 3 hash channels
  - [x] 15J.1 Tier 3 PASS / FAIL classification
    - For every Tier 3 SQLite entry, compare current `sha256_checkpointed` against baseline; compare every per-table `content_hash` against baseline.
    - Classify `PASS` iff checkpointed hash AND every content_hash match; `FAIL[checkpointed,content:<t1>,content:<t2>]` otherwise reporting every mismatching channel.
    - For XProtect entries, compare every per-file `sha256_raw` and the `codesign.valid` field.
    - _Requirements: 10.1, 10.4, 10.5_

  - [ ]* 15J.2 Unit tests for Tier 3 integrity
    - Mutate one row in a fixture TCC.db; assert `FAIL[content:access]` fires.
    - Mutate only the -wal without changing rows; assert `sha256_checkpointed` equality holds and the entry still reports PASS (P17).
    - Mutate one file inside the XProtect fixture bundle; assert `FAIL` names the specific file.
    - _Requirements: 10.4, 10.5_

- [x] 15K. Extend `macaudit.sh` CLI for Tier 3
  - [x] 15K.1 Tier 3 flag parsing + FDA warning
    - Accept `--tier 3` and `--tier all` (default) including Tier 3 entries.
    - At startup, when Tier 3 is enabled, run `utils_fda_probe`; when the probe fails, log the FDA warning message from Requirement 15.7 and record the probe result in the header.
    - Extend `cmd_enumerate` to accept `--databases`.
    - _Requirements: 1.5, 9.3, 15.7, 24.1, 24.5_

  - [ ]* 15K.2 Unit tests for macaudit.sh dispatch (Tier 3)
    - Assert `macaudit.sh baseline --tier 3` invokes only the Tier 3 walk.
    - Assert `macaudit.sh baseline --tier all --user-only` records `no-sudo` reasons for Tier 3 system paths without aborting.
    - Assert a baseline with `manifest_version: "1.1"` is accepted by `audit` and `integrity`.
    - _Requirements: 18.2_

- [x] 15L. Checkpoint — Tier 3 wired end-to-end
  - Ensure all tests pass; ask the user if questions arise before proceeding to integration tests.

- [x] 16. Integration test scenarios (bats end-to-end)
  - [x] 16.1 Clean-run baseline then audit with zero changes
    - Seed a fixture home with two LaunchAgents and one user preference plist.
    - Run `macaudit.sh baseline --tier all --user-only`; run `macaudit.sh audit <baseline>`; assert every delta category empty and exit code 0.
    - _Requirements: 1.7, 7.10, 14.1_

  - [x] 16.2 Added LaunchAgent detected
    - After baseline, drop a new plist into `~/Library/LaunchAgents/`; run audit; assert it appears under Tier 1 `added` and exit code 1.
    - _Requirements: 7.3, 7.11_

  - [x] 16.3 Modified preference value detected
    - After baseline, mutate one security-critical key in a fixture preference; run audit; assert Tier 2 `modified` with a field-level `changes` entry and exit code 1.
    - _Requirements: 7.5, 7.11_

  - [x] 16.4 Removed plist detected
    - After baseline, delete a baselined plist; run audit; assert Tier 1 or Tier 2 `removed` and exit code 1.
    - _Requirements: 7.4, 7.11_

  - [x] 16.5 Stale preference (cfprefsd divergence) detected
    - After baseline, point the `defaults` PATH-shim at a divergent export for one domain; run audit; assert Tier 2 `stale` with `disk` and `live` hashes both set and differing, and exit code 1.
    - _Requirements: 6.3, 7.6, 7.11_

  - [x] 16.6 Injection detected
    - After baseline, inject an extra label into the `launchctl` PATH-shim output that has no matching on-disk plist; run audit; assert `injections` contains the label and exit code 1.
    - _Requirements: 4.1, 4.2, 4.4, 4.5, 7.7, 7.11_

  - [x] 16.7 Determinism — two sequential baselines agree
    - Run baseline twice with no state change between runs; assert every `(path, sha256_canonical)` pair is preserved across runs.
    - _Requirements: 1.7_

  - [x] 16.8 Read-only invariant
    - Before baseline, hash every fixture path; run every subcommand (`baseline`, `audit`, `enumerate`, `integrity`); re-hash every fixture path and assert every hash is unchanged.
    - Assert no write calls were made to audited paths by asserting file mtimes are unchanged.
    - _Requirements: 12.1, 12.2, 12.3, 12.4_

  - [x] 16.9 SIGINT leaves no partial manifest
    - Start a baseline, send SIGINT mid-run; assert the output manifest does not exist and the managed tmpdir is gone; assert exit code 130.
    - _Requirements: 14.5, 19.1, 19.2, 19.3_

  - [x] 16.10 Graceful degradation without sudo
    - Run baseline without sudo and without `--user-only`; assert every system-scoped surface is recorded in `header.skipped_paths` with `reason: "no-sudo"`; assert the tool does not abort.
    - Run baseline with `--user-only`; assert no system-scoped paths appear in entries or in `skipped_paths`.
    - _Requirements: 13.1, 13.2, 13.3, 13.4_

  - [x] 16.11 Offline operation invariant
    - Static check: grep the tool tree for any reference to `curl`, `wget`, `nc`, `ssh`, `scp`, `ftp`; assert none are present.
    - _Requirements: 16.1, 16.2_

  - [ ]* 16.12 Integrity scenarios
    - After baseline, flip one byte of a plist without changing semantics (e.g., re-serialise binary → xml) and assert `integrity` reports `FAIL[raw]` on that entry.
    - Mutate a plist semantically and assert `FAIL[raw,canonical]`.
    - Delete a file and assert `MISSING`; add a file and assert `NEW`.
    - Assert exit 1 when any FAIL/MISSING/NEW is present; exit 0 when only PASS.
    - _Requirements: 10.2, 10.3, 10.4, 10.5, 10.6, 10.7_

  - [x] 16.13 Tier 3 — TCC Override Policy suspicious finding
    - Seed a fixture TCC.db (via `sqlite3`) with one row `auth_reason=7` (Override Policy) and one baseline clean row.
    - Run baseline; run audit after adding a second `auth_reason=7` row; assert Tier 3 `modified` contains the TCC entry AND `suspicious` contains both anomalies with rule `tcc_override_policy`; assert exit code 3.
    - _Requirements: 25.1, 29.1, 29.2, 14.5_

  - [x] 16.14 Tier 3 — Authorization plugin injection
    - Seed a fixture authorization DB via a PATH-shim `security authorizationdb read` returning a `system.login.console` mechanisms list that includes `MyEvilPlugin:invoke,privileged` with no matching bundle.
    - Run baseline; run audit; assert Tier 3 `suspicious` contains `authdb_missing_plugin` AND the correlation pass emits a `correlation:authdb_missing_plugin` entry; assert exit code 3.
    - _Requirements: 26.3, 27.1 (R5), 29.1, 29.2, 14.5_

  - [x] 16.15 Tier 3 — KextPolicy user approval on MDM-managed device
    - Seed a fixture KextPolicy with a `kext_policy` row having no matching `kext_policy_mdm` row. Point the `profiles` PATH-shim at a fixture that reports MDM enrolment.
    - Run baseline; run audit; assert Tier 3 `suspicious` contains `kext_user_approved_on_mdm` AND the correlation pass emits `correlation:kext_user_approved_on_mdm`; assert exit code 3.
    - _Requirements: 27.1 (R4), 28.7, 29.1, 29.2, 14.5_

  - [x] 16.16 Tier 3 — XProtect bundle codesign failure
    - Point `XPROTECT_BUNDLE_OVERRIDE` at a fixture bundle; stub `codesign` to return non-zero for that bundle.
    - Run baseline; run audit; assert the XProtect entry carries `xprotect_codesign_fail` in `anomalies` and exit code is 3.
    - _Requirements: 28.6, 29.1, 29.2, 14.5_

  - [x] 16.17 Tier 3 — Gatekeeper disabled
    - Stub `spctl --status` to return `assessments disabled`.
    - Run baseline; run audit; assert the SystemPolicy entry carries `gatekeeper_disabled` in `anomalies` and exit code is 3.
    - _Requirements: 28.5, 29.1, 29.2, 14.5_

  - [x] 16.18 Tier 3 — FDA unavailable graceful degradation
    - Stub `utils_fda_probe` (via `FDA_PROBE_OVERRIDE`) to return false.
    - Run baseline with `--tier all`; assert `header.fda_available = false`, `skipped_paths` contains system TCC.db, KextPolicy, and ExecPolicy each with `reason: "fda-unavailable"`, and non-FDA Tier 3 entries (authdb, XProtect, per-user quarantine) are still present.
    - Assert exit code 0 (baseline captured the available surfaces cleanly).
    - _Requirements: 13.5, 15.7, 22.2, 24.3, 24.4, 24.6_

  - [x] 16.19 Tier 3 — SQLite safe-copy preserves originals
    - Hash every fixture `.db`, `.db-wal`, `.db-shm` before baseline; run baseline with Tier 3 enabled; re-hash the same files.
    - Assert every hash is unchanged (P10′ / P16).
    - _Requirements: 12.5, 23.7_

  - [x] 16.20 Tier 3 — TCC MDM-without-profile cross-surface correlation
    - Seed TCC.db with `auth_reason=6` for `com.x.app`; point the `profiles show -type configuration` shim at output that does NOT include a `com.apple.TCC.configuration-profile-policy` payload for `com.x.app`.
    - Run baseline; run audit; assert both `tcc_mdm_without_profile` (on the TCC entry) and `correlation:tcc_mdm_without_profile` (as a correlation entry) fire; assert exit code 3.
    - _Requirements: 25.4, 27.1 (R1), 29.1, 29.2, 14.5_

  - [x] 16.21 Tier 3 — persistence ↔ codesign correlation
    - Drop a new LaunchAgent plist into `~/Library/LaunchAgents/` whose `Program` points at an unsigned fixture binary.
    - Run baseline; run audit; assert `correlation:persistence_codesign_fail` fires and exit code is 3.
    - _Requirements: 27.1 (R3), 27.2, 29.1, 14.5_

  - [x] 16.22 Tier 3 — Determinism across two baselines
    - Run baseline twice with no state change in between; assert every `(path, sha256_checkpointed)` pair and every `(path, content_hash)` pair is preserved across runs (including quarantine events).
    - _Requirements: 22.4, 22.5, 17 (P17)_

- [x] 17. Final checkpoint — ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 18. Optional extensions
  - [x]* 18.1 Performance benchmarking
    - Add a `tests/perf/` harness that times `baseline --tier all --user-only` against a synthetic fixture of ~3000 entries; assert the wall-clock time is under the design's 30-second target.
    - Record results in a `perf.md` log file (not committed to the manifest schema).
    - _Requirements: none — performance target is a non-functional design goal_

  - [x]* 18.2 Extended platform compatibility checks
    - Add bats smoke tests that run under bash 3.2 (the minimum supported), bash 4, and bash 5 to catch version-specific regressions.
    - Add a macOS-version override harness asserting BTM handling correctly degrades to `null` on `OS_MAJOR_OVERRIDE=12` across every module that reads BTM.
    - _Requirements: 3.5, 15.3, 15.4, 15.5_

## Notes

- Tasks marked with `*` are optional (tests, performance benchmarking, extended platform matrix) and may be skipped for a faster MVP; core implementation tasks (including all of 15A–15L) are required.
- Testing tasks live as sub-tasks under the module they exercise so defects surface adjacent to the code that introduced them.
- Every task references the specific requirement IDs it fulfills from `requirements.md`; property tests are additionally tagged with the property number (P1–P25) from `design.md`'s Correctness Properties section and its Amended Correctness Properties section.
- Checkpoints at tasks 5, 9, 15, 15L, and 17 allow incremental validation without running the full test suite every iteration.
- The shipped tool depends only on macOS built-ins plus `jq`. `bats-core`, Python 3, `hypothesis`, `plistlib`, and the Python `sqlite3` stdlib are development-time only (per Requirement 15.6 and the design's Dependencies section).
- Tier 3 modules (`sqlite`, `tcc`, `sysdb`, `quarantine`, `xprotect`) and cross-surface correlation (task 15F.2) are additions introduced by the Phase 1 Amendment in `design.md` — they extend rather than replace the Tier 1 / Tier 2 modules.
