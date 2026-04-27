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
</script>

<div class="engine-selector" role="toolbar" aria-label="Engine selector">
	<!-- ── Category filter tabs ──────────────────────────────────────────── -->
	<div class="category-bar" role="tablist" aria-label="Filter by category">
		{#each CATEGORIES as cat}
			{@const active = isCategoryActive(cat)}
			{@const partial = isCategoryPartial(cat)}
			<button
				role="tab"
				aria-selected={active}
				class="cat-tab"
				class:is-active={active}
				class:is-partial={partial && !active}
				onclick={() => cat === 'all' ? toggleAll() : toggleCategory(cat)}
				title="{CATEGORY_LABELS[cat]}: {categoryCount(cat)} of {categoryTotal(cat)} active"
			>
				{#if cat !== 'all'}
					<span class="cat-dot" style="background:{CAT_COLOR[cat]}"></span>
				{/if}
				<span class="cat-label">{CATEGORY_LABELS[cat]}</span>
				<span class="cat-count">{categoryCount(cat)}</span>
			</button>
		{/each}

		<!-- ── Selection toolbar ─────────────────────────────────────────── -->
		<div class="sel-toolbar" role="group" aria-label="Bulk selection">
			<!-- Selection count -->
			<span class="sel-count" aria-live="polite" aria-label="{activeCount} of {totalEngines} engines selected">
				<span class="sel-count__num">{activeCount}</span>
				<span class="sel-count__sep">/</span>
				<span class="sel-count__total">{totalEngines}</span>
			</span>

			<div class="sel-divider" aria-hidden="true"></div>

			<!-- Select All -->
			<button
				class="sel-btn"
				class:sel-btn--disabled={allSelected}
				onclick={selectAll}
				disabled={allSelected}
				title="Select all engines"
				aria-label="Select all engines"
			>
				<svg width="12" height="12" viewBox="0 0 16 16" fill="none" aria-hidden="true">
					<rect x="1" y="1" width="14" height="14" rx="2" stroke="currentColor" stroke-width="1.5"/>
					<path d="M4 8l3 3 5-5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
				</svg>
				All
			</button>

			<!-- Deselect All -->
			<button
				class="sel-btn"
				class:sel-btn--disabled={noneSelected}
				onclick={deselectAll}
				disabled={noneSelected}
				title="Deselect all engines"
				aria-label="Deselect all engines"
			>
				<svg width="12" height="12" viewBox="0 0 16 16" fill="none" aria-hidden="true">
					<rect x="1" y="1" width="14" height="14" rx="2" stroke="currentColor" stroke-width="1.5"/>
					<path d="M5 5l6 6M11 5l-6 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
				</svg>
				None
			</button>

			<div class="sel-divider" aria-hidden="true"></div>

			<!-- Per-category quick-select buttons -->
			{#each (CATEGORIES.filter(c => c !== 'all') as EngineCategory[]) as cat}
				{@const catActive = isCategoryActive(cat)}
				{@const catPartial = isCategoryPartial(cat)}
				<button
					class="sel-cat-btn"
					class:sel-cat-btn--active={catActive}
					class:sel-cat-btn--partial={catPartial && !catActive}
					style="--cat-color:{CAT_COLOR[cat]}"
					onclick={() => selectCategory(cat)}
					title="{catActive ? 'Deselect' : 'Select'} all {CATEGORY_LABELS[cat]} engines"
					aria-pressed={catActive}
				>
					<span class="sel-cat-dot"></span>
					{CATEGORY_LABELS[cat]}
				</button>
			{/each}

			<div class="sel-divider" aria-hidden="true"></div>

			<!-- Browse by use case / category -->
			<button
				class="sel-btn sel-btn--browse"
				class:sel-btn--active={browserOpen}
				onclick={() => { browserOpen = true; emitCmd(cmd.openBrowser()); }}
				title="Browse engines by use case and category"
				aria-label="Open engine browser"
				aria-expanded={browserOpen}
			>
				<svg width="12" height="12" viewBox="0 0 16 16" fill="none" aria-hidden="true">
					<rect x="1" y="1" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.5"/>
					<rect x="9" y="1" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.5"/>
					<rect x="1" y="9" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.5"/>
					<rect x="9" y="9" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.5"/>
				</svg>
				Browse
			</button>
		</div>
	</div>

	<!-- ── Engine chips row ───────────────────────────────────────────────── -->
	<div
		class="chips-row"
		role="list"
		aria-label="Engine chips — click to toggle, shift-click to range-select, drag to reorder"
	>
		{#each orderedEngines as engine, i (engine.id)}
			{@const isActive = $activeEngines.includes(engine.id)}
			{@const isDragOver = dragOverIndex === i && dragFromIndex !== null && dragFromIndex !== i}
			<div
				role="listitem"
				class="chip-wrap"
				class:drag-over={isDragOver}
				draggable="true"
				ondragstart={e => onDragStart(e, i)}
				ondragover={e => onDragOver(e, i)}
				ondrop={e => onDrop(e, i)}
				ondragend={onDragEnd}
			>
				<button
					class="chip"
					class:chip--active={isActive}
					style="--cat-color:{CAT_COLOR[engine.category] ?? 'var(--c-text-3)'}"
					onclick={e => handleChipClick(e, engine.id, i)}
					aria-pressed={isActive}
					title="{engine.displayName} · {engine.operatorCount} operators · tier {engine.tier}{'\n'}Shift+click to range-select"
				>
					<span class="chip__dot"></span>
					<span class="chip__name">{engine.displayName}</span>
					<span class="chip__count">{engine.operatorCount}</span>
				</button>
			</div>
		{/each}
	</div>
</div>

<!-- ── Engine group browser drawer ───────────────────────────────────────── -->
<EngineGroupBrowser open={browserOpen} onclose={() => { browserOpen = false; emitCmd(cmd.closeBrowser()); }} />

<style>
	.engine-selector {
		display: flex;
		flex-direction: column;
		gap: 0;
	}

	/* ── Category tabs ───────────────────────────────────────────────────────── */
	.category-bar {
		display: flex;
		flex-wrap: nowrap;
		gap: 2px;
		padding: var(--sp-2) var(--sp-3) 0;
		overflow-x: auto;
		scrollbar-width: none;
		/* Single row — never grow vertically */
		align-items: flex-end;
	}
	.category-bar::-webkit-scrollbar { display: none; }

	.cat-tab {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 5px 10px;
		border: 1px solid transparent;
		border-bottom: none;
		border-radius: var(--r-sm) var(--r-sm) 0 0;
		background: transparent;
		color: var(--c-text-3);
		font-family: var(--font-sans);
		font-size: 12px;
		font-weight: 500;
		cursor: pointer;
		white-space: nowrap;
		transition: color var(--t-fast), background var(--t-fast), border-color var(--t-fast);
	}

	.cat-tab:hover {
		color: var(--c-text);
		background: var(--c-surface-2);
		border-color: var(--c-border);
	}

	.cat-tab.is-active {
		color: var(--c-text);
		background: var(--c-surface-2);
		border-color: var(--c-border);
	}

	.cat-tab.is-partial {
		color: var(--c-text-2);
	}

	.cat-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		flex-shrink: 0;
	}

	.cat-label {
		font-weight: 500;
	}

	.cat-count {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		min-width: 18px;
		height: 16px;
		padding: 0 4px;
		background: var(--c-surface-3);
		border-radius: 10px;
		font-size: 10px;
		font-weight: 600;
		color: var(--c-text-2);
	}

	.cat-tab.is-active .cat-count {
		background: var(--c-accent-dim);
		color: var(--c-accent);
	}

	/* ── Selection toolbar ───────────────────────────────────────────────────── */
	.sel-toolbar {
		display: flex;
		align-items: center;
		gap: var(--sp-1);
		margin-left: auto;
		padding-left: var(--sp-3);
		flex-shrink: 0;
		/* Scroll horizontally if too many category buttons */
		overflow-x: auto;
		scrollbar-width: none;
		max-width: 60vw;
	}
	.sel-toolbar::-webkit-scrollbar { display: none; }

	.sel-count {
		display: inline-flex;
		align-items: baseline;
		gap: 1px;
		font-size: 11px;
		font-family: var(--font-mono);
		padding: 2px 6px;
		background: var(--c-surface-3);
		border-radius: var(--r-sm);
		user-select: none;
	}
	.sel-count__num  { font-weight: 700; color: var(--c-accent); }
	.sel-count__sep  { color: var(--c-text-3); }
	.sel-count__total { color: var(--c-text-3); }

	.sel-divider {
		width: 1px;
		height: 16px;
		background: var(--c-border);
		flex-shrink: 0;
		margin: 0 var(--sp-1);
	}

	.sel-btn {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 3px 8px;
		background: transparent;
		border: 1px solid var(--c-border);
		border-radius: var(--r-sm);
		color: var(--c-text-2);
		font-size: 11px;
		font-weight: 500;
		cursor: pointer;
		white-space: nowrap;
		transition: all var(--t-fast);
	}
	.sel-btn:hover:not(:disabled) {
		border-color: var(--c-border-2);
		color: var(--c-text);
		background: var(--c-surface-2);
	}
	.sel-btn--disabled,
	.sel-btn:disabled {
		opacity: 0.35;
		cursor: not-allowed;
	}

	/* Per-category quick-select pills */
	.sel-cat-btn {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 2px 7px;
		background: transparent;
		border: 1px solid var(--c-border);
		border-radius: 20px;
		color: var(--c-text-3);
		font-size: 11px;
		font-weight: 500;
		cursor: pointer;
		white-space: nowrap;
		transition: all var(--t-fast);
	}
	.sel-cat-btn:hover {
		border-color: var(--cat-color);
		color: var(--c-text);
		background: color-mix(in srgb, var(--cat-color) 8%, transparent);
	}
	.sel-cat-btn--active {
		border-color: var(--cat-color);
		color: var(--c-text);
		background: color-mix(in srgb, var(--cat-color) 12%, transparent);
	}
	.sel-cat-btn--partial {
		border-color: color-mix(in srgb, var(--cat-color) 50%, var(--c-border));
		color: var(--c-text-2);
	}
	.sel-cat-dot {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: var(--cat-color);
		flex-shrink: 0;
	}

	/* Browse button accent */
	.sel-btn--browse:hover:not(:disabled) {
		border-color: var(--c-accent);
		color: var(--c-accent);
		background: var(--c-accent-dim);
	}
	.sel-btn--active {
		border-color: var(--c-accent);
		color: var(--c-accent);
		background: var(--c-accent-dim);
	}

	/* ── Chips row ───────────────────────────────────────────────────────────── */
	.chips-row {
		display: flex;
		flex-wrap: nowrap;
		gap: var(--sp-1);
		padding: var(--sp-2) var(--sp-3);
		overflow-x: auto;
		align-items: center;
		border-top: 1px solid var(--c-border);
		background: var(--c-surface-2);
	}

	.chip-wrap {
		flex-shrink: 0;
		cursor: grab;
		border-radius: var(--r-sm);
		transition: transform var(--t-fast);
	}

	.chip-wrap:active { cursor: grabbing; }

	.chip-wrap.drag-over {
		outline: 2px dashed var(--c-accent);
		outline-offset: 2px;
	}

	.chip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 3px 10px 3px 7px;
		border: 1px solid var(--c-border);
		border-radius: 20px;
		background: var(--c-surface);
		color: var(--c-text-3);
		font-family: var(--font-sans);
		font-size: 12px;
		font-weight: 500;
		cursor: pointer;
		white-space: nowrap;
		transition: all var(--t-fast);
	}

	.chip:hover {
		border-color: var(--c-border-2);
		color: var(--c-text);
		background: var(--c-surface-2);
	}

	.chip--active {
		border-color: var(--cat-color);
		color: var(--c-text);
		background: color-mix(in srgb, var(--cat-color) 10%, var(--c-surface));
	}

	.chip--active .chip__dot {
		background: var(--cat-color);
	}

	.chip__dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--c-border-2);
		flex-shrink: 0;
		transition: background var(--t-fast);
	}

	.chip__name {
		font-weight: 500;
	}

	.chip__count {
		font-size: 10px;
		color: var(--c-text-3);
		background: var(--c-surface-3);
		padding: 0 4px;
		border-radius: 3px;
		font-weight: 600;
	}

	.chip--active .chip__count {
		color: var(--cat-color);
		background: color-mix(in srgb, var(--cat-color) 15%, transparent);
	}
</style>
