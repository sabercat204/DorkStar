# Requirements Document

## Introduction

macaudit is a terminal-based, read-only macOS forensic configuration auditor that captures a baseline snapshot of system configuration state and compares future snapshots against that baseline to detect drift, additions, removals, integrity failures, in-memory persistence injections, and suspicious security-policy anomalies. Phase 1 is a Bash prototype targeting macOS 13+ (Ventura and later, including Sequoia 15.x), covering three audit surfaces: Tier 1 (persistence mechanisms — LaunchAgents, LaunchDaemons, login items, cron, periodic, login hooks, authorization plugins, emond rules), Tier 2 (preference domains — system, user, and managed preferences with dual-hash verification and cfprefsd cross-reference), and Tier 3 (security databases — TCC system and per-user, KextPolicy, ExecPolicy, quarantine events, authorization database, SystemPolicy/Gatekeeper, and the XProtect bundle).

The tool exposes four subcommands — `baseline`, `audit`, `enumerate`, `integrity` — and emits JSONL manifests and either human-readable or JSON-mode reports. It uses only macOS built-ins plus `jq`, never modifies audited state, never accesses the network, and degrades gracefully when run without sudo or without Full Disk Access.

## Glossary

- **macaudit**: The tool under specification; a Bash script (`macaudit.sh`) plus `lib/*.sh` helpers.
- **Baseline**: A JSONL manifest file captured at a point in time that records the state of every audited artifact.
- **Audit**: Re-capture current state and compute the delta (added / removed / modified / stale / injection / suspicious) against a stored baseline.
- **Manifest**: A JSONL file whose first line is a header JSON object and whose subsequent lines are entry JSON objects, one per artifact.
- **Entry**: A single JSON record describing one audited artifact (plist, persistence item, injection, database table snapshot, or cross-surface correlation finding).
- **Tier 1**: Persistence surfaces — LaunchDaemons, LaunchAgents (system, user), BTM, cron, periodic, login hooks, authorization plugins, emond rules.
- **Tier 2**: Preference surfaces — `/Library/Preferences`, `~/Library/Preferences`, `/Library/Managed Preferences`.
- **Tier 3**: Security-database surfaces — TCC (system + per-user), KextPolicy, ExecPolicy, SystemPolicy / Gatekeeper, quarantine events (per-user LSQuarantineEvent), authorization database (via `security authorizationdb read`), XProtect bundle.
- **Dual-hash**: Two SHA-256 hashes per plist — `sha256_raw` over file bytes and `sha256_canonical` over canonical JSON.
- **Canonical JSON**: Output of `plutil -convert json` piped through `jq -cS` (compact, sorted keys) — stable across plist on-disk formats.
- **cfprefsd cross-reference**: Comparison of a preference domain's on-disk canonical hash against the canonical hash of `defaults export <domain> -` output.
- **Three-view correlation**: For each persistence Label, record whether it is present on-disk, loaded in `launchctl`, and registered in BTM.
- **Injection**: A Label present in `launchctl list` output that has no corresponding on-disk plist.
- **Stale preference**: A Tier 2 entry whose disk canonical hash differs from its cfprefsd live canonical hash.
- **Suspicious anomaly**: A Tier 3 finding (or cross-surface correlation finding) whose pattern matches a hard-coded indicator of abuse — e.g., TCC `auth_reason=7` Override Policy, camera/microphone grants with `auth_reason ≠ 2`, authorization plugin injection, unsigned persistence binaries, MDM-labeled TCC entries without matching PPPC profile, user-approved kexts on MDM-managed devices.
- **BTM**: Background Task Management database (`sfltool dumpbtm`), available on macOS 13+.
- **TCC**: Transparency, Consent, and Control database — Apple's per-service privacy/access grants store (`TCC.db`).
- **KextPolicy**: The kernel-extension approval database recording user-approved and MDM-approved kexts.
- **ExecPolicy**: The Gatekeeper execution policy database recording code-signing validation results and user overrides.
- **SystemPolicy**: The Gatekeeper system policy database used by `spctl`.
- **XProtect**: Apple's built-in anti-malware YARA signature bundle at `/Library/Apple/System/Library/CoreServices/XProtect.bundle/`.
- **LSQuarantineEvent**: The `com.apple.LaunchServices.QuarantineEventsV2` SQLite database recording download provenance per user.
- **FDA (Full Disk Access)**: macOS privacy permission that allows a process to read TCC.db and other protected paths. Probed at startup by reading the `access` table of the system TCC.db.
- **SQLite WAL safe-copy**: The non-destructive protocol macaudit uses to capture SQLite databases: copy `.db`, `.db-wal`, and `.db-shm` into a scratch directory, run `PRAGMA wal_checkpoint(TRUNCATE)` on the copy, then hash and query the checkpointed copy. Originals are never touched.
- **sha256_checkpointed**: SHA-256 of the post-checkpoint copy of an SQLite database. Deterministic across runs when the database content is unchanged, even when the WAL journal is nonempty.
- **wal_present / wal_sha256**: Whether a `-wal` sidecar existed alongside the database at capture time, and its SHA-256 if so.
- **content_hash**: SHA-256 of the canonicalised JSON serialisation of the captured rows of one SQLite table — i.e., what macaudit uses to detect row-level drift independent of WAL journal state.
- **Cross-surface correlation**: A post-scan validation pass that joins Tier 3 findings with Tier 1 / Tier 2 state to produce suspicious anomalies. Five rules are implemented in Phase 1.
- **Stale preference**: See above.
- **SIP**: System Integrity Protection (`csrutil status`).
- **SSV**: Sealed System Volume status.
- **Operator**: The human user invoking macaudit from a terminal.
- **Skipped path**: A path macaudit could not read (permission denied, missing, unreadable, FDA unavailable) and records in the manifest header's `skipped_paths` list.
- **Exit code**: Process exit status — 0 (clean), 1 (drift detected), 2 (unrecoverable error), 3 (drift with suspicious anomalies), 130 (SIGINT).

