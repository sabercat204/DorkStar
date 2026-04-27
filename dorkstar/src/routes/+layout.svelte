<script lang="ts">
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<meta name="viewport" content="width=device-width, initial-scale=1" />
</svelte:head>

<div class="app-shell">
	<!-- CRT scanline overlay -->
	<div class="crt-overlay" aria-hidden="true"></div>
	{@render children()}
</div>

<style>
	/* ════════════════════════════════════════════════════════════════════════
	   DEC VT100 DESIGN TOKENS
	   Phosphor P31 green-on-black CRT terminal aesthetic
	   ════════════════════════════════════════════════════════════════════════ */
	:global(:root) {
		/* ── Phosphor palette ─────────────────────────────────────────────── */
		/* P31 phosphor: peak emission ~525nm, warm green-white */
		--p-bg:          #000a00;          /* deep CRT black with green tint */
		--p-bg-2:        #001400;          /* slightly lighter surface */
		--p-bg-3:        #001e00;          /* raised surface */
		--p-border:      #003300;          /* dim border — etched into phosphor */
		--p-border-2:    #004d00;          /* brighter border */

		--p-dim:         #1a4d1a;          /* dim phosphor — inactive text */
		--p-mid:         #33cc33;          /* mid-brightness phosphor */
		--p-bright:      #66ff66;          /* full-brightness phosphor */
		--p-white:       #ccffcc;          /* near-white phosphor bloom */
		--p-glow:        rgba(51,204,51,0.15); /* phosphor glow ambient */
		--p-glow-strong: rgba(102,255,102,0.25);

		/* Semantic aliases that all components use */
		--c-bg:          var(--p-bg);
		--c-surface:     var(--p-bg-2);
		--c-surface-2:   var(--p-bg-3);
		--c-surface-3:   #002800;
		--c-border:      var(--p-border);
		--c-border-2:    var(--p-border-2);

		--c-text:        var(--p-bright);
		--c-text-2:      var(--p-mid);
		--c-text-3:      var(--p-dim);
		--c-text-inv:    var(--p-bg);

		--c-accent:      var(--p-bright);
		--c-accent-dim:  var(--p-glow);
		--c-accent-hover:var(--p-white);

		/* Semantic colours — all mapped to phosphor variants */
		--c-green:       var(--p-bright);
		--c-red:         #ff4444;          /* error red — rare, high contrast */
		--c-blue:        #33cccc;          /* cyan-shifted for terminal feel */
		--c-purple:      #99cc99;          /* desaturated — phosphor can't do purple */
		--c-cyan:        #33ffcc;
		--c-orange:      #ccff33;          /* amber-green for warnings */

		/* Category colours — all phosphor-shifted */
		--c-web:         #33ccff;
		--c-iot:         var(--p-bright);
		--c-code:        #99ff99;
		--c-threat:      #ff6666;
		--c-paste:       var(--p-mid);
		--c-social:      #33ffcc;
		--c-academic:    #ccff66;

		/* ── Typography ───────────────────────────────────────────────────── */
		/* Standard system monospace — reliable rendering across all platforms */
		--font-sans:  'Courier New', Courier, monospace;
		--font-mono:  'Courier New', Courier, monospace;

		/* ── Spacing ──────────────────────────────────────────────────────── */
		--sp-1: 4px;
		--sp-2: 8px;
		--sp-3: 12px;
		--sp-4: 16px;
		--sp-5: 20px;
		--sp-6: 24px;

		/* ── Radii — terminals have no rounded corners ────────────────────── */
		--r-sm: 0px;
		--r-md: 0px;
		--r-lg: 0px;

		/* ── Shadows — phosphor glow instead of drop shadows ─────────────── */
		--shadow-sm: 0 0 4px var(--p-glow);
		--shadow-md: 0 0 12px var(--p-glow-strong);

		/* ── Transitions ──────────────────────────────────────────────────── */
		--t-fast: 80ms linear;
		--t-base: 150ms linear;

		/* ── CRT effects ──────────────────────────────────────────────────── */
		--crt-scanline-opacity: 0.08;
		--crt-flicker-opacity:  0.015;
		--crt-glow-radius:      2px;
	}

	/* ── Reset ──────────────────────────────────────────────────────────────── */
	:global(*, *::before, *::after) {
		box-sizing: border-box;
		margin: 0;
		padding: 0;
	}

	:global(html) {
		height: 100%;
		font-size: 16px;
		-webkit-font-smoothing: antialiased;
		-moz-osx-font-smoothing: grayscale;
	}

	:global(body) {
		height: 100%;
		background: var(--c-bg);
		color: var(--c-text);
		font-family: var(--font-mono);
		overflow: hidden;
		text-shadow: 0 0 var(--crt-glow-radius) var(--p-glow-strong);
		line-height: 1.2;
		/* IBM EGA bitmap font: zero letter-spacing everywhere */
		letter-spacing: 0;
	}

	/* Force zero letter-spacing on all elements — bitmap fonts break with any spacing */
	:global(*) {
		letter-spacing: 0 !important;
	}

	/* ── Phosphor text glow ─────────────────────────────────────────────────── */
	:global(a, button, input, textarea, select, code, pre) {
		font-family: var(--font-mono);
		text-shadow: 0 0 var(--crt-glow-radius) var(--p-glow-strong);
	}

	/* ── Focus ring — terminal cursor style ─────────────────────────────────── */
	:global(:focus-visible) {
		outline: 1px solid var(--p-bright);
		outline-offset: 0;
		box-shadow: 0 0 6px var(--p-glow-strong);
	}

	/* ── Scrollbars — minimal, phosphor-tinted ──────────────────────────────── */
	:global(::-webkit-scrollbar)       { width: 4px; height: 4px; }
	:global(::-webkit-scrollbar-track) { background: var(--p-bg); }
	:global(::-webkit-scrollbar-thumb) { background: var(--p-border-2); }
	:global(::-webkit-scrollbar-thumb:hover) { background: var(--p-mid); }
	:global(*) { scrollbar-width: thin; scrollbar-color: var(--p-border-2) var(--p-bg); }

	/* ── Selection ──────────────────────────────────────────────────────────── */
	:global(::selection) {
		background: var(--p-mid);
		color: var(--p-bg);
	}

	/* ── App shell ──────────────────────────────────────────────────────────── */
	.app-shell {
		height: 100vh;
		overflow: hidden;
		position: relative;
		background:
			radial-gradient(ellipse at center, transparent 60%, rgba(0,0,0,0.7) 100%),
			var(--p-bg);
	}

	/* Zone grid areas — now managed by +page.svelte directly */
	:global(.zone-engine-selector) { overflow: hidden; flex-shrink: 0; }
	:global(.zone-query-composer)  { overflow: hidden; flex-shrink: 0; }
	:global(.zone-results-panel)   { overflow: hidden; flex: 1; min-height: 0; }

	:global(.budget-footer) {
		position: fixed;
		bottom: 0; left: 0; right: 0;
		z-index: 200;
	}

	/* ── CRT scanline overlay ───────────────────────────────────────────────── */
	.crt-overlay {
		position: fixed;
		inset: 0;
		z-index: 9999;
		pointer-events: none;
		/* Stronger horizontal scanlines — every 2px row */
		background:
			repeating-linear-gradient(
				0deg,
				transparent,
				transparent 1px,
				rgba(0, 0, 0, 0.18) 1px,
				rgba(0, 0, 0, 0.18) 2px
			),
			/* Vertical pixel grid — EGA 8px column separation */
			repeating-linear-gradient(
				90deg,
				transparent,
				transparent 7px,
				rgba(0, 0, 0, 0.04) 7px,
				rgba(0, 0, 0, 0.04) 8px
			);
		/* Subtle flicker */
		animation: crt-flicker 8s infinite;
	}

	@keyframes crt-flicker {
		0%,  19%,  21%,  23%,  25%,  54%,  56%,  100% {
			opacity: 1;
		}
		20%,  24%,  55% {
			opacity: calc(1 - var(--crt-flicker-opacity));
		}
	}

	/* ── Global VT100 border style ──────────────────────────────────────────── */
	/* All borders use single-line box-drawing weight */
	:global(*) {
		border-color: var(--c-border);
	}

	/* ── Inputs — terminal style ────────────────────────────────────────────── */
	:global(input, textarea) {
		background: var(--p-bg);
		color: var(--p-bright);
		border: 1px solid var(--p-border-2);
		caret-color: var(--p-bright);
	}

	:global(input:focus, textarea:focus) {
		border-color: var(--p-bright);
		box-shadow: 0 0 6px var(--p-glow-strong);
		outline: none;
	}

	/* ── Buttons — terminal key style ───────────────────────────────────────── */
	:global(button) {
		cursor: pointer;
		font-family: var(--font-mono);
	}

	/* ── Links ──────────────────────────────────────────────────────────────── */
	:global(a) {
		color: var(--p-bright);
		text-decoration: none;
	}
	:global(a:hover) {
		color: var(--p-white);
		text-shadow: 0 0 8px var(--p-glow-strong);
	}

	/* ── Code ───────────────────────────────────────────────────────────────── */
	:global(code) {
		font-family: var(--font-mono);
		color: var(--p-bright);
		background: var(--p-bg-2);
		padding: 0 3px;
	}
</style>
