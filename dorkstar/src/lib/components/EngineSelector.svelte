<script lang="ts">
	import { activeEngines, engineOrder, toggleEngine, toggleAll, toggleCategory, reorderEngines } from '$lib/stores/engine-store';
	import { ENGINE_REGISTRY } from '$lib/translation/adapters/registry';
	import type { EngineCategory, EngineId } from '$lib/translation/types';
	import EngineGroupBrowser from './EngineGroupBrowser.svelte';
	import { emitCmd, cmd } from '$lib/stores/cmd-log';

	// ── Browser panel state ───────────────────────────────────────────────────
	let browserOpen = $state(false);

	const CATEGORIES: Array<EngineCategory | 'all'> = [
		'all', 'web', 'iot', 'code', 'threat', 'paste', 'social', 'academic'
	];

	const CATEGORY_LABELS: Record<string, string> = {
		all: 'All', web: 'Web', iot: 'IoT', code: 'Code',
		threat: 'Threat', paste: 'Paste', social: 'Social', academic: 'Academic'
	};

	function categoryCount(cat: EngineCategory | 'all') {
		if (cat === 'all') return $activeEngines.length;
		return ENGINE_REGISTRY.filter(e => e.category === cat && $activeEngines.includes(e.id)).length;
	}

	function categoryTotal(cat: EngineCategory | 'all') {
		if (cat === 'all') return ENGINE_REGISTRY.length;
		return ENGINE_REGISTRY.filter(e => e.category === cat).length;
	}

	function isCategoryActive(cat: EngineCategory | 'all') {
		if (cat === 'all') return $activeEngines.length === ENGINE_REGISTRY.length;
		const engines = ENGINE_REGISTRY.filter(e => e.category === cat);
		return engines.length > 0 && engines.every(e => $activeEngines.includes(e.id));
	}

	function isCategoryPartial(cat: EngineCategory | 'all') {
		if (cat === 'all') return $activeEngines.length > 0 && $activeEngines.length < ENGINE_REGISTRY.length;
		const engines = ENGINE_REGISTRY.filter(e => e.category === cat);
		const active = engines.filter(e => $activeEngines.includes(e.id));
		return active.length > 0 && active.length < engines.length;
	}

	const orderedEngines = $derived(
		$engineOrder
			.map(id => ENGINE_REGISTRY.find(e => e.id === id))
			.filter((e): e is (typeof ENGINE_REGISTRY)[number] => e !== undefined)
	);

	// ── Multi-select state ────────────────────────────────────────────────────
	// lastClickedIndex tracks the anchor for shift-click range selection
	let lastClickedIndex = $state<number | null>(null);

	/**
	 * Handle chip click with modifier key support:
	 *   - Plain click:       toggle single engine (existing behaviour)
	 *   - Ctrl/Cmd + click:  add/remove from selection without clearing others
	 *   - Shift + click:     range-select from last clicked to this chip
	 */
	function handleChipClick(e: MouseEvent, engineId: EngineId, index: number) {
		if (e.shiftKey && lastClickedIndex !== null) {
			// Range select: activate all engines between lastClickedIndex and index
			const lo = Math.min(lastClickedIndex, index);
			const hi = Math.max(lastClickedIndex, index);
			const rangeIds = orderedEngines.slice(lo, hi + 1).map(eng => eng.id);
			// Determine intent: if the clicked chip is currently inactive, activate range; else deactivate
			const intent = !$activeEngines.includes(engineId);
			for (const id of rangeIds) {
				const isActive = $activeEngines.includes(id);
				if (intent && !isActive) toggleEngine(id);
				if (!intent && isActive) toggleEngine(id);
			}
		} else {
			// Plain click or Ctrl/Cmd click — both just toggle the single engine
			// (Ctrl/Cmd click feels the same as plain click for individual chips;
			//  the distinction matters mainly for range selection anchor tracking)
			toggleEngine(engineId);
		}
		lastClickedIndex = index;
	}

	// ── Select / deselect helpers ─────────────────────────────────────────────
	function selectAll() {
		// Activate every engine that isn't already active
		for (const e of ENGINE_REGISTRY) {
			if (!$activeEngines.includes(e.id)) toggleEngine(e.id);
		}
	}

	function deselectAll() {
		// Deactivate every active engine
		for (const id of [...$activeEngines]) {
			toggleEngine(id);
		}
	}

	function selectCategory(cat: EngineCategory) {
		const catEngines = ENGINE_REGISTRY.filter(e => e.category === cat);
		const allActive = catEngines.every(e => $activeEngines.includes(e.id));
		// If all are already active, deselect the category; otherwise select it
		for (const e of catEngines) {
			const isActive = $activeEngines.includes(e.id);
			if (!allActive && !isActive) toggleEngine(e.id);
			if (allActive && isActive) toggleEngine(e.id);
		}
	}

	// ── Drag-and-drop ─────────────────────────────────────────────────────────
	let dragFromIndex = $state<number | null>(null);
	let dragOverIndex = $state<number | null>(null);

	function onDragStart(e: DragEvent, i: number) {
		dragFromIndex = i;
		if (e.dataTransfer) { e.dataTransfer.effectAllowed = 'move'; }
	}
	function onDragOver(e: DragEvent, i: number) {
		e.preventDefault();
		dragOverIndex = i;
		if (e.dataTransfer) { e.dataTransfer.dropEffect = 'move'; }
	}
	function onDrop(e: DragEvent, i: number) {
		e.preventDefault();
		if (dragFromIndex !== null && dragFromIndex !== i) reorderEngines(dragFromIndex, i);
		dragFromIndex = null;
		dragOverIndex = null;
	}
	function onDragEnd() { dragFromIndex = null; dragOverIndex = null; }

	// ── Category colour map ───────────────────────────────────────────────────
	const CAT_COLOR: Record<string, string> = {
		web: 'var(--c-web)', iot: 'var(--c-iot)', code: 'var(--c-code)',
		threat: 'var(--c-threat)', paste: 'var(--c-paste)',
		social: 'var(--c-social)', academic: 'var(--c-academic)',
	};

	// ── Derived counts ────────────────────────────────────────────────────────
	const totalEngines = ENGINE_REGISTRY.length;
	const activeCount = $derived($activeEngines.length);
	const allSelected = $derived(activeCount === totalEngines);
	const noneSelected = $derived(activeCount === 0);

	// ── Expanded category for sidebar collapse ────────────────────────────────
	// Clicking a category tab toggles its engine list open/closed
	let expandedCategory = $state<EngineCategory | 'all' | null>(null);

	function toggleExpanded(cat: EngineCategory | 'all') {
		expandedCategory = expandedCategory === cat ? null : cat;
	}

	// Engines filtered to a specific category
	function enginesForCategory(cat: EngineCategory | 'all') {
		if (cat === 'all') return orderedEngines;
		return orderedEngines.filter(e => e.category === cat);
	}