## Requirements

### Requirement 1: Baseline Capture

**User Story:** As an operator, I want to capture a baseline snapshot of persistence, preference, and security-database state into a JSONL manifest, so that I can compare future system state against a known-good reference.

#### Acceptance Criteria

1. WHEN the operator invokes `macaudit baseline`, THE macaudit SHALL write a JSONL manifest to the configured output path.
2. WHEN writing a manifest, THE macaudit SHALL emit a header JSON object as the first line and one entry JSON object per subsequent line.
3. WHEN `--tier 1` is specified, THE macaudit SHALL include only Tier 1 (persistence) entries.
4. WHEN `--tier 2` is specified, THE macaudit SHALL include only Tier 2 (preference) entries.
5. WHEN `--tier all` is specified, THE macaudit SHALL include Tier 1, Tier 2, and Tier 3 entries.
6. WHEN `--user-only` is specified, THE macaudit SHALL skip system-level paths that would require sudo.
7. WHEN the system state is unchanged between two baseline runs, THE macaudit SHALL produce manifests in which every `(path, sha256_canonical)` pair is preserved across runs.
8. WHEN baseline capture completes successfully, THE macaudit SHALL exit with code 0.
9. WHEN an output path is not provided, THE macaudit SHALL write to a default `manifests/baseline_<timestamp>.jsonl` path and print the final path to stdout.

### Requirement 2: Dual-Hash Computation for Plists

**User Story:** As an operator, I want every plist captured with both a raw-bytes hash and a canonical-semantic hash, so that I can distinguish real configuration changes from mere format conversions.

#### Acceptance Criteria

1. WHEN macaudit records a plist entry, THE macaudit SHALL populate `sha256_raw` with the lowercase 64-hex SHA-256 of the file bytes.
2. WHEN macaudit records a valid plist entry, THE macaudit SHALL populate `sha256_canonical` with the lowercase 64-hex SHA-256 of the canonical JSON representation (`plutil -convert json` piped through `jq -cS`).
3. WHEN a single byte of a plist file changes, THE macaudit SHALL produce a different `sha256_raw` value (collision probability is `2⁻²⁵⁶`).
4. WHEN a plist is converted between binary, XML, and JSON formats without semantic change, THE macaudit SHALL produce an unchanged `sha256_canonical` value.
5. WHEN a plist undergoes a semantic mutation (key add, key remove, or value change), THE macaudit SHALL produce a different `sha256_canonical` value.
6. IF `plutil -lint` fails for a file, THEN THE macaudit SHALL emit an entry with `format: "invalid"`, populated `sha256_raw`, empty `sha256_canonical`, and empty `content`, and log a warning.
7. THE macaudit SHALL record the detected plist format for every plist entry as one of `binary`, `xml`, `json`, `invalid`, or `n/a`.

### Requirement 3: Tier 1 Persistence Capture

**User Story:** As an operator, I want every persistence surface on the system captured with a launch-keys content subset and a three-view correlation, so that I can see not only what's on disk but whether each job is loaded and BTM-registered.

#### Acceptance Criteria

1. WHEN baseline runs with Tier 1 enabled, THE macaudit SHALL enumerate LaunchDaemons, LaunchAgents (system and user), cron, periodic, login hooks, authorization plugins, and emond rules.
2. WHEN emitting a Tier 1 plist entry, THE macaudit SHALL extract and include in `content` only these launch keys: `Label`, `Program`, `ProgramArguments`, `RunAtLoad`, `KeepAlive`, `WatchPaths`, `StartInterval`, `StartCalendarInterval`, `MachServices`, `Sockets`, `UserName`, `GroupName`.
3. WHEN emitting a Tier 1 plist entry, THE macaudit SHALL populate `launchctl_loaded` with a boolean indicating whether the plist's `Label` is present in `launchctl list` output.
4. WHEN emitting a Tier 1 plist entry on macOS 13+, THE macaudit SHALL populate `btm_registered` with a boolean indicating whether the plist's `Label` is present in `sfltool dumpbtm` output.
5. WHILE running on macOS < 13, THE macaudit SHALL set `btm_registered` to `null` for every Tier 1 entry.
6. WHEN a Tier 1 plist entry is emitted, THE macaudit SHALL set `cfprefsd_match` to `null`.
7. WHEN baseline runs with Tier 1 enabled, THE macaudit SHALL collect `launchctl list` and `sfltool dumpbtm` output exactly once per run and reuse them across all Tier 1 entries.

### Requirement 4: Injection Detection

**User Story:** As an operator, I want macaudit to flag any launchctl job whose Label does not correspond to a plist on disk, so that I can detect staged or in-memory-only persistence.

#### Acceptance Criteria

1. WHEN baseline runs with Tier 1 enabled, THE macaudit SHALL emit an entry with `surface: "injection"` for every Label present in `launchctl list` output but absent from the set of on-disk Labels.
2. WHEN emitting an injection entry, THE macaudit SHALL set `content` to `{"label": <label>, "pid": <pid>, "status": <status>}`, set `format` to `"n/a"`, set `sha256_raw` and `sha256_canonical` to empty strings, set `launchctl_loaded` to `true`, and set `btm_registered` according to BTM presence (or `null` on macOS < 13).
3. WHEN classifying Labels, THE macaudit SHALL guarantee that the set of injection Labels and the set of on-disk Labels are disjoint.
4. FOR ALL Labels `ℓ` such that `ℓ` is in `launchctl list` and `ℓ` is not in the on-disk Label set, THE macaudit SHALL classify `ℓ` as an injection (completeness).
5. FOR ALL Labels `ℓ` classified as injections by THE macaudit, `ℓ` SHALL be in `launchctl list` and `ℓ` SHALL NOT be in the on-disk Label set (soundness).

### Requirement 5: Tier 2 Preference Capture

