<script lang="ts">
  import type { PageData } from './$types';

  let { data }: { data: PageData } = $props();

  // Category colour mapping for engine column headers
  const CATEGORY_COLORS: Record<string, string> = {
    web: 'var(--color-web)',
    iot: 'var(--color-iot)',
    code: 'var(--color-code)',
    threat: 'var(--color-threat)',
    paste: 'var(--color-paste)',
    social: 'var(--color-social)',
    academic: 'var(--color-academic)',
  };

  // Filter state
  let filterCategory = $state<string>('all');
  let filterOperator = $state('');

  const categories = ['all', 'web', 'iot', 'code', 'threat', 'paste', 'social', 'academic'];

  // Filtered engine columns
  const visibleEngineIds = $derived(
    filterCategory === 'all'
      ? data.engineIds
      : data.engineIds.filter((id) => data.engineCategories[id] === filterCategory)
  );

  // Filtered operator groups
  const visibleGroups = $derived(
    data.groups
      .map((group) => ({
        ...group,
        rows: group.rows.filter((row) =>
          filterOperator === '' ||
          row.operator.toLowerCase().includes(filterOperator.toLowerCase())
        ),
      }))
      .filter((group) => group.rows.length > 0)
  );
</script>

<svelte:head>
  <title>DORKSTAR — Operator Reference</title>
  <meta name="description" content="Auto-generated canonical operator coverage matrix for all 39 DORKSTAR search engines." />
</svelte:head>

