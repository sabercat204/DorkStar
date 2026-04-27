<script lang="ts">
  type Section = 'help' | 'readme' | 'faq' | 'about';

  interface Props {
    open: boolean;
    onclose: () => void;
  }

  let { open, onclose }: Props = $props();
  let activeSection = $state<Section>('help');

  const queryOperators = [
    { op: 'site',      syntax: 'site:example.com',       desc: 'Restrict results to a domain' },
    { op: 'filetype',  syntax: 'filetype:pdf',            desc: 'Filter by file extension' },
    { op: 'intitle',   syntax: 'intitle:"text"',          desc: 'Match text in page title' },
    { op: 'inurl',     syntax: 'inurl:admin',             desc: 'Match text in URL' },
    { op: 'intext',    syntax: 'intext:"secret"',         desc: 'Match text in page body' },
    { op: 'ip',        syntax: 'ip:1.2.3.4',              desc: 'Search by IP address' },
    { op: 'port',      syntax: 'port:443',                desc: 'Search by open port' },
    { op: 'hostname',  syntax: 'hostname:example.com',    desc: 'Match hostname' },
    { op: 'org',       syntax: 'org:"Cloudflare"',        desc: 'Match organisation name' },
    { op: 'asn',       syntax: 'asn:AS13335',             desc: 'Match autonomous system number' },
    { op: 'country',   syntax: 'country:US',              desc: 'Filter by country code' },
    { op: 'city',      syntax: 'city:London',             desc: 'Filter by city' },
    { op: 'os',        syntax: 'os:"Linux"',              desc: 'Match operating system' },
    { op: 'product',   syntax: 'product:"Apache"',        desc: 'Match software product' },
    { op: 'version',   syntax: 'version:"2.4"',           desc: 'Match software version' },
    { op: 'vuln',      syntax: 'vuln:CVE-2021-44228',     desc: 'Search by CVE identifier' },
    { op: 'repo',      syntax: 'repo:owner/name',         desc: 'GitHub repository filter' },
    { op: 'user',      syntax: 'user:username',           desc: 'GitHub user filter' },
    { op: 'path',      syntax: 'path:src/config',         desc: 'File path filter' },
    { op: 'content',   syntax: 'content:"api_key"',       desc: 'File content search' },
    { op: 'author',    syntax: 'author:username',         desc: 'Social post author' },
    { op: 'subreddit', syntax: 'subreddit:netsec',        desc: 'Reddit subreddit filter' },
    { op: 'from',      syntax: 'from:user',               desc: 'Twitter/X from user' },
    { op: 'since',     syntax: 'since:2024-01-01',        desc: 'Date range start' },
    { op: 'until',     syntax: 'until:2024-12-31',        desc: 'Date range end' },
    { op: 'lang',      syntax: 'lang:en',                 desc: 'Language filter' },
    { op: 'before',    syntax: 'before:2024-01-01',       desc: 'Results before date' },
    { op: 'after',     syntax: 'after:2024-01-01',        desc: 'Results after date' },
  ];

  const booleanOperators = [
    { op: 'AND',       syntax: 'term1 AND term2',         desc: 'Both terms required' },
    { op: 'OR',        syntax: 'term1 OR term2',          desc: 'Either term matches' },
    { op: 'NOT',       syntax: 'NOT term',                desc: 'Exclude term' },
    { op: '- (minus)', syntax: '-term',                   desc: 'Exclude term (shorthand)' },
    { op: '+ (plus)',  syntax: '+term',                   desc: 'Require term' },
    { op: '"phrase"',  syntax: '"exact phrase"',          desc: 'Exact phrase match' },
    { op: 'AROUND(n)', syntax: 'word1 AROUND(3) word2',   desc: 'Proximity search' },
  ];

  const cliFlags = [
    { flag: '--engine ENGINE',           desc: 'Target a specific engine' },
    { flag: '--engines all',             desc: 'Target all 39 engines' },
    { flag: '--category CAT',            desc: 'Target engines by category' },
    { flag: '--enable / --disable',      desc: 'Activate or deactivate engines' },
    { flag: '--parallel',                desc: 'Execute all queries concurrently' },
    { flag: '--normalize',               desc: 'Deduplicate and score results' },
    { flag: '--output unified|by-engine|deduplicated', desc: 'Set result view mode' },
    { flag: '--filetype EXT',            desc: 'Add filetype filter' },
    { flag: '--site DOMAIN',             desc: 'Add domain filter' },
    { flag: '--terms "T1" "T2"',         desc: 'Add multi-item OR search' },
    { flag: '--run',                     desc: 'Execute the current query' },
    { flag: '--export json|csv|pdf',     desc: 'Export results' },
    { flag: '--save FORMAT',             desc: 'Save results to local file' },
    { flag: '--redork URL',              desc: 'Generate new query from result' },
    { flag: '--pivot IDENTIFIER',        desc: 'Use result as new query seed' },
    { flag: '--list-engines',            desc: 'List all registered engines' },
    { flag: '--group-by use-case|category', desc: 'Group engine listing' },
  ];

  const keyboardShortcuts = [
    { key: 'Enter',                desc: 'Execute query' },
    { key: 'Ctrl+Shift+E',         desc: 'Toggle per-engine mode' },
    { key: 'Tab / Enter (autocomplete)', desc: 'Insert operator' },
    { key: 'Escape',               desc: 'Close autocomplete / panels' },
    { key: 'Arrow Up/Down',        desc: 'Navigate autocomplete' },
  ];

  const faqItems = [
    {
      q: 'Why does my query return no results?',
      a: 'Ensure at least one engine is active and your query has no parse errors (red border on input). Check that API keys are configured for Tier 1 engines in Settings.'
    },
    {
      q: 'What is a DegradationWarning?',
      a: 'When a canonical operator has no equivalent in a target engine, a \u26a0 warning is emitted. The operator is omitted from that engine\'s query \u2014 never silently dropped.'
    },
    {
      q: 'How do I search multiple domains at once?',
      a: 'Use the Domain filter button in the toolbar. Enter one domain per line. Multiple domains are joined with OR: (site:a.com OR site:b.com).'
    },
    {
      q: 'How do I search for multiple keywords?',
      a: 'Use the Multi-item button. Enter one term per line. Results matching ANY term are returned: ("term1" OR "term2").'
    },
    {
      q: 'Where are my API keys stored?',
      a: 'Exclusively in your browser\'s IndexedDB. They never leave your device and are never transmitted to any server.'
    },
    {
      q: 'What is Shodan credit consumption?',
      a: 'Shodan charges 1 credit per query page. DORKSTAR shows a confirmation dialog before any Shodan query that would consume credits.'
    },
    {
      q: 'What are Tier 3 engines?',
      a: 'Engines with no public API (Qwant, Ecosia, Seznam, Sogou). DORKSTAR uses a Playwright headless browser to query them. Availability is best-effort \u2014 anti-bot detection may block results.'
    },
    {
      q: 'How does deduplication work?',
      a: 'Results are deduplicated by canonical identifier (URL/IP). Duplicates from multiple engines are merged into a single entry with all engine attributions preserved.'
    },
    {
      q: 'Can I export results?',
      a: 'Yes. Use the JSON, CSV, or PDF buttons in the results toolbar. On Chrome/Edge, the Save button opens a native file picker so you can choose the save location.'
    },
    {
      q: 'What is Per-Engine mode?',
      a: 'Press Ctrl+Shift+E to write independent queries for each active engine. Use Clone & Translate to copy one engine\'s query to all others with auto-translation.'
    },
  ];

  const tabs: { id: Section; label: string }[] = [
    { id: 'help',   label: 'F1 HELP' },
    { id: 'readme', label: 'F2 README' },
    { id: 'faq',    label: 'F3 FAQ' },
    { id: 'about',  label: 'F4 ABOUT' },
  ];
