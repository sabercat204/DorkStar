# Implementation Plan: DORKSTAR

## Overview

Implementation follows a bottom-up dependency order: PEG grammar → parser → engine adapters (priority four first, then remaining 35) → dispatch infrastructure → frontend zones → budget footer → docs → test matrix → Docker. The project is a SvelteKit 5 (Runes mode) TypeScript application. Tests use Vitest for unit tests and fast-check for property-based tests.

## Tasks

- [x] 1. Bootstrap project dependencies and test infrastructure
  - Install `ohm-js`, `idb`, `nanoid`, `pdfmake`, `papaparse` as runtime dependencies
  - Install `vitest`, `fast-check`, `@playwright/test`, `better-sqlite3` as dev dependencies
  - Add `"test": "vitest --run"` and `"test:watch": "vitest"` scripts to `package.json`
  - Configure `vite.config.ts` to include Vitest configuration with `globals: true` and `environment: 'jsdom'`
  - Create `dorkstar/src/lib/parser/`, `dorkstar/src/lib/translation/adapters/`, `dorkstar/src/lib/dispatch/`, `dorkstar/src/lib/results/`, `dorkstar/src/lib/keystore/`, `dorkstar/src/lib/stores/` directories
  - _Requirements: 1.1, 2.7, 3.1_


- [x] 2. Define PEG grammar and parser types (ARCH-001)
  - [x] 2.1 Create `src/lib/parser/types.ts` with all AST node interfaces
    - Define `NodeKind` union, `ASTNode` base interface, and all 9 node types: `BooleanExpr`, `OperatorExpr`, `ExcludeTerm`, `IncludeTerm`, `ExactPhrase`, `ProximityExpr`, `RangeExpr`, `WildcardPhrase`, `BareWord`
    - Define `CanonicalOperator` string literal union with all operators from the design spec
    - Define `ParseResult`, `ParseError`, `RangeValue`, `WildcardValue` interfaces
    - _Requirements: 1.1, 1.4, 1.5, 1.6, 1.7, 1.8_

  - [x] 2.2 Create `src/lib/parser/grammar.ohm` — the Ohm PEG grammar
    - Define grammar rules for `Query`, `BooleanExpr` (AND/OR/NOT), `OperatorExpr` (all `CanonicalOperator` values), `ExactPhrase`, `ExcludeTerm`, `IncludeTerm`, `ProximityExpr` (NEAR/n), `RangeExpr`, `WildcardPhrase`, `BareWord`
    - Ensure operator names match the `CanonicalOperator` type exactly
    - _Requirements: 1.1, 1.4, 1.5, 1.6, 1.7, 1.8_

  - [x] 2.3 Create `src/lib/parser/index.ts` — `parseQuery()`, `validateQuery()`, and `prettyPrint()`
    - Implement `parseQuery(input: string): ParseResult` using the Ohm grammar; return `{ ast: null, errors: [] }` for empty input; never throw
    - Implement `validateQuery(input: string): ParseError[]` as a thin wrapper
    - Implement `prettyPrint(node: ASTNode): string` (Pretty_Printer) that serializes any `ASTNode` back to canonical query string
    - Enforce `RangeExpr.min <= max`, `ProximityExpr.distance > 0`, `WildcardPhrase.pattern` contains `*` or `?` during AST construction
    - _Requirements: 1.1, 1.2, 1.3, 1.6, 1.7, 1.8, 1.9_

  - [ ]* 2.4 Write property test: Parse Round-Trip Stability (Property 1)
    - **Property 1: Parse Round-Trip Stability**
    - Use `fc.string()` to generate arbitrary query strings; for any string where `parseQuery` returns a non-null AST, assert that `parseQuery(prettyPrint(ast))` produces a structurally equivalent AST
    - **Validates: Requirements 1.9, 1.10**

  - [ ]* 2.5 Write property test: Parse Error Structure Completeness (Property 2)
    - **Property 2: Parse Error Structure Completeness**
    - Generate strings that produce parse errors; assert every `ParseError` has non-empty `message`, valid `position` index within input, and non-negative `length`
    - **Validates: Requirements 1.2**

  - [ ]* 2.6 Write property test: AST Node Invariants (Property 3)
    - **Property 3: AST Node Invariants**
    - Build an `fc.Arbitrary<ASTNode>` generator; for any generated AST, assert `BooleanExpr.op ∈ {AND,OR,NOT}`, `RangeExpr.min ≤ max` (numeric), `ProximityExpr.distance > 0`, `WildcardPhrase.pattern` contains `*` or `?`
    - **Validates: Requirements 1.5, 1.6, 1.7, 1.8**

  - [ ]* 2.7 Write unit tests for `parseQuery()` and `prettyPrint()`
    - Test empty string returns `{ ast: null, errors: [] }`
    - Test each `CanonicalOperator` parses correctly
    - Test syntax errors return `ParseError[]` with correct positions
    - Test `prettyPrint` round-trips for all node kinds
    - _Requirements: 1.1, 1.2, 1.3, 1.9_


