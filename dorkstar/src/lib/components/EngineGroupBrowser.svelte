<script lang="ts">
  import { activeEngines, toggleEngine } from '$lib/stores/engine-store';
  import { ENGINE_REGISTRY } from '$lib/translation/adapters/registry';
  import type { EngineCategory, EngineId } from '$lib/translation/types';
  import { emitCmd, cmd } from '$lib/stores/cmd-log';

  // ── Props ──────────────────────────────────────────────────────────────────
  let { open, onclose }: { open: boolean; onclose: () => void } = $props();

  // ── Use-case groups ────────────────────────────────────────────────────────
  const USE_CASE_GROUPS: {
    id: string;
    label: string;
    description: string;
    icon: string;
    engineIds: EngineId[];
  }[] = [
    {
      id: 'recon',
      label: 'Recon & OSINT',
      description: 'Surface exposure, infrastructure mapping, and open-source intelligence',
      icon: '🔍',
      engineIds: ['shodan','censys','fofa','zoomeye','binaryedge','onyphe','leakix','netlas','criminalip','hunter','fullhunt'],
    },
    {
      id: 'web-search',
      label: 'Web Search',
      description: 'General-purpose web search across global and regional engines',
      icon: '🌐',
      engineIds: ['google','bing','yandex','duckduckgo','baidu','yahoo','qwant','ecosia','seznam','sogou'],
    },
    {
      id: 'code-leaks',
      label: 'Code & Secret Leaks',
      description: 'Find exposed credentials, API keys, and sensitive code in repositories',
      icon: '💻',
      engineIds: ['github','gitlab','sourcegraph','grep_app','gist','publicwww','grep_io'],
    },
    {
      id: 'threat-intel',
      label: 'Threat Intelligence',
      description: 'Malware, IOCs, URLs, and threat actor attribution',
      icon: '🛡️',
      engineIds: ['virustotal','urlscan','alienvault','threatcrowd'],
    },
    {
      id: 'paste-content',
      label: 'Paste & Content Search',
      description: 'Leaked data, pastes, and indexed web source code',
      icon: '📋',
      engineIds: ['pastebin','gist','publicwww','grep_io'],
    },
    {
      id: 'social',
      label: 'Social & Forums',
      description: 'Social media posts, threads, and community discussions',
      icon: '💬',
      engineIds: ['twitter','reddit','linkedin'],
    },
    {
      id: 'academic',
      label: 'Academic & Research',
      description: 'Scientific papers, citations, and research databases',
      icon: '🎓',
      engineIds: ['arxiv','semantic_scholar','pubmed'],
    },
    {
      id: 'document-discovery',
      label: 'Document Discovery',
      description: 'Find exposed documents, files, and sensitive data via web search',
      icon: '📄',
      engineIds: ['google','bing','yandex','duckduckgo'],
    },
  ];

  // ── Category color map ─────────────────────────────────────────────────────
  const CAT_COLOR: Record<EngineCategory, string> = {
    web: 'var(--c-web)',
    iot: 'var(--c-iot)',
    code: 'var(--c-code)',
    threat: 'var(--c-threat)',
    paste: 'var(--c-paste)',
    social: 'var(--c-social)',
    academic: 'var(--c-academic)',
  };

  const CAT_LABEL: Record<EngineCategory, string> = {
    web: 'Web',
    iot: 'IoT / Network',
    code: 'Code Search',
    threat: 'Threat Intel',
    paste: 'Paste / Content',
    social: 'Social',
    academic: 'Academic',
  };

  // ── Tier metadata ──────────────────────────────────────────────────────────
  const TIER_LABELS: Record<1 | 2 | 3, string> = {
    1: 'Full API',
    2: 'Limited API',
    3: 'Headless',
  };

  const TIER_COLORS: Record<1 | 2 | 3, string> = {
    1: 'var(--c-green)',
    2: 'var(--c-accent)',
    3: 'var(--c-text-3)',
  };

  // ── State ──────────────────────────────────────────────────────────────────
  let searchQuery = $state('');
  let expandedGroups = $state<Set<string>>(new Set(['recon', 'web-search', 'code-leaks']));
  let viewMode = $state<'use-case' | 'category'>('use-case');

  // ── Derived ────────────────────────────────────────────────────────────────
  const filteredGroups = $derived(() => {
    if (!searchQuery.trim()) return USE_CASE_GROUPS;
    const q = searchQuery.toLowerCase();
    return USE_CASE_GROUPS.map((group) => ({
      ...group,
      engineIds: group.engineIds.filter((id) => {
        const entry = ENGINE_REGISTRY.find((e) => e.id === id);
        return entry?.displayName.toLowerCase().includes(q);
      }),
    })).filter((group) => group.engineIds.length > 0);
  });

  const categoryGroups = $derived(() => {
    const cats = new Map<EngineCategory, typeof ENGINE_REGISTRY>();
    for (const entry of ENGINE_REGISTRY) {
      if (!cats.has(entry.category)) cats.set(entry.category, []);
      cats.get(entry.category)!.push(entry);
    }
    return Array.from(cats.entries()).map(([cat, engines]) => ({
      id: cat,
      label: CAT_LABEL[cat],
      color: CAT_COLOR[cat],
      engines,
    }));
  });

  // ── Functions ──────────────────────────────────────────────────────────────
  function toggleGroup(id: string) {
    const next = new Set(expandedGroups);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    expandedGroups = next;
  }

  function isGroupExpanded(id: string): boolean {
    return expandedGroups.has(id);
  }

  function selectGroup(engineIds: EngineId[]) {
    const active = $activeEngines;
    for (const id of engineIds) {
      if (!active.includes(id)) toggleEngine(id);
    }
  }

  function deselectGroup(engineIds: EngineId[]) {
    const active = $activeEngines;
    for (const id of engineIds) {
      if (active.includes(id)) toggleEngine(id);
    }
  }
  function isGroupFullyActive(engineIds: EngineId[]): boolean {
    const active = $activeEngines;
    return engineIds.every((id) => active.includes(id));
  }

  function isGroupPartiallyActive(engineIds: EngineId[]): boolean {
    const active = $activeEngines;
    const count = engineIds.filter((id) => active.includes(id)).length;
    return count > 0 && count < engineIds.length;
  }

  function getEngine(id: EngineId) {
    return ENGINE_REGISTRY.find((e) => e.id === id);
  }

  function isEngineActive(id: EngineId): boolean {
    return $activeEngines.includes(id);
  }
