qq# Requirements Document

## Introduction

DORKSTAR is a universal query translation engine built as a SvelteKit application. It converts a single canonical search syntax into 39 engine-native search formats and executes queries in parallel across multiple search platforms. The system targets security researchers, OSINT practitioners, investigative journalists, and bug bounty hunters who need to search across many platforms simultaneously without manually reformulating queries per engine.

The system parses a canonical query string into an Operator AST via a PEG grammar, translates that AST into each engine's native syntax, dispatches requests in parallel through a worker pool with per-engine rate limiting, and normalizes results into a unified, deduplicated view. All API keys are stored exclusively in browser IndexedDB — no server-side key storage exists.

## Glossary

- **Parser**: The PEG grammar parser component (`src/lib/parser/`) that converts raw canonical query strings into a typed Operator AST using the Ohm library.
- **AST**: Operator Abstract Syntax Tree — the typed tree representation of a parsed canonical query, composed of `ASTNode` union type members.
- **ASTNode**: A single node in the Operator AST; one of `BooleanExpr`, `OperatorExpr`, `ExcludeTerm`, `IncludeTerm`, `ExactPhrase`, `ProximityExpr`, `RangeExpr`, `WildcardPhrase`, or `BareWord`.
- **CanonicalOperator**: A named search operator in the canonical query language (e.g., `site`, `filetype`, `port`, `ip`, `vuln`).
- **TranslationManager**: The component (`src/lib/translation/manager.ts`) that converts an AST into engine-native query strings for all active engines.
- **EngineAdapter**: A per-engine module (`src/lib/translation/adapters/`) that encapsulates translation logic and operator support for one search engine.
- **DegradationWarning**: A structured warning emitted when a canonical operator has no equivalent in a target engine.
- **WorkerPool**: The Web Worker pool (`src/lib/dispatch/worker-pool.ts`) that executes translated queries against engines in parallel.
- **RateLimiter**: The token-bucket rate limiter (`src/lib/dispatch/rate-limiter.ts`) that enforces per-engine request quotas.
- **ResultNormalizer**: The component (`src/lib/results/normalizer.ts`) that merges raw results from all engines into a unified, deduplicated, scored result set.
- **KeyStore**: The IndexedDB-backed key store (`src/lib/keystore/index.ts`) that manages per-engine API keys exclusively in the browser.
- **NormalizedResult**: A deduplicated, scored result entry with engine attribution, canonical identifier, title, snippet, and metadata.
- **ResultSet**: The complete output of a query execution, containing `NormalizedResult[]`, view mode, per-engine counts, and deduplication statistics.
- **EngineId**: A string literal type identifying one of the 39 supported search engines (e.g., `google`, `shodan`, `censys`).
- **Tier 1 Engine**: An engine with a full API requiring an API key, dispatched via `fetch` in a Web Worker.
- **Tier 2 Engine**: An engine with a limited free API, dispatched via `fetch` in a Web Worker.
- **Tier 3 Engine**: An engine with no public API, dispatched via a Playwright headless browser pool on the server.
- **ViewMode**: One of `unified`, `by-engine`, or `deduplicated` — controls how results are presented in the Results Panel.
- **QuerySession**: A record of a single query execution including the canonical query, AST, active engines, translations, and result set reference.
- **EngineCategory**: A classification of engines into one of `web`, `iot`, `code`, `threat`, `paste`, `social`, `academic`, or `all`.
- **CreditModel**: A per-engine configuration describing the cost unit, cost per unit, and whether user confirmation is required before dispatch.
- **Pretty_Printer**: A function that serializes an `ASTNode` back into a canonical query string.

---

## Requirements

### Requirement 1: Canonical Query Parsing

**User Story:** As a security researcher, I want to write queries in a single canonical syntax, so that I do not need to learn the native syntax of each search engine.

#### Acceptance Criteria

