<script lang="ts">
	import { onMount } from 'svelte';
	import EngineSelector from '$lib/components/EngineSelector.svelte';
	import QueryComposer from '$lib/components/QueryComposer.svelte';
	import ResultsPanel from '$lib/components/ResultsPanel.svelte';
	import BudgetFooter from '$lib/components/BudgetFooter.svelte';
	import HelpPanel from '$lib/components/HelpPanel.svelte';
	import { loadFromLocalStorage } from '$lib/stores/engine-store';
	import { activeEngines } from '$lib/stores/engine-store';
	import { emitCmd } from '$lib/stores/cmd-log';
	import avatarSrc from '$lib/assets/avatar.gif';

	import OperatorsPanel from '$lib/components/OperatorsPanel.svelte';

	onMount(() => {
		loadFromLocalStorage();
	});

	let helpOpen = $state(false);
	let opsOpen  = $state(false);

	function openHelp() { helpOpen = true; emitCmd('man dorkstar'); }
	function openOps()  { opsOpen  = true; emitCmd('dork --list-operators'); }

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') { helpOpen = false; opsOpen = false; }
	}
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="app-layout">

	<!-- ── Left sidebar: avatar + nav ──────────────────────────────────────── -->
	<aside class="sidebar">
		<!-- Avatar — top-left, full sidebar width -->
		<div class="sidebar__avatar-wrap">
			<img src={avatarSrc} alt="DORKSTAR" class="sidebar__avatar" />
		</div>

		<!-- Nav items directly below avatar -->
		<nav class="sidebar__nav" aria-label="Main navigation">
			<a href="/" class="nav-item nav-item--active" aria-current="page">
				<span class="nav-item__bullet" aria-hidden="true">▶</span>
				<span class="nav-item__label">[SEARCH]</span>
			</a>
			<button class="nav-item nav-item--btn" onclick={openOps}>
				<span class="nav-item__bullet" aria-hidden="true">▷</span>
				<span class="nav-item__label">[OPERATORS]</span>
			</button>
			<button class="nav-item nav-item--btn" onclick={openHelp}>
				<span class="nav-item__bullet" aria-hidden="true">▷</span>
				<span class="nav-item__label">[HELP]</span>
			</button>
		</nav>

		<!-- Engine count status -->
		<div class="sidebar__status" aria-hidden="true">
			<span class="sidebar__status-label">ENGINES</span>
			<span class="sidebar__status-val">{$activeEngines.length}/39</span>
		</div>

		<div class="sidebar__brand" aria-hidden="true">
			<span class="sidebar__brand-name">DORKSTAR</span>
			<span class="sidebar__brand-ver">v1.0</span>
		</div>
	</aside>

	<!-- ── Main content ─────────────────────────────────────────────────────── -->
	<div class="main-content">

		<!-- Engine selector -->
		<div class="zone-engine-selector">
			<EngineSelector />
		</div>

		<!-- Query composer (toolbar + shell prompt) — directly above results -->
		<div class="zone-query-composer">
			<QueryComposer />
		</div>

		<!-- Results panel — fills remaining space -->
		<div class="zone-results-panel">
			<ResultsPanel />
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
		padding-bottom: 28px; /* budget footer height */
	}

	/* ── Sidebar ─────────────────────────────────────────────────────────────── */
	.sidebar {
		display: flex;
		flex-direction: column;
		width: 120px;
		flex-shrink: 0;
		background: var(--p-bg-2, #001400);
		border-right: 1px solid var(--p-border-2, #004d00);
		overflow: hidden;
		/* Sidebar must not grow beyond viewport */
		max-height: 100%;
	}

	/* Avatar — capped height so it doesn't dominate the sidebar */
	.sidebar__avatar-wrap {
		width: 100%;
		flex-shrink: 0;
		border-bottom: 1px solid var(--p-border, #003300);
		overflow: hidden;
		/* Cap at ~40% of viewport height so nav items are always visible */
		max-height: 40vh;
	}

	.sidebar__avatar {
		width: 100%;
		height: 100%;
		display: block;
		object-fit: cover;
		object-position: top center;
	}

	/* Nav items — stacked vertically below avatar */
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

	/* Engine count status */
	.sidebar__status {
		display: flex;
		flex-direction: column;
		align-items: center;
		padding: 4px var(--sp-2);
		border-bottom: 1px solid var(--p-border, #003300);
		flex-shrink: 0;
	}

	.sidebar__status-label {
		font-size: 9px;
		color: var(--p-dim, #1a4d1a);
		letter-spacing: 0.1em;
	}

	.sidebar__status-val {
		font-size: 13px;
		font-weight: 700;
		color: var(--p-bright, #66ff66);
		font-family: var(--font-mono);
		text-shadow: 0 0 4px var(--p-glow-strong);
	}

	/* Brand at bottom of sidebar */
	.sidebar__brand {
		margin-top: auto;
		padding: 4px var(--sp-2);
		border-top: 1px solid var(--p-border, #003300);
		display: flex;
		flex-direction: column;
		align-items: center;
		flex-shrink: 0;
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

	.zone-engine-selector {
		background: var(--p-bg-2, #001400);
		border-bottom: 1px solid var(--p-border-2, #004d00);
		flex-shrink: 0;
		/* Single-row chips — no vertical growth */
		overflow: hidden;
	}

	.zone-query-composer {
		background: var(--p-bg-2, #001400);
		border-bottom: 1px solid var(--p-border-2, #004d00);
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
