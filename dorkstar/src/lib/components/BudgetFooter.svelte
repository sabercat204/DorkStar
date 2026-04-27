<script lang="ts">
	import { workerStatus } from '$lib/stores/results-store';

	const entries = $derived(Object.entries($workerStatus.perEngineStatus));
	const rateLimited = $derived(entries.filter(([, s]) => s.isRateLimited));
	const hasActivity = $derived(entries.length > 0);
</script>

<footer class="budget-footer" aria-label="Engine quota status">
	{#if !hasActivity}
		<span class="footer-brand" aria-hidden="true">█ DORKSTAR</span>
		<span class="footer-sep" aria-hidden="true">│</span>
		<span class="footer-idle">READY. SELECT ENGINES AND ENTER QUERY.</span>
		<span class="footer-clock" aria-hidden="true">{new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'})}</span>
	{:else}
		<span class="footer-brand" aria-hidden="true">█</span>
		<span class="footer-sep" aria-hidden="true">│</span>
		<div class="quota-list" role="list" aria-label="Per-engine quota">
			{#each entries as [engineId, status]}
				<div
					class="quota-item"
					class:quota-item--limited={status.isRateLimited}
					role="listitem"
					title="{engineId}: {status.quotaUsed}/{status.quotaLimit}"
				>
					<span class="quota-item__engine">{engineId.toUpperCase()}</span>
					<span class="quota-item__bar" aria-hidden="true">
						{#each {length: 10} as _, i}
							<span class="quota-bar-cell" class:quota-bar-cell--fill={i < Math.round((status.quotaUsed / status.quotaLimit) * 10)} class:quota-bar-cell--warn={status.quotaUsed / status.quotaLimit > 0.8}></span>
						{/each}
					</span>
					<span class="quota-item__nums">{status.quotaUsed}/{status.quotaLimit}</span>
					{#if status.isRateLimited && status.resetAt}
						<span class="quota-item__reset">
							[LIMIT {new Date(status.resetAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}]
						</span>
					{/if}
				</div>
			{/each}
		</div>

		{#if rateLimited.length > 0}
			<span class="rate-limited-summary" role="status" aria-live="polite">
				⚠ {rateLimited.length} RATE-LIMITED
			</span>
		{/if}
	{/if}
</footer>

<style>
	.budget-footer {
		position: fixed;
		bottom: 0; left: 0; right: 0;
		height: 28px;
		background: var(--p-bg-2, #001400);
		border-top: 1px solid var(--p-border-2, #004d00);
		z-index: 200;
		display: flex;
		align-items: center;
		gap: var(--sp-2);
		padding: 0 var(--sp-3);
		overflow: hidden;
		font-size: 11px;
		letter-spacing: 0.06em;
	}

	.footer-brand {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 700;
		color: var(--p-bright, #66ff66);
		text-shadow: 0 0 6px var(--p-glow-strong);
		flex-shrink: 0;
		animation: cursor-blink 1.2s step-end infinite;
	}

	@keyframes cursor-blink {
		0%, 100% { opacity: 1; }
		50%       { opacity: 0; }
	}

	.footer-sep {
		color: var(--p-border-2, #004d00);
		flex-shrink: 0;
	}

	.footer-idle {
		font-size: 11px;
		color: var(--p-mid, #33cc33);
		letter-spacing: 0.08em;
	}

	.footer-clock {
		margin-left: auto;
		font-size: 11px;
		color: var(--p-dim, #1a4d1a);
		font-family: var(--font-mono);
		letter-spacing: 0.05em;
	}

	/* ── Quota list ──────────────────────────────────────────────────────────── */
	.quota-list {
		display: flex;
		align-items: center;
		gap: var(--sp-3);
		overflow-x: auto;
		flex: 1;
		scrollbar-width: none;
	}
	.quota-list::-webkit-scrollbar { display: none; }

	.quota-item {
		display: flex;
		align-items: center;
		gap: 5px;
		flex-shrink: 0;
	}

	.quota-item--limited .quota-item__engine {
		color: var(--c-orange, #ccff33);
	}

	.quota-item__engine {
		font-size: 10px;
		font-weight: 700;
		color: var(--p-dim, #1a4d1a);
		letter-spacing: 0.06em;
		min-width: 64px;
	}

	/* ASCII-style block bar */
	.quota-item__bar {
		display: flex;
		gap: 1px;
	}

	.quota-bar-cell {
		display: inline-block;
		width: 4px;
		height: 8px;
		background: var(--p-border, #003300);
	}

	.quota-bar-cell--fill {
		background: var(--p-mid, #33cc33);
		box-shadow: 0 0 3px var(--p-glow);
	}

	.quota-bar-cell--warn {
		background: var(--c-orange, #ccff33);
		box-shadow: 0 0 3px rgba(204,255,51,0.3);
	}

	.quota-item__nums {
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--p-dim, #1a4d1a);
	}

	.quota-item__reset {
		font-size: 10px;
		color: var(--c-orange, #ccff33);
		letter-spacing: 0.04em;
	}

	/* ── Rate limited summary ────────────────────────────────────────────────── */
	.rate-limited-summary {
		font-size: 11px;
		color: var(--c-orange, #ccff33);
		flex-shrink: 0;
		margin-left: auto;
		letter-spacing: 0.06em;
	}
</style>
