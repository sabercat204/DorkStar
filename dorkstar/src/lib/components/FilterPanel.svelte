<script lang="ts">
  import {
    activeFilterPanel, toggleFilterPanel,
    selectedFT, toggleFT, clearFT, applyFT,
    domainInput, domains, applyDomains, removeDomain, clearDomains,
    multiInput, multiItems, applyMulti, removeMultiItem, clearMulti
  } from '$lib/stores/filter-store';

  const FT_GROUPS: { label: string; types: string[] }[] = [
    { label: 'Documents',   types: ['pdf','doc','docx','xls','xlsx','ppt','pptx','odt','rtf','txt'] },
    { label: 'Images',      types: ['jpg','jpeg','png','gif','bmp','tiff','webp','svg','heic','raw'] },
    { label: 'Video',       types: ['mp4','mkv','avi','mov','wmv','flv','webm','m4v','mpg','mpeg'] },
    { label: 'Audio',       types: ['mp3','wav','flac','aac','ogg','wma','m4a','opus','aiff'] },
    { label: 'Archives',    types: ['zip','rar','7z','tar','gz','bz2','xz','tgz','cab','iso'] },
    { label: 'Source Code', types: ['js','ts','py','rb','go','java','c','cpp','php','sh','env','yaml','json','xml','sql'] },
    { label: 'Web',         types: ['html','htm','css','scss','xml','json','yaml','yml','toml','graphql'] },
    { label: 'Data',        types: ['csv','tsv','db','sqlite','bak','log'] },
    { label: 'Config',      types: ['conf','cfg','ini','htaccess','htpasswd','env','properties'] },
    { label: 'Secrets',     types: ['pem','key','crt','p12','pfx','pub','ppk','ovpn','gpg'] },
    { label: 'Executables', types: ['exe','dll','so','dylib','bin','msi','dmg','pkg','deb','rpm','apk'] },
    { label: 'Disk Images', types: ['iso','img','vmdk','vhd','qcow2','ova','nrg','mdf'] },
    { label: 'Database',    types: ['sql','dump','bak','mdf','sqlite','db3','accdb','mdb'] },
    { label: 'CAD/3D',      types: ['dwg','dxf','stl','obj','fbx','step','blend'] },
    { label: 'System',      types: ['log','tmp','dmp','crash','evtx','lock','pid'] },
    { label: 'Misc',        types: ['torrent','nfo','sfv','md5','par2','nzb'] },
  ];

  const SUGGESTED_PRESETS: { label: string; types: string[] }[] = [
    { label: 'Music',        types: ['mp3','flac','wav','aac','ogg','m4a','wma','opus','aiff'] },
    { label: 'Movies',       types: ['mp4','mkv','avi','mov','wmv','m4v','mpg','mpeg','webm'] },
    { label: 'Documents',    types: ['pdf','doc','docx','xls','xlsx','ppt','pptx','txt','rtf','odt'] },
    { label: 'Images',       types: ['jpg','jpeg','png','gif','bmp','tiff','webp','svg','heic','raw'] },
    { label: 'Applications', types: ['exe','msi','dmg','pkg','deb','rpm','apk'] },
    { label: 'Databases',    types: ['sql','db','sqlite','mdb','accdb','dump','bak','dbf'] },
    { label: 'Disk Images',  types: ['iso','img','vmdk','vhd','qcow2','ova','nrg','mdf'] },
    { label: 'CAD',          types: ['dwg','dxf','stl','obj','fbx','step','blend'] },
    { label: 'System',       types: ['log','tmp','dmp','crash','evtx','lock','pid'] },
    { label: 'Settings',     types: ['conf','cfg','ini','env','properties','yaml','toml'] },
    { label: 'Secrets',      types: ['pem','key','crt','p12','pfx','pub','ppk','ovpn','gpg'] },
    { label: 'Archives',     types: ['zip','rar','7z','tar','gz','bz2','xz','tgz','cab'] },
    { label: 'Source Code',  types: ['py','js','ts','go','java','c','cpp','php','rb','sh'] },
    { label: 'Misc',         types: ['torrent','nfo','sfv','md5','par2','nzb'] },
  ];

  function applyPreset(types: string[]) {
    for (const t of types) {
      if (!$selectedFT.has(t)) toggleFT(t);
    }
  }

  // Derived filetype fragment preview
  function ftFragment(sel: Set<string>): string {
    const types = [...sel];
    if (types.length === 0) return '';
    if (types.length === 1) return `filetype:${types[0]}`;
    return `(${types.map(t => `filetype:${t}`).join(' OR ')})`;
  }

  // Derived domain fragment preview
  function domainFragment(ds: string[]): string {
    if (ds.length === 0) return '';
    if (ds.length === 1) return `site:${ds[0]}`;
    return `(${ds.map(d => `site:${d}`).join(' OR ')})`;
  }

  // Derived multi fragment preview
  function multiFragment(items: string[]): string {
    if (items.length === 0) return '';
    if (items.length === 1) return `"${items[0]}"`;
    return `(${items.map(i => `"${i}"`).join(' OR ')})`;
  }