**User Story:** As an operator, I want every preference surface captured with a dual hash, a cfprefsd cross-reference, and only security-critical keys in content, so that I can detect preference drift without exfiltrating personal data.

#### Acceptance Criteria

1. WHEN baseline runs with Tier 2 enabled, THE macaudit SHALL enumerate preference plists under `/Library/Preferences`, `~/Library/Preferences`, and `/Library/Managed Preferences`.
2. WHEN emitting a Tier 2 entry, THE macaudit SHALL include in `content` only the security-critical keys defined for that domain in the Security-Critical Key Map.
3. FOR ALL Tier 2 entries emitted by THE macaudit, `keys(content)` SHALL be a subset of the security-critical key map for that entry's preference domain.
4. WHEN emitting a Tier 2 entry, THE macaudit SHALL populate `cfprefsd_match` with `true`, `false`, or `null` according to the cfprefsd cross-reference algorithm.
5. WHEN a Tier 2 entry is emitted, THE macaudit SHALL set `launchctl_loaded` and `btm_registered` to `null`.
6. THE Security-Critical Key Map SHALL define keys for at least these domains: `com.apple.loginwindow`, `com.apple.screensaver`, `com.apple.SoftwareUpdate`, `com.apple.alf`, `.GlobalPreferences`, `com.apple.Safari`.

### Requirement 6: cfprefsd Cross-Reference

**User Story:** As an operator, I want each preference domain's on-disk state compared against what cfprefsd is serving live, so that I can detect divergence between disk and the running preference daemon.

#### Acceptance Criteria

1. WHEN computing cfprefsd cross-reference for a preference plist, THE macaudit SHALL invoke `defaults export <domain> -` and hash the result through the same canonicalization pipeline used for the disk file.
2. WHEN both the disk canonical hash and the live canonical hash are defined, THE macaudit SHALL set `cfprefsd_match` to `true` if and only if the two hashes are equal.
3. WHEN both the disk canonical hash and the live canonical hash are defined and differ, THE macaudit SHALL set `cfprefsd_match` to `false`.
4. IF `defaults export` exits non-zero, produces empty output, or produces `{}`, THEN THE macaudit SHALL set `cfprefsd_match` to `null`.
5. IF the domain cannot be derived from the plist path, THEN THE macaudit SHALL set `cfprefsd_match` to `null`.
6. THE macaudit SHALL apply the identical canonicalization pipeline (`plutil -convert json` piped through `jq -cS`) to both the disk bytes and the `defaults export` output.

### Requirement 7: Audit Delta Computation

**User Story:** As an operator, I want to compare the current system state against a stored baseline and see a categorized delta report, so that I can spot additions, removals, modifications, stale preferences, injections, and suspicious anomalies at a glance.

#### Acceptance Criteria

1. WHEN the operator invokes `macaudit audit <baseline>`, THE macaudit SHALL re-capture current state using the same `tier` and `user_only` values as the baseline's header and compute the delta against the baseline.
2. WHEN computing the delta, THE macaudit SHALL classify every path present in baseline or current state into exactly one of `added`, `removed`, `modified`, or `unchanged` per tier.
3. FOR ALL paths `p`, IF `p` is in the current state and not in the baseline, THEN THE macaudit SHALL place `p` in `added`.
4. FOR ALL paths `p`, IF `p` is in the baseline and not in the current state, THEN THE macaudit SHALL place `p` in `removed`.
5. FOR ALL paths `p`, IF `p` is in both baseline and current, and their `sha256_canonical`, `content`, `launchctl_loaded`, `btm_registered`, `content_hash`, `sha256_checkpointed`, or `wal_sha256` fields differ, THEN THE macaudit SHALL place `p` in `modified` with a field-level `changes` list.
6. FOR ALL Tier 2 entries `e` in the current state with `cfprefsd_match = false`, THE macaudit SHALL place `e` in `stale`.
7. FOR ALL entries `e` in the current state with `surface = "injection"`, THE macaudit SHALL place `e` in `injections`.
8. THE macaudit SHALL guarantee that within any single tier, `added`, `removed`, and `modified` are pairwise disjoint.
9. THE macaudit SHALL produce a `summary` object whose per-tier and total counts equal the sum of the corresponding category sizes.
10. WHEN the audit completes with every delta category empty, THE macaudit SHALL exit with code 0.
11. WHEN the audit completes with any delta category non-empty and no `suspicious` entries are present, THE macaudit SHALL exit with code 1.
12. WHEN the audit completes with any delta category non-empty AND at least one `suspicious` entry is present, THE macaudit SHALL exit with code 3.

### Requirement 8: Audit Report Rendering

**User Story:** As an operator, I want the delta in either a colored human-readable terminal report or machine-parseable JSON, so that I can either read it directly or pipe it into other tooling.

#### Acceptance Criteria

1. WHEN `macaudit audit` runs without `--json`, THE macaudit SHALL render the delta in human mode with category symbols, colors (when the terminal supports them), per-entry details, and a summary block.
2. WHEN `--json` is specified, THE macaudit SHALL render the delta as a single JSON document matching the delta schema.
3. WHEN rendering the human report, THE macaudit SHALL include the baseline timestamp and the elapsed time since baseline capture.
4. WHEN the terminal does not support color (non-tty or `tput colors < 8`), THE macaudit SHALL render without color escape sequences.
5. WHEN rendering any field value, THE macaudit SHALL NOT eval or interpolate the value into a shell command.
6. WHEN at least one `suspicious` entry is present, THE macaudit SHALL render a `[⚑] SUSPICIOUS` section in magenta (when color is supported) before the summary block, with one line per finding and an inline description of the indicator that fired.

### Requirement 9: Enumerate Subcommand

**User Story:** As an operator, I want a one-shot live dump of current persistence, preference, and security-database state without comparing against any baseline, so that I can quickly reconnoiter a system.

#### Acceptance Criteria

