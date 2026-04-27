import type { EngineId } from '../translation/types';

export interface EngineQueryOptions {
	maxResults?: number;
	page?: number;
	timeout?: number; // ms
}

export interface EngineQuery {
	engineId: EngineId;
	nativeQuery: string;
	apiKey?: string;
	options?: EngineQueryOptions;
}

export interface RawResultItem {
	url?: string;
	ip?: string;
	identifier?: string;
	title?: string;
	snippet?: string;
	metadata: Record<string, unknown>;
	timestamp: string;
}

export interface DispatchError {
	code: 'rate_limited' | 'auth_failed' | 'timeout' | 'anti_bot' | 'network' | 'unknown';
	message: string;
	retryAfter?: number; // Unix timestamp ms
}

export interface RawResult {
	engineId: EngineId;
	items: RawResultItem[];
	totalEstimated?: number;
	creditsUsed?: number;
	error?: DispatchError;
}

export interface EngineStatus {
	quotaUsed: number;
	quotaLimit: number;
	resetAt?: string; // ISO timestamp
	isRateLimited: boolean;
}

export interface WorkerPoolStatus {
	activeWorkers: number;
	queuedJobs: number;
	perEngineStatus: Partial<Record<EngineId, EngineStatus>>;
}