- [x] 3. Checkpoint — parser layer complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Implement Translation Manager and base adapter (ARCH-002)
  - [x] 4.1 Create `src/lib/translation/types.ts`
    - Define `TranslationResult`, `DegradationWarning`, `EngineId` (39-value union), `EngineCategory` types
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6_

  - [x] 4.2 Create `src/lib/translation/adapters/base.ts` — `EngineAdapter` interface
    - Define `EngineAdapter` interface with `engineId`, `displayName`, `category`, `tier`, `supportedOperators`, `operatorCount`, `translate()`, `translateNode()`, `supportsOperator()`
    - Implement `AbstractEngineAdapter` base class with shared `translate()` logic: walk AST via `translateNode()`, collect `DegradationWarning` for every unsupported operator, set `isFullySupported`
    - Implement `formatBoolean()`, `escapeBareWord()`, `translateRange()`, `translateWildcard()` as overridable methods with sensible defaults
    - _Requirements: 2.3, 2.4, 2.10, 3.2, 3.3_

  - [x] 4.3 Create `src/lib/translation/manager.ts` — `TranslationManager`
    - Implement `translateAll(ast, engines): TranslationResult[]` — returns exactly `engines.length` results with `result[i].engineId === engines[i]`
    - Implement `translateOne(ast, engineId): TranslationResult`
    - Implement `translateFrom(sourceEngine, ast, targetEngines): TranslationResult[]`
    - Implement `getSupportedOperators(engineId): CanonicalOperator[]`
    - Implement `getCommonOperators(engines): CanonicalOperator[]` — returns intersection of `supportedOperators` across all specified engines
    - Wire adapter registry (populated in task 5)
    - _Requirements: 2.1, 2.2, 2.7, 2.8, 2.9_

  - [ ]* 2.8 Write property test: Translation Count and Order Invariant (Property 5)
    - **Property 5: Translation Count and Order Invariant**
    - Use `fc.array(fc.constantFrom(...ALL_ENGINE_IDS), { minLength: 1, maxLength: 39 })` and an arbitrary AST; assert `translateAll(ast, engines).length === engines.length` and `result[i].engineId === engines[i]`
    - **Validates: Requirements 2.1, 2.2, 2.8**

  - [ ]* 2.9 Write property test: isFullySupported Consistency (Property 6)
    - **Property 6: isFullySupported Consistency**
    - For any `TranslationResult`, assert `isFullySupported === (degradations.length === 0)`
    - **Validates: Requirements 2.5, 2.6**

  - [ ]* 2.10 Write property test: Common Operators Intersection (Property 7)
    - **Property 7: Common Operators Intersection**
    - For any non-empty subset of engine IDs, assert every operator returned by `getCommonOperators(engines)` is present in every engine's `supportedOperators`
    - **Validates: Requirements 2.9**


