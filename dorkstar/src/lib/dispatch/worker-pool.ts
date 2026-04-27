import type { EngineQuery, RawResult, WorkerPoolStatus, EngineStatus } from './types';
import type { EngineId } from '../translation/types';
import { ENGINE_REGISTRY } from '../translation/adapters/registry';
import { TokenBucketRateLimiter, createRateLimiter } from './rate-limiter';

export type CreditConfirmCallback = (
	engineId: EngineId,
	estimatedCost: number
) => Promise<boolean>;

export class WorkerPool {
	private rateLimiters: Map<EngineId, TokenBucketRateLimiter>;
	private engineStatus: Map<EngineId, EngineStatus>;
	private activeWorkers: number = 0;
	private queuedJobs: number = 0;
	private creditConfirmCallback?: CreditConfirmCallback;

	constructor(creditConfirmCallback?: CreditConfirmCallback) {
		this.creditConfirmCallback = creditConfirmCallback;

		// Initialize rate limiters for all 39 engines from ENGINE_REGISTRY
		this.rateLimiters = new Map<EngineId, TokenBucketRateLimiter>();
		this.engineStatus = new Map<EngineId, EngineStatus>();

		for (const entry of ENGINE_REGISTRY) {
			this.rateLimiters.set(entry.id, createRateLimiter(entry.rateLimit));
			this.engineStatus.set(entry.id, {
				quotaUsed: 0,
				quotaLimit: entry.rateLimit.requestsPerMinute,
				resetAt: undefined,
				isRateLimited: false
			});
		}
	}

	async dispatch(queries: EngineQuery[]): Promise<RawResult[]> {
		if (queries.length === 0) return [];

		// 1. For each query that requires credit confirmation, check with callback
		const confirmedQueries = await this.filterByCredit(queries);

		// 2. Execute ALL queries concurrently using Promise.all
		this.queuedJobs += confirmedQueries.length;

		const results = await Promise.all(
			confirmedQueries.map((item) => this.dispatchSingle(item.query, item.skip))
		);

		this.queuedJobs = Math.max(0, this.queuedJobs - confirmedQueries.length);

		return results;
	}

	async dispatchOne(query: EngineQuery): Promise<RawResult> {
		return (await this.dispatch([query]))[0];
	}

	private async filterByCredit(
		queries: EngineQuery[]
	): Promise<Array<{ query: EngineQuery; skip: boolean }>> {
		return Promise.all(
			queries.map(async (query) => {
				const entry = ENGINE_REGISTRY.find((e) => e.id === query.engineId);
				const requiresConfirmation = entry?.creditModel?.requiresConfirmation === true;

				if (requiresConfirmation && this.creditConfirmCallback) {
					const estimatedCost = entry?.creditModel?.costPerUnit ?? 1;
					const confirmed = await this.creditConfirmCallback(query.engineId, estimatedCost);
					return { query, skip: !confirmed };
				}

				return { query, skip: false };
			})
		);
	}

	private async dispatchSingle(
		query: EngineQuery,
		skip: boolean
	): Promise<RawResult> {
		// If credit was denied, return empty result
		if (skip) {
			return {
				engineId: query.engineId,
				items: [],
				error: {
					code: 'unknown',
					message: 'Query cancelled: credit confirmation denied'
				}
			};
		}

		// 3. Acquire rate limiter token before dispatching
		const rateLimiter = this.rateLimiters.get(query.engineId);
		if (rateLimiter) {
			await rateLimiter.acquire();
		}

		this.activeWorkers++;

		let result: RawResult;
		try {
			// 4. Route Tier 1/2 engines to Web Worker, Tier 3 to Playwright endpoint
			const entry = ENGINE_REGISTRY.find((e) => e.id === query.engineId);
			const tier = entry?.tier ?? 1;

			if (tier === 3) {
				result = await this.dispatchViaPlaywright(query);
			} else {
				result = await this.dispatchViaWorker(query);
			}
		} finally {
			this.activeWorkers = Math.max(0, this.activeWorkers - 1);
		}

		// 6. Update engineStatus after each dispatch
		this.updateEngineStatus(query.engineId, result);

		return result;
	}

	private async dispatchViaWorker(query: EngineQuery): Promise<RawResult> {
		// In SSR/non-browser environments, fall back to direct fetch
		if (typeof Worker === 'undefined') {
			return this.dispatchViaDirectFetch(query);
		}

		return new Promise<RawResult>((resolve) => {
			let worker: Worker;

			try {
				// Create a new Worker from engine.worker.ts
				// Vite handles the URL transformation for module workers
				worker = new Worker(new URL('./engine.worker.ts', import.meta.url), {
					type: 'module'
				});
			} catch {
				// Worker creation failed — fall back to direct fetch
				resolve(this.dispatchViaDirectFetch(query));
				return;
			}

			// Post the query, wait for response, terminate worker
			worker.onmessage = (event: MessageEvent<RawResult>) => {
				worker.terminate();
				resolve(event.data);
			};

			worker.onerror = (err: ErrorEvent) => {
				worker.terminate();
				resolve({
					engineId: query.engineId,
					items: [],
					error: {
						code: 'unknown',
						message: `Worker error: ${err.message}`
					}
				});
			};

			worker.postMessage(query);
		});
	}