1. WHEN a user provides a non-empty canonical query string, THE Parser SHALL parse it into a typed `ASTNode` tree with zero parse errors.
2. WHEN a user provides a query string containing a syntax error, THE Parser SHALL return a `ParseError[]` array where each entry contains a `message`, a `position` character index, and a `length` value.
3. WHEN a user provides an empty string, THE Parser SHALL return `{ ast: null, errors: [] }` without throwing an exception.
4. THE Parser SHALL support all `CanonicalOperator` values defined in the grammar specification.
5. WHEN a query contains a `BooleanExpr` node, THE Parser SHALL set `op` to one of `AND`, `OR`, or `NOT`.
6. WHEN a query contains a `RangeExpr` node with two numeric bounds, THE Parser SHALL ensure `min` is less than or equal to `max`.
7. WHEN a query contains a `ProximityExpr` node, THE Parser SHALL ensure `distance` is a positive integer.
8. WHEN a query contains a `WildcardPhrase` node, THE Parser SHALL ensure `pattern` contains at least one `*` or `?` character.
9. THE Pretty_Printer SHALL serialize any valid `ASTNode` back into a canonical query string.
10. FOR ALL valid canonical query strings `q`, parsing `q` then printing the resulting AST then parsing again SHALL produce an AST equivalent to the first parse (round-trip property).

---

### Requirement 2: Engine Translation

**User Story:** As a security researcher, I want my canonical query automatically translated into each engine's native syntax, so that I can search all platforms without reformulating queries manually.

#### Acceptance Criteria

1. WHEN `translateAll(ast, engines)` is called, THE TranslationManager SHALL return exactly `engines.length` `TranslationResult` objects.
2. WHEN `translateAll(ast, engines)` is called, THE TranslationManager SHALL set `result[i].engineId` equal to `engines[i]` for every valid index `i`.
3. WHEN a `CanonicalOperator` in the AST is not supported by a target engine, THE EngineAdapter SHALL record a `DegradationWarning` for that operator in `TranslationResult.degradations`.
4. WHEN a `CanonicalOperator` in the AST is not supported by a target engine, THE EngineAdapter SHALL NOT silently omit the operator without recording a `DegradationWarning`.
5. WHEN `TranslationResult.degradations` is empty, THE TranslationManager SHALL set `TranslationResult.isFullySupported` to `true`.
6. WHEN `TranslationResult.degradations` is non-empty, THE TranslationManager SHALL set `TranslationResult.isFullySupported` to `false`.
7. THE TranslationManager SHALL maintain a registry of exactly 39 `EngineAdapter` instances, one per supported `EngineId`.
8. WHEN `translateFrom(sourceEngine, ast, targetEngines)` is called, THE TranslationManager SHALL return one `TranslationResult` per engine in `targetEngines`.
9. WHEN `getCommonOperators(engines)` is called, THE TranslationManager SHALL return the intersection of `supportedOperators` across all specified engines.
10. THE EngineAdapter SHALL handle engine-specific quoting, escaping, and boolean syntax without exposing raw canonical syntax to the engine.

---

### Requirement 3: Engine Adapter Coverage

**User Story:** As a security researcher, I want DORKSTAR to support all 39 search engines, so that I can reach the broadest possible set of data sources from a single query.

#### Acceptance Criteria

1. THE system SHALL include an `EngineAdapter` for each of the following engines: `google`, `bing`, `yandex`, `duckduckgo`, `baidu`, `yahoo`, `shodan`, `censys`, `fofa`, `zoomeye`, `binaryedge`, `onyphe`, `leakix`, `netlas`, `criminalip`, `hunter`, `fullhunt`, `github`, `gitlab`, `sourcegraph`, `grep_app`, `virustotal`, `urlscan`, `alienvault`, `threatcrowd`, `pastebin`, `gist`, `publicwww`, `grep_io`, `twitter`, `reddit`, `linkedin`, `arxiv`, `semantic_scholar`, `pubmed`, `qwant`, `ecosia`, `seznam`, `sogou`.
2. WHEN an `EngineAdapter` is instantiated, THE EngineAdapter SHALL declare a non-empty `supportedOperators` set.
3. WHEN an `EngineAdapter` is instantiated, THE EngineAdapter SHALL set `operatorCount` equal to `supportedOperators.size`.
4. THE system SHALL classify `qwant`, `ecosia`, `seznam`, `sogou`, `daum`, `coccoc`, and `mail.ru` as Tier 3 engines dispatched via the Playwright headless pool.
5. THE system SHALL classify engines requiring an API key as Tier 1 and dispatch them via `fetch` in a Web Worker.
6. THE system SHALL classify engines with a limited free API as Tier 2 and dispatch them via `fetch` in a Web Worker.

---

### Requirement 4: Parallel Query Dispatch

**User Story:** As a security researcher, I want queries dispatched to all selected engines simultaneously, so that total search time is bounded by the slowest engine rather than the sum of all engines.