</script>

<div class="engine-selector" role="toolbar" aria-label="Engine selector">
	<!-- ── Collapsible category sections ─────────────────────────────────── -->
	{#each CATEGORIES.filter(c => c !== 'all') as cat}
		{@const catEngines = enginesForCategory(cat as EngineCategory)}
		{@const active = isCategoryActive(cat as EngineCategory)}
		{@const partial = isCategoryPartial(cat as EngineCategory)}
		{@const isExpanded = expandedCategory === cat}
		{@const count = categoryCount(cat as EngineCategory)}
		{@const total = categoryTotal(cat as EngineCategory)}

		<div class="cat-section" class:cat-section--expanded={isExpanded}>
			<!-- Category header: click to expand/collapse, right-click to toggle all -->
			<div class="cat-section__header">
				<button
					class="cat-section__toggle"
					onclick={() => toggleExpanded(cat as EngineCategory)}
					aria-expanded={isExpanded}
					title="Expand {CATEGORY_LABELS[cat]} engines"
				>
					<span class="cat-chevron">{isExpanded ? '▼' : '▶'}</span>
					{#if cat !== 'all'}
						<span class="cat-dot" style="background:{CAT_COLOR[cat]}"></span>
					{/if}
					<span class="cat-label">{CATEGORY_LABELS[cat]}</span>
					<span class="cat-count" class:cat-count--partial={partial && !active} class:cat-count--active={active}>
						{count}/{total}
					</span>
				</button>
				<!-- Quick toggle all in category -->
				<button
					class="cat-section__all-btn"
					onclick={() => selectCategory(cat as EngineCategory)}
					title="{active ? 'Deselect' : 'Select'} all {CATEGORY_LABELS[cat]}"
					aria-label="{active ? 'Deselect' : 'Select'} all {CATEGORY_LABELS[cat]} engines"
				>{active ? '−' : '+'}</button>
			</div>

			<!-- Engine chips — only shown when expanded -->
			{#if isExpanded}
				<div class="cat-section__chips" role="list">
					{#each catEngines as engine, i (engine.id)}
						{@const isActive = $activeEngines.includes(engine.id)}
						{@const globalIndex = orderedEngines.findIndex(e => e.id === engine.id)}
						<button
							class="chip"
							class:chip--active={isActive}
							style="--cat-color:{CAT_COLOR[engine.category] ?? 'var(--c-text-3)'}"
							onclick={e => handleChipClick(e, engine.id, globalIndex)}
							aria-pressed={isActive}
							title="{engine.displayName} · {engine.operatorCount} ops · tier {engine.tier}"
							role="listitem"
						>
							<span class="chip__dot"></span>
							<span class="chip__name">{engine.displayName}</span>
							<span class="chip__count">{engine.operatorCount}</span>
						</button>
					{/each}
				</div>
			{/if}
		</div>
	{/each}
</div>

<!-- ── Engine group browser drawer ───────────────────────────────────────── -->
<EngineGroupBrowser open={browserOpen} onclose={() => { browserOpen = false; emitCmd(cmd.closeBrowser()); }} />

<style>
	.engine-selector {
		display: flex;
		flex-direction: column;
	}

	/* ── Collapsible category section ────────────────────────────────────────── */
	.cat-section {
		border-bottom: 1px solid var(--p-border, #003300);
	}

	.cat-section__header {
		display: flex;
		align-items: center;
	}

	/* Main toggle button — expands/collapses the engine list */
	.cat-section__toggle {
		flex: 1;
		display: flex;
		align-items: center;
		gap: 5px;
		padding: 5px var(--sp-2);
		background: var(--p-bg-2, #001400);
		border: none;
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		font-size: 11px;
		text-align: left;
		cursor: pointer;
		transition: color var(--t-fast), background var(--t-fast);
		min-width: 0;
	}

	.cat-section__toggle:hover {
		color: var(--p-mid, #33cc33);
		background: var(--p-bg-3, #001e00);
	}

	.cat-section--expanded .cat-section__toggle {
		color: var(--p-mid, #33cc33);
		border-left: 2px solid var(--p-border-2, #004d00);
	}

	.cat-chevron {
		font-size: 8px;
		flex-shrink: 0;
		color: var(--p-dim, #1a4d1a);
	}

	.cat-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		flex-shrink: 0;
	}

	.cat-label {
		flex: 1;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.cat-count {
		font-size: 10px;
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		flex-shrink: 0;
	}

	.cat-count--partial { color: var(--p-mid, #33cc33); }
	.cat-count--active  { color: var(--p-bright, #66ff66); }

	/* Quick +/− toggle for the whole category */
	.cat-section__all-btn {
		flex-shrink: 0;
		width: 20px;
		background: none;
		border: none;
		border-left: 1px solid var(--p-border, #003300);
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		font-size: 14px;
		cursor: pointer;
		padding: 0;
		height: 100%;
		display: flex;
		align-items: center;
		justify-content: center;
		transition: color var(--t-fast);
	}

	.cat-section__all-btn:hover {
		color: var(--p-bright, #66ff66);
	}

	/* ── Engine chips inside expanded section ────────────────────────────────── */
	.cat-section__chips {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: var(--sp-1) var(--sp-1) var(--sp-2);
		background: var(--p-bg-3, #001e00);
	}

	.chip {
		display: flex;
		align-items: center;
		gap: 5px;
		width: 100%;
		padding: 3px var(--sp-2);
		border: 1px solid var(--p-border, #003300);
		background: transparent;
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		font-size: 11px;
		cursor: pointer;
		text-align: left;
		transition: all var(--t-fast);
		white-space: nowrap;
		overflow: hidden;
	}

	.chip:hover {
		border-color: var(--p-border-2, #004d00);
		color: var(--p-mid, #33cc33);
		background: rgba(51, 204, 51, 0.05);
	}

	.chip--active {
		border-color: rgba(51, 204, 51, 0.35);
		color: var(--p-mid, #33cc33);
		background: rgba(51, 204, 51, 0.08);
	}

	.chip--active .chip__dot {
		background: var(--cat-color);
	}

	.chip__dot {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: var(--p-border-2, #004d00);
		flex-shrink: 0;
		transition: background var(--t-fast);
	}

	.chip__name {
		flex: 1;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.chip__count {
		font-size: 9px;
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		flex-shrink: 0;
		margin-left: auto;
	}

	.chip--active .chip__count {
		color: var(--p-mid, #33cc33);
	}
</style>
