<script lang="ts">
  import { ENGINE_REGISTRY } from '$lib/translation/adapters/registry';
  import { ALL_CANONICAL_OPERATORS } from '$lib/parser/types';
  import type { CanonicalOperator } from '$lib/parser/types';
  import type { EngineId, EngineCategory } from '$lib/translation/types';

  interface Props {
    open: boolean;
    onclose: () => void;
  }

  let { open, onclose }: Props = $props();

  // ── Operator groups ──────────────────────────────────────────────────────
  const OPERATOR_GROUPS: { label: string; operators: CanonicalOperator[] }[] = [
    {
      label: 'Web / Content',
      operators: [
        'site', 'filetype', 'ext', 'intitle', 'allintitle',
        'inurl', 'allinurl', 'intext', 'allintext', 'inbody',
        'inanchor', 'allinanchor', 'inpage', 'url', 'domain',
        'host', 'mime', 'related', 'cache', 'define',
        'source', 'feed', 'hasfeed', 'contains', 'prefer',
      ],
    },
    {
      label: 'Network / IoT',
      operators: [
        'ip', 'port', 'hostname', 'org', 'asn', 'net',
        'country', 'city', 'os', 'product', 'version', 'vuln',
        'ssl.jarm', 'ssl.ja3s', 'http.favicon.hash', 'has_screenshot',
        'rhost', 'cidr', 'banner', 'service', 'protocol', 'jarm',
        'http.title', 'http.body', 'is_vulnerability', 'tag', 'tech',
        'app', 'ver', 'device',
        'services.port', 'services.http.response.html_title',
      ],
    },
    {
      label: 'Language / Locale',
      operators: ['lang', 'language', 'loc', 'location'],
    },
    {
      label: 'Code Search',
      operators: ['repo', 'user', 'path', 'content', 'symbol'],
    },
    {
      label: 'Social',
      operators: [
        'author', 'subreddit', 'flair', 'self', 'selftext', 'title',
        'from', 'to', 'filter', 'since', 'until',
        'min_retweets', 'min_faves', 'min_replies',
      ],
    },
    {
      label: 'Date',
      operators: ['before', 'after', 'daterange', 'date'],
    },
    {
      label: 'Threat Intelligence',
      operators: ['classification', 'actor', 'tags', 'cve', 'labels'],
    },
    {
      label: 'Academic',
      operators: ['fieldsOfStudy', 'venue', 'minCitationCount', 'matchType'],
    },
    {
      label: 'API / Query Control',
      operators: ['output', 'fl', 'limit', 'collapse'],
    },
  ];

  // ── Category colour map ──────────────────────────────────────────────────
  const CATEGORY_COLORS: Record<string, string> = {
    web:      'var(--c-web)',
    iot:      'var(--c-iot)',
    code:     'var(--c-code)',
    threat:   'var(--c-threat)',
    paste:    'var(--c-paste)',
    social:   'var(--c-social)',
    academic: 'var(--c-academic)',
  };

  // ── Filter state ─────────────────────────────────────────────────────────
  let filterCategory = $state('all');
  let filterOp       = $state('');
  let expandedGroups = $state(new Set(['Web / Content', 'Network / IoT']));

  // ── Derived: engine metadata ─────────────────────────────────────────────
  const engineIds = $derived(ENGINE_REGISTRY.map((e) => e.id as EngineId));

  const engineNames = $derived(
    Object.fromEntries(ENGINE_REGISTRY.map((e) => [e.id, e.displayName])) as Record<EngineId, string>
  );

  const engineDocs = $derived(
    Object.fromEntries(ENGINE_REGISTRY.map((e) => [e.id, e.docsUrl])) as Record<EngineId, string>
  );

  const engineCategories = $derived(
    Object.fromEntries(ENGINE_REGISTRY.map((e) => [e.id, e.category])) as Record<EngineId, EngineCategory>
  );

  const supportMap = $derived((() => {
    const m = new Map<EngineId, Set<CanonicalOperator>>();
    for (const entry of ENGINE_REGISTRY) {
      m.set(entry.id as EngineId, new Set(entry.supportedOperators));
    }
    return m;
  })());

  // ── Derived: filtered columns ────────────────────────────────────────────
  const visibleEngineIds = $derived(
    filterCategory === 'all'
      ? engineIds
      : engineIds.filter((id) => engineCategories[id] === filterCategory)
  );

  // ── Derived: unique categories for filter tabs ───────────────────────────
  const uniqueCategories = $derived(
    ['all', ...new Set(ENGINE_REGISTRY.map((e) => e.category))]
  );

  // ── Derived: filtered operator groups ───────────────────────────────────
  const visibleGroups = $derived(
    OPERATOR_GROUPS
      .map((group) => {
        const rows = group.operators
          .filter((op) =>
            filterOp === '' || op.toLowerCase().includes(filterOp.toLowerCase())
          )
          .map((op) => {
            let supportCount = 0;
            const support: Partial<Record<EngineId, boolean>> = {};
            for (const id of visibleEngineIds) {
              if (supportMap.get(id)?.has(op)) {
                support[id] = true;
                supportCount++;
              }
            }
            return { operator: op, support, supportCount };
          });
        return { label: group.label, rows };
      })
      .filter((g) => g.rows.length > 0)
  );

  // ── Derived: footer counts ───────────────────────────────────────────────
  const totalVisibleOps = $derived(visibleGroups.reduce((n, g) => n + g.rows.length, 0));

  // ── Helpers ──────────────────────────────────────────────────────────────
  function toggleGroup(label: string) {
    const next = new Set(expandedGroups);
    if (next.has(label)) {
      next.delete(label);
    } else {
      next.add(label);
    }
    expandedGroups = next;
  }