</script>

{#if open}
  <!-- Backdrop -->
  <div
    class="backdrop"
    role="presentation"
    onclick={onclose}
  ></div>

  <!-- Panel -->
  <aside class="help-panel" aria-label="Help panel">
    <!-- Header -->
    <header class="panel-header">
      <nav class="tab-bar" aria-label="Help sections">
        {#each tabs as tab}
          <button
            class="tab-btn"
            class:active={activeSection === tab.id}
            onclick={() => (activeSection = tab.id)}
            aria-pressed={activeSection === tab.id}
          >
            [{tab.label}]
          </button>
        {/each}
      </nav>
      <button class="close-btn" onclick={onclose} aria-label="Close help panel">[X]</button>
    </header>

    <!-- Body -->
    <div class="panel-body">

      <!-- ═══════════════════════════════════════════════ HELP -->
      {#if activeSection === 'help'}
        <section class="help-section">
          <div class="section-heading">SYNOPSIS</div>
          <pre class="synopsis">dork [OPTIONS] -- "QUERY"
dork --engine ENGINE [--enable|--disable]
dork --category CATEGORY [--enable|--disable]
dork --engines all [--enable|--disable]</pre>

          <div class="section-heading">QUERY OPERATORS</div>
          <table class="op-table">
            <thead>
              <tr>
                <th>OPERATOR</th>
                <th>SYNTAX</th>
                <th>DESCRIPTION</th>
              </tr>
            </thead>
            <tbody>
              {#each queryOperators as row}
                <tr>
                  <td class="op-name">{row.op}</td>
                  <td class="op-syntax">{row.syntax}</td>
                  <td class="op-desc">{row.desc}</td>
                </tr>
              {/each}
            </tbody>
          </table>

          <div class="section-heading">BOOLEAN OPERATORS</div>
          <table class="op-table">
            <thead>
              <tr>
                <th>OPERATOR</th>
                <th>SYNTAX</th>
                <th>DESCRIPTION</th>
              </tr>
            </thead>
            <tbody>
              {#each booleanOperators as row}
                <tr>
                  <td class="op-name">{row.op}</td>
                  <td class="op-syntax">{row.syntax}</td>
                  <td class="op-desc">{row.desc}</td>
                </tr>
              {/each}
            </tbody>
          </table>

          <div class="section-heading">CLI FLAGS</div>
          <table class="op-table">
            <thead>
              <tr>
                <th>FLAG</th>
                <th>DESCRIPTION</th>
              </tr>
            </thead>
            <tbody>
              {#each cliFlags as row}
                <tr>
                  <td class="op-name">{row.flag}</td>
                  <td class="op-desc">{row.desc}</td>
                </tr>
              {/each}
            </tbody>
          </table>

          <div class="section-heading">KEYBOARD SHORTCUTS</div>
          <table class="op-table">
            <thead>
              <tr>
                <th>KEY</th>
                <th>ACTION</th>
              </tr>
            </thead>
            <tbody>
              {#each keyboardShortcuts as row}
                <tr>
                  <td class="op-name">{row.key}</td>
                  <td class="op-desc">{row.desc}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </section>

      <!-- ═══════════════════════════════════════════════ README -->
      {:else if activeSection === 'readme'}
        <section class="pre-section">
          <pre class="vt-pre">DORKSTAR v1.0.0
Universal Query Translation Engine

DESCRIPTION
  DORKSTAR converts a single canonical search query into 39
  engine-native formats and executes them in parallel. It is
  not a search aggregator &mdash; it is a query permutation engine.

ARCHITECTURE
  Layer 1: Canonical Query Layer
    PEG grammar parser (Ohm.js) produces a typed operator AST
    from raw query strings. Supports 95+ canonical operators.

  Layer 2: Translation Layer
    39 engine adapter modules convert the AST to native syntax.
    Unsupported operators emit DegradationWarnings &mdash; never
    silently dropped.

  Layer 3: Dispatch &amp; Rate Management
    Web Worker pool executes Tier 1/2 API engines via fetch.
    Playwright headless pool handles Tier 3 (no-API) engines.
    Token-bucket rate limiter enforces per-engine quotas.

  Layer 4: Results Normalization
    Deduplication by URL/IP/identifier. Scoring by engine
    attribution count &times; recency weight. Three view modes:
    Unified, By Engine, Deduplicated.

ENGINE TIERS
  Tier 1  Full API with key    fetch via Web Worker
  Tier 2  Limited free API     fetch via Web Worker
  Tier 3  No public API        Playwright headless browser

SECURITY
  All API keys stored exclusively in browser IndexedDB.
  Zero server-side key storage. Keys never transmitted.
  CSP headers prevent XSS exfiltration of IndexedDB.

CATEGORIES
  web       General web search (Google, Bing, Yandex, ...)
  iot       Internet-of-Things / network (Shodan, Censys, ...)
  code      Source code search (GitHub, GitLab, Sourcegraph, ...)
  threat    Threat intelligence (VirusTotal, urlscan, ...)
  paste     Paste / content (Pastebin, Gist, PublicWWW, ...)
  social    Social media (Twitter/X, Reddit, LinkedIn)
  academic  Research databases (arXiv, Semantic Scholar, PubMed)</pre>
        </section>

      <!-- ═══════════════════════════════════════════════ FAQ -->
      {:else if activeSection === 'faq'}
        <section class="faq-section">
          {#each faqItems as item, i}
            <details class="faq-item">
              <summary class="faq-q">
                <span class="faq-num">Q{i + 1}</span>
                {item.q}
              </summary>
              <p class="faq-a">{item.a}</p>
            </details>
          {/each}
        </section>

      <!-- ═══════════════════════════════════════════════ ABOUT -->
      {:else if activeSection === 'about'}
        <section class="pre-section">
          <pre class="vt-pre">DORKSTAR v1.0.0
Universal Query Translation Engine

Built on SvelteKit 5 (Runes mode) with TypeScript throughout.

STACK
  Frontend     SvelteKit 5, Svelte Runes, TypeScript
  Parser       Ohm.js PEG grammar
  Dispatch     Web Workers + Playwright headless pool
  Storage      Browser IndexedDB (keys), SQLite (results)
  Export       pdfmake (PDF), papaparse (CSV)
  Testing      Vitest + fast-check (property-based)

CORRECTNESS PROPERTIES
  1. No silent operator drops
  2. Translation count invariant
  3. Deduplication monotonicity
  4. Rate limiter token conservation
  5. Parse round-trip stability
  6. Key store isolation
  7. Credit confirmation gate

SUPPORTED ENGINES (39)
  Web (10)      Google, Bing, Yandex, DuckDuckGo, Baidu,
                Yahoo, Qwant, Ecosia, Seznam, Sogou
  IoT (11)      Shodan, Censys, FOFA, ZoomEye, BinaryEdge,
                Onyphe, LeakIX, Netlas, Criminal IP,
                Hunter.how, FullHunt
  Code (4)      GitHub, GitLab, Sourcegraph, grep.app
  Threat (4)    VirusTotal, urlscan.io, AlienVault OTX,
                ThreatCrowd
  Paste (4)     Pastebin, GitHub Gist, PublicWWW, grep.io
  Social (3)    Twitter/X, Reddit, LinkedIn
  Academic (3)  arXiv, Semantic Scholar, PubMed

LICENSE
  For authorised security research and OSINT use only.
  Scope limited to publicly accessible engines.
  No credential harvesting. No exploitation. No evasion.</pre>
        </section>
      {/if}

    </div>
  </aside>
{/if}

<style>
  /* ── Backdrop ─────────────────────────────────────────────── */
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    z-index: 200;
  }

  /* ── Panel ────────────────────────────────────────────────── */
  .help-panel {
    position: fixed;
    top: 0;
    right: 0;
    width: 480px;
    height: 100dvh;
    display: flex;
    flex-direction: column;
    background: var(--p-bg);
    border-left: 1px solid var(--p-border);
    z-index: 201;
    font-family: var(--font-mono);
    animation: slide-in var(--t-fast, 120ms) ease-out;
  }

  @keyframes slide-in {
    from { transform: translateX(100%); }
    to   { transform: translateX(0); }
  }

  /* ── Header ───────────────────────────────────────────────── */
  .panel-header {
    display: flex;
    align-items: center;
    gap: var(--sp-2, 8px);
    padding: var(--sp-2, 8px) var(--sp-3, 12px);
    border-bottom: 1px solid var(--p-border);
    background: var(--p-bg-2);
    flex-shrink: 0;
  }

  .tab-bar {
    display: flex;
    gap: var(--sp-1, 4px);
    flex: 1;
    flex-wrap: wrap;
  }

  .tab-btn {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    letter-spacing: 0;
    color: var(--p-dim);
    background: transparent;
    border: 1px solid var(--p-border);
    padding: 2px var(--sp-2, 8px);
    cursor: pointer;
    letter-spacing: 0.04em;
    transition: color var(--t-fast, 120ms), border-color var(--t-fast, 120ms),
                background var(--t-fast, 120ms);
  }

  .tab-btn:hover {
    color: var(--p-bright);
    border-color: var(--p-border-2);
    background: var(--p-bg-3);
  }

  .tab-btn.active {
    color: var(--p-white);
    border-color: var(--p-glow);
    background: var(--p-bg-3);
    text-shadow: 0 0 6px var(--p-glow-strong);
  }

  .close-btn {
    font-family: var(--font-mono);
    font-size: 0.72rem;
    color: var(--p-dim);
    background: transparent;
    border: 1px solid var(--p-border);
    padding: 2px var(--sp-2, 8px);
    cursor: pointer;
    flex-shrink: 0;
    transition: color var(--t-fast, 120ms), border-color var(--t-fast, 120ms);
  }

  .close-btn:hover {
    color: var(--p-bright);
    border-color: var(--p-border-2);
  }

  /* ── Body ─────────────────────────────────────────────────── */
  .panel-body {
    flex: 1;
    overflow-y: auto;
    padding: var(--sp-3, 12px);
    scrollbar-width: thin;
    scrollbar-color: var(--p-border) transparent;
  }

  /* ── Section heading ──────────────────────────────────────── */
  .section-heading {
    font-family: var(--font-mono);
    font-size: 0.7rem;
    color: var(--p-bright);
    letter-spacing: 0.1em;
    margin: var(--sp-4, 16px) 0 var(--sp-2, 8px);
    padding-bottom: 2px;
    border-bottom: 1px solid var(--p-border);
    text-shadow: 0 0 4px var(--p-glow);
  }

  .section-heading:first-child {
    margin-top: 0;
  }

  /* ── Synopsis pre ─────────────────────────────────────────── */
  .synopsis {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    letter-spacing: 0;
    color: var(--p-mid);
    background: var(--p-bg-2);
    border: 1px solid var(--p-border);
    padding: var(--sp-2, 8px) var(--sp-3, 12px);
    margin: 0 0 var(--sp-3, 12px);
    white-space: pre;
    overflow-x: auto;
    line-height: 1.6;
  }

  /* ── Operator tables ──────────────────────────────────────── */
  .op-table {
    width: 100%;
    border-collapse: collapse;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    margin-bottom: var(--sp-3, 12px);
    /* IBM EGA bitmap font — no letter-spacing, no wrapping */
    letter-spacing: 0;
    white-space: nowrap;
  }

  .op-table thead tr {
    border-bottom: 1px solid var(--p-border-2);
  }

  .op-table th {
    text-align: left;
    color: var(--p-dim);
    font-weight: normal;
    letter-spacing: 0;
    padding: 3px 12px 5px 0;
    white-space: nowrap;
  }

  .op-table td {
    padding: 4px 12px 4px 0;
    vertical-align: top;
    border-bottom: 1px solid color-mix(in srgb, var(--p-border) 40%, transparent);
    white-space: nowrap;
  }

  .op-table tr:last-child td {
    border-bottom: none;
  }

  .op-name {
    color: var(--p-bright);
    white-space: nowrap;
    min-width: 140px;
    padding-right: 16px;
  }

  .op-syntax {
    color: var(--p-glow);
    white-space: nowrap;
    min-width: 200px;
    padding-right: 16px;
    font-family: var(--font-mono);
  }

  .op-desc {
    color: var(--p-mid);
    white-space: normal;
    max-width: 260px;
  }

  /* ── Pre sections (README / ABOUT) ───────────────────────── */
  .pre-section {
    padding: 0;
  }

  .vt-pre {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    letter-spacing: 0;
    color: var(--p-mid);
    background: transparent;
    white-space: pre;
    overflow-x: auto;
    line-height: 1.65;
    margin: 0;
    padding: 0;
  }

  /* ── FAQ section ──────────────────────────────────────────── */
  .faq-section {
    display: flex;
    flex-direction: column;
    gap: var(--sp-2, 8px);
  }

  .faq-item {
    border: 1px solid var(--p-border);
    background: var(--p-bg-2);
  }

  .faq-item[open] {
    border-color: var(--p-border-2);
  }

  .faq-q {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    letter-spacing: 0;
    color: var(--p-bright);
    padding: var(--sp-2, 8px) var(--sp-3, 12px);
    cursor: pointer;
    list-style: none;
    display: flex;
    align-items: baseline;
    gap: var(--sp-2, 8px);
    user-select: none;
  }

  .faq-q::-webkit-details-marker {
    display: none;
  }

  .faq-q::before {
    content: '▶';
    font-size: 0.55rem;
    color: var(--p-dim);
    flex-shrink: 0;
    transition: transform var(--t-fast, 120ms);
  }

  .faq-item[open] .faq-q::before {
    transform: rotate(90deg);
  }

  .faq-num {
    color: var(--p-glow);
    flex-shrink: 0;
    font-size: 0.65rem;
    letter-spacing: 0.05em;
  }

  .faq-a {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    letter-spacing: 0;
    color: var(--p-mid);
    line-height: 1.6;
    margin: 0;
    padding: 0 var(--sp-3, 12px) var(--sp-3, 12px) calc(var(--sp-3, 12px) + 1.4rem);
    border-top: 1px solid var(--p-border);
  }

  /* ── Scrollbar ────────────────────────────────────────────── */
  .panel-body::-webkit-scrollbar {
    width: 4px;
  }

  .panel-body::-webkit-scrollbar-track {
    background: transparent;
  }

  .panel-body::-webkit-scrollbar-thumb {
    background: var(--p-border);
  }

  .panel-body::-webkit-scrollbar-thumb:hover {
    background: var(--p-border-2);
  }
</style>
