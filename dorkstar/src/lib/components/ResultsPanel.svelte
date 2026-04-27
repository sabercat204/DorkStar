<script lang="ts">
	import { resultSet, isLoading, viewMode, setViewMode, queryError } from '$lib/stores/results-store';
	import { canonicalQuery } from '$lib/stores/query-store';
	import { exportResults } from '$lib/results/exporter';
	import type { NormalizedResult, ViewMode } from '$lib/results/types';
	import type { EngineId } from '$lib/translation/types';
	import { emitCmd, cmd } from '$lib/stores/cmd-log';

	// ── Derived result views ──────────────────────────────────────────────────
	const unifiedResults = $derived($resultSet?.results ?? []);

	const byEngineMap = $derived((() => {
		if (!$resultSet) return new Map<EngineId, NormalizedResult[]>();
		const map = new Map<EngineId, NormalizedResult[]>();
		for (const r of $resultSet.results) {
			for (const a of r.engines) {
				const list = map.get(a.engineId) ?? [];
				list.push(r);
				map.set(a.engineId, list);
			}
		}
		return map;
	})());

	const deduplicatedResults = $derived(
		$resultSet
			? [...$resultSet.results].sort((a, b) => b.engines.length - a.engines.length || b.score - a.score)
			: []
	);

	const byEngineEngines = $derived([...byEngineMap.keys()]);
	let activeTab = $state<EngineId | null>(null);

	$effect(() => {
		if (byEngineEngines.length > 0 && (!activeTab || !byEngineEngines.includes(activeTab))) {
			activeTab = byEngineEngines[0] ?? null;
		}
	});

	// ── Save to file ──────────────────────────────────────────────────────────
	let showSavePanel = $state(false);
	let saveFormat = $state<'json' | 'csv' | 'txt'>('json');

	async function doExport(format: 'json' | 'csv' | 'pdf') {
		if (!$resultSet) return;
		emitCmd(cmd.exportResults(format, $resultSet.results.length));
		const blob = await exportResults($resultSet.results, format);
		triggerDownload(blob, `dorkstar-results.${format}`);
	}

	async function saveToFile() {
		if (!$resultSet) return;
		emitCmd(cmd.saveToFile(saveFormat));
		let blob: Blob;
		let name: string;

		if (saveFormat === 'txt') {
			const lines = $resultSet.results.map(r =>
				`${r.title || r.canonicalIdentifier}\n${r.canonicalIdentifier}\n${r.snippet ?? ''}`
			);
			blob = new Blob([lines.join('\n\n---\n\n')], { type: 'text/plain' });
			name = 'dorkstar-results.txt';
		} else {
			blob = await exportResults($resultSet.results, saveFormat);
			name = `dorkstar-results.${saveFormat}`;
		}

		const mimes: Record<string, string> = { json: 'application/json', csv: 'text/csv', txt: 'text/plain' };

		if ('showSaveFilePicker' in window) {
			try {
				const handle = await (window as Window & typeof globalThis & {
					showSaveFilePicker: (o: object) => Promise<FileSystemFileHandle>
				}).showSaveFilePicker({
					suggestedName: name,
					types: [{ description: `${saveFormat.toUpperCase()} file`, accept: { [mimes[saveFormat]]: [`.${saveFormat}`] } }],
				});
				const w = await handle.createWritable();
				await w.write(blob);
				await w.close();
				return;
			} catch (e) {
				if ((e as DOMException).name === 'AbortError') return;
			}
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

	// ── Per-result actions ────────────────────────────────────────────────────
	function openResult(url: string) { emitCmd(cmd.openResult(url)); window.open(url, '_blank', 'noopener,noreferrer'); }

	function redork(r: NormalizedResult) {
		emitCmd(cmd.redork(r.canonicalIdentifier));
		try { canonicalQuery.set(`site:${new URL(r.canonicalIdentifier).hostname}`); }
		catch { canonicalQuery.set(`"${r.canonicalIdentifier}"`); }
	}

	function pivot(r: NormalizedResult) { emitCmd(cmd.pivot(r.canonicalIdentifier)); canonicalQuery.set(r.canonicalIdentifier); }

	// ── Stats ─────────────────────────────────────────────────────────────────
	const stats = $derived($resultSet ? {
		total: $resultSet.deduplicationStats.totalUnique,
		raw: $resultSet.deduplicationStats.totalRaw,
		dupes: $resultSet.deduplicationStats.duplicatesRemoved,
		engines: Object.keys($resultSet.totalByEngine).length,
	} : null);
</script>

<div class="results-panel zone-results-panel">
	<!-- ── Content ──────────────────────────────────────────────────────────── -->
	<div class="results-content">
		{#if $isLoading}
			<div class="state-view" role="status" aria-live="polite">
				<div class="spinner" aria-hidden="true"></div>
				<p class="state-view__title">Running query…</p>
				<p class="state-view__sub">Dispatching to all active engines in parallel</p>
			</div>

		{:else if !$resultSet}
			<!-- ── Error output ───────────────────────────────────────────────── -->
			{#if $queryError}
				<div class="query-error-output" role="alert" aria-live="assertive">
					<div class="qe-header">
						<span class="qe-prompt" aria-hidden="true">root@dorkstar:~# </span>
						<span class="qe-title" class:qe-title--warn={$queryError.code === 'NO_KEYS'}>{$queryError.title}</span>
					</div>
					<div class="qe-body">
						<p class="qe-detail">{$queryError.detail}</p>
						<div class="qe-steps">
							<span class="qe-steps-label">RESOLUTION:</span>
							{#each $queryError.steps as step}
								<div class="qe-step">{step}</div>
							{/each}
						</div>
					</div>
				</div>
			{/if}

			<!-- ── D0RKSTAR ANSI splash ───────────────────────────────────────── -->
			<div class="ansi-splash" role="status" aria-label="DORKSTAR — ready">
				<pre class="ansi-art" aria-hidden="true">{`
 ██████╗  ██████╗ ██████╗ ██╗  ██╗███████╗████████╗ █████╗ ██████╗
 ██╔══██╗██╔═████╗██╔══██╗██║ ██╔╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗
 ██║  ██║██║██╔██║██████╔╝█████╔╝ ███████╗   ██║   ███████║██████╔╝
 ██║  ██║████╔╝██║██╔══██╗██╔═██╗ ╚════██║   ██║   ██╔══██║██╔══██╗
 ██████╔╝╚██████╔╝██║  ██║██║  ██╗███████║   ██║   ██║  ██║██║  ██║
 ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝`}</pre>
				<p class="ansi-hint">Select engines · write a query · press Enter</p>
			</div>

		{:else if $viewMode === 'unified'}
			<div class="result-list result-list--scroll-in" role="list">
				{#each unifiedResults as r (r.id)}
					<ResultCard result={r} on:open={() => openResult(r.canonicalIdentifier)} on:redork={() => redork(r)} on:pivot={() => pivot(r)} />
				{/each}
				{#if unifiedResults.length === 0}
					<div class="empty-list">
						<p class="empty-list__title">No results returned from active engines.</p>
						<p class="empty-list__reason">Most engines require API keys to return results.</p>
						<div class="empty-list__hints">
							<div class="empty-list__hint">
								<span class="hint-label">Tier 1/2 engines</span>
								<span class="hint-text">Require API keys — configure in Settings (coming soon) or use the KeyStore API</span>
							</div>
							<div class="empty-list__hint">
								<span class="hint-label">Tier 3 engines</span>
								<span class="hint-text">Qwant, Ecosia, Seznam, Sogou — dispatched via headless browser, may be blocked by anti-bot</span>
							</div>
							<div class="empty-list__hint">
								<span class="hint-label">Check dispatch errors</span>
								<span class="hint-text">Open browser DevTools → Network to see per-engine HTTP responses</span>
							</div>
						</div>
					</div>
				{/if}
			</div>

		{:else if $viewMode === 'by-engine'}
			<div class="by-engine">
				<div class="engine-tabs" role="tablist" aria-label="Engine tabs">
					{#each byEngineEngines as eid}
						<button
							role="tab"
							aria-selected={activeTab === eid}
							class="engine-tab"
							class:engine-tab--active={activeTab === eid}
							onclick={() => { activeTab = eid; }}
						>
							{eid}
							<span class="engine-tab__count">{byEngineMap.get(eid)?.length ?? 0}</span>
						</button>
					{/each}
				</div>
				<div class="engine-results" role="tabpanel">
					{#if activeTab}
						{#each (byEngineMap.get(activeTab) ?? []) as r (r.id)}
							<ResultCard result={r} on:open={() => openResult(r.canonicalIdentifier)} on:redork={() => redork(r)} on:pivot={() => pivot(r)} />
						{/each}
					{/if}
				</div>
			</div>

		{:else}
			<div class="result-list" role="list">
				{#each deduplicatedResults as r (r.id)}
					<ResultCard result={r} showMerged on:open={() => openResult(r.canonicalIdentifier)} on:redork={() => redork(r)} on:pivot={() => pivot(r)} />
				{/each}
				{#if deduplicatedResults.length === 0}
					<div class="empty-list">No results returned from active engines.</div>
				{/if}
			</div>
		{/if}
	</div>
</div>

<!-- ── Inline result card ────────────────────────────────────────────────── -->
{#snippet ResultCard({ result, showMerged = false, on: { open, redork, pivot } }: { result: NormalizedResult; showMerged?: boolean; on: { open: () => void; redork: () => void; pivot: () => void } })}
	<article class="result-card" role="listitem">
		<div class="result-card__header">
			<a
				href={result.canonicalIdentifier}
				class="result-card__title"
				target="_blank"
				rel="noopener noreferrer"
				title={result.canonicalIdentifier}
			>{result.title || result.canonicalIdentifier}</a>

			<div class="result-card__engines" aria-label="Found by">
				{#each result.engines as attr}
					<span
						class="engine-pill"
						class:engine-pill--merged={showMerged}
						title="{attr.engineId} · rank {attr.rank}"
					>{attr.engineId}</span>
				{/each}
			</div>
		</div>

		{#if result.snippet}
			<p class="result-card__snippet">{result.snippet}</p>
		{/if}

		<div class="result-card__url">{result.canonicalIdentifier}</div>

		<div class="result-card__actions">
			<button class="action-btn" onclick={open}>
				<svg width="11" height="11" viewBox="0 0 16 16" fill="none" aria-hidden="true">
					<path d="M7 3H3a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V9" stroke="currentColor" stroke-width="1.5"/>
					<path d="M10 2h4v4M14 2l-6 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
				</svg>
				Open
			</button>
			<button class="action-btn" onclick={redork}>Re-dork</button>
			<button class="action-btn" onclick={pivot}>Pivot</button>
			<span class="result-card__score" aria-label="Score {result.score.toFixed(2)}">{result.score.toFixed(2)}</span>
		</div>
	</article>
{/snippet}

<style>
	.results-panel {
		display: flex;
		flex-direction: column;
		background: var(--c-bg);
		overflow: hidden;
	}

	/* ── Toolbar ─────────────────────────────────────────────────────────────── */
	.results-toolbar {
		display: flex;
		align-items: center;
		gap: var(--sp-3);
		padding: var(--sp-2) var(--sp-3);
		background: var(--c-surface);
		border-bottom: 1px solid var(--c-border);
		flex-shrink: 0;
		flex-wrap: wrap;
	}

	/* ── View tabs ───────────────────────────────────────────────────────────── */
	.view-tabs { display: flex; gap: 2px; }

	.view-tab {
		padding: 4px 12px; border-radius: var(--r-sm);
		background: transparent; border: 1px solid transparent;
		color: var(--c-text-3); font-size: 12px; font-weight: 500;
		cursor: pointer; transition: all var(--t-fast);
	}
	.view-tab:hover { color: var(--c-text-2); background: var(--c-surface-2); }
	.view-tab--active { color: var(--c-text); background: var(--c-surface-2); border-color: var(--c-border); }

	/* ── Stats pill ──────────────────────────────────────────────────────────── */
	.stats-pill {
		display: inline-flex; align-items: center; gap: 4px;
		padding: 3px 10px; background: var(--c-surface-2);
		border: 1px solid var(--c-border); border-radius: 20px;
		font-size: 11px;
	}
	.stats-pill__num { font-weight: 700; color: var(--c-accent); }
	.stats-pill__label { color: var(--c-text-3); }
	.stats-pill__sep { color: var(--c-text-3); }
	.stats-pill__dedup { color: var(--c-text-3); font-size: 10px; }

	/* ── Export / Save ───────────────────────────────────────────────────────── */
	.export-group {
		display: flex; align-items: center; gap: var(--sp-1);
		margin-left: auto; flex-wrap: wrap;
	}

	.btn { display: inline-flex; align-items: center; gap: 4px; border-radius: var(--r-sm); font-family: var(--font-sans); font-weight: 500; cursor: pointer; transition: all var(--t-fast); white-space: nowrap; border: 1px solid transparent; }
	.btn--xs { padding: 3px 8px; font-size: 11px; }
	.btn--ghost { background: transparent; border-color: var(--c-border); color: var(--c-text-2); }
	.btn--ghost:hover:not(:disabled) { border-color: var(--c-border-2); color: var(--c-text); background: var(--c-surface-2); }
	.btn--ghost.btn--active { border-color: var(--c-accent); color: var(--c-accent); background: var(--c-accent-dim); }
	.btn--primary { background: var(--c-accent); color: var(--c-text-inv); border-color: var(--c-accent); font-weight: 600; }
	.btn--primary:hover:not(:disabled) { background: var(--c-accent-hover); }
	.btn:disabled { opacity: 0.35; cursor: not-allowed; }

	.save-wrap { position: relative; }

	.save-panel {
		position: absolute; top: calc(100% + 6px); right: 0;
		background: var(--c-surface-2); border: 1px solid var(--c-border-2);
		border-radius: var(--r-md); box-shadow: var(--shadow-md);
		padding: var(--sp-2) var(--sp-3);
		display: flex; align-items: center; gap: var(--sp-2);
		z-index: 100; white-space: nowrap;
	}

	.save-panel__label { font-size: 11px; color: var(--c-text-3); }

	.save-fmt-btn {
		padding: 2px 8px; background: var(--c-surface); border: 1px solid var(--c-border);
		border-radius: var(--r-sm); color: var(--c-text-2); font-family: var(--font-mono);
		font-size: 11px; cursor: pointer; transition: all var(--t-fast);
	}
	.save-fmt-btn:hover { border-color: var(--c-border-2); color: var(--c-text); }
	.save-fmt-btn--active { background: var(--c-accent-dim); border-color: var(--c-accent); color: var(--c-accent); }

	/* ── Content area ────────────────────────────────────────────────────────── */
	.results-content { flex: 1; overflow-y: auto; }

	/* ── ANSI splash screen ─────────────────────────────────────────────────── */
	.ansi-splash {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		height: 100%;
		padding: var(--sp-4);
		gap: var(--sp-3);
	}

	.ansi-art {
		font-family: var(--font-mono);
		/* Scale to fill available width */
		font-size: clamp(7px, 1.6vw, 14px);
		line-height: 1.2;
		color: var(--p-mid, #33cc33);
		text-shadow:
			0 0 4px var(--p-glow, rgba(51,204,51,0.15)),
			0 0 12px var(--p-glow-strong, rgba(102,255,102,0.25));
		white-space: pre;
		margin: 0;
		padding: 0;
		background: transparent;
		border: none;
		animation: ansi-glow 4s ease-in-out infinite alternate;
		user-select: none;
		/* Center the star glyph in a different colour */
	}

	/* Make the ★ character brighter */
	.ansi-art :global(*) { color: inherit; }

	@keyframes ansi-glow {
		0%   { text-shadow: 0 0 4px var(--p-glow), 0 0 12px var(--p-glow-strong); opacity: 0.85; }
		50%  { text-shadow: 0 0 8px var(--p-glow), 0 0 24px var(--p-glow-strong); opacity: 1; }
		100% { text-shadow: 0 0 4px var(--p-glow), 0 0 12px var(--p-glow-strong); opacity: 0.9; }
	}

	.ansi-hint {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--p-dim, #1a4d1a);
		letter-spacing: 0.1em;
		text-transform: uppercase;
		animation: cursor-blink 2s step-end infinite;
	}

	@keyframes cursor-blink {
		0%, 100% { opacity: 1; }
		50%       { opacity: 0.3; }
	}

	/* ── Query error output ──────────────────────────────────────────────────── */
	.query-error-output {
		margin: var(--sp-3) var(--sp-4);
		border: 1px solid var(--c-red, #ff4444);
		background: color-mix(in srgb, var(--c-red, #ff4444) 6%, var(--p-bg, #000a00));
		font-family: var(--font-mono);
		box-shadow: 0 0 8px rgba(255, 68, 68, 0.15);
	}

	.qe-header {
		display: flex;
		align-items: center;
		gap: var(--sp-2);
		padding: var(--sp-2) var(--sp-3);
		border-bottom: 1px solid color-mix(in srgb, var(--c-red, #ff4444) 40%, transparent);
		background: color-mix(in srgb, var(--c-red, #ff4444) 10%, var(--p-bg-2, #001400));
	}

	.qe-prompt {
		color: var(--p-dim, #1a4d1a);
		font-size: 12px;
		flex-shrink: 0;
	}

	.qe-title {
		font-size: 13px;
		font-weight: 700;
		color: var(--c-red, #ff4444);
		letter-spacing: 0.04em;
	}

	.qe-title--warn {
		color: var(--c-orange, #ccff33);
	}

	.qe-body {
		padding: var(--sp-3) var(--sp-4);
		display: flex;
		flex-direction: column;
		gap: var(--sp-3);
	}

	.qe-detail {
		font-size: 12px;
		color: var(--p-mid, #33cc33);
		line-height: 1.5;
	}

	.qe-steps {
		display: flex;
		flex-direction: column;
		gap: 3px;
		border-left: 2px solid color-mix(in srgb, var(--c-red, #ff4444) 40%, transparent);
		padding-left: var(--sp-3);
	}

	.qe-steps-label {
		font-size: 10px;
		font-weight: 700;
		color: var(--p-dim, #1a4d1a);
		letter-spacing: 0.1em;
		margin-bottom: 3px;
	}

	.qe-step {
		font-size: 12px;
		color: var(--p-mid, #33cc33);
		line-height: 1.5;
	}

	/* ── Scroll-in animation for results replacing the splash ────────────────── */
	/* Each result card slides up from below as it enters */
	.result-list--scroll-in .result-card {
		animation: result-slide-in 200ms linear both;
	}

	/* Stagger each card by its index — CSS can't do this natively so we use
	   a generous delay that covers the first ~20 results */
	.result-list--scroll-in .result-card:nth-child(1)  { animation-delay:   0ms; }
	.result-list--scroll-in .result-card:nth-child(2)  { animation-delay:  40ms; }
	.result-list--scroll-in .result-card:nth-child(3)  { animation-delay:  80ms; }
	.result-list--scroll-in .result-card:nth-child(4)  { animation-delay: 120ms; }
	.result-list--scroll-in .result-card:nth-child(5)  { animation-delay: 160ms; }
	.result-list--scroll-in .result-card:nth-child(6)  { animation-delay: 200ms; }
	.result-list--scroll-in .result-card:nth-child(7)  { animation-delay: 240ms; }
	.result-list--scroll-in .result-card:nth-child(8)  { animation-delay: 280ms; }
	.result-list--scroll-in .result-card:nth-child(9)  { animation-delay: 320ms; }
	.result-list--scroll-in .result-card:nth-child(10) { animation-delay: 360ms; }
	.result-list--scroll-in .result-card:nth-child(n+11) { animation-delay: 400ms; }

	@keyframes result-slide-in {
		from {
			opacity: 0;
			transform: translateY(12px);
			/* Simulate terminal line-print: start dim, brighten */
			filter: brightness(0.3);
		}
		to {
			opacity: 1;
			transform: translateY(0);
			filter: brightness(1);
		}
	}

	/* ── State views ─────────────────────────────────────────────────────────── */
	.state-view {
		display: flex; flex-direction: column; align-items: center; justify-content: center;
		height: 100%; gap: var(--sp-3); color: var(--c-text-3); padding: var(--sp-6);
	}
	.state-view__icon { color: var(--c-border-2); }
	.state-view__title { font-size: 15px; font-weight: 600; color: var(--c-text-2); }
	.state-view__sub { font-size: 13px; }

	.spinner {
		width: 32px; height: 32px;
		border: 2px solid var(--c-border); border-top-color: var(--c-accent);
		border-radius: 50%; animation: spin 0.7s linear infinite;
	}
	@keyframes spin { to { transform: rotate(360deg); } }

	/* ── Result list ─────────────────────────────────────────────────────────── */
	.result-list { padding: var(--sp-2) 0; }

	.empty-list { padding: var(--sp-4) var(--sp-6); color: var(--c-text-3); font-size: 13px; font-family: var(--font-mono); }

	.empty-list__title { color: var(--p-mid, #33cc33); font-size: 13px; margin-bottom: var(--sp-2); }
	.empty-list__reason { color: var(--p-dim, #1a4d1a); font-size: 11px; margin-bottom: var(--sp-4); }
	.empty-list__hints { display: flex; flex-direction: column; gap: var(--sp-2); border-left: 2px solid var(--p-border-2, #004d00); padding-left: var(--sp-3); }
	.empty-list__hint { display: flex; flex-direction: column; gap: 2px; }
	.hint-label { font-size: 11px; font-weight: 700; color: var(--p-mid, #33cc33); letter-spacing: 0.04em; }
	.hint-text { font-size: 11px; color: var(--p-dim, #1a4d1a); line-height: 1.5; }

	/* ── Result card ─────────────────────────────────────────────────────────── */
	.result-card {
		padding: var(--sp-3) var(--sp-4);
		border-bottom: 1px solid var(--c-border);
		transition: background var(--t-fast);
	}
	.result-card:hover { background: var(--c-surface); }

	.result-card__header {
		display: flex; align-items: flex-start; gap: var(--sp-3); flex-wrap: wrap;
	}

	.result-card__title {
		flex: 1; font-size: 13px; font-weight: 600; color: var(--c-blue);
		text-decoration: none; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
		min-width: 0;
	}
	.result-card__title:hover { text-decoration: underline; color: var(--c-accent); }

	.result-card__engines { display: flex; flex-wrap: wrap; gap: 3px; flex-shrink: 0; }

	.engine-pill {
		font-size: 10px; padding: 1px 6px;
		background: var(--c-surface-2); border: 1px solid var(--c-border);
		border-radius: 20px; color: var(--c-text-3); font-weight: 500;
	}
	.engine-pill--merged { border-color: var(--c-accent); color: var(--c-accent); background: var(--c-accent-dim); }

	.result-card__snippet {
		font-size: 12px; color: var(--c-text-2); margin: var(--sp-1) 0;
		line-height: 1.5; overflow: hidden;
		display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical;
	}

	.result-card__url {
		font-family: var(--font-mono); font-size: 11px; color: var(--c-green);
		overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
		margin-bottom: var(--sp-1);
	}

	.result-card__actions {
		display: flex; align-items: center; gap: var(--sp-2); margin-top: var(--sp-1);
	}

	.action-btn {
		display: inline-flex; align-items: center; gap: 4px;
		padding: 2px 8px; background: transparent;
		border: 1px solid var(--c-border); border-radius: var(--r-sm);
		color: var(--c-text-3); font-size: 11px; font-weight: 500;
		cursor: pointer; transition: all var(--t-fast);
	}
	.action-btn:hover { border-color: var(--c-border-2); color: var(--c-text); background: var(--c-surface-2); }

	.result-card__score {
		margin-left: auto; font-size: 10px; color: var(--c-text-3);
		font-family: var(--font-mono);
	}

	/* ── By-engine layout ────────────────────────────────────────────────────── */
	.by-engine { display: flex; flex-direction: column; height: 100%; }

	.engine-tabs {
		display: flex; flex-wrap: nowrap; overflow-x: auto; gap: 2px;
		padding: var(--sp-2) var(--sp-3); border-bottom: 1px solid var(--c-border);
		background: var(--c-surface); flex-shrink: 0; scrollbar-width: none;
	}
	.engine-tabs::-webkit-scrollbar { display: none; }

	.engine-tab {
		display: inline-flex; align-items: center; gap: 5px;
		padding: 3px 10px; background: transparent;
		border: 1px solid transparent; border-radius: var(--r-sm);
		color: var(--c-text-3); font-size: 11px; font-weight: 500;
		cursor: pointer; white-space: nowrap; transition: all var(--t-fast);
	}
	.engine-tab:hover { color: var(--c-text-2); background: var(--c-surface-2); }
	.engine-tab--active { color: var(--c-text); background: var(--c-surface-2); border-color: var(--c-border); }

	.engine-tab__count {
		display: inline-flex; align-items: center; justify-content: center;
		min-width: 18px; height: 16px; padding: 0 4px;
		background: var(--c-surface-3); border-radius: 10px;
		font-size: 10px; font-weight: 600; color: var(--c-text-3);
	}
	.engine-tab--active .engine-tab__count { background: var(--c-accent-dim); color: var(--c-accent); }

	.engine-results { flex: 1; overflow-y: auto; }
</style>