- [x] 5. Implement priority engine adapters: Google, Bing, Yandex, Shodan
  - [x] 5.1 Create `src/lib/translation/adapters/google.ts` — `GoogleAdapter`
    - Tier 2, category `web`; supported operators: `site`, `filetype`, `intitle`, `allintitle`, `inurl`, `allinurl`, `intext`, `allintext`, `inanchor`, `allinanchor`, `related`, `cache`, `define`, `daterange`, `before`, `after`, `lang`, `loc`
    - Boolean syntax: `AND`, `OR`, `-` for NOT; quote phrases with `""`
    - Record `DegradationWarning` for all unsupported operators (ip, port, asn, vuln, ssl.*, http.*, services.*, etc.)
    - _Requirements: 2.3, 2.4, 2.10, 3.1, 3.5_

  - [x] 5.2 Create `src/lib/translation/adapters/bing.ts` — `BingAdapter`
    - Tier 2, category `web`; supported operators: `site`, `filetype`, `intitle`, `inurl`, `inbody`, `inanchor`, `contains`, `prefer`, `language`, `loc`, `feed`, `hasfeed`, `url`, `ip`
    - Boolean syntax: `AND`, `OR`, `NOT`; quote phrases with `""`
    - _Requirements: 2.3, 2.4, 2.10, 3.1, 3.5_

  - [x] 5.3 Create `src/lib/translation/adapters/yandex.ts` — `YandexAdapter`
    - Tier 2, category `web`; supported operators: `site`, `url`, `title` (maps to `intitle`), `mime` (maps to `filetype`), `lang`, `date`
    - Boolean syntax: `&&`, `||`, `~~` for NOT; Yandex-specific operator syntax
    - _Requirements: 2.3, 2.4, 2.10, 3.1, 3.5_

  - [x] 5.4 Create `src/lib/translation/adapters/shodan.ts` — `ShodanAdapter`
    - Tier 1, category `iot`; supported operators: `ip`, `port`, `hostname`, `org`, `asn`, `net`, `country`, `city`, `os`, `product`, `version`, `ssl.jarm`, `ssl.ja3s`, `http.favicon.hash`, `has_screenshot`, `http.title`, `http.body`, `before`, `after`
    - Boolean syntax: `AND`, `OR`, `NOT`; Shodan filter syntax `key:value`
    - Set `creditModel: { unit: 'query', costPerUnit: 1, requiresConfirmation: true }`
    - _Requirements: 2.3, 2.4, 2.10, 3.1, 3.4, 6.4_

  - [ ]* 5.5 Write property test: No Silent Operator Drops (Property 4) — priority adapters
    - **Property 4: No Silent Operator Drops**
    - For Google, Bing, Yandex, Shodan adapters: generate arbitrary `OperatorExpr` nodes; for any operator not in `supportedOperators`, assert `translate(node).degradations` contains a warning for that operator
    - **Validates: Requirements 2.3, 2.4**

  - [ ]* 5.6 Write unit tests for priority adapters
    - For each of Google, Bing, Yandex, Shodan: test every supported operator produces correct native syntax; test every unsupported operator produces a `DegradationWarning`; test boolean formatting; test quoting/escaping
    - _Requirements: 2.3, 2.4, 2.10_