1. WHEN the operator invokes `macaudit enumerate --persistence`, THE macaudit SHALL print a live summary of persistence state including counts of LaunchAgents (user, system), LaunchDaemons, launchctl jobs, BTM records, cron entries, non-Apple periodic entries, login hooks, non-Apple authorization plugins, and emond rules.
2. WHEN the operator invokes `macaudit enumerate --preferences`, THE macaudit SHALL print a live summary of preference state.
3. WHEN the operator invokes `macaudit enumerate --databases`, THE macaudit SHALL print a live summary of Tier 3 state including row counts for TCC system + user, KextPolicy kext_policy + kext_policy_mdm, ExecPolicy, SystemPolicy, LSQuarantineEvent per user, authorization database mechanism counts, and the XProtect bundle version.
4. WHEN the operator invokes `macaudit enumerate --all`, THE macaudit SHALL print persistence, preference, and databases summaries.
5. WHEN a data source is unavailable due to missing sudo, missing Full Disk Access, or unsupported macOS version, THE macaudit SHALL render the corresponding line with a `---` placeholder and a parenthetical reason.
6. WHEN enumeration completes successfully, THE macaudit SHALL exit with code 0.

### Requirement 10: Integrity Subcommand

**User Story:** As an operator, I want to re-hash every file referenced in a baseline and classify each as PASS / FAIL / MISSING / NEW, so that I can detect file-level tampering without a full audit.

#### Acceptance Criteria

1. WHEN the operator invokes `macaudit integrity <baseline>`, THE macaudit SHALL iterate every non-injection entry in the baseline and compute its current dual hash (for plist entries) or its current `sha256_checkpointed` and per-table `content_hash` (for Tier 3 database entries).
2. WHEN a plist entry's current `sha256_raw` and `sha256_canonical` both equal the baseline values, THE macaudit SHALL classify the entry as `PASS`.
3. WHEN a plist entry's current `sha256_raw` or `sha256_canonical` differs from the baseline values, THE macaudit SHALL classify the entry as `FAIL` and report which hash channels changed (`raw`, `canonical`, or both).
4. WHEN a Tier 3 database entry's current `sha256_checkpointed` and every current per-table `content_hash` match the baseline values, THE macaudit SHALL classify the entry as `PASS`.
5. WHEN a Tier 3 database entry's current `sha256_checkpointed` or any per-table `content_hash` differs from the baseline values, THE macaudit SHALL classify the entry as `FAIL` and report which channels changed (`checkpointed`, `content:<table>`, or both).
6. IF an entry's baseline path no longer exists on disk, THEN THE macaudit SHALL classify the entry as `MISSING`.
7. WHEN a path exists in the current state but was absent from the baseline, THE macaudit SHALL classify the path as `NEW`.
8. WHEN integrity completes with zero FAIL, MISSING, or NEW classifications, THE macaudit SHALL exit with code 0.
9. WHEN integrity completes with any FAIL, MISSING, or NEW classification, THE macaudit SHALL exit with code 1.
10. WHEN integrity completes, THE macaudit SHALL print a summary block with the totals for each classification.

### Requirement 11: JSONL Manifest Format

**User Story:** As an operator, I want the manifest in a stable, documented JSONL schema, so that I can parse, diff, and grep it with standard Unix tools.

#### Acceptance Criteria

1. THE macaudit SHALL produce manifests whose first line is a header JSON object and whose subsequent lines are entry JSON objects, one per line.
2. THE manifest header SHALL include `manifest_version`, `tool`, `tool_version`, `timestamp`, `hostname`, `os_version`, `os_major`, `sip_status`, `ssv_status`, `fda_available`, `tier`, `user_only`, `environment`, and `skipped_paths`.
3. THE macaudit SHALL set `manifest_version` to `"1.1"` for Phase 1 output that includes Tier 3.
4. THE manifest header `sip_status` and `ssv_status` fields SHALL each be one of `enabled`, `disabled`, or `unknown`.
5. THE manifest header `timestamp` SHALL be ISO 8601 with a timezone offset.
6. THE manifest header `skipped_paths` SHALL always be present and SHALL record every path macaudit could not read, with fields `path` and `reason` (where `reason` is one of `permission-denied`, `no-sudo`, `fda-unavailable`, `macos-too-old`, `missing`, `invalid`).
7. FOR ALL entries `e`, `e.tier` SHALL be `1`, `2`, or `3`, and `e.surface` SHALL be a member of the surface set for that tier.
8. FOR ALL entries `e`, `e.format` SHALL be one of `binary`, `xml`, `json`, `invalid`, `sqlite`, `bundle`, `authdb`, or `n/a`.
9. FOR ALL entries `e`, `e.sha256_raw` and `e.sha256_canonical` SHALL each be either an empty string or a lowercase 64-hex-character string.
10. FOR ALL entries `e`, `e.cfprefsd_match` SHALL be `true`, `false`, or `null`, and SHALL be `null` for every Tier 1 and Tier 3 entry.
11. FOR ALL entries `e`, `e.launchctl_loaded` and `e.btm_registered` SHALL each be `true`, `false`, or `null`, and SHALL each be `null` for every Tier 2 and Tier 3 entry.
12. FOR ALL manifests `m`, parsing `serialize(m)` as JSONL SHALL produce a manifest equal to `m` (manifest round-trip).
13. FOR ALL Tier 3 database entries `e`, `e.sha256_checkpointed` SHALL be a lowercase 64-hex-character string (or empty when the database was unreadable), `e.wal_present` SHALL be `true` or `false`, and `e.wal_sha256` SHALL be a lowercase 64-hex-character string or empty.
14. FOR ALL Tier 3 database entries `e`, `e.table_snapshots` SHALL be an object mapping table names to objects `{row_count: integer, content_hash: 64-hex, primary_key: [string, ...], rows: [object, ...]}`.
15. FOR ALL Tier 3 entries `e`, `e.anomalies` SHALL be present and SHALL be an array (possibly empty) of objects `{rule: string, severity: "info"|"warn"|"high", detail: string}`.

### Requirement 12: Read-Only Non-Modification Invariant