</script>

{#if open}
  <!-- Backdrop -->
  <div
    class="backdrop"
    role="presentation"
    onclick={onclose}
  ></div>

  <!-- Panel -->
  <aside class="ops-panel" aria-label="Operator reference panel">

    <!-- ── Header ──────────────────────────────────────────────────────── -->
    <header class="panel-header">
      <div class="panel-header__top">
        <span class="panel-title">OPERATOR REFERENCE</span>
        <button class="close-btn" onclick={onclose} aria-label="Close operator panel">[X]</button>
      </div>

      <div class="panel-header__controls">
        <input
          class="filter-input"
          type="search"
          placeholder="Filter operators…"
          bind:value={filterOp}
          aria-label="Filter operators by name"
        />
      </div>

      <!-- Category filter tabs -->
      <nav class="cat-tabs" aria-label="Filter engines by category">
        {#each uniqueCategories as cat}
          {@const color = cat === 'all' ? 'var(--p-bright)' : (CATEGORY_COLORS[cat] ?? 'var(--p-dim)')}
          <button
            class="cat-tab"
            class:active={filterCategory === cat}
            onclick={() => (filterCategory = cat)}
            aria-pressed={filterCategory === cat}
          >
            {#if cat !== 'all'}
              <span class="cat-dot" style="background:{color}"></span>
            {/if}
            {cat === 'all' ? 'All' : cat.toUpperCase()}
          </button>
        {/each}
      </nav>
    </header>

    <!-- ── Body ────────────────────────────────────────────────────────── -->
    <div class="panel-body">
      {#each visibleGroups as group}
        {@const expanded = expandedGroups.has(group.label)}

        <!-- Group header -->
        <div class="group-header" role="button" tabindex="0"
          onclick={() => toggleGroup(group.label)}
          onkeydown={(e) => (e.key === 'Enter' || e.key === ' ') && toggleGroup(group.label)}
          aria-expanded={expanded}
        >
          <span class="group-label">{group.label}</span>
          <span class="group-badge">{group.rows.length}</span>
          <span class="group-chevron" class:rotated={expanded}>▶</span>
        </div>

        <!-- Group table (when expanded) -->
        {#if expanded}
          <div class="table-scroll-wrapper">
            <table class="matrix-table">
              <colgroup>
                <col style="width:200px;min-width:200px" />
                <col style="width:32px;min-width:32px" />
                {#each visibleEngineIds as _id}
                  <col style="width:80px;min-width:80px" />
                {/each}
              </colgroup>
              <thead>
                <tr>
                  <th class="col-op" scope="col">OPERATOR</th>
                  <th class="col-count" scope="col" title="Support count">#</th>
                  {#each visibleEngineIds as id}
                    {@const cat = engineCategories[id]}
                    {@const color = CATEGORY_COLORS[cat] ?? 'var(--p-dim)'}
                    <th
                      class="col-engine"
                      scope="col"
                      style="--eng-color:{color}"
                    >
                      <a
                        href={engineDocs[id]}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="engine-link"
                        title="Open {engineNames[id]} docs"
                      >{engineNames[id]}</a>
                    </th>
                  {/each}
                </tr>
              </thead>
              <tbody>
                {#each group.rows as row}
                  <tr class="matrix-row">
                    <td class="cell-op">
                      <code>{row.operator}</code>
                    </td>
                    <td class="cell-count" title="{row.supportCount} of {visibleEngineIds.length} engines">
                      {row.supportCount}
                    </td>
                    {#each visibleEngineIds as id}
                      {@const ok = row.support[id] ?? false}
                      <td
                        class="cell-support"
                        class:yes={ok}
                        aria-label="{row.operator} on {engineNames[id]}: {ok ? 'supported' : 'not supported'}"
                        title="{engineNames[id]}: {ok ? '✓' : '—'}"
                      >
                        {#if ok}
                          <span class="check" aria-hidden="true">✓</span>
                        {:else}
                          <span class="dash" aria-hidden="true">—</span>
                        {/if}
                      </td>
                    {/each}
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        {/if}
      {/each}
    </div>

    <!-- ── Footer ──────────────────────────────────────────────────────── -->
    <footer class="panel-footer">
      <span>{totalVisibleOps} operators</span>
      <span class="footer-sep">·</span>
      <span>{visibleEngineIds.length} engines</span>
    </footer>

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
  .ops-panel {
    position: fixed;
    top: 0;
    right: 0;
    width: 560px;
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
    flex-direction: column;
    gap: var(--sp-2, 8px);
    padding: var(--sp-2, 8px) var(--sp-3, 12px);
    border-bottom: 1px solid var(--p-border);
    background: var(--p-bg-2);
    flex-shrink: 0;
  }

  .panel-header__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .panel-title {
    font-size: 0.72rem;
    font-weight: 700;
    letter-spacing: 0.12em;
    color: var(--p-bright);
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

  /* ── Filter input ─────────────────────────────────────────── */
  .panel-header__controls {
    display: flex;
  }

  .filter-input {
    flex: 1;
    background: var(--p-bg-3);
    border: 1px solid var(--p-border);
    color: var(--p-mid);
    font-family: var(--font-mono);
    font-size: 0.72rem;
    padding: 4px var(--sp-2, 8px);
    outline: none;
    transition: border-color var(--t-fast, 120ms);
  }

  .filter-input:focus {
    border-color: var(--p-glow);
    color: var(--p-bright);
  }

  .filter-input::placeholder {
    color: var(--p-dim);
  }

  /* ── Category tabs ────────────────────────────────────────── */
  .cat-tabs {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }

  .cat-tab {
    display: flex;
    align-items: center;
    gap: 4px;
    font-family: var(--font-mono);
    font-size: 0.65rem;
    letter-spacing: 0.06em;
    color: var(--p-dim);
    background: transparent;
    border: 1px solid var(--p-border);
    padding: 2px 6px;
    cursor: pointer;
    transition: color var(--t-fast, 120ms), border-color var(--t-fast, 120ms),
                background var(--t-fast, 120ms);
  }

  .cat-tab:hover {
    color: var(--p-bright);
    border-color: var(--p-border-2);
    background: var(--p-bg-3);
  }

  .cat-tab.active {
    color: var(--p-white);
    border-color: var(--p-glow);
    background: var(--p-bg-3);
    text-shadow: 0 0 4px var(--p-glow-strong);
  }

  .cat-dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  /* ── Body ─────────────────────────────────────────────────── */
  .panel-body {
    flex: 1;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: var(--p-border) transparent;
  }

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

  /* ── Group header ─────────────────────────────────────────── */
  .group-header {
    display: flex;
    align-items: center;
    gap: var(--sp-2, 8px);
    padding: 6px var(--sp-3, 12px);
    background: var(--p-bg-2);
    border-bottom: 1px solid var(--p-border);
    cursor: pointer;
    user-select: none;
  }

  .group-header:hover {
    background: var(--p-bg-3);
  }

  .group-label {
    font-size: 0.68rem;
    font-weight: 700;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--p-bright);
    flex: 1;
  }

  .group-badge {
    font-size: 0.62rem;
    color: var(--p-dim);
    background: var(--p-bg-3);
    border: 1px solid var(--p-border);
    padding: 0 5px;
    min-width: 22px;
    text-align: center;
  }

  .group-chevron {
    font-size: 0.55rem;
    color: var(--p-dim);
    transition: transform var(--t-fast, 120ms);
  }

  .group-chevron.rotated {
    transform: rotate(90deg);
  }

  /* ── Table scroll wrapper ─────────────────────────────────── */
  .table-scroll-wrapper {
    overflow-x: auto;
    overflow-y: visible;
    width: 100%;
    scrollbar-width: thin;
    scrollbar-color: var(--p-border) transparent;
  }

  .table-scroll-wrapper::-webkit-scrollbar {
    height: 4px;
  }

  .table-scroll-wrapper::-webkit-scrollbar-track {
    background: transparent;
  }

  .table-scroll-wrapper::-webkit-scrollbar-thumb {
    background: var(--p-border);
  }

  /* ── Matrix table ─────────────────────────────────────────── */
  .matrix-table {
    border-collapse: collapse;
    font-size: 0.75rem;
    font-family: var(--font-mono);
    white-space: nowrap;
    min-width: 100%;
    letter-spacing: 0;
    table-layout: fixed;
  }

  .matrix-table thead {
    background: var(--p-bg-2);
  }

  .matrix-table th,
  .matrix-table td {
    border: 1px solid color-mix(in srgb, var(--p-border) 60%, transparent);
    padding: 3px 6px;
    text-align: center;
    vertical-align: middle;
    white-space: nowrap;
  }

  /* Operator name column — left-aligned, sticky, fixed width */
  .col-op,
  .cell-op {
    text-align: left;
    position: sticky;
    left: 0;
    background: var(--p-bg);
    z-index: 1;
    width: 200px;
    min-width: 200px;
    max-width: 200px;
  }

  .matrix-table thead .col-op {
    background: var(--p-bg-2);
  }

  .cell-op code {
    color: var(--p-glow);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    display: block;
    white-space: nowrap;
  }

  /* Count column — fixed narrow */
  .col-count,
  .cell-count {
    width: 32px;
    min-width: 32px;
    max-width: 32px;
    color: var(--p-dim);
    font-size: 0.7rem;
    text-align: center;
  }

  /* Engine column headers — fixed width */
  .col-engine {
    width: 80px;
    min-width: 80px;
    max-width: 80px;
    border-top: 2px solid var(--eng-color, var(--p-dim));
    border-bottom: 1px solid color-mix(in srgb, var(--p-border) 60%, transparent);
    font-size: 0.68rem;
    font-weight: 600;
    color: var(--p-mid);
    text-align: center;
  }

  .engine-link {
    color: inherit;
    text-decoration: none;
    display: block;
    white-space: nowrap;
  }

  .engine-link:hover {
    color: var(--p-bright);
    text-decoration: underline;
  }

  /* Support cells — fixed width, centered */
  .cell-support {
    color: var(--p-dim);
    font-size: 0.75rem;
    width: 80px;
    min-width: 80px;
    max-width: 80px;
    text-align: center;
    padding: 3px 4px;
  }

  .cell-support.yes {
    background: rgba(80, 200, 120, 0.07);
    color: var(--p-green, #50c878);
  }

  .check {
    font-weight: 700;
    display: block;
    text-align: center;
  }

  .dash {
    opacity: 0.3;
    display: block;
    text-align: center;
  }

  /* Row hover */
  .matrix-row:hover .cell-op,
  .matrix-row:hover .cell-count,
  .matrix-row:hover .cell-support {
    background: color-mix(in srgb, var(--p-glow) 6%, var(--p-bg));
  }

  /* ── Footer ───────────────────────────────────────────────── */
  .panel-footer {
    display: flex;
    align-items: center;
    gap: var(--sp-2, 8px);
    padding: 6px var(--sp-3, 12px);
    border-top: 1px solid var(--p-border);
    background: var(--p-bg-2);
    font-size: 0.65rem;
    color: var(--p-dim);
    flex-shrink: 0;
  }

  .footer-sep {
    opacity: 0.4;
  }

  /* ── CSS custom properties (fallback defaults) ────────────── */
  :global(:root) {
    --c-web:      #3b82f6;
    --c-iot:      #f59e0b;
    --c-code:     #a855f7;
    --c-threat:   #ef4444;
    --c-paste:    #6b7280;
    --c-social:   #06b6d4;
    --c-academic: #f97316;
  }
</style>
