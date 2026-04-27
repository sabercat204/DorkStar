<script lang="ts">
	import { canonicalQuery, mode, perEngineQueries, parseErrors, translations } from '$lib/stores/query-store';
	import { activeEngines } from '$lib/stores/engine-store';
	import { executeQuery } from '$lib/stores/results-store';
	import { TranslationManager } from '$lib/translation/manager';
	import { adapterRegistry } from '$lib/translation/adapters/registry';
	import { parseQuery } from '$lib/parser/index';
	import type { EngineId } from '$lib/translation/types';
	import { emitCmd, cmd, lastCmd } from '$lib/stores/cmd-log';

	const tm = new TranslationManager(adapterRegistry);

	// ── Autocomplete ──────────────────────────────────────────────────────────
	let showAC = $state(false);
	let acOptions = $state<string[]>([]);
	let acIndex = $state(0);
	let textareaEl = $state<HTMLTextAreaElement | null>(null);

	// ── Degradation popover ───────────────────────────────────────────────────
	let openDegEngine = $state<string | null>(null);

	// ── Active panel: only one sub-panel open at a time ───────────────────────
	type Panel = 'filetype' | 'domain' | 'multi' | null;
	let activePanel = $state<Panel>(null);
	function togglePanel(p: Panel) { activePanel = activePanel === p ? null : p; }

	// ── File type selector ────────────────────────────────────────────────────
	const FT_GROUPS: { label: string; types: string[] }[] = [
		{ label: 'Documents', types: ['pdf','doc','docx','xls','xlsx','ppt','pptx','odt','ods','odp','rtf','txt','wps','wpd','pages','numbers','key','epub','mobi','azw','djvu','xps','oxps'] },
		{ label: 'Images', types: ['jpg','jpeg','png','gif','bmp','tiff','tif','webp','svg','ico','heic','heif','raw','cr2','nef','arw','dng','psd','ai','eps','cdr','xcf','sketch'] },
		{ label: 'Video', types: ['mp4','mkv','avi','mov','wmv','flv','webm','m4v','mpg','mpeg','3gp','ogv','ts','mts','m2ts','vob','divx','xvid','rm','rmvb'] },
		{ label: 'Audio', types: ['mp3','wav','flac','aac','ogg','wma','m4a','opus','aiff','aif','mid','midi','ape','mka','ra','rm'] },
		{ label: 'Archives', types: ['zip','rar','7z','tar','gz','bz2','xz','tgz','tbz2','cab','iso','img','dmg','pkg','deb','rpm','apk','ipa','jar','war','ear'] },
		{ label: 'Source Code', types: ['js','ts','jsx','tsx','py','rb','go','java','c','cpp','h','hpp','cs','php','swift','kt','rs','scala','lua','pl','r','m','sh','bash','zsh','ps1','bat','cmd','asm','s','vb','vbs','coffee','elm','ex','exs','erl','hs','ml','clj','lisp','f','f90','f95'] },
		{ label: 'Web', types: ['html','htm','css','scss','sass','less','xml','json','yaml','yml','toml','graphql','gql','wasm','htaccess','htpasswd','webmanifest'] },
		{ label: 'Data', types: ['csv','tsv','sql','db','sqlite','sqlite3','mdb','accdb','dbf','parquet','avro','orc','hdf5','h5','mat','sav','dta','rdata','rds','feather','arrow'] },
		{ label: 'Config', types: ['conf','cfg','ini','env','properties','plist','reg','inf','sys','service','socket','timer','desktop','rc','profile','bashrc','zshrc','vimrc','gitconfig','npmrc','yarnrc','editorconfig','prettierrc','eslintrc','babelrc','dockerignore','gitignore'] },
		{ label: 'Secrets', types: ['pem','key','crt','cer','p12','pfx','jks','keystore','pub','ppk','asc','gpg','pgp','ovpn','p8','der','csr'] },
		{ label: 'Executables', types: ['exe','dll','so','dylib','bin','elf','com','scr','msi','msix','appx','xpi','crx','vsix','snap','flatpak'] },
		{ label: 'Disk Images', types: ['iso','img','vmdk','vhd','vhdx','qcow2','ova','ovf','vdi','hdd','toast','nrg','mdf','bin','cue'] },
		{ label: 'Database', types: ['sql','dump','bak','mdf','ldf','frm','ibd','myd','myi','dbf','accdb','mdb','sqlite','db3','s3db','sl3'] },
		{ label: 'CAD/3D', types: ['dwg','dxf','stl','obj','fbx','3ds','blend','max','maya','mb','ma','step','stp','iges','igs','sat','x_t','x_b','sldprt','sldasm','slddrw','ipt','iam','idw','catpart','catproduct'] },
		{ label: 'System', types: ['log','tmp','temp','swp','lock','pid','sock','fifo','core','dmp','crash','etl','evt','evtx','cab','inf','cat','manifest','mui','mun'] },
		{ label: 'Fonts', types: ['ttf','otf','woff','woff2','eot','fon','fnt','pfb','pfm','afm'] },
		{ label: 'Ebooks', types: ['epub','mobi','azw','azw3','lit','lrf','pdb','fb2','djvu','cbz','cbr','cb7'] },
		{ label: 'Misc', types: ['torrent','nfo','sfv','md5','sha1','sha256','crc','par2','nzb','magnet'] },
	];

	const SUGGESTED_PRESETS: { label: string; icon: string; types: string[] }[] = [
		{ label: 'Music',       icon: '♪', types: ['mp3','flac','wav','aac','ogg','m4a','wma','opus','aiff'] },
		{ label: 'Movies',      icon: '▶', types: ['mp4','mkv','avi','mov','wmv','m4v','mpg','mpeg','webm'] },
		{ label: 'Documents',   icon: '📄', types: ['pdf','doc','docx','xls','xlsx','ppt','pptx','txt','rtf','odt'] },
		{ label: 'Images',      icon: '🖼', types: ['jpg','jpeg','png','gif','bmp','tiff','webp','svg','heic','raw'] },
		{ label: 'Applications',icon: '⚙', types: ['exe','msi','dmg','pkg','deb','rpm','apk','ipa','appx'] },
		{ label: 'Databases',   icon: '🗄', types: ['sql','db','sqlite','mdb','accdb','dump','bak','dbf'] },
		{ label: 'Disk Images', icon: '💿', types: ['iso','img','vmdk','vhd','qcow2','ova','nrg','mdf'] },
		{ label: 'CAD',         icon: '📐', types: ['dwg','dxf','stl','obj','fbx','step','iges','blend'] },
		{ label: 'System',      icon: '🖥', types: ['log','tmp','dmp','crash','evtx','etl','core','lock'] },
		{ label: 'Settings',    icon: '⚙', types: ['conf','cfg','ini','env','plist','reg','properties','yaml','toml'] },
		{ label: 'Secrets',     icon: '🔑', types: ['pem','key','crt','p12','pfx','pub','ppk','ovpn','gpg'] },
		{ label: 'Archives',    icon: '📦', types: ['zip','rar','7z','tar','gz','bz2','xz','tgz','cab'] },
		{ label: 'Source Code', icon: '💻', types: ['py','js','ts','go','java','c','cpp','php','rb','rs','sh'] },
		{ label: 'Misc',        icon: '?', types: ['torrent','nfo','sfv','md5','par2','nzb'] },
	];

	let selectedFT = $state<Set<string>>(new Set());

	function toggleFT(ft: string) {
		const next = new Set(selectedFT);
		const adding = !next.has(ft);
		next.has(ft) ? next.delete(ft) : next.add(ft);
		selectedFT = next;
		emitCmd(adding ? cmd.filetypeAdd(ft) : cmd.filetypeRemove(ft));
		applyFT();
	}

	function clearFT() { selectedFT = new Set(); emitCmd(cmd.filetypeClear()); applyFT(); }

	function applyFT() {
		let base = $canonicalQuery
			.replace(/\(\s*filetype:[^)]+\)/gi, '')
			.replace(/filetype:\S+/gi, '')
			.trim();
		if (selectedFT.size === 0) { canonicalQuery.set(base); return; }
		const types = [...selectedFT];
		const frag = types.length === 1
			? `filetype:${types[0]}`
			: `(${types.map(t => `filetype:${t}`).join(' OR ')})`;
		canonicalQuery.set(base ? `${base} ${frag}` : frag);
	}

	// ── Domain search ─────────────────────────────────────────────────────────
	// Stores the raw comma/newline-separated domain input
	let domainInput = $state('');
	// Parsed list of trimmed, non-empty domains
	const domains = $derived(
		domainInput
			.split(/[\n,]+/)
			.map(d => d.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, ''))
			.filter(d => d.length > 0)
	);

	function applyDomains() {
		// Remove any existing site: fragments from the query
		let base = $canonicalQuery
			.replace(/\(\s*site:[^)]+\)/gi, '')
			.replace(/site:\S+/gi, '')
			.trim();
		if (domains.length === 0) { canonicalQuery.set(base); return; }
		const frag = domains.length === 1
			? `site:${domains[0]}`
			: `(${domains.map(d => `site:${d}`).join(' OR ')})`;
		canonicalQuery.set(base ? `${base} ${frag}` : frag);
		emitCmd(cmd.domainApply(domains));
	}

	function removeDomain(domain: string) {
		const remaining = domains.filter(d => d !== domain);
		domainInput = remaining.join('\n');
		applyDomains();
	}

	function clearDomains() { domainInput = ''; emitCmd(cmd.domainClear()); applyDomains(); }

	// ── Multi-item search ─────────────────────────────────────────────────────
	// One keyword/phrase per line; each is quoted and OR-joined
	let multiInput = $state('');
	const multiItems = $derived(
		multiInput
			.split('\n')
			.map(l => l.trim())
			.filter(l => l.length > 0)
	);

	function applyMulti() {
		// Remove any existing multi-item OR group from the query
		let base = $canonicalQuery
			.replace(/\(\s*"[^"]*"(?:\s+OR\s+"[^"]*")+\s*\)/gi, '')
			.trim();
		if (multiItems.length === 0) { canonicalQuery.set(base); return; }
		// Single item: just quote it; multiple: wrap in OR group
		const frag = multiItems.length === 1
			? `"${multiItems[0]}"`
			: `(${multiItems.map(t => `"${t}"`).join(' OR ')})`;
		canonicalQuery.set(base ? `${base} ${frag}` : frag);
		emitCmd(cmd.multiApply(multiItems));
	}

	function removeMultiItem(item: string) {
		const remaining = multiItems.filter(i => i !== item);
		multiInput = remaining.join('\n');
		applyMulti();
	}

	function clearMulti() { multiInput = ''; emitCmd(cmd.multiClear()); applyMulti(); }

	// ── Common operators for autocomplete ─────────────────────────────────────
	const commonOps = $derived((() => {
		try { return tm.getCommonOperators($activeEngines); } catch { return []; }
	})());

	// ── Keyboard handler ──────────────────────────────────────────────────────
	function handleKeydown(e: KeyboardEvent) {
		if (showAC) {
			if (e.key === 'ArrowDown') { e.preventDefault(); acIndex = Math.min(acIndex+1, acOptions.length-1); return; }
			if (e.key === 'ArrowUp')   { e.preventDefault(); acIndex = Math.max(acIndex-1, 0); return; }
			if (e.key === 'Tab' || e.key === 'Enter') { e.preventDefault(); insertOp(acOptions[acIndex]); return; }
			if (e.key === 'Escape')    { showAC = false; return; }
		}
		if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.altKey) {
			e.preventDefault(); executeQuery(); return;
		}
		if (e.ctrlKey && e.shiftKey && e.key === 'E') {
			e.preventDefault();
			const next = $mode === 'unified' ? 'per-engine' : 'unified';
			mode.update(() => next);
			emitCmd(cmd.modeToggle(next));
		}
	}

	function handleInput(e: Event) {
		const t = e.target as HTMLTextAreaElement;
		const before = t.value.slice(0, t.selectionStart ?? t.value.length);
		const m = before.match(/(\w+):$/);
		if (m) {
			const filtered = commonOps.filter(op => op.toLowerCase().startsWith(m[1].toLowerCase()));
			if (filtered.length) { acOptions = filtered; acIndex = 0; showAC = true; return; }
		}
		showAC = false;
	}

	function insertOp(op: string) {
		if (!textareaEl) return;
		const v = textareaEl.value;
		const pos = textareaEl.selectionStart ?? v.length;
		const before = v.slice(0, pos);
		const newText = before.replace(/(\w+):$/, op + ':') + v.slice(pos);
		canonicalQuery.set(newText);
		showAC = false;
		emitCmd(cmd.insertOperator(op));
		const newPos = before.replace(/(\w+):$/, op + ':').length;
		setTimeout(() => { textareaEl?.setSelectionRange(newPos, newPos); textareaEl?.focus(); }, 0);
	}

	function cloneAndTranslate() {
		if (!$activeEngines.length) return;
		const first = $activeEngines[0];
		const q = $perEngineQueries[first] ?? '';
		if (!q.trim()) return;
		const { ast } = parseQuery(q);
		if (!ast) return;
		const results = tm.translateFrom(first, ast, $activeEngines);
		const next: Partial<Record<EngineId, string>> = {};
		for (const r of results) next[r.engineId] = r.nativeQuery;
		perEngineQueries.set(next);
	}