**User Story:** As an operator, I want a hard guarantee that macaudit never modifies any audited path or system state, so that I can safely run it on production or evidence systems.

#### Acceptance Criteria

1. FOR ALL subcommands `s` in {`baseline`, `audit`, `enumerate`, `integrity`} and all audited paths `p`, THE macaudit SHALL leave `state(p)` unchanged after `s` completes.
2. THE macaudit SHALL NOT invoke `defaults write`, `defaults delete`, `launchctl load`, `launchctl unload`, `plutil -replace`, `security authorizationdb write`, `spctl --master-enable`, `spctl --master-disable`, or any other state-mutating command against audited paths.
3. THE macaudit SHALL NOT open any audited path for writing.
4. THE macaudit SHALL restrict write operations to its own output manifest path, its own report output path, and its own managed temporary directory.
5. FOR ALL SQLite databases `d` captured by THE macaudit, the on-disk byte content of `d`, `d-wal`, and `d-shm` SHALL be byte-identical before and after the tool run.

### Requirement 13: Graceful Degradation Without Sudo or FDA

**User Story:** As an operator, I want macaudit to still produce a manifest when I run it without sudo or without Full Disk Access, recording every path it could not read, so that I never get silent data omissions.

#### Acceptance Criteria

1. WHEN macaudit lacks permission to read a path in an audit surface, THE macaudit SHALL append an entry to the header's `skipped_paths` list with that path and a `reason` of `permission-denied`.
2. FOR ALL run-time permission sets `π`, THE macaudit SHALL either produce a manifest whose `skipped_paths` records every inaccessible path OR exit with code 2 and a clear error message — THE macaudit SHALL NOT silently omit data.
3. WHEN macaudit runs without sudo and `--user-only` is not specified, THE macaudit SHALL record system-level surfaces as skipped with reason `no-sudo` rather than aborting.
4. WHEN `--user-only` is specified, THE macaudit SHALL NOT attempt to read system-level paths and SHALL NOT record them as skipped.
5. WHEN macaudit runs without Full Disk Access and Tier 3 is enabled, THE macaudit SHALL record each FDA-protected Tier 3 surface as skipped with `reason: "fda-unavailable"` and SHALL NOT abort.

### Requirement 14: Exit Code Semantics

**User Story:** As an operator, I want precise and predictable exit codes, so that I can compose macaudit into scripts and CI pipelines.

#### Acceptance Criteria

1. WHEN `macaudit baseline`, `macaudit enumerate`, `macaudit audit`, or `macaudit integrity` completes successfully with no drift and no failures, THE macaudit SHALL exit with code 0.
2. WHEN `macaudit audit` detects any non-empty delta category and no `suspicious` entries are present, THE macaudit SHALL exit with code 1.
3. WHEN `macaudit integrity` detects any FAIL, MISSING, or NEW classification, THE macaudit SHALL exit with code 1.
4. IF macaudit encounters an unrecoverable error before producing a comparison result, THEN THE macaudit SHALL exit with code 2.
5. WHEN `macaudit audit` detects any non-empty delta category AND at least one `suspicious` entry is present, THE macaudit SHALL exit with code 3.
6. WHEN macaudit receives SIGINT during any subcommand, THE macaudit SHALL exit with code 130.

### Requirement 15: Platform and Dependency Preconditions

**User Story:** As an operator, I want macaudit to check its preconditions at startup and fail fast with a clear message when they are not met, so that I never get a partial run under a broken environment.

#### Acceptance Criteria

1. WHEN macaudit starts, THE macaudit SHALL verify that `jq` is available on PATH.
2. IF `jq` is not on PATH, THEN THE macaudit SHALL print `[x] macaudit requires jq. Install via: brew install jq` to stderr and exit with code 2.
3. WHEN macaudit starts, THE macaudit SHALL verify that the running shell is bash 3.2 or later.
4. IF the running shell is bash older than 3.2, THEN THE macaudit SHALL print `[x] macaudit requires bash 3.2 or later. Current: $BASH_VERSION` to stderr and exit with code 2.
5. WHEN macaudit starts on macOS older than 13, THE macaudit SHALL log `[!] macOS < 13 — BTM enumeration skipped. Three-view correlation limited to two views.` to stderr and SHALL set `btm_registered` to `null` for every entry it emits.
6. THE macaudit SHALL depend only on macOS built-in utilities (`plutil`, `defaults`, `shasum`, `xattr`, `launchctl`, `sfltool`, `sw_vers`, `csrutil`, `tput`, `awk`, `sort`, `comm`, `tr`, `grep`, `find`, `sqlite3`, `codesign`, `spctl`, `security`, `profiles`) plus `jq`.
7. WHEN macaudit starts with Tier 3 enabled and detects that FDA is unavailable, THE macaudit SHALL log `[!] Full Disk Access not granted — Tier 3 protected databases will be skipped. See System Settings → Privacy & Security → Full Disk Access.` to stderr.

### Requirement 16: Offline Operation

**User Story:** As an operator, I want a hard guarantee that macaudit never makes a network call, so that I can run it in air-gapped or quarantined environments.

#### Acceptance Criteria

1. THE macaudit SHALL NOT invoke any network utility (including `curl`, `wget`, `nc`, `ssh`, `scp`, `ftp`).
2. THE macaudit SHALL NOT open outbound sockets.

### Requirement 17: Error Handling for Corrupted or Invalid Plists

**User Story:** As an operator, I want macaudit to surface corrupted plists rather than crash or silently skip them, so that I can investigate the corruption.

#### Acceptance Criteria

1. IF `plutil -lint` fails for a file in a Tier 1 or Tier 2 surface, THEN THE macaudit SHALL emit an entry with `format: "invalid"`, `sha256_raw` populated from raw bytes, `sha256_canonical` set to empty string, `content` set to an empty object, and log a warning to stderr.
2. WHEN a plist is marked `invalid`, THE macaudit SHALL still include it in audit delta comparisons on the basis of `sha256_raw`.

