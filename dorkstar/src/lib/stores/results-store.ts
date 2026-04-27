import { writable, get } from 'svelte/store';
import type { ResultSet, ViewMode } from '../results/types';
import type { WorkerPoolStatus } from '../dispatch/types';
import { WorkerPool } from '../dispatch/worker-pool';
import { ResultNormalizer } from '../results/normalizer';
import { keyStore } from '../keystore/index';
import { activeEngines } from './engine-store';
import { translations, canonicalQuery } from './query-store';
import { emitCmd, cmd } from './cmd-log';

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

/** Set view mode and emit a shell command */
export function setViewMode(mode: ViewMode): void {
	viewMode.set(mode);
	emitCmd(cmd.viewMode(mode));
}

export async function executeQuery(): Promise<void> {
	const $translations = get(translations);
	const $activeEngines = get(activeEngines);
	const $query = get(canonicalQuery);

	if ($translations.length === 0 || $activeEngines.length === 0) return;

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
	} finally {
		isLoading.set(false);
	}
}