#### Acceptance Criteria

1. WHEN `dispatch(queries)` is called with `N` engine queries, THE WorkerPool SHALL return exactly `N` `RawResult` objects upon completion.
2. WHEN an engine query fails, THE WorkerPool SHALL return a `RawResult` with an empty `items` array and a populated `error` field of type `DispatchError`, rather than throwing an exception.
3. WHEN dispatching Tier 1 and Tier 2 engine queries, THE WorkerPool SHALL execute them via Web Workers using `fetch`.
4. WHEN dispatching Tier 3 engine queries, THE WorkerPool SHALL route them to the server-side Playwright headless pool endpoint.
5. WHEN `dispatch(queries)` is called, THE WorkerPool SHALL execute all engine queries concurrently rather than sequentially.
6. WHEN an engine returns HTTP 429, THE WorkerPool SHALL set `DispatchError.code` to `rate_limited` and populate `DispatchError.retryAfter` with the reset timestamp.
7. WHEN an engine returns HTTP 401 or HTTP 403, THE WorkerPool SHALL set `DispatchError.code` to `auth_failed`.
8. WHEN a Tier 3 engine returns a CAPTCHA or bot-detection page, THE WorkerPool SHALL set `DispatchError.code` to `anti_bot` and SHALL NOT automatically retry.
9. AFTER `dispatch(queries)` completes, THE RateLimiter SHALL update the quota state for each engine that was dispatched.

---

### Requirement 5: Per-Engine Rate Limiting

**User Story:** As a security researcher, I want per-engine rate limits enforced automatically, so that I do not accidentally exhaust API quotas or get blocked by engines.

#### Acceptance Criteria

1. THE RateLimiter SHALL implement a token-bucket algorithm with a configurable `requestsPerMinute` capacity.
2. WHEN `acquire()` is called and a token is available, THE RateLimiter SHALL consume exactly one token and return immediately.
3. WHEN `acquire()` is called and no token is available, THE RateLimiter SHALL wait until a token is available before returning.
4. WHILE the RateLimiter is operating, THE RateLimiter SHALL keep `tokens` within the range `[0, capacity]` at all times.
5. WHEN multiple concurrent `acquire()` calls are made for the same engine, THE RateLimiter SHALL serialize token consumption so that no more tokens are consumed than are available.
6. THE RateLimiter SHALL refill tokens continuously based on elapsed time at a rate of `requestsPerMinute / 60000` tokens per millisecond.

---

### Requirement 6: Credit Confirmation Gate

**User Story:** As a security researcher, I want to be warned before consuming paid API credits, so that I do not accidentally exhaust my Shodan or other paid engine quotas.

#### Acceptance Criteria

1. WHEN a query is dispatched to an engine where `creditModel.requiresConfirmation === true`, THE WorkerPool SHALL display a credit confirmation dialog showing the estimated credit cost before executing the query.
2. WHEN the user cancels the credit confirmation dialog, THE WorkerPool SHALL return an empty `RawResult` for that engine and SHALL NOT execute the query.
3. WHEN the user confirms the credit confirmation dialog, THE WorkerPool SHALL proceed with query execution for that engine.
4. THE system SHALL set `creditModel.requiresConfirmation` to `true` for Shodan and for any engine where `creditModel.costPerUnit > 0`.

---

### Requirement 7: Result Normalization and Deduplication

**User Story:** As a security researcher, I want results from all engines merged into a single deduplicated view, so that I can identify unique findings without manually cross-referencing engine outputs.

#### Acceptance Criteria

1. WHEN `normalize(rawResults)` is called, THE ResultNormalizer SHALL set `resultSet.deduplicationStats.totalRaw` equal to the sum of `items.length` across all `RawResult` entries.
2. WHEN `normalize(rawResults)` is called, THE ResultNormalizer SHALL set `resultSet.deduplicationStats.totalUnique` to a value less than or equal to `totalRaw`.
3. WHEN two or more raw results share the same canonical identifier, THE ResultNormalizer SHALL merge their `EngineAttribution` entries into a single `NormalizedResult`.
4. WHEN results are deduplicated, THE ResultNormalizer SHALL ensure each `canonicalIdentifier` appears exactly once in the output.
5. WHEN results are deduplicated, THE ResultNormalizer SHALL ensure every `EngineAttribution` from the input appears in exactly one output `NormalizedResult`.
6. THE ResultNormalizer SHALL compute a `score` for each `NormalizedResult` based on engine attribution count and recency weight.
7. WHEN `normalize(rawResults)` is called, THE ResultNormalizer SHALL set `resultSet.totalByEngine[engineId]` equal to the count of raw items from that engine.
8. WHEN a `NormalizedResult` is produced, THE ResultNormalizer SHALL ensure it has at least one `EngineAttribution`.
9. THE ResultNormalizer SHALL normalize URLs by stripping trailing slashes, lowercasing scheme and host, and removing UTM parameters before deduplication.