### Requirement 18: Baseline Input Validation for audit and integrity

**User Story:** As an operator, I want clear errors when the baseline I pass to `audit` or `integrity` is missing or incompatible, so that I don't accidentally interpret a garbage comparison as a clean run.

#### Acceptance Criteria

1. IF the path passed to `macaudit audit <baseline>` or `macaudit integrity <baseline>` does not exist, THEN THE macaudit SHALL print `[x] baseline not found: <path>` to stderr and exit with code 2.
2. IF the baseline's header `manifest_version` is not `"1.0"` or `"1.1"`, THEN THE macaudit SHALL print `[x] baseline version X.Y not supported by this tool (expected 1.0 or 1.1)` to stderr and exit with code 2.

### Requirement 19: Interrupt Handling

**User Story:** As an operator, I want Ctrl-C to leave no partial or half-written manifest on disk, so that an interrupted run cannot be mistaken for a completed baseline.

#### Acceptance Criteria

1. WHEN macaudit receives SIGINT, THE macaudit SHALL remove its managed temporary directory via an EXIT trap.
2. WHEN macaudit receives SIGINT during baseline capture, THE macaudit SHALL remove any partial output manifest file before exiting.
3. WHEN macaudit exits due to SIGINT, THE macaudit SHALL exit with code 130.

### Requirement 20: Manifest Header Provenance

**User Story:** As an operator, I want the manifest header to record the environment under which the baseline was captured, so that downstream analysis can weight findings by SIP/SSV/FDA status and macOS version.

#### Acceptance Criteria

1. WHEN writing a manifest header, THE macaudit SHALL populate `hostname` from the system hostname.
2. WHEN writing a manifest header, THE macaudit SHALL populate `os_version` and `os_major` from `sw_vers`.
3. WHEN writing a manifest header, THE macaudit SHALL populate `sip_status` from `csrutil status`.
4. WHEN writing a manifest header, THE macaudit SHALL populate `ssv_status` with one of `enabled`, `disabled`, or `unknown`.
5. WHEN writing a manifest header, THE macaudit SHALL populate `tier` with the tier used for the run (`1`, `2`, `3`, or `all`) and `user_only` with the boolean value of that flag.
6. WHEN writing a manifest header, THE macaudit SHALL populate `fda_available` with `true` or `false` according to the FDA probe result.
7. WHEN writing a manifest header, THE macaudit SHALL populate `environment` with an object containing `fda_available`, `has_sudo`, `gatekeeper_enabled`, `mdm_managed`, and `xprotect_version`.

### Requirement 21: Extended Attribute Capture

**User Story:** As an operator, I want extended attributes (including quarantine) captured for every plist, so that I can reason about provenance of added persistence items.

#### Acceptance Criteria

1. WHEN emitting a plist entry, THE macaudit SHALL populate `xattrs` with a JSON object mapping each extended attribute name to its base64-encoded value.
2. WHEN a plist has no extended attributes, THE macaudit SHALL set `xattrs` to an empty JSON object.

### Requirement 22: Tier 3 Security Database Capture

**User Story:** As an operator, I want Tier 3 security databases captured as deterministic table snapshots so that I can detect row-level changes in TCC grants, kext approvals, execution policy, quarantine events, authorization rules, Gatekeeper policy, and XProtect signatures.

#### Acceptance Criteria

1. WHEN baseline runs with Tier 3 enabled and FDA is available, THE macaudit SHALL capture snapshots of the following seven surfaces: system TCC.db (`/Library/Application Support/com.apple.TCC/TCC.db`), per-user TCC.db (`~/Library/Application Support/com.apple.TCC/TCC.db` for each enumerable home), KextPolicy (`/var/db/SystemPolicyConfiguration/KextPolicy`), ExecPolicy (`/var/db/SystemPolicyConfiguration/ExecPolicy`), SystemPolicy (`/var/db/SystemPolicyConfiguration/SystemPolicy`), per-user LSQuarantineEvent (`~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`), and the authorization database (via `security authorizationdb read`), plus the XProtect bundle (`/Library/Apple/System/Library/CoreServices/XProtect.bundle/`).
2. WHEN baseline runs with Tier 3 enabled and FDA is unavailable, THE macaudit SHALL record each FDA-protected Tier 3 path in `skipped_paths` with `reason: "fda-unavailable"` and SHALL emit no entry for those paths.
3. FOR ALL Tier 3 SQLite entries, THE macaudit SHALL populate `surface` with one of `tcc_system`, `tcc_user`, `kextpolicy`, `execpolicy`, `systempolicy`, `quarantine_events`, `authdb`, or `xprotect`.
4. FOR ALL Tier 3 SQLite entries, THE macaudit SHALL populate `table_snapshots` with one object per captured table, whose `rows` array is sorted by primary key and whose `content_hash` is the SHA-256 of the canonical JSON serialisation of that sorted rows array.
5. FOR ALL Tier 3 SQLite entries, THE macaudit SHALL populate `sha256_checkpointed` with the SHA-256 of the post-checkpoint copy of the database.
6. WHEN the XProtect bundle is captured, THE macaudit SHALL emit one entry per file in the bundle (`Info.plist`, `XProtect.meta.plist`, `XProtect.yara`, `gk.db`, any auxiliary files) each with its raw SHA-256, along with a parent entry recording the bundle version extracted from `Info.plist` and the `codesign --verify --deep --strict` result.
7. WHEN the authorization database is captured, THE macaudit SHALL emit one entry per named rule and one entry per named right, each with its full mechanism list and `class`, `shared`, `timeout`, and `tries` fields when present.

### Requirement 23: SQLite WAL Safe-Copy Protocol

**User Story:** As an operator, I want SQLite databases captured without mutating them, so that forensic integrity is preserved.

#### Acceptance Criteria