</script>

<div class="query-composer zone-query-composer">
	{#if $mode === 'unified'}
		<!-- ── Toolbar ──────────────────────────────────────────────────────── -->
		<div class="toolbar">
			<div class="toolbar__left">
				<!-- File type button -->
				<button
					class="btn btn--ghost btn--sm"
					class:btn--active={activePanel === 'filetype'}
					onclick={() => togglePanel('filetype')}
					aria-expanded={activePanel === 'filetype'}
					aria-label="File type filter"
				>
					<svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
						<path d="M9 1H3a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V6L9 1z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>
						<path d="M9 1v5h5" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>
					</svg>
					File type
					{#if selectedFT.size > 0}
						<span class="badge badge--accent">{selectedFT.size}</span>
					{/if}
				</button>

				<!-- Domain button -->
				<button
					class="btn btn--ghost btn--sm"
					class:btn--active={activePanel === 'domain'}
					onclick={() => togglePanel('domain')}
					aria-expanded={activePanel === 'domain'}
					aria-label="Domain filter"
				>
					<svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
						<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.5"/>
						<path d="M8 1.5C8 1.5 5.5 4 5.5 8s2.5 6.5 2.5 6.5M8 1.5C8 1.5 10.5 4 10.5 8S8 14.5 8 14.5M1.5 8h13" stroke="currentColor" stroke-width="1.5"/>
					</svg>
					Domain
					{#if domains.length > 0}
						<span class="badge badge--accent">{domains.length}</span>
					{/if}
				</button>

				<!-- Multi-item button -->
				<button
					class="btn btn--ghost btn--sm"
					class:btn--active={activePanel === 'multi'}
					onclick={() => togglePanel('multi')}
					aria-expanded={activePanel === 'multi'}
					aria-label="Multi-item search"
				>
					<svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
						<path d="M2 4h12M2 8h8M2 12h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
					</svg>
					Multi-item
					{#if multiItems.length > 0}
						<span class="badge badge--accent">{multiItems.length}</span>
					{/if}
				</button>

				<!-- Active chips row -->
				{#each [...selectedFT] as ft}
					<span class="chip-tag chip-tag--file">
						.{ft}
						<button class="chip-tag__remove" onclick={() => toggleFT(ft)} aria-label="Remove .{ft}">×</button>
					</span>
				{/each}
				{#if selectedFT.size > 1}
					<button class="btn-link" onclick={clearFT}>Clear files</button>
				{/if}

				{#each domains as d}
					<span class="chip-tag chip-tag--domain">
						{d}
						<button class="chip-tag__remove" onclick={() => removeDomain(d)} aria-label="Remove {d}">×</button>
					</span>
				{/each}
				{#if domains.length > 1}
					<button class="btn-link" onclick={clearDomains}>Clear domains</button>
				{/if}

				{#each multiItems as item}
					<span class="chip-tag chip-tag--multi">
						"{item}"
						<button class="chip-tag__remove" onclick={() => removeMultiItem(item)} aria-label='Remove "{item}"'>×</button>
					</span>
				{/each}
				{#if multiItems.length > 1}
					<button class="btn-link" onclick={clearMulti}>Clear items</button>
				{/if}
			</div>

			<div class="toolbar__right">
				<button
					class="btn btn--ghost btn--sm"
					class:btn--active={$mode === 'per-engine'}
					onclick={() => { const next = $mode === 'unified' ? 'per-engine' : 'unified'; mode.set(next); emitCmd(cmd.modeToggle(next)); }}
					title="Toggle per-engine mode (Ctrl+Shift+E)"
					aria-pressed={$mode === 'per-engine'}
				>Per-engine</button>

				<button
					class="btn btn--primary btn--sm"
					onclick={() => executeQuery()}
					aria-label="Run query (Enter)"
				>
					<svg width="11" height="11" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
						<path d="M2 1l9 5-9 5V1z"/>
					</svg>
					Run
				</button>
			</div>
		</div>

		<!-- ── File type panel ──────────────────────────────────────────────── -->
		{#if activePanel === 'filetype'}
			<div class="sub-panel" role="group" aria-label="File type selector">
				<div class="sub-panel__header">
					<span class="sub-panel__title">Filter by file type</span>
					<span class="sub-panel__hint">Click to toggle · multiple selections are OR-joined</span>
				</div>
				<!-- Suggested presets row -->
				<div class="ft-suggested">
					<span class="ft-suggested__label">SUGGESTED</span>
					<div class="ft-suggested__items">
						{#each SUGGESTED_PRESETS as preset}
							<button
								class="ft-preset-btn"
								onclick={() => {
									// Toggle all types in preset: if all selected, deselect all; else select all
									const allSelected = preset.types.every(t => selectedFT.has(t));
									const next = new Set(selectedFT);
									if (allSelected) {
										preset.types.forEach(t => next.delete(t));
									} else {
										preset.types.forEach(t => next.add(t));
									}
									selectedFT = next;
									applyFT();
								}}
								class:ft-preset-btn--active={preset.types.some(t => selectedFT.has(t))}
								title="{preset.types.join(', ')}"
							>
								<span class="ft-preset-icon">{preset.icon}</span>
								{preset.label}
							</button>
						{/each}
					</div>
				</div>
				<div class="ft-groups">
					{#each FT_GROUPS as group}
						<div class="ft-group">
							<span class="ft-group__label">{group.label}</span>
							<div class="ft-group__items">
								{#each group.types as ft}
									<button
										class="ft-btn"
										class:ft-btn--selected={selectedFT.has(ft)}
										onclick={() => toggleFT(ft)}
										aria-pressed={selectedFT.has(ft)}
									>.{ft}</button>
								{/each}
							</div>
						</div>
					{/each}
				</div>
				{#if selectedFT.size > 0}
					<div class="sub-panel__footer">
						<span class="sub-panel__preview">
							→ <code>{selectedFT.size === 1 ? `filetype:${[...selectedFT][0]}` : `(${[...selectedFT].map(t=>`filetype:${t}`).join(' OR ')})`}</code>
						</span>
						<button class="btn-link" onclick={clearFT}>Clear all</button>
					</div>
				{/if}
			</div>
		{/if}

		<!-- ── Domain search panel ───────────────────────────────────────────── -->
		{#if activePanel === 'domain'}
			<div class="sub-panel" role="group" aria-label="Domain search">
				<div class="sub-panel__header">
					<span class="sub-panel__title">Search by domain</span>
					<span class="sub-panel__hint">Enter one domain per line, or comma-separated · multiple domains are OR-joined</span>
				</div>
				<div class="domain-input-wrap">
					<textarea
						class="domain-textarea"
						placeholder="example.com&#10;*.gov&#10;subdomain.example.org"
						bind:value={domainInput}
						oninput={applyDomains}
						rows="3"
						spellcheck="false"
						autocomplete="off"
						aria-label="Domain list"
					></textarea>
					<div class="domain-actions">
						{#if domains.length > 0}
							<span class="domain-preview">
								→ <code>{domains.length === 1 ? `site:${domains[0]}` : `(${domains.map(d=>`site:${d}`).join(' OR ')})`}</code>
							</span>
							<button class="btn btn--ghost btn--sm" onclick={clearDomains}>Clear</button>
						{/if}
					</div>
				</div>
				<div class="domain-tips">
					<span class="tip">Tip: use <code>*.example.com</code> for all subdomains</span>
					<span class="tip">Tip: paste a list of URLs — protocols and paths are stripped automatically</span>
				</div>
			</div>
		{/if}

		<!-- ── Multi-item search panel ───────────────────────────────────────── -->
		{#if activePanel === 'multi'}
			<div class="sub-panel" role="group" aria-label="Multi-item search">
				<div class="sub-panel__header">
					<span class="sub-panel__title">Search for multiple items</span>
					<span class="sub-panel__hint">One keyword or phrase per line · results matching ANY item are returned (OR logic)</span>
				</div>
				<div class="multi-input-wrap">
					<textarea
						class="multi-textarea"
						placeholder="admin panel&#10;login page&#10;password reset&#10;api key"
						bind:value={multiInput}
						oninput={applyMulti}
						rows="5"
						spellcheck="false"
						autocomplete="off"
						aria-label="Search terms list"
					></textarea>
					<div class="multi-actions">
						{#if multiItems.length > 0}
							<span class="multi-count">{multiItems.length} item{multiItems.length !== 1 ? 's' : ''}</span>
							<span class="multi-preview">
								→ <code>{multiItems.length === 1 ? `"${multiItems[0]}"` : `("${multiItems[0]}" OR ... +${multiItems.length - 1} more)`}</code>
							</span>
							<button class="btn btn--ghost btn--sm" onclick={clearMulti}>Clear</button>
						{/if}
					</div>
				</div>
				<div class="domain-tips">
					<span class="tip">Tip: phrases with spaces are automatically quoted</span>
					<span class="tip">Tip: combine with domain and file type filters for precise targeting</span>
				</div>
			</div>
		{/if}

		<!-- ── Query input — root csh shell prompt ──────────────────────────── -->
		<div class="shell-block" class:shell-block--error={$parseErrors.length > 0}>
			<div class="shell-line">
				<!-- Static prompt -->
				<span class="shell-prompt" aria-hidden="true">root@dorkstar:~# </span>

				<!-- Input area: textarea + trailing cursor overlay -->
				<div class="shell-input-area">
					<!-- Hidden text mirror — measures rendered text width for cursor positioning -->
					<span class="shell-text-mirror" aria-hidden="true">{$canonicalQuery}</span>
					<!-- Blinking block cursor — positioned after the text via the mirror -->
					<span class="shell-cursor" aria-hidden="true">█</span>
					<!-- Actual textarea — transparent, sits over the mirror -->
					<textarea
						bind:this={textareaEl}
						class="query-input"
						class:query-input--error={$parseErrors.length > 0}
						placeholder=""
						value={$canonicalQuery}
						oninput={e => { canonicalQuery.set((e.target as HTMLTextAreaElement).value); handleInput(e); }}
						onkeydown={handleKeydown}
						spellcheck="false"
						autocomplete="off"
						aria-label="Canonical query — root shell"
						rows="1"
					></textarea>
				</div>
			</div>

			<!-- Autocomplete dropdown -->
			{#if showAC && acOptions.length > 0}
				<ul class="autocomplete" role="listbox" aria-label="Operator suggestions">
					{#each acOptions as op, i}
						<li
							role="option"
							aria-selected={i === acIndex}
							class="autocomplete__item"
							class:autocomplete__item--active={i === acIndex}
							onmousedown={(e) => { e.preventDefault(); insertOp(op); }}
						>
							<span class="autocomplete__op">{op}:</span>
						</li>
					{/each}
				</ul>
			{/if}
		</div>

		<!-- ── Parse errors ──────────────────────────────────────────────────── -->
		{#if $parseErrors.length > 0}
			<div class="parse-errors" role="alert">
				{#each $parseErrors as err}
					<span class="parse-error">
						<svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
							<path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 3.5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4.5zm0 7a1 1 0 1 1 0-2 1 1 0 0 1 0 2z"/>
						</svg>
						{err.message}
						<span class="parse-error__pos">col {err.position}</span>
					</span>
				{/each}
			</div>
		{/if}

		<!-- ── Translation preview strip ────────────────────────────────────── -->
		{#if $translations.length > 0}
			<div class="preview-strip" aria-label="Translation preview">
				{#each $translations as t}
					<div class="preview-item" class:preview-item--warn={t.degradations.length > 0}>
						<span class="preview-item__engine">{t.engineId}</span>
						<span class="preview-item__query" title={t.nativeQuery}>{t.nativeQuery || '—'}</span>
						{#if t.degradations.length > 0}
							<button
								class="warn-badge"
								onclick={() => { openDegEngine = openDegEngine === t.engineId ? null : t.engineId; }}
								aria-expanded={openDegEngine === t.engineId}
								aria-label="{t.degradations.length} warnings for {t.engineId}"
							>⚠ {t.degradations.length}</button>
							{#if openDegEngine === t.engineId}
								<div class="deg-popover" role="tooltip">
									{#each t.degradations as d}
										<div class="deg-row">
											<code class="deg-op">{d.operator}</code>
											<span class="deg-reason">{d.reason}</span>
										</div>
									{/each}
								</div>
							{/if}
						{/if}
					</div>
				{/each}
			</div>
		{/if}

	{:else}
		<!-- ── Per-engine mode ───────────────────────────────────────────────── -->
		<div class="toolbar">
			<div class="toolbar__left">
				<span class="mode-badge">Per-engine mode</span>
				<button class="btn btn--ghost btn--sm" onclick={cloneAndTranslate}>Clone &amp; translate</button>
			</div>
			<div class="toolbar__right">
				<button class="btn btn--ghost btn--sm btn--active" onclick={() => mode.set('unified')} aria-pressed="true">Per-engine</button>
				<button class="btn btn--primary btn--sm" onclick={() => executeQuery()}>
					<svg width="11" height="11" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true"><path d="M2 1l9 5-9 5V1z"/></svg>
					Run all
				</button>
			</div>
		</div>
		<div class="per-engine-list">
			{#each $activeEngines as engineId}
				<div class="per-engine-row">
					<label class="per-engine-label" for="pe-{engineId}">{engineId}</label>
					<textarea
						id="pe-{engineId}"
						class="query-input per-engine-input"
						value={$perEngineQueries[engineId] ?? ''}
						oninput={e => perEngineQueries.update(pq => ({ ...pq, [engineId]: (e.target as HTMLTextAreaElement).value }))}
						onkeydown={handleKeydown}
						spellcheck="false"
						autocomplete="off"
						rows="1"
						aria-label="Query for {engineId}"
					></textarea>
				</div>
			{/each}
		</div>
	{/if}
</div>

<style>
	.query-composer {
		display: flex;
		flex-direction: column;
		background: var(--c-surface);
		/* Never grow beyond its natural content height */
		flex-shrink: 0;
		overflow: hidden;
	}

	/* ── Toolbar ─────────────────────────────────────────────────────────────── */
	.toolbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--sp-2);
		padding: var(--sp-2) var(--sp-3);
		border-bottom: 1px solid var(--c-border);
		flex-shrink: 0;
		/* No wrapping — scroll if needed */
		flex-wrap: nowrap;
		overflow-x: auto;
		scrollbar-width: none;
	}
	.toolbar::-webkit-scrollbar { display: none; }
	.toolbar__left, .toolbar__right { display: flex; align-items: center; gap: var(--sp-2); flex-wrap: nowrap; flex-shrink: 0; }

	/* ── Buttons ─────────────────────────────────────────────────────────────── */
	.btn {
		display: inline-flex; align-items: center; gap: 5px;
		border-radius: var(--r-sm); font-family: var(--font-sans); font-weight: 500;
		cursor: pointer; transition: all var(--t-fast); white-space: nowrap; border: 1px solid transparent;
	}
	.btn--sm { padding: 4px 10px; font-size: 12px; }
	.btn--ghost { background: transparent; border-color: var(--c-border); color: var(--c-text-2); }
	.btn--ghost:hover { border-color: var(--c-border-2); color: var(--c-text); background: var(--c-surface-2); }
	.btn--ghost.btn--active { border-color: var(--c-accent); color: var(--c-accent); background: var(--c-accent-dim); }
	.btn--primary { background: var(--c-accent); color: var(--c-text-inv); border-color: var(--c-accent); font-weight: 600; }
	.btn--primary:hover { background: var(--c-accent-hover); border-color: var(--c-accent-hover); }
	.btn-link { background: none; border: none; color: var(--c-text-3); font-size: 12px; cursor: pointer; text-decoration: underline; padding: 0; }
	.btn-link:hover { color: var(--c-text-2); }

	.badge { display: inline-flex; align-items: center; justify-content: center; min-width: 16px; height: 16px; padding: 0 4px; border-radius: 8px; font-size: 10px; font-weight: 700; }
	.badge--accent { background: var(--c-accent); color: var(--c-text-inv); }

	/* ── Active filter chips in toolbar ─────────────────────────────────────── */
	.chip-tag {
		display: inline-flex; align-items: center; gap: 3px;
		padding: 2px 5px 2px 8px; border-radius: 20px;
		font-size: 11px; font-family: var(--font-mono);
		border: 1px solid; white-space: nowrap;
	}
	.chip-tag--file   { background: color-mix(in srgb, var(--c-purple) 10%, transparent); border-color: var(--c-purple); color: var(--c-purple); }
	.chip-tag--domain { background: color-mix(in srgb, var(--c-blue) 10%, transparent);   border-color: var(--c-blue);   color: var(--c-blue); }
	.chip-tag--multi  { background: color-mix(in srgb, var(--c-cyan) 10%, transparent);   border-color: var(--c-cyan);   color: var(--c-cyan); }

	.chip-tag__remove {
		background: none; border: none; cursor: pointer; padding: 0 1px;
		font-size: 13px; line-height: 1; color: inherit; opacity: 0.7;
	}
	.chip-tag__remove:hover { opacity: 1; }

	/* ── Sub-panels (file type / domain / multi) ─────────────────────────────── */
	.sub-panel {
		background: var(--c-surface-2);
		border-bottom: 1px solid var(--c-border);
		flex-shrink: 0;
	}

	.sub-panel__header {
		display: flex; align-items: baseline; gap: var(--sp-3);
		padding: var(--sp-2) var(--sp-4) var(--sp-1);
	}
	.sub-panel__title { font-size: 12px; font-weight: 600; color: var(--c-text); }
	.sub-panel__hint  { font-size: 11px; color: var(--c-text-3); }

	.sub-panel__footer {
		display: flex; align-items: center; gap: var(--sp-3);
		padding: var(--sp-1) var(--sp-4) var(--sp-2);
		border-top: 1px solid var(--c-border);
	}
	.sub-panel__preview { font-size: 11px; color: var(--c-text-2); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.sub-panel__preview code { font-family: var(--font-mono); color: var(--c-accent); }

	/* ── File type groups ────────────────────────────────────────────────────── */
	.ft-groups { display: flex; flex-wrap: wrap; gap: var(--sp-4); padding: var(--sp-2) var(--sp-4); }
	.ft-group { display: flex; flex-direction: column; gap: var(--sp-1); }
	.ft-group__label { font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--c-text-3); }
	.ft-group__items { display: flex; flex-wrap: wrap; gap: 3px; }
	.ft-btn { padding: 2px 8px; background: var(--c-surface); border: 1px solid var(--c-border); border-radius: var(--r-sm); color: var(--c-text-2); font-family: var(--font-mono); font-size: 11px; cursor: pointer; transition: all var(--t-fast); }
	.ft-btn:hover { border-color: var(--c-border-2); color: var(--c-text); }
	.ft-btn--selected { background: color-mix(in srgb, var(--c-purple) 12%, transparent); border-color: var(--c-purple); color: var(--c-purple); }

	/* ── Suggested presets ───────────────────────────────────────────────────── */
	.ft-suggested { display: flex; align-items: center; gap: var(--sp-3); padding: var(--sp-2) var(--sp-4); border-bottom: 1px solid var(--c-border); flex-wrap: wrap; }
	.ft-suggested__label { font-size: 9px; font-weight: 700; letter-spacing: 0.1em; color: var(--c-text-3); flex-shrink: 0; }
	.ft-suggested__items { display: flex; flex-wrap: wrap; gap: 4px; }
	.ft-preset-btn { display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; background: var(--c-surface); border: 1px solid var(--c-border); color: var(--c-text-2); font-family: var(--font-mono); font-size: 11px; cursor: pointer; transition: all var(--t-fast); }
	.ft-preset-btn:hover { border-color: var(--c-border-2); color: var(--c-text); }
	.ft-preset-btn--active { background: color-mix(in srgb, var(--c-purple) 12%, transparent); border-color: var(--c-purple); color: var(--c-purple); }
	.ft-preset-icon { font-size: 12px; }

	/* ── Domain panel ────────────────────────────────────────────────────────── */
	.domain-input-wrap { padding: var(--sp-1) var(--sp-4) var(--sp-2); display: flex; flex-direction: column; gap: var(--sp-2); }

	.domain-textarea, .multi-textarea {
		width: 100%; background: var(--c-bg); color: var(--c-text);
		border: 1px solid var(--c-border); border-radius: var(--r-md);
		font-family: var(--font-mono); font-size: 12px; line-height: 1.5;
		padding: var(--sp-2) var(--sp-3); resize: vertical; outline: none;
		caret-color: var(--c-accent); transition: border-color var(--t-fast);
	}
	.domain-textarea:focus, .multi-textarea:focus { border-color: var(--c-accent); }
	.domain-textarea::placeholder, .multi-textarea::placeholder { color: var(--c-text-3); }

	.domain-actions, .multi-actions {
		display: flex; align-items: center; gap: var(--sp-3); flex-wrap: wrap;
	}
	.domain-preview, .multi-preview {
		font-size: 11px; color: var(--c-text-2); flex: 1;
		overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
	}
	.domain-preview code, .multi-preview code { font-family: var(--font-mono); color: var(--c-blue); }

	.multi-count { font-size: 11px; font-weight: 600; color: var(--c-cyan); font-family: var(--font-mono); flex-shrink: 0; }

	/* ── Multi panel ─────────────────────────────────────────────────────────── */
	.multi-input-wrap { padding: var(--sp-1) var(--sp-4) var(--sp-2); display: flex; flex-direction: column; gap: var(--sp-2); }

	/* ── Tips ────────────────────────────────────────────────────────────────── */
	.domain-tips {
		display: flex; flex-wrap: wrap; gap: var(--sp-3);
		padding: var(--sp-1) var(--sp-4) var(--sp-2);
		border-top: 1px solid var(--c-border);
	}
	.tip { font-size: 10px; color: var(--c-text-3); }
	.tip code { font-family: var(--font-mono); color: var(--c-text-2); }

	/* ── Shell block ─────────────────────────────────────────────────────────── */
	.shell-block {
		background: var(--p-bg, #000a00);
		border: 1px solid var(--p-border-2, #004d00);
		margin: var(--sp-1) var(--sp-2);
		flex-shrink: 0;
		box-shadow: 0 0 0 1px var(--p-border, #003300), 0 0 16px var(--p-glow, rgba(51,204,51,0.15));
		position: relative;
	}

	.shell-block--error {
		border-color: var(--c-red, #ff4444);
		box-shadow: 0 0 0 1px var(--c-red, #ff4444), 0 0 12px rgba(255,68,68,0.2);
	}

	/* ── Single prompt line ──────────────────────────────────────────────────── */
	/* prompt + input-area all on one horizontal line */
	.shell-line {
		display: flex;
		align-items: center;
		padding: var(--sp-1) var(--sp-2);
		gap: 0;
		overflow: hidden;
	}

	/* Input area: contains mirror text + cursor + transparent textarea overlay */
	.shell-input-area {
		position: relative;
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		/* Must have explicit height for the absolute textarea to fill */
		height: 1.6em;
		overflow: hidden;
	}

	/* Hidden mirror — same font/size as textarea, renders text to push cursor right */
	.shell-text-mirror {
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: 1.6;
		letter-spacing: 0.02em;
		white-space: pre;
		color: transparent;       /* invisible — only used for width */
		pointer-events: none;
		user-select: none;
		flex-shrink: 0;
		/* Ensure empty string still has zero width */
		min-width: 0;
	}

	/* Blinking block cursor — sits immediately after the mirror text */
	.shell-cursor {
		color: var(--p-bright, #66ff66);
		font-size: 13px;
		line-height: 1.6;
		text-shadow: 0 0 6px var(--p-glow-strong);
		animation: cursor-blink 1s step-end infinite;
		flex-shrink: 0;
		pointer-events: none;
		user-select: none;
		/* Slight negative margin so cursor overlaps the next character position */
		margin-left: -1px;
	}

	@keyframes cursor-blink {
		0%, 100% { opacity: 1; }
		50%       { opacity: 0; }
	}

	/* Textarea — absolutely covers the input-area, transparent so mirror shows through */
	.query-input {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		background: transparent;
		color: var(--p-bright, #66ff66);
		border: none;
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: 1.6;
		padding: 0;
		resize: none;
		outline: none;
		/* Hide the native browser caret — our █ cursor replaces it */
		caret-color: transparent;
		text-shadow: 0 0 4px var(--p-glow-strong, rgba(102,255,102,0.25));
		letter-spacing: 0.02em;
		overflow: hidden;
		white-space: nowrap;
	}

	.query-input::placeholder {
		color: var(--p-border-2, #004d00);
		text-shadow: none;
	}

	.query-input--error {
		color: var(--c-red, #ff4444);
		text-shadow: 0 0 4px rgba(255,68,68,0.3);
		caret-color: var(--c-red, #ff4444);
	}

	/* ── Autocomplete ────────────────────────────────────────────────────────── */
	.autocomplete {
		position: absolute; top: 100%; left: var(--sp-4);
		background: var(--c-surface-2); border: 1px solid var(--c-border-2);
		border-radius: var(--r-md); box-shadow: var(--shadow-md);
		z-index: 100; min-width: 200px; max-height: 200px; overflow-y: auto;
		list-style: none; padding: var(--sp-1);
	}
	.autocomplete__item { padding: 5px 10px; border-radius: var(--r-sm); cursor: pointer; font-size: 12px; color: var(--c-text-2); transition: background var(--t-fast), color var(--t-fast); }
	.autocomplete__item:hover, .autocomplete__item--active { background: var(--c-accent-dim); color: var(--c-accent); }
	.autocomplete__op { font-family: var(--font-mono); font-weight: 600; }

	/* ── Parse errors ────────────────────────────────────────────────────────── */
	.parse-errors { display: flex; flex-wrap: wrap; gap: var(--sp-2); padding: var(--sp-1) var(--sp-4); background: color-mix(in srgb, var(--c-red) 8%, var(--c-surface)); border-bottom: 1px solid color-mix(in srgb, var(--c-red) 30%, transparent); flex-shrink: 0; }
	.parse-error { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; color: var(--c-red); }
	.parse-error__pos { color: color-mix(in srgb, var(--c-red) 60%, transparent); font-family: var(--font-mono); }

	/* ── Translation preview strip ───────────────────────────────────────────── */
	.preview-strip { display: flex; flex-wrap: nowrap; overflow-x: auto; border-top: 1px solid var(--c-border); background: var(--c-surface-2); flex-shrink: 0; max-height: 52px; }
	.preview-item { display: flex; align-items: center; gap: var(--sp-2); padding: var(--sp-1) var(--sp-3); border-right: 1px solid var(--c-border); min-width: 140px; max-width: 220px; flex-shrink: 0; position: relative; }
	.preview-item--warn { background: color-mix(in srgb, var(--c-orange) 6%, var(--c-surface-2)); }
	.preview-item__engine { font-size: 10px; font-weight: 600; color: var(--c-text-3); text-transform: uppercase; letter-spacing: 0.04em; flex-shrink: 0; }
	.preview-item__query { font-family: var(--font-mono); font-size: 10px; color: var(--c-text-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
	.warn-badge { background: none; border: 1px solid var(--c-orange); border-radius: var(--r-sm); color: var(--c-orange); font-size: 9px; padding: 1px 5px; cursor: pointer; flex-shrink: 0; transition: background var(--t-fast); }
	.warn-badge:hover { background: color-mix(in srgb, var(--c-orange) 12%, transparent); }
	.deg-popover { position: absolute; top: 100%; right: 0; background: var(--c-surface-2); border: 1px solid var(--c-border-2); border-radius: var(--r-md); box-shadow: var(--shadow-md); padding: var(--sp-2) var(--sp-3); z-index: 80; min-width: 260px; max-width: 340px; }
	.deg-row { display: flex; align-items: center; gap: var(--sp-2); padding: 3px 0; font-size: 11px; color: var(--c-text-2); }
	.deg-op { color: var(--c-accent); font-size: 11px; }
	.deg-reason { color: var(--c-orange); font-size: 10px; }

	/* ── Per-engine mode ─────────────────────────────────────────────────────── */
	.mode-badge { font-size: 11px; font-weight: 600; color: var(--c-accent); background: var(--c-accent-dim); padding: 2px 8px; border-radius: 20px; }
	.per-engine-list { flex: 1; overflow-y: auto; }
	.per-engine-row { display: flex; align-items: stretch; border-bottom: 1px solid var(--c-border); }
	.per-engine-label { width: 110px; flex-shrink: 0; display: flex; align-items: center; padding: 0 var(--sp-3); font-size: 11px; font-weight: 600; color: var(--c-text-3); text-transform: uppercase; letter-spacing: 0.04em; border-right: 1px solid var(--c-border); background: var(--c-surface-2); }
	.per-engine-input { flex: 1; height: 32px; border: none; padding: var(--sp-2) var(--sp-3); font-size: 12px; background: var(--c-bg); }
</style>