- [x] 6. Implement remaining 35 engine adapters
  - [x] 6.1 Create web-tier adapters: `duckduckgo.ts`, `baidu.ts`, `yahoo.ts`, `qwant.ts`, `ecosia.ts`, `seznam.ts`, `sogou.ts`
    - `duckduckgo`, `baidu`, `yahoo`: Tier 2, category `web`; declare supported operators and boolean syntax per engine docs
    - `qwant`, `ecosia`, `seznam`, `sogou`: Tier 3, category `web`; dispatched via Playwright headless pool
    - _Requirements: 3.1, 3.4, 3.5, 3.6_

  - [x] 6.2 Create IoT/network adapters: `censys.ts`, `fofa.ts`, `zoomeye.ts`, `binaryedge.ts`, `onyphe.ts`, `leakix.ts`, `netlas.ts`, `criminalip.ts`, `hunter.ts`, `fullhunt.ts`
    - All Tier 1, category `iot`; each declares its own `supportedOperators` set and native query syntax
    - Censys uses `services.port`, `metadata.os`, `location.country_code` syntax; FOFA uses `&&`/`||` with `key="value"` syntax; ZoomEye uses `app:`, `ver:`, `device:` syntax
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [x] 6.3 Create code-search adapters: `github.ts`, `gitlab.ts`, `sourcegraph.ts`, `grep_app.ts`
    - All Tier 1, category `code`; GitHub supports `repo:`, `user:`, `path:`, `content:`, `symbol:`, `language:`, `extension:`; Sourcegraph supports `repo:`, `file:`, `lang:`, `content:`
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [x] 6.4 Create threat-intel adapters: `virustotal.ts`, `urlscan.ts`, `alienvault.ts`, `threatcrowd.ts`
    - All Tier 1, category `threat`; VirusTotal supports `url:`, `domain:`, `ip:`, `tag:`, `labels:`; URLScan supports `domain:`, `ip:`, `url:`, `page.title:`, `tech:`
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [x] 6.5 Create paste/content adapters: `pastebin.ts`, `gist.ts`, `publicwww.ts`, `grep_io.ts`
    - All Tier 1, category `paste`; declare supported operators (mostly keyword/content search with limited operator support)
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [x] 6.6 Create social adapters: `twitter.ts`, `reddit.ts`, `linkedin.ts`
    - All Tier 1, category `social`; Twitter supports `from:`, `to:`, `since:`, `until:`, `min_retweets:`, `min_faves:`, `min_replies:`, `filter:`, `lang:`; Reddit supports `author:`, `subreddit:`, `flair:`, `self:`, `selftext:`, `title:`, `before:`, `after:`
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [x] 6.7 Create academic adapters: `arxiv.ts`, `semantic_scholar.ts`, `pubmed.ts`
    - All Tier 1, category `academic`; arXiv supports `ti:` (title), `au:` (author), `abs:` (abstract), `cat:` (category), `submittedDate:`; Semantic Scholar supports `fieldsOfStudy:`, `venue:`, `minCitationCount:`, `matchType:`; PubMed supports `[Title]`, `[Author]`, `[MeSH Terms]`, `[Publication Type]`
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [x] 6.8 Create `src/lib/translation/adapters/registry.ts` — engine registry with all 39 entries
    - Instantiate all 39 adapters and export as `adapterRegistry: Map<EngineId, EngineAdapter>`
    - Export `ENGINE_REGISTRY: EngineRegistryEntry[]` with full metadata (tier, category, baseUrl, apiEndpoint, docsUrl, supportedOperators, operatorCount, requiresKey, creditModel, rateLimit) for all 39 engines
    - Ensure `operatorCount === supportedOperators.size` for every entry
    - Ensure `creditModel.requiresConfirmation === true` for Shodan and any engine with `costPerUnit > 0`
    - _Requirements: 2.7, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 6.4, 17.1, 17.2, 17.3, 17.4_

  - [ ]* 6.9 Write property test: Engine Registry Self-Consistency (Property 8)
    - **Property 8: Engine Registry Self-Consistency**
    - For every entry in `ENGINE_REGISTRY`: assert `operatorCount === supportedOperators.length`, `tier ∈ {1,2,3}`, `rateLimit.requestsPerMinute > 0`, and if `creditModel.costPerUnit > 0` then `creditModel.requiresConfirmation === true`
    - **Validates: Requirements 3.2, 3.3, 6.4, 17.1, 17.2, 17.3, 17.4**

  - [ ]* 6.10 Write property test: No Silent Operator Drops (Property 4) — all 39 adapters
    - **Property 4: No Silent Operator Drops (full coverage)**
    - Extend the Property 4 test from task 5.5 to cover all 39 adapters; use `fc.constantFrom(...ALL_ENGINE_IDS)` to sample adapters
    - **Validates: Requirements 2.3, 2.4**

  - [ ]* 6.11 Write unit tests for remaining 35 adapters
    - For each adapter: test at least one supported operator produces correct native syntax; test at least one unsupported operator produces a `DegradationWarning`; test `operatorCount === supportedOperators.size`
    - _Requirements: 2.3, 2.4, 3.2, 3.3_


- [x] 7. Checkpoint — translation layer complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. Implement Rate Limiter
  - [x] 8.1 Create `src/lib/dispatch/rate-limiter.ts` — `TokenBucketRateLimiter`
    - Implement `TokenBucketRateLimiter` class with `capacity`, `refillRate` (tokens/ms = `requestsPerMinute / 60000`), `tokens`, `lastRefill`
    - Implement `async acquire(): Promise<void>` — refill tokens based on elapsed time, consume one token, wait if none available
    - Ensure `tokens` stays within `[0, capacity]` at all times
    - Serialize concurrent `acquire()` calls per instance using a promise queue to prevent over-consumption
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

  - [ ]* 8.2 Write property test: Rate Limiter Token Conservation (Property 11)
    - **Property 11: Rate Limiter Token Conservation**
    - Generate sequences of `acquire()` calls; assert `tokens` remains in `[0, capacity]` after each call and each resolved call consumed exactly one token
    - **Validates: Requirements 5.2, 5.4**

  - [ ]* 8.3 Write property test: Rate Limiter Refill Correctness (Property 12)
    - **Property 12: Rate Limiter Refill Correctness**
    - For arbitrary `requestsPerMinute` and elapsed time `t`, assert tokens added equals `min(capacity, currentTokens + t × (requestsPerMinute / 60000))`
    - **Validates: Requirements 5.6**

  - [ ]* 8.4 Write unit tests for `TokenBucketRateLimiter`
    - Test token refill timing; test burst behavior (capacity limit); test concurrent `acquire()` serialization; test wait behavior when no tokens available
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_