1. FOR ALL SQLite database paths `d` to be captured, THE macaudit SHALL copy `d`, `d-wal` (if present), and `d-shm` (if present) into a per-database scratch subdirectory inside its managed tmpdir before reading any content.
2. WHEN copying the files, THE macaudit SHALL use `cp -p` to preserve ownership, mtime, and mode where permitted.
3. WHEN the copies are in place, THE macaudit SHALL run `PRAGMA wal_checkpoint(TRUNCATE)` against the copy — and only the copy — so the database and WAL are consolidated before hashing.
4. THE macaudit SHALL NEVER invoke `PRAGMA wal_checkpoint` or any other `sqlite3` statement against the original `d`, `d-wal`, or `d-shm`.
5. FOR ALL queries against the captured database, THE macaudit SHALL open the checkpointed copy in read-only mode (`sqlite3 -readonly` or `file:<path>?mode=ro`).
6. FOR ALL Tier 3 SQLite entries, THE macaudit SHALL populate `wal_present` with a boolean reflecting whether the source `-wal` file existed at capture time, and `wal_sha256` with the SHA-256 of the source `-wal` bytes (empty string when absent).
7. THE macaudit SHALL guarantee that the original `d`, `d-wal`, and `d-shm` files are byte-identical before and after the tool run.

### Requirement 24: Full Disk Access Probe and Gating

**User Story:** As an operator, I want macaudit to probe for Full Disk Access at startup and skip FDA-protected surfaces cleanly when FDA is not granted, so that I am never surprised by a silent partial baseline.

#### Acceptance Criteria

1. WHEN macaudit starts with Tier 3 enabled, THE macaudit SHALL probe FDA availability by attempting a read-only `SELECT COUNT(*) FROM access` against the checkpointed copy of the system TCC.db.
2. IF the probe succeeds, THEN THE macaudit SHALL set `fda_available` to `true` in the manifest header and in the environment block.
3. IF the probe fails with a permission-denied, `authorization denied`, or `unable to open database file` error, THEN THE macaudit SHALL set `fda_available` to `false`, log the FDA warning message from Requirement 15.7, and skip every FDA-protected Tier 3 surface.
4. THE macaudit SHALL NEVER silently drop a Tier 3 surface because of FDA — every skip SHALL be recorded in `skipped_paths`.
5. THE macaudit SHALL probe FDA exactly once per run and cache the result.
6. WHEN FDA is unavailable, Tier 3 surfaces that are NOT protected by FDA (e.g., the authorization database via `security authorizationdb read`, XProtect bundle metadata, Gatekeeper `spctl --status`) SHALL still be captured normally.

### Requirement 25: TCC Anomaly Rules

**User Story:** As an operator, I want macaudit to flag TCC grants that match known indicators of abuse, so that I can spot override-policy abuse, unsigned FDA grants, and MDM-labeled entries without matching PPPC profiles.

#### Acceptance Criteria

1. FOR ALL rows `r` in the `access` table with `auth_reason = 7` (Override Policy), THE macaudit SHALL add an anomaly `{rule: "tcc_override_policy", severity: "high", detail: "<service> granted to <client> via Override Policy"}` to the entry's `anomalies` array.
2. FOR ALL rows `r` in the `access` table where `service = "kTCCServiceCamera"` or `service = "kTCCServiceMicrophone"` and `auth_reason ≠ 2`, THE macaudit SHALL add an anomaly `{rule: "tcc_av_unusual_reason", severity: "warn", ...}`.
3. FOR ALL rows `r` in the `access` table with `service = "kTCCServiceSystemPolicyAllFiles"` (FDA) where the `client` binary's `codesign --verify` result is a failure, THE macaudit SHALL add an anomaly `{rule: "tcc_fda_unsigned", severity: "high", ...}`.
4. FOR ALL rows `r` with `auth_reason = 6` (MDM policy-set) where no matching `com.apple.TCC.configuration-profile-policy` payload is present in `profiles show -type configuration`, THE macaudit SHALL add an anomaly `{rule: "tcc_mdm_without_profile", severity: "high", ...}`.
5. FOR ALL anomaly rules above, the matching entry's `anomalies` array SHALL contain one object per rule that fires, and the entry SHALL be classified `suspicious` in the audit delta iff its `anomalies` array is non-empty.

### Requirement 26: Authorization Plugin Injection Detection

**User Story:** As an operator, I want macaudit to detect injection into the authorization database by flagging mechanisms whose prefix is not `builtin:` and whose corresponding bundle is not at `/System/Library/CoreServices/SecurityAgentPlugins/`, so that I can spot attempts to backdoor authentication.

#### Acceptance Criteria

1. FOR ALL mechanisms `m` in every parsed authorization rule and right, THE macaudit SHALL classify `m` as one of `builtin`, `system-plugin`, `third-party-plugin`, or `missing` based on its prefix and the presence of the corresponding bundle under `/System/Library/CoreServices/SecurityAgentPlugins/` or `/Library/Security/SecurityAgentPlugins/`.
2. FOR ALL mechanisms `m` classified as `third-party-plugin`, THE macaudit SHALL add an anomaly `{rule: "authdb_third_party_plugin", severity: "warn", detail: "<mechanism> resolves to /Library/Security/SecurityAgentPlugins/..."}` to the authdb entry's `anomalies`.
3. FOR ALL mechanisms `m` classified as `missing`, THE macaudit SHALL add an anomaly `{rule: "authdb_missing_plugin", severity: "high", detail: "<mechanism> does not resolve to any plugin bundle"}` to the authdb entry's `anomalies`.
4. FOR ALL mechanisms `m` with a non-`builtin:` prefix, THE macaudit SHALL flag them (soundness: every flagged mechanism has a non-builtin prefix; completeness: every mechanism with a non-builtin prefix is either classified `system-plugin` without anomaly or classified as one of the two anomalous categories above).
5. THE macaudit SHALL cache the plugin-bundle directory listing once per run and reuse it across every mechanism classification.

### Requirement 27: Cross-Surface Correlation