---

### Requirement 8: Result View Modes

**User Story:** As a security researcher, I want to view results in multiple modes, so that I can analyze findings from different perspectives.

#### Acceptance Criteria

1. THE Results Panel SHALL support a `unified` view mode that interleaves results from all engines sorted by score.
2. THE Results Panel SHALL support a `by-engine` view mode that presents results in separate tabs per engine.
3. THE Results Panel SHALL support a `deduplicated` view mode that shows only unique results with merged engine attributions.
4. WHEN the user switches view mode, THE Results Panel SHALL re-render the current `ResultSet` in the selected mode without re-executing the query.

---

### Requirement 9: Result Export

**User Story:** As a security researcher, I want to export results in standard formats, so that I can share findings and integrate them into reports.

#### Acceptance Criteria

1. THE ResultNormalizer SHALL export `NormalizedResult[]` to a JSON `Blob` when `format` is `json`.
2. THE ResultNormalizer SHALL export `NormalizedResult[]` to a CSV `Blob` when `format` is `csv`.
3. THE ResultNormalizer SHALL export `NormalizedResult[]` to a PDF `Blob` when `format` is `pdf`.
4. THE system SHALL generate all export formats client-side without transmitting result data to any server endpoint.

---

### Requirement 10: API Key Management

**User Story:** As a security researcher, I want to store my API keys locally in the browser, so that my credentials are never transmitted to or stored on any server.

#### Acceptance Criteria

1. THE KeyStore SHALL store all API keys exclusively in browser IndexedDB.
2. WHEN `setKey(engineId, key)` is called, THE KeyStore SHALL persist the key to IndexedDB without transmitting it to any server endpoint.
3. WHEN `getKey(engineId)` is called for an engine with no stored key, THE KeyStore SHALL return `null`.
4. WHEN `deleteKey(engineId)` is called, THE KeyStore SHALL remove the key for that engine from IndexedDB.
5. WHEN `clearAll()` is called, THE KeyStore SHALL remove all keys from IndexedDB.
6. THE system SHALL never include API key values in any outbound network request to a server endpoint.
7. WHEN `listEnginesWithKeys()` is called, THE KeyStore SHALL return the list of `EngineId` values for which a key is currently stored.

---

### Requirement 11: Engine Selector UI

**User Story:** As a security researcher, I want to select and organize which engines to query, so that I can focus searches on relevant data sources.

#### Acceptance Criteria

1. THE Engine Selector Bar SHALL display engines grouped into category tabs: `web`, `iot`, `code`, `threat`, `paste`, `social`, `academic`, and `all`.
2. THE Engine Selector Bar SHALL display each engine as a chip showing the engine name and its supported operator count.
3. WHEN the user toggles an engine chip, THE EngineStore SHALL add or remove that engine from `activeEngines`.
4. WHEN the user clicks a category tab, THE EngineStore SHALL toggle all engines in that category simultaneously.
5. WHEN the user reorders engine chips via drag-and-drop, THE EngineStore SHALL update `engineOrder` to reflect the new order.
6. WHEN the user modifies engine selection or order, THE EngineStore SHALL persist the updated state to `localStorage`.
7. WHEN the application loads, THE EngineStore SHALL restore `activeEngines` and `engineOrder` from `localStorage`.

---

### Requirement 12: Query Composer UI

**User Story:** As a security researcher, I want a rich query input interface, so that I can compose, preview, and refine canonical queries efficiently.

#### Acceptance Criteria