- [x] 9. Implement Worker Pool and API dispatch
  - [x] 9.1 Create `src/lib/dispatch/types.ts`
    - Define `EngineQuery`, `EngineQueryOptions`, `RawResult`, `RawResultItem`, `DispatchError`, `WorkerPool`, `WorkerPoolStatus`, `EngineStatus` interfaces
    - _Requirements: 4.1, 4.2, 4.6, 4.7, 4.8_

  - [x] 9.2 Create `src/lib/dispatch/engine.worker.ts` — Web Worker entry point
    - Handle `message` events with `EngineQuery` payloads; execute `fetch` against the engine's API endpoint using the provided `apiKey`; post back `RawResult`
    - Map HTTP 429 → `DispatchError { code: 'rate_limited', retryAfter }`, HTTP 401/403 → `DispatchError { code: 'auth_failed' }`, network errors → `DispatchError { code: 'network' }`
    - Never throw — always post a `RawResult` (with `items: []` and `error` set on failure)
    - _Requirements: 4.2, 4.3, 4.6, 4.7_

  - [x] 9.3 Create `src/routes/api/dispatch/+server.ts` — Playwright headless pool endpoint
    - Accept POST with `EngineQuery` body; launch Playwright browser, navigate to engine URL, extract results, return `RawResult` JSON
    - Return `DispatchError { code: 'anti_bot' }` when CAPTCHA or bot-detection page is detected; do NOT retry automatically
    - Do NOT log or persist query content beyond the current request
    - _Requirements: 4.4, 4.8, 15.1, 15.2, 15.3, 16.4_

  - [x] 9.4 Create `src/lib/dispatch/worker-pool.ts` — `WorkerPool` implementation
    - Implement `dispatch(queries: EngineQuery[]): Promise<RawResult[]>` — execute all queries concurrently (not sequentially); route Tier 1/2 to Web Workers, Tier 3 to `/api/dispatch` endpoint
    - Implement `dispatchOne(query: EngineQuery): Promise<RawResult>`
    - Acquire rate limiter token per engine before dispatching; update quota state after dispatch
    - Show credit confirmation dialog (via a callback/event) for engines where `creditModel.requiresConfirmation === true`; return empty `RawResult` if user cancels
    - Implement `getStatus(): WorkerPoolStatus` and `shutdown(): void`
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.9, 6.1, 6.2, 6.3_

  - [ ]* 9.5 Write property test: Dispatch Result Count Invariant (Property 9)
    - **Property 9: Dispatch Result Count Invariant**
    - Mock engine responses; for any array of N `EngineQuery` objects, assert `dispatch(queries)` returns exactly N `RawResult` objects
    - **Validates: Requirements 4.1**

  - [ ]* 9.6 Write property test: Dispatch Error Containment (Property 10)
    - **Property 10: Dispatch Error Containment**
    - Simulate engine failures (network error, 429, 401, anti-bot); assert each failed engine returns `RawResult` with `items: []` and non-null `error`; assert `dispatch()` never throws
    - **Validates: Requirements 4.2**

  - [ ]* 9.7 Write unit tests for `WorkerPool`
    - Test parallel execution (all queries dispatched concurrently); test Tier 3 routing to `/api/dispatch`; test credit confirmation gate; test rate limiter integration; test `getStatus()` reflects active workers
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 6.1, 6.2, 6.3_


