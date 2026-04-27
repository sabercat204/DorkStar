/**
 * filter-store.ts
 *
 * Shared reactive state for the three query filters:
 *   - File type selector
 *   - Domain search
 *   - Multi-item search
 *
 * Lives here so both the sidebar FilterPanel and the QueryComposer
 * can read/write the same state without prop drilling.
 */

import { writable, derived } from 'svelte/store';
import { canonicalQuery } from './query-store';
import { get } from 'svelte/store';
import { emitCmd, cmd } from './cmd-log';

// ── Active panel ──────────────────────────────────────────────────────────────
export type FilterPanel = 'filetype' | 'domain' | 'multi' | null;
export const activeFilterPanel = writable<FilterPanel>(null);
export function toggleFilterPanel(p: FilterPanel) {
	activeFilterPanel.update(cur => cur === p ? null : p);
}

// ── File type ─────────────────────────────────────────────────────────────────
export const selectedFT = writable<Set<string>>(new Set());

export function toggleFT(ft: string) {
	let adding = false;
	selectedFT.update(s => {
		const next = new Set(s);
		adding = !next.has(ft);
		adding ? next.add(ft) : next.delete(ft);
		return next;
	});
	emitCmd(adding ? cmd.filetypeAdd(ft) : cmd.filetypeRemove(ft));
	applyFT();
}

export function clearFT() {
	selectedFT.set(new Set());
	emitCmd(cmd.filetypeClear());
	applyFT();
}

export function applyFT() {
	const types = [...get(selectedFT)];
	let base = get(canonicalQuery)
		.replace(/\(\s*filetype:[^)]+\)/gi, '')
		.replace(/filetype:\S+/gi, '')
		.trim();
	if (types.length === 0) { canonicalQuery.set(base); return; }
	const frag = types.length === 1
		? `filetype:${types[0]}`
		: `(${types.map(t => `filetype:${t}`).join(' OR ')})`;
	canonicalQuery.set(base ? `${base} ${frag}` : frag);
}

// ── Domain ────────────────────────────────────────────────────────────────────
export const domainInput = writable<string>('');

export const domains = derived(domainInput, ($d) =>
	$d.split(/[\n,]+/)
		.map(d => d.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, ''))
		.filter(d => d.length > 0)
);

export function applyDomains() {
	const ds = get(domains);
	let base = get(canonicalQuery)
		.replace(/\(\s*site:[^)]+\)/gi, '')
		.replace(/site:\S+/gi, '')
		.trim();
	if (ds.length === 0) { canonicalQuery.set(base); return; }
	const frag = ds.length === 1
		? `site:${ds[0]}`
		: `(${ds.map(d => `site:${d}`).join(' OR ')})`;
	canonicalQuery.set(base ? `${base} ${frag}` : frag);
	emitCmd(cmd.domainApply(ds));
}

export function removeDomain(domain: string) {
	const remaining = get(domains).filter(d => d !== domain);
	domainInput.set(remaining.join('\n'));
	applyDomains();
}

export function clearDomains() {
	domainInput.set('');
	emitCmd(cmd.domainClear());
	applyDomains();
}

// ── Multi-item ────────────────────────────────────────────────────────────────
export const multiInput = writable<string>('');

export const multiItems = derived(multiInput, ($m) =>
	$m.split('\n').map(l => l.trim()).filter(l => l.length > 0)
);

export function applyMulti() {
	const items = get(multiItems);
	let base = get(canonicalQuery)
		.replace(/\(\s*"[^"]*"(?:\s+OR\s+"[^"]*")+\s*\)/gi, '')
		.trim();
	if (items.length === 0) { canonicalQuery.set(base); return; }
	const frag = items.length === 1
		? `"${items[0]}"`
		: `(${items.map(t => `"${t}"`).join(' OR ')})`;
	canonicalQuery.set(base ? `${base} ${frag}` : frag);
	emitCmd(cmd.multiApply(items));
}

export function removeMultiItem(item: string) {
	const remaining = get(multiItems).filter(i => i !== item);
	multiInput.set(remaining.join('\n'));
	applyMulti();
}

export function clearMulti() {
	multiInput.set('');
	emitCmd(cmd.multiClear());
	applyMulti();
}