**User Story:** As an operator, I want macaudit to perform a post-scan validation pass that joins findings across tiers, so that multi-surface attack patterns surface as single high-signal findings rather than three disconnected drifts.

#### Acceptance Criteria

1. AFTER baseline capture completes (and during audit after the re-capture), THE macaudit SHALL run a correlation pass implementing exactly five rules:
   - **R1 TCC ↔ MDM profiles**: every TCC `access` row with `auth_reason = 6` SHALL have a matching `com.apple.TCC.configuration-profile-policy` payload in `profiles show -type configuration`; misses produce a `correlation:tcc_mdm_without_profile` suspicious finding.
   - **R2 Persistence ↔ Quarantine**: for every Tier 1 plist with a non-empty `com.apple.quarantine` xattr, the xattr's UUID SHALL correspond to a row in the operator's LSQuarantineEvent database; misses produce a `correlation:persistence_quarantine_orphan` informational finding; absence of the xattr on a newly-added persistence plist produces a `correlation:persistence_no_quarantine` warning finding.
   - **R3 Persistence ↔ Code Signing**: for every Tier 1 plist whose `Program` or first element of `ProgramArguments` resolves to an absolute path, THE macaudit SHALL run `codesign --verify --deep --strict --` against that path; failures produce a `correlation:persistence_codesign_fail` suspicious finding.
   - **R4 KextPolicy ↔ MDM**: on MDM-managed devices (as reported by `profiles status -type enrollment`), every row in `kext_policy` without a matching row in `kext_policy_mdm` SHALL produce a `correlation:kext_user_approved_on_mdm` suspicious finding.
   - **R5 AuthDB ↔ Plugin Directory**: every mechanism with a non-builtin prefix SHALL resolve to a plugin bundle under `/System/Library/CoreServices/SecurityAgentPlugins/` or `/Library/Security/SecurityAgentPlugins/`; misses produce `correlation:authdb_missing_plugin` suspicious findings (see also Requirement 26).
2. WHEN rule R3 fails, THE macaudit SHALL include in the finding's `detail` field the full exit-code and first stderr line of `codesign --verify`.
3. THE macaudit SHALL emit correlation findings as entries with `surface: "correlation"` and `anomalies` populated with one object per rule hit.
4. FOR ALL correlation findings, classification as `suspicious` SHALL follow the same rule as Tier 3 entries: an entry appears in the `suspicious` delta category iff its `anomalies` array is non-empty in the current state.
5. THE macaudit SHALL guarantee soundness and completeness for each of R1–R5: every flagged instance matches the rule's preconditions, and every instance matching the preconditions is flagged.

### Requirement 28: KextPolicy, ExecPolicy, SystemPolicy, and XProtect Capture

**User Story:** As an operator, I want kernel-extension policy, execution policy, system policy, and XProtect signatures captured deterministically so that I can detect unauthorised kext approvals, Gatekeeper tampering, and XProtect bundle integrity failures.

#### Acceptance Criteria

1. WHEN capturing KextPolicy, THE macaudit SHALL snapshot the `kext_policy` and `kext_policy_mdm` tables with primary key `(team_id, bundle_id)` and emit one entry with `surface: "kextpolicy"`.
2. WHEN capturing ExecPolicy, THE macaudit SHALL snapshot the `legacy_exec_history_v4`, `policy_scan_cache`, and `provisional_policy` tables (present-tables subset), each with the table's own primary key, and emit one entry with `surface: "execpolicy"`.
3. WHEN capturing SystemPolicy, THE macaudit SHALL snapshot the `authority` and `bookmarkhints` tables and emit one entry with `surface: "systempolicy"`, plus capture `spctl --status` and `spctl --test-devid-status` outputs into the entry's `gatekeeper` field.
4. WHEN capturing the XProtect bundle, THE macaudit SHALL extract the bundle version from `Info.plist`, compute raw SHA-256 over every file in the bundle, and run `codesign --verify --deep --strict -- /Library/Apple/System/Library/CoreServices/XProtect.bundle` recording exit status and stderr.
5. IF Gatekeeper is disabled (`spctl --status` reports `assessments disabled`), THEN THE macaudit SHALL add an anomaly `{rule: "gatekeeper_disabled", severity: "high", ...}` to the SystemPolicy entry.
6. IF the XProtect bundle fails codesign verification, THEN THE macaudit SHALL add an anomaly `{rule: "xprotect_codesign_fail", severity: "high", ...}` to the XProtect parent entry.
7. FOR ALL rows `r` in `kext_policy` on an MDM-managed device where no matching row in `kext_policy_mdm` exists, THE macaudit SHALL add an anomaly `{rule: "kext_user_approved_on_mdm", severity: "high", ...}` to the KextPolicy entry's `anomalies`.

### Requirement 29: Suspicious Category in Delta Report

**User Story:** As an operator, I want suspicious anomalies rendered as a dedicated delta category in magenta, so that I cannot miss them in a long report.

#### Acceptance Criteria

1. WHEN the audit delta is rendered, THE macaudit SHALL include a `suspicious` delta category in addition to `added`, `removed`, `modified`, `stale`, and `injections`.
2. FOR ALL current-state entries `e`, `e ∈ suspicious ⟺ |e.anomalies| > 0`.
3. WHEN `suspicious` entries are rendered in human mode, THE macaudit SHALL display a `[⚑] SUSPICIOUS` section header and render each finding with its `rule`, `severity`, and `detail`, colored magenta (when color is supported).
4. WHEN the delta summary is rendered, THE macaudit SHALL include `suspicious: <count>` in the per-tier and total summary lines.

## Versioning Note

Baselines produced by the Tier-1/Tier-2-only build of macaudit carry `manifest_version: "1.0"`. Baselines produced by this amended spec (which includes Tier 3) carry `manifest_version: "1.1"`. The tool accepts both on input to `audit` and `integrity`; when a 1.0 baseline is supplied, Tier 3 entries present in the current state are reported as `added` on first comparison.