- [x] 10. Checkpoint — dispatch layer complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. Implement Result Normalizer and Key Store
  - [x] 11.1 Create `src/lib/results/types.ts`
    - Define `NormalizedResult`, `EngineAttribution`, `ViewMode`, `ResultSet`, `DeduplicationStats` interfaces
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8_

  - [x] 11.2 Create `src/lib/results/normalizer.ts` — `ResultNormalizer`
    - Implement `normalize(rawResults: RawResult[]): ResultSet`
      - Set `deduplicationStats.totalRaw` = sum of `items.length` across all inputs
      - Set `totalByEngine[engineId]` = count of raw items per engine
      - Normalize each `RawResultItem` into `NormalizedResult` (assign `canonicalIdentifier` from `url ?? ip ?? identifier`)
      - Call `deduplicate()` and set `deduplicationStats.totalUnique`
    - Implement `deduplicate(results: NormalizedResult[]): NormalizedResult[]`
      - Use `canonicalKey()` for deduplication: strip trailing slash, lowercase scheme+host, remove UTM params
      - Merge `EngineAttribution` arrays for duplicates; re-score merged entries
      - Return sorted by score descending
    - Implement `score(result: NormalizedResult): number` — engine attribution count × recency weight
    - Ensure every output `NormalizedResult` has `engines.length >= 1`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9_

  - [x] 11.3 Create `src/lib/results/exporter.ts` — `export()` function
    - Implement `export(results: NormalizedResult[], format: 'json' | 'csv' | 'pdf'): Blob`
    - JSON: `JSON.stringify` to `Blob` with `application/json` MIME type
    - CSV: use `papaparse` to serialize fields; `Blob` with `text/csv` MIME type
    - PDF: use `pdfmake` to generate a table layout; `Blob` with `application/pdf` MIME type
    - All exports generated client-side — no server transmission
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 16.3_

  - [x] 11.4 Create `src/lib/keystore/index.ts` — `KeyStore`
    - Implement `KeyStore` using `idb` library backed by IndexedDB database `dorkstar-keys`
    - Implement `getKey(engineId)`, `setKey(engineId, key)`, `deleteKey(engineId)`, `listEnginesWithKeys()`, `clearAll()`
    - Never transmit key values to any server endpoint; keys stay in IndexedDB only
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7_

  - [ ]* 11.5 Write property test: Deduplication Monotonicity and Attribution Conservation (Property 13)
    - **Property 13: Deduplication Monotonicity and Attribution Conservation**
    - Generate arbitrary `NormalizedResult[]`; assert output length ≤ input length, every `canonicalIdentifier` unique in output, every input `EngineAttribution` appears in exactly one output entry, every output entry has `engines.length >= 1`
    - **Validates: Requirements 7.2, 7.3, 7.4, 7.5, 7.8**

  - [ ]* 11.6 Write property test: Normalization Statistics Accuracy (Property 14)
    - **Property 14: Normalization Statistics Accuracy**
    - Generate arbitrary `RawResult[]`; assert `deduplicationStats.totalRaw === sum(items.length)`, `totalUnique <= totalRaw`, `totalByEngine[id]` equals raw item count per engine
    - **Validates: Requirements 7.1, 7.2, 7.7**

  - [ ]* 11.7 Write property test: URL Canonicalization Idempotence (Property 15)
    - **Property 15: URL Canonicalization Idempotence**
    - Use `fc.webUrl()` to generate URLs; assert `canonicalKey(canonicalKey(u)) === canonicalKey(u)`
    - **Validates: Requirements 7.9**

  - [ ]* 11.8 Write property test: Score Monotonicity with Attribution Count (Property 16)
    - **Property 16: Score Monotonicity with Attribution Count**
    - Generate pairs of `NormalizedResult` differing only in `engines.length`; assert the one with more attributions has score ≥ the other
    - **Validates: Requirements 7.6**

  - [ ]* 11.9 Write unit tests for `ResultNormalizer` and `KeyStore`
    - Normalizer: test `totalRaw` accounting, deduplication by URL/IP, attribution merging, score calculation, all three export formats
    - KeyStore: test IndexedDB isolation, `getKey` returns null for missing key, `clearAll` removes all keys
    - _Requirements: 7.1–7.9, 9.1–9.4, 10.1–10.7_


