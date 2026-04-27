import type { EngineQuery, RawResult, RawResultItem, DispatchError } from './types';
import { ENGINE_REGISTRY } from '../translation/adapters/registry';

// Listen for messages from the main thread
self.addEventListener('message', async (event: MessageEvent<EngineQuery>) => {
	const query = event.data;
	const result = await executeQuery(query);
	self.postMessage(result);
});

async function executeQuery(query: EngineQuery): Promise<RawResult> {
	// 1. Look up the engine's apiEndpoint from ENGINE_REGISTRY
	const entry = ENGINE_REGISTRY.find((e) => e.id === query.engineId);

	if (!entry || !entry.apiEndpoint) {
		// 2. If no apiEndpoint, return error result
		return {
			engineId: query.engineId,
			items: [],
			error: {
				code: 'unknown',
				message: `No API endpoint configured for engine: ${query.engineId}`
			}
		};
	}

	// 3. Build the fetch URL with the native query as a parameter
	const url = new URL(entry.apiEndpoint);
	url.searchParams.set('q', query.nativeQuery);

	if (query.options?.maxResults !== undefined) {
		url.searchParams.set('count', String(query.options.maxResults));
	}
	if (query.options?.page !== undefined) {
		url.searchParams.set('page', String(query.options.page));
	}

	// 4. Build headers — add Authorization if apiKey is provided
	const headers: Record<string, string> = {
		Accept: 'application/json'
	};
	if (query.apiKey) {
		headers['Authorization'] = `Bearer ${query.apiKey}`;
	}

	// 5. Execute fetch with timeout (default 15s)
	const timeoutMs = query.options?.timeout ?? 15_000;
	const controller = new AbortController();
	const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

	let response: Response;
	try {
		response = await fetch(url.toString(), {
			headers,
			signal: controller.signal
		});
	} catch (err: unknown) {
		clearTimeout(timeoutId);

		// Distinguish timeout from other network errors
		if (err instanceof DOMException && err.name === 'AbortError') {
			const dispatchError: DispatchError = {
				code: 'timeout',
				message: `Request to ${query.engineId} timed out after ${timeoutMs}ms`
			};
			return { engineId: query.engineId, items: [], error: dispatchError };
		}

		const dispatchError: DispatchError = {
			code: 'network',
			message: err instanceof Error ? err.message : 'Network error'
		};
		return { engineId: query.engineId, items: [], error: dispatchError };
	}

	clearTimeout(timeoutId);

	// 6. Map HTTP status codes to DispatchError
	if (!response.ok) {
		let dispatchError: DispatchError;

		if (response.status === 429) {
			// rate_limited — parse Retry-After header if present
			const retryAfterHeader = response.headers.get('Retry-After');
			let retryAfter: number | undefined;
			if (retryAfterHeader) {
				const parsed = parseInt(retryAfterHeader, 10);
				if (!isNaN(parsed)) {
					// Retry-After can be seconds-from-now or an HTTP date
					retryAfter = Date.now() + parsed * 1000;
				}
			}
			dispatchError = {
				code: 'rate_limited',
				message: `Rate limited by ${query.engineId}`,
				retryAfter
			};
		} else if (response.status === 401 || response.status === 403) {
			dispatchError = {
				code: 'auth_failed',
				message: `Authentication failed for ${query.engineId} (HTTP ${response.status})`
			};
		} else {
			dispatchError = {
				code: 'unknown',
				message: `Unexpected HTTP ${response.status} from ${query.engineId}`
			};
		}

		return { engineId: query.engineId, items: [], error: dispatchError };
	}

	// 7. On success: parse JSON response and map to RawResultItem[]
	let json: unknown;
	try {
		json = await response.json();
	} catch {
		return {
			engineId: query.engineId,
			items: [],
			error: {
				code: 'unknown',
				message: `Failed to parse JSON response from ${query.engineId}`
			}
		};
	}

	const items = extractItems(json);
	const totalEstimated = extractTotal(json);

	return {
		engineId: query.engineId,
		items,
		totalEstimated
	};
}

/**
 * Extract an array of raw items from a generic JSON response.
 * Looks for common array field names: items, results, matches, data.
 */
function extractItems(json: unknown): RawResultItem[] {
	if (!json || typeof json !== 'object') return [];

	const obj = json as Record<string, unknown>;

	// Find the first array field among common names
	const arrayFields = ['items', 'results', 'matches', 'data'];
	let rawArray: unknown[] | null = null;

	for (const field of arrayFields) {
		if (Array.isArray(obj[field])) {
			rawArray = obj[field] as unknown[];
			break;
		}
	}

	// If no named array found, check if the root itself is an array
	if (!rawArray && Array.isArray(json)) {
		rawArray = json as unknown[];
	}

	if (!rawArray) return [];

	return rawArray.map((item) => mapToRawResultItem(item));
}

/**
 * Map a single raw API response item to a RawResultItem.
 * Extracts url/ip/identifier, title, snippet from common field names.
 */
function mapToRawResultItem(item: unknown): RawResultItem {
	if (!item || typeof item !== 'object') {
		return {
			metadata: {},
			timestamp: new Date().toISOString()
		};
	}

	const obj = item as Record<string, unknown>;

	// Extract URL from common field names
	const url =
		stringField(obj, 'url') ??
		stringField(obj, 'link') ??
		stringField(obj, 'href') ??
		stringField(obj, 'uri') ??
		undefined;

	// Extract IP from common field names
	const ip =
		stringField(obj, 'ip') ??
		stringField(obj, 'ip_str') ??
		stringField(obj, 'ip_address') ??
		undefined;

	// Extract identifier from common field names
	const identifier =
		stringField(obj, 'identifier') ??
		stringField(obj, 'id') ??
		stringField(obj, 'hash') ??
		stringField(obj, 'sha256') ??
		undefined;

	// Extract title from common field names
	const title =
		stringField(obj, 'title') ??
		stringField(obj, 'name') ??
		stringField(obj, 'displayName') ??
		undefined;

	// Extract snippet from common field names
	const snippet =
		stringField(obj, 'snippet') ??
		stringField(obj, 'description') ??
		stringField(obj, 'summary') ??
		stringField(obj, 'abstract') ??
		stringField(obj, 'body') ??
		undefined;

	// Timestamp
	const timestamp =
		stringField(obj, 'timestamp') ??
		stringField(obj, 'date') ??
		stringField(obj, 'created_at') ??
		stringField(obj, 'updated_at') ??
		new Date().toISOString();

	return {
		url,
		ip,
		identifier,
		title,
		snippet,
		metadata: obj,
		timestamp
	};
}

/** Safely extract a string field from an object. */
function stringField(obj: Record<string, unknown>, key: string): string | null {
	const val = obj[key];
	return typeof val === 'string' ? val : null;
}

/** Try to extract a total count from the response. */
function extractTotal(json: unknown): number | undefined {
	if (!json || typeof json !== 'object' || Array.isArray(json)) return undefined;

	const obj = json as Record<string, unknown>;
	const totalFields = ['total', 'totalResults', 'total_results', 'count', 'hits', 'total_count'];

	for (const field of totalFields) {
		const val = obj[field];
		if (typeof val === 'number') return val;
		if (typeof val === 'string') {
			const parsed = parseInt(val, 10);
			if (!isNaN(parsed)) return parsed;
		}
	}

	return undefined;
}