	/**
	 * Direct fetch fallback for SSR environments where Web Workers are unavailable.
	 */
	private async dispatchViaDirectFetch(query: EngineQuery): Promise<RawResult> {
		const entry = ENGINE_REGISTRY.find((e) => e.id === query.engineId);

		if (!entry?.apiEndpoint) {
			return {
				engineId: query.engineId,
				items: [],
				error: {
					code: 'unknown',
					message: `No API endpoint configured for engine: ${query.engineId}`
				}
			};
		}

		const url = new URL(entry.apiEndpoint);
		url.searchParams.set('q', query.nativeQuery);

		const headers: Record<string, string> = { Accept: 'application/json' };
		if (query.apiKey) {
			headers['Authorization'] = `Bearer ${query.apiKey}`;
		}

		const timeoutMs = query.options?.timeout ?? 15_000;
		const controller = new AbortController();
		const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

		try {
			const response = await fetch(url.toString(), {
				headers,
				signal: controller.signal
			});
			clearTimeout(timeoutId);

			if (!response.ok) {
				if (response.status === 429) {
					return {
						engineId: query.engineId,
						items: [],
						error: { code: 'rate_limited', message: `Rate limited by ${query.engineId}` }
					};
				}
				if (response.status === 401 || response.status === 403) {
					return {
						engineId: query.engineId,
						items: [],
						error: {
							code: 'auth_failed',
							message: `Auth failed for ${query.engineId}`
						}
					};
				}
				return {
					engineId: query.engineId,
					items: [],
					error: {
						code: 'unknown',
						message: `HTTP ${response.status} from ${query.engineId}`
					}
				};
			}

			const data = await response.json();
			return {
				engineId: query.engineId,
				items: Array.isArray(data?.items) ? data.items : [],
				totalEstimated: data?.total
			};
		} catch (err: unknown) {
			clearTimeout(timeoutId);
			const isTimeout = err instanceof DOMException && err.name === 'AbortError';
			return {
				engineId: query.engineId,
				items: [],
				error: {
					code: isTimeout ? 'timeout' : 'network',
					message: err instanceof Error ? err.message : 'Network error'
				}
			};
		}
	}

	private async dispatchViaPlaywright(query: EngineQuery): Promise<RawResult> {
		// POST to /api/dispatch with the query as JSON body
		try {
			const response = await fetch('/api/dispatch', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(query)
			});

			if (!response.ok) {
				return {
					engineId: query.engineId,
					items: [],
					error: {
						code: 'network',
						message: `Playwright endpoint returned HTTP ${response.status}`
					}
				};
			}

			// Parse response as RawResult
			const result: RawResult = await response.json();
			return result;
		} catch (err: unknown) {
			// Handle fetch errors as DispatchError { code: 'network' }
			return {
				engineId: query.engineId,
				items: [],
				error: {
					code: 'network',
					message: err instanceof Error ? err.message : 'Failed to reach Playwright endpoint'
				}
			};
		}
	}

	/** Update engine status after a dispatch completes. */
	private updateEngineStatus(engineId: EngineId, result: RawResult): void {
		const current = this.engineStatus.get(engineId);
		if (!current) return;

		const updated: EngineStatus = {
			...current,
			quotaUsed: current.quotaUsed + 1,
			isRateLimited: result.error?.code === 'rate_limited'
		};

		if (result.error?.code === 'rate_limited' && result.error.retryAfter) {
			updated.resetAt = new Date(result.error.retryAfter).toISOString();
		}

		if (result.creditsUsed !== undefined) {
			updated.quotaUsed = current.quotaUsed + result.creditsUsed;
		}

		this.engineStatus.set(engineId, updated);
	}

	getStatus(): WorkerPoolStatus {
		return {
			activeWorkers: this.activeWorkers,
			queuedJobs: this.queuedJobs,
			perEngineStatus: Object.fromEntries(this.engineStatus) as Partial<
				Record<EngineId, EngineStatus>
			>
		};
	}

	shutdown(): void {
		// Reset counters — active workers are self-terminating
		this.activeWorkers = 0;
		this.queuedJobs = 0;
	}
}

export function createWorkerPool(creditConfirmCallback?: CreditConfirmCallback): WorkerPool {
	return new WorkerPool(creditConfirmCallback);
}
