<script lang="ts">
	import { onMount } from 'svelte';
	import EngineSelector from '$lib/components/EngineSelector.svelte';
	import QueryComposer from '$lib/components/QueryComposer.svelte';
	import ResultsPanel from '$lib/components/ResultsPanel.svelte';
	import BudgetFooter from '$lib/components/BudgetFooter.svelte';
	import HelpPanel from '$lib/components/HelpPanel.svelte';
	import FilterPanel from '$lib/components/FilterPanel.svelte';
	import OperatorsPanel from '$lib/components/OperatorsPanel.svelte';
	import { loadFromLocalStorage } from '$lib/stores/engine-store';
	import { activeEngines } from '$lib/stores/engine-store';
	import { emitCmd } from '$lib/stores/cmd-log';
	import { resultSet } from '$lib/stores/results-store';
	import { exportResults } from '$lib/results/exporter';

	// ── Export helpers ────────────────────────────────────────────────────────
	let saveFormat = $state<'json' | 'csv' | 'txt'>('json');

	async function doExport(format: 'json' | 'csv' | 'pdf') {
		if (!$resultSet) return;
		const blob = await exportResults($resultSet.results, format);
		triggerDownload(blob, `dorkstar-results.${format}`);
	}

	async function saveToFile() {
		if (!$resultSet) return;
		let blob: Blob;
		let name: string;
		if (saveFormat === 'txt') {
			const lines = $resultSet.results.map(r => `${r.title || r.canonicalIdentifier}\n${r.canonicalIdentifier}\n${r.snippet ?? ''}`);
			blob = new Blob([lines.join('\n\n---\n\n')], { type: 'text/plain' });
			name = 'dorkstar-results.txt';
		} else {
			blob = await exportResults($resultSet.results, saveFormat);
			name = `dorkstar-results.${saveFormat}`;
		}
		const mimes: Record<string, string> = { json: 'application/json', csv: 'text/csv', txt: 'text/plain' };
		if ('showSaveFilePicker' in window) {
			try {
				const handle = await (window as Window & typeof globalThis & { showSaveFilePicker: (o: object) => Promise<FileSystemFileHandle> }).showSaveFilePicker({
					suggestedName: name,
					types: [{ description: `${saveFormat.toUpperCase()} file`, accept: { [mimes[saveFormat]]: [`.${saveFormat}`] } }],
				});
				const w = await handle.createWritable();
				await w.write(blob);
				await w.close();
				return;
			} catch (e) { if ((e as DOMException).name === 'AbortError') return; }
		}
		triggerDownload(blob, name);
	}

	function triggerDownload(blob: Blob, filename: string) {
		const url = URL.createObjectURL(blob);
		const a = document.createElement('a');
		a.href = url; a.download = filename;
		document.body.appendChild(a); a.click();
		document.body.removeChild(a); URL.revokeObjectURL(url);
	}
	import avatarSrc from '$lib/assets/avatar.gif';

	onMount(() => {
		loadFromLocalStorage();
	});

	let helpOpen = $state(false);
	let opsOpen  = $state(false);
	let exportOpen = $state(false);

	function openHelp() { helpOpen = true; emitCmd('man dorkstar'); }
	function openOps()  { opsOpen  = true; emitCmd('dork --list-operators'); }
	function toggleExport() { exportOpen = !exportOpen; }

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') { helpOpen = false; opsOpen = false; }
	}
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="app-layout">

	<!-- ── Left sidebar: banner + avatar + nav + engine selector ───────────── -->
	<aside class="sidebar">
		<!-- Top: avatar only, full width -->
		<div class="sidebar__header">
			<div class="sidebar__avatar-wrap">
				<img src={avatarSrc} alt="DORKSTAR avatar" class="sidebar__avatar" />
			</div>
		</div>

		<!-- Nav items — HOME at top, OPERATORS + HELP at bottom -->
		<nav class="sidebar__nav" aria-label="Main navigation">
			<a href="/" class="nav-item nav-item--active" aria-current="page">
				<span class="nav-item__bullet" aria-hidden="true">▶</span>
				<span class="nav-item__label">[HOME]</span>
			</a>
		</nav>

		<!-- Filter panel: filetype / domain / multi-item -->
		<div class="sidebar__filters">
			<FilterPanel />
		</div>

		<!-- Engine selector — scrollable menu in sidebar -->
		<div class="sidebar__engines">
			<EngineSelector />
		</div>

		<!-- Engine count + brand + bottom nav pinned to bottom -->
		<div class="sidebar__footer">
			<div class="sidebar__status" aria-hidden="true">
				<span class="sidebar__status-label">ENGINES</span>
				<span class="sidebar__status-val">{$activeEngines.length}/39</span>
			</div>
			<div class="sidebar__brand" aria-hidden="true">
				<span class="sidebar__brand-name">DORKSTAR</span>
				<span class="sidebar__brand-ver">v1.0</span>
			</div>
			<!-- Bottom nav: OPERATORS + HELP + EXPORT -->
			<nav class="sidebar__bottom-nav" aria-label="Secondary navigation">
				<button class="nav-item nav-item--btn" onclick={openOps}>
					<span class="nav-item__bullet" aria-hidden="true">▷</span>
					<span class="nav-item__label">[OPERATORS]</span>
				</button>
				<button class="nav-item nav-item--btn" onclick={openHelp}>
					<span class="nav-item__bullet" aria-hidden="true">▷</span>
					<span class="nav-item__label">[HELP]</span>
				</button>
				<button class="nav-item nav-item--btn" onclick={toggleExport}>
					<span class="nav-item__bullet" aria-hidden="true">▷</span>
					<span class="nav-item__label">[EXPORT]</span>
				</button>
			</nav>

			<!-- Export panel (inline, above bottom nav) -->
			{#if exportOpen}
				<div class="sidebar__export-panel" role="group" aria-label="Export results">
					<div class="export-row">
						<button class="export-fmt-btn" onclick={() => doExport('json')} disabled={!$resultSet}>JSON</button>
						<button class="export-fmt-btn" onclick={() => doExport('csv')}  disabled={!$resultSet}>CSV</button>
						<button class="export-fmt-btn" onclick={() => doExport('pdf')}  disabled={!$resultSet}>PDF</button>
					</div>
					<div class="export-row">
						{#each (['json','csv','txt'] as const) as fmt}
							<button
								class="export-fmt-btn"
								class:export-fmt-btn--active={saveFormat === fmt}
								onclick={() => { saveFormat = fmt; }}
							>.{fmt}</button>
						{/each}
						<button class="export-save-btn" onclick={saveToFile} disabled={!$resultSet}>💾 Save</button>
					</div>
				</div>
			{/if}
		</div>
	</aside>

	<!-- ── Main content: results + query at bottom ──────────────────────────── -->
	<div class="main-content">

		<!-- Results panel — fills remaining space -->
		<div class="zone-results-panel">
			<ResultsPanel />
		</div>

		<!-- Query composer (shell prompt) — pinned to bottom -->
		<div class="zone-query-composer">
			<QueryComposer />
		</div>

	</div>
</div>

<!-- Status bar -->
<BudgetFooter />

<!-- Help panel -->
<HelpPanel open={helpOpen} onclose={() => { helpOpen = false; }} />

<!-- Operators panel -->
<OperatorsPanel open={opsOpen} onclose={() => { opsOpen = false; }} />

<style>
	/* ── App layout: sidebar + main ──────────────────────────────────────────── */
	.app-layout {
		display: flex;
		height: 100vh;
		overflow: hidden;
		padding-bottom: 28px;
	}

	/* ── Sidebar ─────────────────────────────────────────────────────────────── */
	.sidebar {
		display: flex;
		flex-direction: column;
		width: 160px;
		flex-shrink: 0;
		background: var(--p-bg-2, #001400);
		border-right: 1px solid var(--p-border-2, #004d00);
		overflow: hidden;
		max-height: 100%;
	}

	/* Top header: avatar full width */
	.sidebar__header {
		display: flex;
		width: 100%;
		flex-shrink: 0;
		border-bottom: 1px solid var(--p-border, #003300);
		overflow: hidden;
	}

	/* Avatar — full width, full natural height */
	.sidebar__avatar-wrap {
		width: 100%;
		overflow: hidden;
	}

	.sidebar__avatar {
		width: 100%;
		height: auto;
		display: block;
		object-fit: contain;
	}

	/* Nav items */
	.sidebar__nav {
		display: flex;
		flex-direction: column;
		padding: var(--sp-1) 0;
		border-bottom: 1px solid var(--p-border, #003300);
		flex-shrink: 0;
	}

	.nav-item {
		display: flex;
		align-items: center;
		gap: var(--sp-1);
		padding: 5px var(--sp-2);
		color: var(--p-mid, #33cc33);
		text-decoration: none;
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.06em;
		transition: color var(--t-fast), background var(--t-fast);
		white-space: nowrap;
	}

	.nav-item:hover {
		color: var(--p-bright, #66ff66);
		background: var(--p-bg-3, #001e00);
		text-shadow: 0 0 6px var(--p-glow-strong);
	}

	.nav-item--active {
		color: var(--p-bright, #66ff66);
		text-shadow: 0 0 4px var(--p-glow-strong);
	}

	.nav-item--btn {
		background: none;
		border: none;
		text-align: left;
		cursor: pointer;
		width: 100%;
	}

	.nav-item__bullet {
		font-size: 9px;
		flex-shrink: 0;
		color: var(--p-dim, #1a4d1a);
	}

	.nav-item--active .nav-item__bullet {
		color: var(--p-bright, #66ff66);
	}

	.nav-item__label {
		font-size: 11px;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	/* Filter panel — below nav, above engine selector */
	.sidebar__filters {
		flex-shrink: 0;
		border-bottom: 1px solid var(--p-border, #003300);
		overflow: hidden;
	}

	/* Engine selector — scrollable, fills remaining sidebar space */
	.sidebar__engines {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		overflow-x: hidden;
		border-bottom: 1px solid var(--p-border, #003300);
		scrollbar-width: thin;
		scrollbar-color: var(--p-border-2) transparent;
	}

	.sidebar__engines::-webkit-scrollbar { width: 3px; }
	.sidebar__engines::-webkit-scrollbar-thumb { background: var(--p-border-2); }

	/* Footer: engine count + brand + bottom nav */
	.sidebar__footer {
		flex-shrink: 0;
		border-top: 1px solid var(--p-border, #003300);
	}

	.sidebar__bottom-nav {
		display: flex;
		flex-direction: column;
		border-top: 1px solid var(--p-border, #003300);
	}

	/* Inline export panel */
	.sidebar__export-panel {
		border-top: 1px solid var(--p-border, #003300);
		padding: var(--sp-2);
		background: var(--p-bg-3, #001e00);
		display: flex;
		flex-direction: column;
		gap: var(--sp-1);
	}

	.export-row {
		display: flex;
		gap: 3px;
		flex-wrap: wrap;
	}

	.export-fmt-btn {
		flex: 1;
		background: transparent;
		border: 1px solid var(--p-border, #003300);
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		font-size: 10px;
		padding: 3px 4px;
		cursor: pointer;
		transition: all var(--t-fast);
		text-align: center;
	}

	.export-fmt-btn:hover:not(:disabled) {
		border-color: var(--p-border-2, #004d00);
		color: var(--p-mid, #33cc33);
	}

	.export-fmt-btn:disabled { opacity: 0.3; cursor: not-allowed; }

	.export-fmt-btn--active {
		background: rgba(51, 204, 51, 0.1);
		border-color: rgba(51, 204, 51, 0.4);
		color: var(--p-mid, #33cc33);
	}

	.export-save-btn {
		flex: 2;
		background: rgba(51, 204, 51, 0.1);
		border: 1px solid rgba(51, 204, 51, 0.4);
		color: var(--p-mid, #33cc33);
		font-family: var(--font-mono);
		font-size: 10px;
		padding: 3px 6px;
		cursor: pointer;
		transition: all var(--t-fast);
	}

	.export-save-btn:hover:not(:disabled) {
		background: rgba(51, 204, 51, 0.18);
		border-color: var(--p-mid, #33cc33);
	}

	.export-save-btn:disabled { opacity: 0.3; cursor: not-allowed; }

	.sidebar__status {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 3px var(--sp-2);
		border-bottom: 1px solid var(--p-border, #003300);
	}

	.sidebar__status-label {
		font-size: 9px;
		color: var(--p-dim, #1a4d1a);
		letter-spacing: 0.1em;
	}

	.sidebar__status-val {
		font-size: 12px;
		font-weight: 700;
		color: var(--p-bright, #66ff66);
		font-family: var(--font-mono);
		text-shadow: 0 0 4px var(--p-glow-strong);
	}

	.sidebar__brand {
		padding: 3px var(--sp-2);
		display: flex;
		justify-content: space-between;
		align-items: center;
	}

	.sidebar__brand-name {
		font-size: 10px;
		font-weight: 700;
		color: var(--p-mid, #33cc33);
		letter-spacing: 0.12em;
		font-family: var(--font-mono);
	}

	.sidebar__brand-ver {
		font-size: 9px;
		color: var(--p-dim, #1a4d1a);
		letter-spacing: 0.06em;
	}

	/* ── Main content ────────────────────────────────────────────────────────── */
	.main-content {
		flex: 1;
		display: flex;
		flex-direction: column;
		overflow: hidden;
		min-width: 0;
		min-height: 0;
	}

	.zone-query-composer {
		background: var(--p-bg-2, #001400);
		border-top: 1px solid var(--p-border-2, #004d00);
		flex-shrink: 0;
		overflow: hidden;
	}

	.zone-results-panel {
		flex: 1;
		min-height: 0;
		overflow: hidden;
		background: var(--p-bg, #000a00);
	}
</style>