</script>

{#if open}
  <!-- Backdrop -->
  <div
    class="browser-overlay"
    role="presentation"
    onclick={onclose}
    aria-hidden="true"
  ></div>

  <!-- Drawer panel -->
  <aside class="engine-browser" aria-label="Engine Browser">
    <!-- Header -->
    <div class="browser-header">
      <div class="header-top">
        <h2 class="browser-title">Engine Browser</h2>
        <button class="close-btn" onclick={onclose} aria-label="Close engine browser">✕</button>
      </div>

      <!-- Search -->
      <div class="search-wrap">
        <span class="search-icon">🔎</span>
        <input
          class="search-input"
          type="search"
          placeholder="Filter engines…"
          bind:value={searchQuery}
          aria-label="Filter engines"
        />
      </div>

      <!-- View mode toggle -->
      <div class="view-toggle" role="group" aria-label="View mode">
        <button
          class="toggle-btn"
          class:active={viewMode === 'use-case'}
          onclick={() => (viewMode = 'use-case')}
        >Use Case</button>
        <button
          class="toggle-btn"
          class:active={viewMode === 'category'}
          onclick={() => (viewMode = 'category')}
        >Category</button>
      </div>
    </div>

    <!-- Body -->
    <div class="browser-body">
      {#if viewMode === 'use-case'}
        {#each filteredGroups() as group (group.id)}
          <section class="group-section">
            <!-- Group header -->
            <div class="group-header">
              <button
                class="group-toggle"
                onclick={() => toggleGroup(group.id)}
                aria-expanded={isGroupExpanded(group.id)}
                aria-controls={`group-${group.id}`}
              >
                <span class="group-icon">{group.icon}</span>
                <div class="group-meta">
                  <span class="group-label">{group.label}</span>
                  <span class="group-desc">{group.description}</span>
                </div>
                <span class="engine-count">{group.engineIds.length}</span>
                <span class="chevron" class:rotated={isGroupExpanded(group.id)}>›</span>
              </button>

              <div class="group-actions">
                {#if isGroupFullyActive(group.engineIds)}
                  <button
                    class="action-btn deselect"
                    onclick={() => deselectGroup(group.engineIds)}
                    title="Deselect all"
                  >Deselect all</button>
                {:else}
                  <button
                    class="action-btn select"
                    onclick={() => selectGroup(group.engineIds)}
                    title="Select all"
                  >
                    {isGroupPartiallyActive(group.engineIds) ? 'Select rest' : 'Select all'}
                  </button>
                {/if}
              </div>
            </div>

            <!-- Engine cards grid -->
            {#if isGroupExpanded(group.id)}
              <div class="engine-grid" id={`group-${group.id}`}>
                {#each group.engineIds as engineId (engineId)}
                  {@const engine = getEngine(engineId)}
                  {#if engine}
                    <button
                      class="engine-card"
                      class:active={isEngineActive(engineId)}
                      onclick={() => toggleEngine(engineId)}
                      aria-pressed={isEngineActive(engineId)}
                      title={engine.displayName}
                    >
                      <span
                        class="card-indicator"
                        style:background={isEngineActive(engineId) ? 'var(--c-accent)' : 'var(--c-border)'}
                      ></span>
                      <div class="card-body">
                        <span class="card-name">{engine.displayName}</span>
                        <div class="card-meta">
                          <span
                            class="tier-badge"
                            style:color={TIER_COLORS[engine.tier]}
                          >{TIER_LABELS[engine.tier]}</span>
                          <span class="op-count">{engine.operatorCount} ops</span>
                          <span
                            class="cat-dot"
                            style:background={CAT_COLOR[engine.category]}
                            title={CAT_LABEL[engine.category]}
                          ></span>
                        </div>
                      </div>
                    </button>
                  {/if}
                {/each}
              </div>
            {/if}
          </section>
        {/each}
      {:else}
        {#each categoryGroups() as group (group.id)}
          <section class="group-section">
            <div class="group-header">
              <button
                class="group-toggle"
                onclick={() => toggleGroup(group.id)}
                aria-expanded={isGroupExpanded(group.id)}
                aria-controls={`cat-${group.id}`}
              >
                <span
                  class="cat-swatch"
                  style:background={group.color}
                ></span>
                <div class="group-meta">
                  <span class="group-label">{group.label}</span>
                </div>
                <span class="engine-count">{group.engines.length}</span>
                <span class="chevron" class:rotated={isGroupExpanded(group.id)}>›</span>
              </button>

              <div class="group-actions">
                {#if isGroupFullyActive(group.engines.map(e => e.id))}
                  <button
                    class="action-btn deselect"
                    onclick={() => deselectGroup(group.engines.map(e => e.id))}
                  >Deselect all</button>
                {:else}
                  <button
                    class="action-btn select"
                    onclick={() => selectGroup(group.engines.map(e => e.id))}
                  >
                    {isGroupPartiallyActive(group.engines.map(e => e.id)) ? 'Select rest' : 'Select all'}
                  </button>
                {/if}
              </div>
            </div>

            {#if isGroupExpanded(group.id)}
              <div class="engine-grid" id={`cat-${group.id}`}>
                {#each group.engines as engine (engine.id)}
                  <button
                    class="engine-card"
                    class:active={isEngineActive(engine.id)}
                    onclick={() => toggleEngine(engine.id)}
                    aria-pressed={isEngineActive(engine.id)}
                    title={engine.displayName}
                  >
                    <span
                      class="card-indicator"
                      style:background={isEngineActive(engine.id) ? group.color : 'var(--c-border)'}
                    ></span>
                    <div class="card-body">
                      <span class="card-name">{engine.displayName}</span>
                      <div class="card-meta">
                        <span
                          class="tier-badge"
                          style:color={TIER_COLORS[engine.tier]}
                        >{TIER_LABELS[engine.tier]}</span>
                        <span class="op-count">{engine.operatorCount} ops</span>
                      </div>
                    </div>
                  </button>
                {/each}
              </div>
            {/if}
          </section>
        {/each}
      {/if}
    </div>

    <!-- Footer -->
    <div class="browser-footer">
      <span class="footer-label">Active engines</span>
      <span class="footer-count">{$activeEngines.length}</span>
    </div>
  </aside>
{/if}

<style>
  /* ── Overlay ────────────────────────────────────────────────────────────── */
  .browser-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.45);
    z-index: 200;
    cursor: pointer;
  }

  /* ── Drawer ─────────────────────────────────────────────────────────────── */
  .engine-browser {
    position: fixed;
    top: 0;
    right: 0;
    bottom: 0;
    width: 380px;
    z-index: 201;
    display: flex;
    flex-direction: column;
    background: var(--c-bg, #0d1117);
    border-left: 1px solid var(--c-border, #30363d);
    box-shadow: var(--shadow-md, -4px 0 24px rgba(0,0,0,0.4));
    font-family: var(--font-sans, system-ui, sans-serif);
    animation: slide-in var(--t-fast, 150ms) ease-out;
  }

  @keyframes slide-in {
    from { transform: translateX(100%); }
    to   { transform: translateX(0); }
  }

  /* ── Header ─────────────────────────────────────────────────────────────── */
  .browser-header {
    padding: var(--sp-3, 12px) var(--sp-4, 16px) var(--sp-2, 8px);
    border-bottom: 1px solid var(--c-border, #30363d);
    display: flex;
    flex-direction: column;
    gap: var(--sp-2, 8px);
    flex-shrink: 0;
  }

  .header-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .browser-title {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
    color: var(--c-text, #e6edf3);
    letter-spacing: 0.01em;
  }

  .close-btn {
    background: none;
    border: none;
    color: var(--c-text-3, #6e7681);
    cursor: pointer;
    font-size: 1rem;
    padding: var(--sp-1, 4px);
    border-radius: var(--r-sm, 4px);
    line-height: 1;
    transition: color var(--t-fast, 150ms), background var(--t-fast, 150ms);
  }

  .close-btn:hover {
    color: var(--c-text, #e6edf3);
    background: var(--c-surface-2, #21262d);
  }

  /* ── Search ─────────────────────────────────────────────────────────────── */
  .search-wrap {
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: var(--sp-2, 8px);
    font-size: 0.8rem;
    pointer-events: none;
  }

  .search-input {
    width: 100%;
    padding: var(--sp-1, 4px) var(--sp-2, 8px) var(--sp-1, 4px) calc(var(--sp-2, 8px) + 1.4rem);
    background: var(--c-surface, #161b22);
    border: 1px solid var(--c-border, #30363d);
    border-radius: var(--r-md, 6px);
    color: var(--c-text, #e6edf3);
    font-size: 0.8rem;
    font-family: var(--font-sans, system-ui, sans-serif);
    outline: none;
    transition: border-color var(--t-fast, 150ms);
  }

  .search-input:focus {
    border-color: var(--c-accent, #58a6ff);
  }

  .search-input::placeholder {
    color: var(--c-text-3, #6e7681);
  }

  /* ── View toggle ────────────────────────────────────────────────────────── */
  .view-toggle {
    display: flex;
    gap: 2px;
    background: var(--c-surface, #161b22);
    border: 1px solid var(--c-border, #30363d);
    border-radius: var(--r-md, 6px);
    padding: 2px;
  }

  .toggle-btn {
    flex: 1;
    padding: var(--sp-1, 4px) var(--sp-2, 8px);
    background: none;
    border: none;
    border-radius: calc(var(--r-md, 6px) - 2px);
    color: var(--c-text-2, #8b949e);
    font-size: 0.75rem;
    font-family: var(--font-sans, system-ui, sans-serif);
    cursor: pointer;
    transition: background var(--t-fast, 150ms), color var(--t-fast, 150ms);
  }

  .toggle-btn.active {
    background: var(--c-surface-2, #21262d);
    color: var(--c-text, #e6edf3);
  }

  /* ── Body ───────────────────────────────────────────────────────────────── */
  .browser-body {
    flex: 1;
    overflow-y: auto;
    padding: var(--sp-2, 8px) 0;
    scrollbar-width: thin;
    scrollbar-color: var(--c-border, #30363d) transparent;
  }

  /* ── Group section ──────────────────────────────────────────────────────── */
  .group-section {
    border-bottom: 1px solid var(--c-border, #30363d);
  }

  .group-section:last-child {
    border-bottom: none;
  }

  .group-header {
    display: flex;
    align-items: center;
    gap: var(--sp-2, 8px);
    padding: var(--sp-1, 4px) var(--sp-3, 12px) var(--sp-1, 4px) 0;
  }

  .group-toggle {
    flex: 1;
    display: flex;
    align-items: center;
    gap: var(--sp-2, 8px);
    padding: var(--sp-2, 8px) var(--sp-3, 12px);
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
    color: var(--c-text, #e6edf3);
    border-radius: var(--r-sm, 4px);
    transition: background var(--t-fast, 150ms);
  }

  .group-toggle:hover {
    background: var(--c-surface, #161b22);
  }

  .group-icon {
    font-size: 1rem;
    flex-shrink: 0;
  }

  .cat-swatch {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .group-meta {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }

  .group-label {
    font-size: 0.82rem;
    font-weight: 600;
    color: var(--c-text, #e6edf3);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .group-desc {
    font-size: 0.7rem;
    color: var(--c-text-3, #6e7681);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .engine-count {
    font-size: 0.7rem;
    font-family: var(--font-mono, monospace);
    color: var(--c-text-3, #6e7681);
    background: var(--c-surface-2, #21262d);
    border: 1px solid var(--c-border, #30363d);
    border-radius: var(--r-sm, 4px);
    padding: 1px 5px;
    flex-shrink: 0;
  }

  .chevron {
    font-size: 1rem;
    color: var(--c-text-3, #6e7681);
    transition: transform var(--t-fast, 150ms);
    display: inline-block;
    flex-shrink: 0;
  }

  .chevron.rotated {
    transform: rotate(90deg);
  }

  .group-actions {
    flex-shrink: 0;
    padding-right: var(--sp-3, 12px);
  }

  .action-btn {
    font-size: 0.68rem;
    padding: 2px 7px;
    border-radius: var(--r-sm, 4px);
    border: 1px solid var(--c-border, #30363d);
    cursor: pointer;
    font-family: var(--font-sans, system-ui, sans-serif);
    transition: background var(--t-fast, 150ms), color var(--t-fast, 150ms);
    white-space: nowrap;
  }

  .action-btn.select {
    background: var(--c-accent-dim, rgba(88,166,255,0.1));
    color: var(--c-accent, #58a6ff);
    border-color: var(--c-accent, #58a6ff);
  }

  .action-btn.select:hover {
    background: var(--c-accent, #58a6ff);
    color: #000;
  }

  .action-btn.deselect {
    background: var(--c-surface-2, #21262d);
    color: var(--c-text-2, #8b949e);
  }

  .action-btn.deselect:hover {
    background: var(--c-surface, #161b22);
    color: var(--c-text, #e6edf3);
  }

  /* ── Engine grid ────────────────────────────────────────────────────────── */
  .engine-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: var(--sp-1, 4px);
    padding: var(--sp-1, 4px) var(--sp-3, 12px) var(--sp-2, 8px);
  }

  /* ── Engine card ────────────────────────────────────────────────────────── */
  .engine-card {
    display: flex;
    align-items: stretch;
    background: var(--c-surface, #161b22);
    border: 1px solid var(--c-border, #30363d);
    border-radius: var(--r-md, 6px);
    cursor: pointer;
    text-align: left;
    overflow: hidden;
    transition: border-color var(--t-fast, 150ms), background var(--t-fast, 150ms);
    font-family: var(--font-sans, system-ui, sans-serif);
    padding: 0;
  }

  .engine-card:hover {
    background: var(--c-surface-2, #21262d);
    border-color: var(--c-accent, #58a6ff);
  }

  .engine-card.active {
    border-color: var(--c-accent, #58a6ff);
    background: var(--c-accent-dim, rgba(88,166,255,0.08));
  }

  .card-indicator {
    width: 3px;
    flex-shrink: 0;
    border-radius: var(--r-md, 6px) 0 0 var(--r-md, 6px);
    transition: background var(--t-fast, 150ms);
  }

  .card-body {
    flex: 1;
    padding: var(--sp-1, 4px) var(--sp-2, 8px);
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .card-name {
    font-size: 0.78rem;
    font-weight: 500;
    color: var(--c-text, #e6edf3);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .card-meta {
    display: flex;
    align-items: center;
    gap: var(--sp-1, 4px);
    flex-wrap: wrap;
  }

  .tier-badge {
    font-size: 0.62rem;
    font-family: var(--font-mono, monospace);
    font-weight: 500;
  }

  .op-count {
    font-size: 0.62rem;
    color: var(--c-text-3, #6e7681);
    font-family: var(--font-mono, monospace);
  }

  .cat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
    margin-left: auto;
  }

  /* ── Footer ─────────────────────────────────────────────────────────────── */
  .browser-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--sp-2, 8px) var(--sp-4, 16px);
    border-top: 1px solid var(--c-border, #30363d);
    flex-shrink: 0;
  }

  .footer-label {
    font-size: 0.75rem;
    color: var(--c-text-3, #6e7681);
  }

  .footer-count {
    font-size: 0.82rem;
    font-family: var(--font-mono, monospace);
    font-weight: 600;
    color: var(--c-accent, #58a6ff);
    background: var(--c-accent-dim, rgba(88,166,255,0.1));
    border: 1px solid var(--c-accent, #58a6ff);
    border-radius: var(--r-sm, 4px);
    padding: 1px 7px;
  }
</style>