<div class="docs-page">
  <!-- ── Header ─────────────────────────────────────────────────────────── -->
  <header class="docs-header">
    <div class="docs-header__title">
      <h1>Operator Reference</h1>
      <p class="docs-header__subtitle">
        Coverage matrix for <strong>{data.totalOperators}</strong> canonical operators
        across <strong>{data.totalEngines}</strong> search engines.
        Auto-generated from the engine registry.
      </p>
    </div>

    <div class="docs-header__controls">
      <!-- Operator search -->
      <input
        class="docs-filter-input"
        type="search"
        placeholder="Filter operators…"
        bind:value={filterOperator}
        aria-label="Filter operators"
      />

      <!-- Category filter tabs -->
      <nav class="docs-category-tabs" aria-label="Filter by engine category">
        {#each categories as cat}
          <button
            class="docs-category-tab"
            class:active={filterCategory === cat}
            onclick={() => (filterCategory = cat)}
            aria-pressed={filterCategory === cat}
          >
            {cat === 'all' ? 'All' : cat.toUpperCase()}
          </button>
        {/each}
      </nav>
    </div>
  </header>

  <!-- ── Coverage matrix ────────────────────────────────────────────────── -->
  <div class="docs-matrix-wrapper" role="region" aria-label="Operator coverage matrix">
    <table class="docs-matrix">
      <thead>
        <tr>
          <th class="docs-matrix__op-col" scope="col">Operator</th>
          <th class="docs-matrix__count-col" scope="col" title="Number of engines that support this operator">
            #
          </th>
          {#each visibleEngineIds as engineId}
            {@const cat = data.engineCategories[engineId]}
            <th
              class="docs-matrix__engine-col"
              scope="col"
              style="--engine-color: {CATEGORY_COLORS[cat] ?? '#888'}"
            >
              <a
                href={data.engineDocs[engineId]}
                target="_blank"
                rel="noopener noreferrer"
                class="docs-matrix__engine-link"
                title="Open {data.engineNames[engineId]} documentation"
              >
                {data.engineNames[engineId]}
              </a>
            </th>
          {/each}
        </tr>
      </thead>

      <tbody>
        {#each visibleGroups as group}
          <!-- Group header row -->
          <tr class="docs-matrix__group-row">
            <td
              class="docs-matrix__group-label"
              colspan={2 + visibleEngineIds.length}
            >
              {group.label}
            </td>
          </tr>

          <!-- Operator rows -->
          {#each group.rows as row}
            <tr class="docs-matrix__row">
              <td class="docs-matrix__op-name">
                <code>{row.operator}</code>
              </td>
              <td class="docs-matrix__support-count" title="{row.supportCount} of {visibleEngineIds.length} visible engines">
                {row.supportCount}
              </td>
              {#each visibleEngineIds as engineId}
                {@const supported = row.support[engineId] ?? false}
                <td
                  class="docs-matrix__cell"
                  class:supported
                  title="{data.engineNames[engineId]}: {supported ? 'supported' : 'not supported'}"
                  aria-label="{row.operator} on {data.engineNames[engineId]}: {supported ? 'supported' : 'not supported'}"
                >
                  {#if supported}
                    <span class="docs-matrix__check" aria-hidden="true">✓</span>
                  {:else}
                    <span class="docs-matrix__dash" aria-hidden="true">—</span>
                  {/if}
                </td>
              {/each}
            </tr>
          {/each}
        {/each}
      </tbody>
    </table>
  </div>

  <!-- ── Legend ─────────────────────────────────────────────────────────── -->
  <footer class="docs-legend">
    <div class="docs-legend__item">
      <span class="docs-legend__check">✓</span> Operator supported natively
    </div>
    <div class="docs-legend__item">
      <span class="docs-legend__dash">—</span> Operator not supported (degradation warning emitted)
    </div>
    <div class="docs-legend__categories">
      {#each Object.entries(CATEGORY_COLORS) as [cat, color]}
        <span class="docs-legend__cat" style="border-color: {color}">
          {cat.toUpperCase()}
        </span>
      {/each}
    </div>
  </footer>
</div>

<style>
  /* ── Page layout ──────────────────────────────────────────────────────── */
  .docs-page {
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    padding: 1.5rem;
    min-height: 100vh;
    background: var(--color-bg, #0d0d0d);
    color: var(--color-text, #e8e8e8);
    font-family: var(--font-mono, 'JetBrains Mono', 'Fira Code', monospace);
  }

  /* ── Header ───────────────────────────────────────────────────────────── */
  .docs-header {
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .docs-header h1 {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--color-amber, #f5a623);
    margin: 0;
  }

  .docs-header__subtitle {
    font-size: 0.85rem;
    color: var(--color-muted, #888);
    margin: 0.25rem 0 0;
  }

  .docs-header__controls {
    display: flex;
    flex-wrap: wrap;
    gap: 0.75rem;
    align-items: center;
  }

  /* ── Filter input ─────────────────────────────────────────────────────── */
  .docs-filter-input {
    background: var(--color-surface, #1a1a1a);
    border: 1px solid var(--color-border, #333);
    border-radius: 4px;
    color: var(--color-text, #e8e8e8);
    font-family: inherit;
    font-size: 0.85rem;
    padding: 0.4rem 0.75rem;
    width: 220px;
    outline: none;
  }

  .docs-filter-input:focus {
    border-color: var(--color-amber, #f5a623);
  }

  /* ── Category tabs ────────────────────────────────────────────────────── */
  .docs-category-tabs {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem;
  }

  .docs-category-tab {
    background: var(--color-surface, #1a1a1a);
    border: 1px solid var(--color-border, #333);
    border-radius: 4px;
    color: var(--color-muted, #888);
    cursor: pointer;
    font-family: inherit;
    font-size: 0.75rem;
    padding: 0.3rem 0.6rem;
    transition: border-color 0.15s, color 0.15s;
  }

  .docs-category-tab:hover {
    border-color: var(--color-amber, #f5a623);
    color: var(--color-text, #e8e8e8);
  }

  .docs-category-tab.active {
    background: var(--color-amber, #f5a623);
    border-color: var(--color-amber, #f5a623);
    color: #000;
    font-weight: 600;
  }

  /* ── Matrix wrapper ───────────────────────────────────────────────────── */
  .docs-matrix-wrapper {
    overflow-x: auto;
    border: 1px solid var(--color-border, #333);
    border-radius: 6px;
  }

  /* ── Matrix table ─────────────────────────────────────────────────────── */
  .docs-matrix {
    border-collapse: collapse;
    font-size: 0.78rem;
    min-width: 100%;
    white-space: nowrap;
  }

  .docs-matrix thead {
    position: sticky;
    top: 0;
    z-index: 2;
    background: var(--color-surface, #1a1a1a);
  }

  .docs-matrix th,
  .docs-matrix td {
    border: 1px solid var(--color-border, #222);
    padding: 0.3rem 0.5rem;
    text-align: center;
    vertical-align: middle;
  }

  /* Operator name column — left-aligned, sticky */
  .docs-matrix__op-col,
  .docs-matrix__op-name {
    text-align: left;
    position: sticky;
    left: 0;
    background: var(--color-surface, #1a1a1a);
    z-index: 1;
    min-width: 200px;
  }

  .docs-matrix__op-name code {
    color: var(--color-amber, #f5a623);
    font-size: 0.8rem;
  }

  /* Count column */
  .docs-matrix__count-col,
  .docs-matrix__support-count {
    min-width: 32px;
    color: var(--color-muted, #888);
    font-size: 0.75rem;
  }

  /* Engine column headers */
  .docs-matrix__engine-col {
    min-width: 80px;
    border-bottom: 3px solid var(--engine-color, #888);
    font-size: 0.72rem;
    font-weight: 600;
  }

  .docs-matrix__engine-link {
    color: inherit;
    text-decoration: none;
  }

  .docs-matrix__engine-link:hover {
    text-decoration: underline;
    color: var(--color-amber, #f5a623);
  }

  /* Group header rows */
  .docs-matrix__group-row {
    background: var(--color-surface-2, #141414);
  }

  .docs-matrix__group-label {
    text-align: left;
    font-weight: 700;
    font-size: 0.72rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-muted, #888);
    padding: 0.4rem 0.5rem;
  }

  /* Data cells */
  .docs-matrix__cell {
    color: var(--color-muted, #555);
  }

  .docs-matrix__cell.supported {
    background: rgba(80, 200, 120, 0.08);
    color: var(--color-green, #50c878);
  }

  .docs-matrix__check {
    font-size: 0.85rem;
    font-weight: 700;
  }

  .docs-matrix__dash {
    font-size: 0.85rem;
    opacity: 0.35;
  }

  /* Alternating row shading */
  .docs-matrix__row:nth-child(even) {
    background: rgba(255, 255, 255, 0.02);
  }

  .docs-matrix__row:hover {
    background: rgba(245, 166, 35, 0.05);
  }

  /* ── Legend ───────────────────────────────────────────────────────────── */
  .docs-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 1rem;
    align-items: center;
    font-size: 0.78rem;
    color: var(--color-muted, #888);
    padding-top: 0.5rem;
    border-top: 1px solid var(--color-border, #333);
  }

  .docs-legend__check {
    color: var(--color-green, #50c878);
    font-weight: 700;
  }

  .docs-legend__dash {
    opacity: 0.5;
  }

  .docs-legend__categories {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin-left: auto;
  }

  .docs-legend__cat {
    border-left: 3px solid;
    padding-left: 0.4rem;
    font-size: 0.7rem;
    font-weight: 600;
    letter-spacing: 0.05em;
  }

  /* ── CSS custom properties (dark theme defaults) ──────────────────────── */
  :global(:root) {
    --color-web: #3b82f6;
    --color-iot: #f59e0b;
    --color-code: #a855f7;
    --color-threat: #ef4444;
    --color-paste: #6b7280;
    --color-social: #06b6d4;
    --color-academic: #f97316;
    --color-academic: #f97316;
  }
</style>
