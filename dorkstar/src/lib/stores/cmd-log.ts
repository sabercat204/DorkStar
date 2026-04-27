/**
 * cmd-log.ts
 *
 * Reactive command log for the VT100 vanity shell prompt.
 * Every UI interaction emits a shell-style command string here.
 * The QueryComposer shell block subscribes and displays the last command.
 */

import { writable, derived } from 'svelte/store';

export interface CmdEntry {
	/** The full command string to display, e.g. "dork --engine google --toggle on" */
	cmd: string;
	/** Timestamp for potential history display */
	ts: number;
}

// Ring buffer — keep last 50 commands for potential history view
const MAX_HISTORY = 50;

export const cmdHistory = writable<CmdEntry[]>([]);

/** The most recent command string (empty string = idle) */
export const lastCmd = derived(cmdHistory, ($h) => ($h.length > 0 ? $h[$h.length - 1].cmd : ''));

/**
 * Emit a new command to the log.
 * Call this from any UI interaction handler.
 */
export function emitCmd(cmd: string): void {
	cmdHistory.update((h) => {
		const next = [...h, { cmd, ts: Date.now() }];
		return next.length > MAX_HISTORY ? next.slice(-MAX_HISTORY) : next;
	});
}

// ── Pre-built command generators ─────────────────────────────────────────────
// These produce authentic csh/dork CLI syntax for each interaction type.

export const cmd = {
	/** Engine toggle on/off */
	engineToggle: (id: string, active: boolean) =>
		`dork --engine ${id} --${active ? 'enable' : 'disable'}`,

	/** Toggle all engines */
	engineAll: (enable: boolean) =>
		`dork --engines all --${enable ? 'enable' : 'disable'}`,

	/** Toggle a category */
	engineCategory: (cat: string, enable: boolean) =>
		`dork --category ${cat} --${enable ? 'enable' : 'disable'}`,

	/** Select all engines in a group */
	engineGroupSelect: (groupLabel: string, enable: boolean) =>
		`dork --group "${groupLabel}" --${enable ? 'select' : 'deselect'}`,

	/** Reorder engines */
	engineReorder: (from: string, to: string) =>
		`dork --reorder ${from} ${to}`,

	/** File type filter */
	filetypeAdd: (ft: string) =>
		`setenv DORK_FILETYPE ${ft}; dork --filetype ${ft}`,

	filetypeRemove: (ft: string) =>
		`unsetenv DORK_FILETYPE_${ft.toUpperCase()}`,

	filetypeClear: () =>
		`unsetenv DORK_FILETYPE; dork --filetype clear`,

	/** Domain filter */
	domainApply: (domains: string[]) =>
		domains.length === 0
			? `unsetenv DORK_SITE`
			: `setenv DORK_SITE "${domains.join(',')}"; dork --site ${domains.map(d => `"${d}"`).join(' ')}`,

	domainClear: () =>
		`unsetenv DORK_SITE`,

	/** Multi-item search */
	multiApply: (items: string[]) =>
		items.length === 0
			? `unsetenv DORK_TERMS`
			: `setenv DORK_TERMS ${items.length}; dork --terms ${items.map(t => `"${t}"`).join(' ')}`,

	multiClear: () =>
		`unsetenv DORK_TERMS`,

	/** Query execution */
	execute: (engineCount: number, query: string) => {
		const q = query.trim().slice(0, 48) + (query.trim().length > 48 ? '...' : '');
		return `dork --run --engines ${engineCount} --parallel -- "${q}"`;
	},

	/** View mode change */
	viewMode: (mode: string) =>
		`setenv DORK_VIEW ${mode.toUpperCase()}`,

	/** Per-engine mode toggle */
	modeToggle: (mode: string) =>
		`setenv DORK_MODE ${mode === 'per-engine' ? 'PER_ENGINE' : 'UNIFIED'}`,

	/** Clone & translate */
	cloneTranslate: (from: string, count: number) =>
		`dork --clone-from ${from} --translate-to ${count} engines`,

	/** Export */
	exportResults: (format: string, count: number) =>
		`dork --export ${format} --results ${count} > dorkstar-results.${format}`,

	/** Save to file */
	saveToFile: (format: string) =>
		`dork --save ${format} --picker`,

	/** Re-dork */
	redork: (identifier: string) => {
		const id = identifier.slice(0, 40) + (identifier.length > 40 ? '...' : '');
		return `dork --redork "${id}"`;
	},

	/** Pivot */
	pivot: (identifier: string) => {
		const id = identifier.slice(0, 40) + (identifier.length > 40 ? '...' : '');
		return `dork --pivot "${id}"`;
	},

	/** Open result */
	openResult: (url: string) => {
		const u = url.slice(0, 48) + (url.length > 48 ? '...' : '');
		return `open "${u}"`;
	},

	/** Browse engines panel */
	openBrowser: () =>
		`dork --list-engines --group-by use-case`,

	closeBrowser: () =>
		`exit`,

	/** Operator autocomplete insert */
	insertOperator: (op: string) =>
		`# operator: ${op}:`,
};
