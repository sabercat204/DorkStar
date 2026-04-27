import { writable, get } from 'svelte/store';
import type { ResultSet, ViewMode } from '../results/types';
import type { WorkerPoolStatus } from '../dispatch/types';
import { WorkerPool } from '../dispatch/worker-pool';
import { ResultNormalizer } from '../results/normalizer';
import { keyStore } from '../keystore/index';
import { activeEngines } from './engine-store';
import { translations, canonicalQuery } from './query-store';
import { emitCmd, cmd } from './cmd-log';
import { ENGINE_REGISTRY } from '../translation/adapters/registry';

const normalizer = new ResultNormalizer();

// Lazy-initialize worker pool (only in browser)
let workerPool: WorkerPool | null = null;

function getWorkerPool(): WorkerPool {
	if (!workerPool) {
		workerPool = new WorkerPool(async (engineId, cost) => {
			// Default credit confirmation: show browser confirm dialog
			if (typeof window !== 'undefined') {
				return window.confirm(
					`This query will consume ${cost} credit(s) on ${engineId}. Proceed?`
				);
			}
			return false;
		});
	}
	return workerPool;
}

export const resultSet = writable<ResultSet | null>(null);
export const isLoading = writable<boolean>(false);
export const viewMode = writable<ViewMode>('unified');
export const workerStatus = writable<WorkerPoolStatus>({
	activeWorkers: 0,
	queuedJobs: 0,
	perEngineStatus: {}
});

/** Structured query error — displayed in the results panel */
export interface QueryError {
	code: 'NO_ENGINES' | 'NO_QUERY' | 'NO_KEYS' | 'DISPATCH_FAILED' | 'PARSE_ERROR';
	title: string;
	detail: string;
	steps: string[];
}

export const queryError = writable<QueryError | null>(null);

/** Set view mode and emit a shell command */
export function setViewMode(mode: ViewMode): void {
	viewMode.set(mode);
	emitCmd(cmd.viewMode(mode));
}

export async function executeQuery(): Promise<void> {
	const $translations = get(translations);
	const $activeEngines = get(activeEngines);
	const $query = get(canonicalQuery);

	// ── Pre-flight checks ─────────────────────────────────────────────────────

	if ($activeEngines.length === 0) {
		queryError.set({
			code: 'NO_ENGINES',
			title: 'ERROR: No engines selected',
			detail: 'Query aborted — no search engines are active. At least one engine must be enabled before executing a query.',
			steps: [
				'1. Open the left sidebar engine list',
				'2. Click a category (Web, IoT, Code, etc.) to expand it',
				'3. Click one or more engine names to activate them',
				'4. Re-run your query',
			],
		});
		resultSet.set(null);
		return;
	}

	if (!$query || !$query.trim()) {
		queryError.set({
			code: 'NO_QUERY',
			title: 'ERROR: Empty query',
			detail: 'Query aborted — no search terms were entered.',
			steps: [
				'1. Type a query in the terminal input at the bottom',
				'2. Example: site:example.com filetype:pdf',
				'3. Press Enter or click ▶ RUN',
			],
		});
		resultSet.set(null);
		return;
	}

	// Check if any active engine has a key configured (Tier 1/2 engines require keys)
	const enginesWithKeys = await keyStore.listEnginesWithKeys();
	// Tier 3 engines don't need keys — check if all active engines are Tier 3
	const hasNonTier3Active = $activeEngines.some(id => {
		const entry = ENGINE_REGISTRY.find(e => e.id === id);
		return entry && entry.tier !== 3;
	});

	if (enginesWithKeys.length === 0 && hasNonTier3Active) {
		queryError.set({
			code: 'NO_KEYS',
			title: 'WARNING: No API keys configured',
			detail: 'No API keys are stored. Tier 1/2 engines require API keys to return results. Tier 3 engines (Qwant, Ecosia, Seznam, Sogou) will be attempted via headless browser but may be blocked.',
			steps: [
				'1. Run: node scripts/setup.js  (interactive API key wizard)',
				'2. Or run: npm run setup',
				'3. Configure keys for the engines you want to use',
				'4. Keys are stored locally in .env.keys — never sent to any server',
				'5. Re-run your query after setup',
			],
		});
		// Don't abort — still attempt dispatch (Tier 3 may work)
	} else {
		queryError.set(null);
	}

	emitCmd(cmd.execute($activeEngines.length, $query));
	isLoading.set(true);

	try {
		const pool = getWorkerPool();
		const $viewMode = get(viewMode);

		// Build engine queries with API keys from keyStore
		const engineQueries = await Promise.all(
			$translations.map(async (t) => ({
				engineId: t.engineId,
				nativeQuery: t.nativeQuery,
				apiKey: (await keyStore.getKey(t.engineId)) ?? undefined
			}))
		);

		// Dispatch all queries in parallel
		const rawResults = await pool.dispatch(engineQueries);

		// Update worker status
		workerStatus.set(pool.getStatus());

		// Normalize results
		const normalized = normalizer.normalize(rawResults, $viewMode);
		resultSet.set(normalized);
	} catch (err) {
		console.error('Query execution failed:', err);
		queryError.set({
			code: 'DISPATCH_FAILED',
			title: 'ERROR: Query execution failed',
			detail: err instanceof Error ? err.message : String(err),
			steps: [
				'1. Check your network connection',
				'2. Verify API keys are valid (run: node scripts/setup.js --check)',
				'3. Check browser DevTools → Network for failed requests',
				'4. Try with fewer engines active',
			],
		});
	} finally {
		isLoading.set(false);
	}
}