1. WHEN the user types in the canonical query input, THE Query Composer SHALL parse the input in real time and display inline error highlights at the positions reported by `ParseError`.
2. WHEN the user types in the canonical query input, THE Query Composer SHALL display a real-time translation preview showing the native query string for each active engine.
3. WHEN a translation contains a `DegradationWarning`, THE Query Composer SHALL display a ⚠ badge on the affected engine chip and an inline warning in the translation preview.
4. WHEN the user presses Ctrl+Enter, THE Query Composer SHALL execute the query against all active engines.
5. WHEN the user presses Ctrl+Shift+E, THE Query Composer SHALL toggle Per-Engine mode, rendering individual input rows for each active engine.
6. WHILE in Per-Engine mode, THE Query Composer SHALL allow the user to edit each engine's query independently.
7. WHILE in Per-Engine mode, THE Query Composer SHALL provide a "Clone & Translate" action that calls `translateFrom` to propagate one engine's query to all other active engines.
8. THE Query Composer SHALL provide operator autocomplete that shows only operators returned by `getCommonOperators(activeEngines)` when in Unified mode.

---

### Requirement 13: Budget Footer

**User Story:** As a security researcher, I want to see real-time quota and rate limit status for each engine, so that I can manage my API usage proactively.

#### Acceptance Criteria

1. THE Budget Footer SHALL display per-engine quota usage as `quotaUsed / quotaLimit` for each active engine.
2. WHEN an engine is rate-limited, THE Budget Footer SHALL display the engine as rate-limited with the reset time.
3. WHEN an engine's `DispatchError.code` is `rate_limited`, THE Budget Footer SHALL update that engine's status to show "Rate limited — resets at HH:MM".

---

### Requirement 14: Query Session Persistence

**User Story:** As a security researcher, I want my query sessions recorded, so that I can review and re-execute past searches.

#### Acceptance Criteria

1. WHEN a query is executed, THE system SHALL create a `QuerySession` record containing the `canonicalQuery`, `ast`, `mode`, `activeEngines`, and `translations`.
2. WHEN a `ResultSet` is produced, THE system SHALL associate it with the corresponding `QuerySession` via `resultSetId`.
3. THE `QuerySession.id` SHALL be a unique identifier generated at session creation time.

---

### Requirement 15: Tier 3 Engine Dispatch

**User Story:** As a security researcher, I want to query engines that have no public API, so that I can access data sources that are only available through a web browser.

#### Acceptance Criteria

1. WHEN a Tier 3 engine query is dispatched, THE system SHALL route it to the server-side SvelteKit endpoint at `/api/dispatch`.
2. WHEN the Playwright headless pool executes a Tier 3 query, THE server SHALL NOT log or persist the query content beyond the current session.
3. WHEN a Tier 3 engine returns a CAPTCHA or bot-detection page, THE system SHALL return a `DispatchError` with `code: 'anti_bot'` and SHALL inform the user that Tier 3 engine availability is best-effort.
4. WHEN Tier 3 results arrive asynchronously, THE Results Panel SHALL stream them into the display as they complete rather than waiting for all engines to finish.

---

### Requirement 16: Security and Privacy

**User Story:** As a security researcher, I want the application to follow secure coding practices, so that my API keys and query data are not exposed to unauthorized parties.

#### Acceptance Criteria

1. THE SvelteKit application SHALL set a strict Content Security Policy to prevent XSS attacks that could exfiltrate IndexedDB keys.
2. THE system SHALL parse all canonical query strings through the PEG grammar before constructing engine URLs, and SHALL NOT interpolate raw query strings into engine URLs without adapter-level escaping.
3. THE system SHALL generate PDF and CSV exports client-side to avoid server-side retention of result data.
4. WHEN the Playwright server-side endpoint processes a Tier 3 query, THE server SHALL NOT store API key values received from the client.
5. THE system SHALL scope its functionality exclusively to publicly accessible search engines and SHALL NOT include any credential-testing or authentication-bypass capabilities.

---

### Requirement 17: Engine Registry Integrity

**User Story:** As a developer, I want the engine registry to be self-consistent, so that runtime behavior matches declared capabilities.

#### Acceptance Criteria

1. WHEN an `EngineRegistryEntry` is created, THE system SHALL ensure `operatorCount` equals `supportedOperators.length`.
2. WHEN an `EngineRegistryEntry` is created, THE system SHALL ensure `tier` is one of `1`, `2`, or `3`.
3. WHEN an `EngineRegistryEntry` is created, THE system SHALL ensure `rateLimit.requestsPerMinute` is greater than zero.
4. WHEN an `EngineRegistryEntry` is created with `creditModel.costPerUnit > 0`, THE system SHALL ensure `creditModel.requiresConfirmation` is `true`.