</script>

<div class="filter-panel">

  <!-- ═══════════════════════════════════════════════════════ FILE TYPE ══ -->
  <div class="section" class:active={$activeFilterPanel === 'filetype'}>
    <button
      class="section-header"
      onclick={() => toggleFilterPanel('filetype')}
      aria-expanded={$activeFilterPanel === 'filetype'}
    >
      <span class="label">[FILE TYPE]</span>
      {#if $selectedFT.size > 0}
        <span class="badge">{$selectedFT.size}</span>
      {/if}
      <span class="chevron">{$activeFilterPanel === 'filetype' ? '▲' : '▼'}</span>
    </button>

    {#if $activeFilterPanel === 'filetype'}
      <div class="section-body">

        <!-- Presets row -->
        <div class="presets-row">
          {#each SUGGESTED_PRESETS as preset}
            <button
              class="preset-btn"
              onclick={() => applyPreset(preset.types)}
              title={preset.types.join(', ')}
            >{preset.label}</button>
          {/each}
        </div>

        <!-- FT groups -->
        {#each FT_GROUPS as group}
          <div class="ft-group">
            <span class="group-label">{group.label}</span>
            <div class="type-buttons">
              {#each group.types as ft}
                <button
                  class="type-btn"
                  class:selected={$selectedFT.has(ft)}
                  onclick={() => toggleFT(ft)}
                >{ft}</button>
              {/each}
            </div>
          </div>
        {/each}

        <!-- Footer -->
        {#if $selectedFT.size > 0}
          <div class="section-footer">
            <span class="fragment-preview" title={ftFragment($selectedFT)}>{ftFragment($selectedFT)}</span>
            <button class="clear-btn" onclick={clearFT}>Clear</button>
          </div>
        {/if}

      </div>
    {/if}
  </div>

  <!-- ═══════════════════════════════════════════════════════════ DOMAIN ══ -->
  <div class="section" class:active={$activeFilterPanel === 'domain'}>
    <button
      class="section-header"
      onclick={() => toggleFilterPanel('domain')}
      aria-expanded={$activeFilterPanel === 'domain'}
    >
      <span class="label">[DOMAIN]</span>
      {#if $domains.length > 0}
        <span class="badge">{$domains.length}</span>
      {/if}
      <span class="chevron">{$activeFilterPanel === 'domain' ? '▲' : '▼'}</span>
    </button>

    {#if $activeFilterPanel === 'domain'}
      <div class="section-body">
        <textarea
          class="filter-textarea"
          rows={3}
          placeholder={"example.com\nfoo.org"}
          bind:value={$domainInput}
          oninput={applyDomains}
        ></textarea>

        {#if $domains.length > 0}
          <div class="section-footer">
            <span class="fragment-preview" title={domainFragment($domains)}>{domainFragment($domains)}</span>
            <button class="clear-btn" onclick={clearDomains}>Clear</button>
          </div>
        {/if}
      </div>
    {/if}
  </div>

  <!-- ══════════════════════════════════════════════════════ MULTI-ITEM ══ -->
  <div class="section" class:active={$activeFilterPanel === 'multi'}>
    <button
      class="section-header"
      onclick={() => toggleFilterPanel('multi')}
      aria-expanded={$activeFilterPanel === 'multi'}
    >
      <span class="label">[MULTI-ITEM]</span>
      {#if $multiItems.length > 0}
        <span class="badge">{$multiItems.length}</span>
      {/if}
      <span class="chevron">{$activeFilterPanel === 'multi' ? '▲' : '▼'}</span>
    </button>

    {#if $activeFilterPanel === 'multi'}
      <div class="section-body">
        <textarea
          class="filter-textarea"
          rows={4}
          placeholder={"one item per line"}
          bind:value={$multiInput}
          oninput={applyMulti}
        ></textarea>

        {#if $multiItems.length > 0}
          <div class="section-footer">
            <span class="item-count">{$multiItems.length} item{$multiItems.length !== 1 ? 's' : ''}</span>
            <span class="fragment-preview" title={multiFragment($multiItems)}>{multiFragment($multiItems)}</span>
            <button class="clear-btn" onclick={clearMulti}>Clear</button>
          </div>
        {/if}
      </div>
    {/if}
  </div>

</div>

<style>
  .filter-panel {
    display: flex;
    flex-direction: column;
    width: 100%;
    font-family: var(--font-mono, monospace);
    font-size: 12px;
    color: var(--p-mid, #33cc33);
    background: var(--p-bg, #000a00);
    overflow-y: auto;
    overflow-x: hidden;
  }

  /* ── Section ── */
  .section {
    border-bottom: 1px solid var(--p-border, #003300);
  }

  .section.active > .section-header {
    border-left: 2px solid var(--p-border-2, #004d00);
    color: var(--p-mid, #33cc33);
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 4px;
    width: 100%;
    padding: 6px 8px;
    background: var(--p-bg-2, #001400);
    border: none;
    border-left: 2px solid transparent;
    color: var(--p-dim, #1a4d1a);
    font-family: var(--font-mono, monospace);
    font-size: 12px;
    text-align: left;
    cursor: pointer;
    transition: color 0.1s, border-color 0.1s;
  }

  .section-header:hover {
    color: var(--p-mid, #33cc33);
    border-left-color: var(--p-border-2, #004d00);
  }

  .label {
    flex: 1;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    letter-spacing: 0.05em;
  }

  /* Badge: translucent tint, no solid lime */
  .badge {
    background: rgba(51, 204, 51, 0.18);
    color: var(--p-mid, #33cc33);
    font-size: 10px;
    font-weight: bold;
    padding: 1px 4px;
    min-width: 16px;
    text-align: center;
    flex-shrink: 0;
    border: 1px solid rgba(51, 204, 51, 0.3);
  }

  .chevron {
    font-size: 10px;
    flex-shrink: 0;
    color: var(--p-dim, #1a4d1a);
  }

  /* ── Section body ── */
  .section-body {
    padding: 6px 8px 8px;
    background: var(--p-bg, #000a00);
    display: flex;
    flex-direction: column;
    gap: 5px;
    max-height: 300px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: var(--p-border-2, #004d00) transparent;
  }

  .section-body::-webkit-scrollbar { width: 3px; }
  .section-body::-webkit-scrollbar-thumb { background: var(--p-border-2, #004d00); }

  /* ── Presets ── */
  .presets-row {
    display: flex;
    flex-wrap: wrap;
    gap: 3px;
    padding-bottom: 5px;
    border-bottom: 1px solid var(--p-border, #003300);
  }

  .preset-btn {
    background: transparent;
    border: 1px solid var(--p-border, #003300);
    color: var(--p-dim, #1a4d1a);
    font-family: var(--font-mono, monospace);
    font-size: 11px;
    padding: 2px 5px;
    cursor: pointer;
    white-space: nowrap;
    transition: color 0.1s, border-color 0.1s, background 0.1s;
  }

  .preset-btn:hover {
    color: var(--p-mid, #33cc33);
    border-color: var(--p-border-2, #004d00);
    background: rgba(51, 204, 51, 0.06);
  }

  /* ── FT groups ── */
  .ft-group {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .group-label {
    font-size: 10px;
    color: var(--p-dim, #1a4d1a);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding-top: 2px;
  }

  .type-buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 3px;
  }

  .type-btn {
    background: transparent;
    border: 1px solid var(--p-border, #003300);
    color: var(--p-dim, #1a4d1a);
    font-family: var(--font-mono, monospace);
    font-size: 11px;
    padding: 2px 5px;
    cursor: pointer;
    transition: color 0.1s, border-color 0.1s, background 0.1s;
    white-space: nowrap;
  }

  .type-btn:hover {
    color: var(--p-mid, #33cc33);
    border-color: var(--p-border-2, #004d00);
    background: rgba(51, 204, 51, 0.06);
  }

  /* Selected: translucent tint only — no solid lime green */
  .type-btn.selected {
    background: rgba(51, 204, 51, 0.12);
    border-color: rgba(51, 204, 51, 0.4);
    color: var(--p-mid, #33cc33);
  }

  /* ── Textarea ── */
  .filter-textarea {
    width: 100%;
    box-sizing: border-box;
    background: var(--p-bg-2, #001400);
    border: 1px solid var(--p-border, #003300);
    border-radius: 0;
    color: var(--p-mid, #33cc33);
    font-family: var(--font-mono, monospace);
    font-size: 12px;
    padding: 5px 6px;
    resize: vertical;
    outline: none;
    caret-color: var(--p-mid, #33cc33);
  }

  .filter-textarea::placeholder {
    color: var(--p-dim, #1a4d1a);
    opacity: 0.7;
  }

  .filter-textarea:focus {
    border-color: var(--p-border-2, #004d00);
    background: rgba(51, 204, 51, 0.04);
  }

  /* ── Footer ── */
  .section-footer {
    display: flex;
    align-items: flex-start;
    gap: 5px;
    flex-wrap: wrap;
    padding-top: 4px;
    border-top: 1px solid var(--p-border, #003300);
  }

  .fragment-preview {
    flex: 1;
    font-size: 10px;
    color: var(--p-dim, #1a4d1a);
    word-break: break-all;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }

  .item-count {
    font-size: 10px;
    color: var(--p-dim, #1a4d1a);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .clear-btn {
    background: transparent;
    border: 1px solid var(--p-border, #003300);
    color: var(--p-dim, #1a4d1a);
    font-family: var(--font-mono, monospace);
    font-size: 10px;
    padding: 2px 6px;
    cursor: pointer;
    flex-shrink: 0;
    transition: color 0.1s, border-color 0.1s, background 0.1s;
  }

  .clear-btn:hover {
    color: var(--p-mid, #33cc33);
    border-color: var(--p-border-2, #004d00);
    background: rgba(51, 204, 51, 0.06);
  }
</style>
