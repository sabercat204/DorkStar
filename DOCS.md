# D0RKSTAR — Technical Documentation

## Table of Contents

1. [Architecture](#architecture)
2. [Query Language](#query-language)
3. [Engine Adapters](#engine-adapters)
4. [Dispatch Layer](#dispatch-layer)
5. [Results Normalization](#results-normalization)
6. [Key Store](#key-store)
7. [Frontend Components](#frontend-components)
8. [CLI Scripts](#cli-scripts)
9. [Testing](#testing)
10. [Deployment](#deployment)
11. [Correctness Properties](#correctness-properties)

---

## Architecture

D0RKSTAR implements a four-layer architecture with strict unidirectional data flow:

```
User Input → [Layer 1: Parse] → [Layer 2: Translate] → [Layer 3: Dispatch] → [Layer 4: Normalize] → UI
```

### Layer 1: Canonical Query Layer (`src/lib/parser/`)

- **grammar.ohm** — Ohm PEG grammar definition (reference only, not used at runtime)
- **index.ts** — Custom tokenizer + recursive-descent parser
  - `parseQuery(input)` → `{ ast: ASTNode | null, errors: ParseError[] }`
  - `validateQuery(input)` → `ParseError[]`
  - `prettyPrint(node)` → canonical query string
- **types.ts** — AST node types, `CanonicalOperator` union (95+ operators)

The parser tokenizes on whitespace, classifies each token (operator, quoted phrase, boolean keyword, wildcard, bare word), then builds an AST with implicit AND between adjacent terms.

### Layer 2: Translation Layer (`src/lib/translation/`)

- **manager.ts** — `TranslationManager` class
  - `translateAll(ast, engines)` → `TranslationResult[]`
  - `translateOne(ast, engineId)` → `TranslationResult`
  - `translateFrom(sourceEngine, ast, targetEngines)` → `TranslationResult[]`
  - `getSupportedOperators(engineId)` → `CanonicalOperator[]`
  - `getCommonOperators(engines)` → `CanonicalOperator[]` (intersection)
- **types.ts** — `EngineId`, `TranslationResult`, `DegradationWarning`, `EngineRegistryEntry`
- **adapters/base.ts** — `AbstractEngineAdapter` base class with AST walker
- **adapters/*.ts** — 39 engine adapter implementations
- **adapters/registry.ts** — `adapterRegistry` map + `ENGINE_REGISTRY` metadata array

Each adapter declares its `supportedOperators` set and implements `translateOperator()` for engine-specific syntax. Unsupported operators emit `DegradationWarning` — never silently dropped.

### Layer 3: Dispatch & Rate Management (`src/lib/dispatch/`)

- **worker-pool.ts** — `WorkerPool` class
  - Routes Tier 1/2 engines to Web Workers via `fetch`
  - Routes Tier 3 engines to `/api/dispatch` Playwright endpoint
  - Credit confirmation gate for Shodan and paid engines
- **rate-limiter.ts** — `TokenBucketRateLimiter` with promise-queue serialization
- **engine.worker.ts** — Web Worker entry point for API dispatch
- **types.ts** — `EngineQuery`, `RawResult`, `DispatchError`

### Layer 4: Results Normalization (`src/lib/results/`)

- **normalizer.ts** — `ResultNormalizer` class
  - `normalize(rawResults, viewMode)` → `ResultSet`
  - `deduplicate(results)` → `NormalizedResult[]`
  - URL canonicalization: strip trailing slash, lowercase scheme+host, remove UTM params
  - Scoring: engine attribution count × recency weight
- **exporter.ts** — `exportResults(results, format)` → `Blob` (JSON/CSV/PDF)
- **types.ts** — `NormalizedResult`, `ResultSet`, `ViewMode`

---

## Query Language

### Canonical Operators (95+)

#### Web / Content
`site`, `filetype`, `ext`, `intitle`, `allintitle`, `inurl`, `allinurl`, `intext`, `allintext`, `inbody`, `inanchor`, `allinanchor`, `inpage`, `url`, `domain`, `host`, `mime`, `related`, `cache`, `define`, `source`, `feed`, `hasfeed`, `contains`, `prefer`

#### Network / IoT
`ip`, `port`, `hostname`, `org`, `asn`, `net`, `country`, `city`, `os`, `product`, `version`, `vuln`, `ssl.jarm`, `ssl.ja3s`, `http.favicon.hash`, `has_screenshot`, `rhost`, `cidr`, `banner`, `service`, `protocol`, `jarm`, `http.title`, `http.body`, `is_vulnerability`, `tag`, `tech`, `app`, `ver`, `device`, `services.port`, `services.http.response.html_title`

#### Code Search
`repo`, `user`, `path`, `content`, `symbol`

#### Social
`author`, `subreddit`, `flair`, `self`, `selftext`, `title`, `from`, `to`, `filter`, `since`, `until`, `min_retweets`, `min_faves`, `min_replies`

#### Date
`before`, `after`, `daterange`, `date`

#### Threat Intelligence
`classification`, `actor`, `tags`, `cve`, `labels`

#### Academic
`fieldsOfStudy`, `venue`, `minCitationCount`, `matchType`

#### API / Query Control
`output`, `fl`, `limit`, `collapse`

### Boolean Operators

| Operator | Syntax | Description |
|----------|--------|-------------|
| AND | `term1 AND term2` | Both terms required |
| OR | `term1 OR term2` | Either term matches |
| NOT | `NOT term` | Exclude term |
| - | `-term` | Exclude (shorthand) |
| + | `+term` | Require term |
| "" | `"exact phrase"` | Exact phrase match |
| AROUND | `word1 AROUND(3) word2` | Proximity search |

---

## Engine Adapters

Each adapter extends `AbstractEngineAdapter` and must implement:

```typescript
interface EngineAdapter {
  readonly engineId: EngineId;
  readonly displayName: string;
  readonly category: EngineCategory;
  readonly tier: 1 | 2 | 3;
  readonly supportedOperators: ReadonlySet<CanonicalOperator>;
  readonly operatorCount: number;
  translate(ast: ASTNode): TranslationResult;
  supportsOperator(op: CanonicalOperator): boolean;
}
```

### Adding a New Engine

1. Create `src/lib/translation/adapters/myengine.ts`
2. Extend `AbstractEngineAdapter`
3. Declare `supportedOperators` set
4. Override `translateOperator()` for engine-specific syntax
5. Add to `registry.ts` — both `adapterRegistry` map and `ENGINE_REGISTRY` array
6. Add to `ALL_ENGINE_IDS` in `types.ts`

---

## Key Store

`src/lib/keystore/index.ts` — IndexedDB-backed storage.

```typescript
keyStore.getKey(engineId)           // → string | null
keyStore.setKey(engineId, key)      // → void
keyStore.deleteKey(engineId)        // → void
keyStore.listEnginesWithKeys()      // → EngineId[]
keyStore.clearAll()                 // → void
```

On first access, seeds from `VITE_KEY_*` environment variables (set by `npm run setup`). User-set keys take priority over env vars.

---

## Frontend Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `QueryComposer` | `src/lib/components/` | Shell prompt input + autocomplete |
| `ResultsPanel` | `src/lib/components/` | ANSI splash, error display, result cards |
| `EngineSelector` | `src/lib/components/` | Collapsible category sections with engine chips |
| `FilterPanel` | `src/lib/components/` | File type / domain / multi-item filters |
| `BudgetFooter` | `src/lib/components/` | Per-engine quota bars and rate limit status |
| `HelpPanel` | `src/lib/components/` | F1 HELP / F2 README / F3 FAQ / F4 ABOUT |
| `OperatorsPanel` | `src/lib/components/` | Operator coverage matrix |
| `EngineGroupBrowser` | `src/lib/components/` | Use-case / category engine browser drawer |

### Svelte Stores

| Store | Location | Purpose |
|-------|----------|---------|
| `engine-store` | `src/lib/stores/` | Active engines, order, localStorage persistence |
| `query-store` | `src/lib/stores/` | Canonical query, mode, AST, translations |
| `results-store` | `src/lib/stores/` | Result set, loading state, view mode, errors |
| `filter-store` | `src/lib/stores/` | File type, domain, multi-item filter state |
| `cmd-log` | `src/lib/stores/` | Shell command echo for VT100 vanity prompt |

---

## CLI Scripts

### `npm run setup`
Interactive API key configuration wizard. Offers two modes:
- **Register** — Playwright opens a browser for each engine's signup page
- **Manual** — Paste keys directly in the terminal

### `npm run setup:check`
Show current key configuration status for all engines.

### `npm run setup:reset`
Clear all configured API keys from `.env.keys`.

### `npm run setup:register`
Skip directly to Playwright registration mode.

### `npm run setup:manual`
Skip directly to manual key entry mode.

---

## Testing

```bash
npm run test          # 496 tests, single run
npm run test:watch    # Watch mode
```

### Test Structure

- `src/lib/translation/adapters/__tests__/coverage-matrix.test.ts` — 471 tests verifying all 39 adapters
- `src/lib/translation/__tests__/translation-integration.test.ts` — 25 end-to-end translation flow tests

### Correctness Properties (Property-Based Testing)

Optional property tests using fast-check (tasks marked `*` in the spec):

1. Parse Round-Trip Stability
2. Parse Error Structure Completeness
3. AST Node Invariants
4. No Silent Operator Drops
5. Translation Count and Order Invariant
6. isFullySupported Consistency
7. Common Operators Intersection
8. Engine Registry Self-Consistency
9. Dispatch Result Count Invariant
10. Dispatch Error Containment
11. Rate Limiter Token Conservation
12. Rate Limiter Refill Correctness
13. Deduplication Monotonicity and Attribution Conservation
14. Normalization Statistics Accuracy
15. URL Canonicalization Idempotence
16. Score Monotonicity with Attribution Count

---

## Deployment

### Development
```bash
npm run dev
```

### Production Build
```bash
npm run build
npm run preview
```

### Docker
```bash
docker compose up --build
```

Multi-stage Dockerfile:
- Builder: `node:22-alpine`, `npm ci`, `npm run build` with `SVELTE_ADAPTER=node`
- Production: `node:22-alpine` + Playwright Chromium for Tier 3 dispatch
- Healthcheck: `wget -qO- http://localhost:3000/`
- Named volume for SQLite persistence

### Environment Variables

All `VITE_KEY_*` variables are injected at build time from `.env.keys`:

| Variable | Engine |
|----------|--------|
| `VITE_KEY_GOOGLE` | Google CSE |
| `VITE_KEY_BING` | Bing Search |
| `VITE_KEY_SHODAN` | Shodan |
| `VITE_KEY_CENSYS` | Censys |
| `VITE_KEY_GITHUB` | GitHub |
| `VITE_KEY_VIRUSTOTAL` | VirusTotal |
| ... | (25 total) |

---

## Correctness Properties

### Property 1: No Silent Operator Drops
For all AST nodes and all engine adapters: if an operator is unsupported, a `DegradationWarning` must be recorded. No operator is ever silently omitted.

### Property 2: Translation Count Invariant
`translateAll(ast, engines)` always returns exactly `engines.length` results, with `result[i].engineId === engines[i]`.

### Property 3: Deduplication Monotonicity
`deduplicate(results)` output length ≤ input length. Every canonical identifier appears exactly once. All engine attributions are preserved.

### Property 4: Rate Limiter Token Conservation
`tokens` remains in `[0, capacity]` at all times. Each `acquire()` consumes exactly one token.

### Property 5: Key Store Isolation
No API key value is ever transmitted to a server endpoint. Keys live exclusively in IndexedDB.

### Property 6: Credit Confirmation Gate
Engines with `creditModel.requiresConfirmation === true` must show a confirmation dialog before dispatch.

---

## File Structure

```
dorkstar/
├── src/
│   ├── lib/
│   │   ├── parser/          # PEG grammar, tokenizer, AST types
│   │   ├── translation/     # Manager, 39 adapters, registry
│   │   ├── dispatch/        # Worker pool, rate limiter, Web Worker
│   │   ├── results/         # Normalizer, exporter, types
│   │   ├── keystore/        # IndexedDB key store
│   │   ├── stores/          # Svelte stores (engine, query, results, filter, cmd-log)
│   │   └── components/      # All UI components
│   ├── routes/
│   │   ├── +layout.svelte   # Global layout, CRT theme, font
│   │   ├── +page.svelte     # Main app page
│   │   ├── api/dispatch/    # Playwright Tier 3 endpoint
│   │   └── docs/            # Standalone operator reference page
│   └── app.html
├── scripts/
│   ├── setup.js             # API key wizard
│   └── register.js          # Playwright registration assistant
├── static/                   # Static assets (fonts, robots.txt)
├── Dockerfile
├── docker-compose.yml
└── .env.keys                 # API keys (gitignored)
```