- [x] 12. Checkpoint — results and keystore layer complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 13. Implement Svelte stores
  - [x] 13.1 Create `src/lib/stores/engine-store.ts` — `EngineStore`
    - Implement `activeEngines` (writable), `engineOrder` (writable), `toggleEngine(id)`, `toggleAll()`, `toggleCategory(category)`, `reorderEngines(from, to)`
    - Implement `persistToLocalStorage()` — serialize `PersistedEngineState` to `localStorage`
    - Implement `loadFromLocalStorage()` — restore `activeEngines` and `engineOrder` on app load
    - _Requirements: 11.3, 11.4, 11.5, 11.6, 11.7_

  - [x] 13.2 Create `src/lib/stores/query-store.ts` — `QueryStore`
    - Implement `canonicalQuery` (writable), `mode` (writable), `perEngineQueries` (writable)
    - Derive `ast` and `parseErrors` reactively from `canonicalQuery` using `parseQuery()`
    - Derive `translations` reactively from `ast` and `activeEngines` using `translationManager.translateAll()`
    - _Requirements: 12.1, 12.2, 12.3_

  - [x] 13.3 Create `src/lib/stores/results-store.ts` — `ResultsStore`
    - Implement `resultSet` (writable), `isLoading` (writable), `viewMode` (writable), `workerStatus` (derived from `workerPool.getStatus()`)
    - Implement `executeQuery()` action that calls `workerPool.dispatch()` then `resultNormalizer.normalize()` and updates `resultSet`
    - Stream Tier 3 results into `resultSet` as they arrive (update `resultSet` incrementally)
    - _Requirements: 8.4, 14.1, 14.2, 14.3, 15.4_

  - [ ]* 13.4 Write unit tests for Svelte stores
    - Test `toggleEngine` adds/removes from `activeEngines`; test `toggleCategory` toggles all engines in category; test `reorderEngines` updates order; test localStorage persistence and restoration; test `viewMode` switching does not re-execute query
    - _Requirements: 11.3, 11.4, 11.5, 11.6, 11.7, 8.4_


- [x] 14. Implement three-zone frontend layout
  - [x] 14.1 Create `src/routes/+layout.svelte` — three-zone layout shell
    - Implement CSS grid layout with three zones: Engine Selector Bar (top), Query Composer (middle), Results Panel (bottom) with Budget Footer pinned to viewport bottom
    - Apply strict Content Security Policy headers via `src/hooks.server.ts` to prevent XSS
    - _Requirements: 11.1, 16.1_

  - [x] 14.2 Create Engine Selector Bar component (`src/lib/components/EngineSelector.svelte`)
    - Render 8 category tabs (`web`, `iot`, `code`, `threat`, `paste`, `social`, `academic`, `all`) using `EngineCategory` values
    - Render each engine as a chip showing engine name and `operatorCount` badge; highlight active engines
    - Wire chip toggle to `engineStore.toggleEngine(id)`; wire category tab click to `engineStore.toggleCategory(category)`
    - Implement drag-and-drop reorder using HTML5 drag events; call `engineStore.reorderEngines(from, to)` on drop
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

  - [x] 14.3 Create Query Composer component (`src/lib/components/QueryComposer.svelte`)
    - Bind canonical query input to `queryStore.canonicalQuery`; display inline error highlights at `ParseError.position` and `ParseError.length` using a `<mark>` overlay or CodeMirror decoration
    - Display real-time translation preview panel showing `nativeQuery` for each active engine (derived from `queryStore.translations`)
    - Show ⚠ badge on engine chip and inline warning in preview when `TranslationResult.degradations` is non-empty
    - Handle `Ctrl+Enter` → call `resultsStore.executeQuery()`; handle `Ctrl+Shift+E` → toggle `queryStore.mode` between `unified` and `per-engine`
    - In Per-Engine mode: render individual `<textarea>` rows per active engine bound to `queryStore.perEngineQueries`; provide "Clone & Translate" button that calls `translationManager.translateFrom()`
    - Implement operator autocomplete using `translationManager.getCommonOperators(activeEngines)` in Unified mode
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 12.8_

  - [x] 14.4 Create Results Panel component (`src/lib/components/ResultsPanel.svelte`)
    - Render `resultsStore.resultSet` in the active `viewMode`
    - Unified mode: interleave all results sorted by score
    - By-Engine mode: render separate tab per engine with that engine's results
    - Deduplicated mode: show only unique results with merged engine attribution badges
    - Per-result actions: "Open" (open URL), "Re-dork" (pre-fill query composer), "Pivot" (use result as new query seed)
    - Export controls: JSON / CSV / PDF buttons that call `exporter.export(results, format)` and trigger browser download
    - Stream Tier 3 results in as they arrive (reactive to `resultsStore.resultSet` updates)
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 9.1, 9.2, 9.3, 15.4_

  - [x] 14.5 Create `src/routes/+page.svelte` — main application page
    - Compose `EngineSelector`, `QueryComposer`, `ResultsPanel`, and `BudgetFooter` components
    - Initialize stores on mount: call `engineStore.loadFromLocalStorage()`
    - _Requirements: 11.7_


- [x] 15. Implement Budget Footer
  - [x] 15.1 Create Budget Footer component (`src/lib/components/BudgetFooter.svelte`)
    - Render per-engine quota usage as `quotaUsed / quotaLimit` for each active engine (derived from `resultsStore.workerStatus.perEngineStatus`)
    - Display rate-limited engines with "Rate limited — resets at HH:MM" using `EngineStatus.resetAt`
    - Update reactively when `workerStatus` changes after each dispatch
    - _Requirements: 13.1, 13.2, 13.3_

  - [ ]* 15.2 Write unit tests for `BudgetFooter`
    - Test quota display renders `quotaUsed / quotaLimit` correctly; test rate-limited state shows reset time; test updates when `workerStatus` changes
    - _Requirements: 13.1, 13.2, 13.3_

- [x] 16. Checkpoint — frontend complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 17. Implement `/docs` auto-generated operator reference
  - [x] 17.1 Create `src/routes/docs/+page.server.ts` — server-side data loader
    - Load `ENGINE_REGISTRY` and build a per-operator coverage matrix: for each `CanonicalOperator`, list which engines support it
    - Return the matrix as page data
    - _Requirements: 3.1, 3.2_

  - [x] 17.2 Create `src/routes/docs/+page.svelte` — operator reference page
    - Render a table with `CanonicalOperator` values as rows and engine names as columns; mark supported cells with ✓ and unsupported with —
    - Group operators by category (network, content, metadata, etc.)
    - Link each engine name to its `docsUrl` from `ENGINE_REGISTRY`
    - _Requirements: 3.1, 3.2_


- [x] 18. Implement operator coverage test matrix
  - [x] 18.1 Create `src/lib/translation/adapters/__tests__/coverage-matrix.test.ts`
    - For each of the 39 `EngineId` values, instantiate the adapter and assert `supportedOperators.size > 0`
    - For each adapter, assert `operatorCount === supportedOperators.size`
    - For each adapter, assert `tier ∈ {1, 2, 3}` and `rateLimit.requestsPerMinute > 0`
    - Generate a coverage report table (logged to console) showing operator support per engine — useful for `/docs` validation
    - _Requirements: 3.1, 3.2, 3.3, 17.1, 17.2, 17.3_

  - [x] 18.2 Create `src/lib/translation/__tests__/translation-integration.test.ts`
    - End-to-end flow test: `parseQuery(canonical)` → `translateAll(ast, allEngines)` → assert all 39 `TranslationResult` objects returned, each with correct `engineId`
    - Test `translateFrom` propagation: parse a Google query, translate to all other engines, assert no result is missing
    - Test degradation warnings surface correctly for known unsupported operators (e.g., `vuln:` on Google)
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.7, 2.8_


- [x] 19. Checkpoint — test matrix complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 20. Docker containerization
  - [x] 20.1 Create `dorkstar/Dockerfile`
    - Multi-stage build: `node:22-alpine` builder stage runs `npm ci` and `npm run build`; production stage copies `.svelte-kit/output` and `node_modules` (production only)
    - Install Playwright browser dependencies (`playwright install --with-deps chromium`) in the production stage for Tier 3 dispatch
    - Expose port 3000; set `NODE_ENV=production`; `CMD ["node", "build"]`
    - _Requirements: 15.1_

  - [x] 20.2 Create `dorkstar/docker-compose.yml`
    - Define `dorkstar` service using the `Dockerfile`; map host port 3000 → container 3000
    - Mount a named volume for any SQLite result store persistence
    - Add `healthcheck` using `curl -f http://localhost:3000/` with 30s interval
    - _Requirements: 15.1_

  - [x] 20.3 Create `.dockerignore`
    - Exclude `node_modules`, `.svelte-kit`, `.git`, `*.test.ts`, `*.spec.ts` from Docker build context
    - _Requirements: 15.1_

- [x] 21. Final checkpoint — all layers integrated
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- Each task references specific requirements for traceability
- Checkpoints at tasks 3, 7, 10, 12, 16, 19, and 21 ensure incremental validation
- Property tests (fast-check) validate universal correctness properties; unit tests (Vitest) validate specific examples and edge cases
- The 39 engine adapters in tasks 5–6 are the largest surface area; the priority four (Google, Bing, Yandex, Shodan) in task 5 unblock all downstream integration work
- All API keys remain in browser IndexedDB throughout — the SvelteKit server never receives or stores them
- Tier 3 engines (qwant, ecosia, seznam, sogou) require Playwright in the Docker image; their results stream asynchronously into the Results Panel
