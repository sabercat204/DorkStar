import type { RawResult } from '../dispatch/types';
import type { NormalizedResult, ResultSet, ViewMode } from './types';
import type { EngineId } from '../translation/types';

/**
 * Normalize a URL or identifier to a canonical form for deduplication.
 * - Lowercases scheme+host
 * - Strips trailing slash
 * - Removes UTM parameters
 */
export function canonicalKey(identifier: string): string {
	return identifier
		.toLowerCase()
		.replace(/\/$/, '')
		.replace(/[?&]utm_[^&]*/g, '')
		.replace(/[?&]$/, '');
}

/**
 * Simple djb2-style hash returning a hex string.
 * Not cryptographic — used only for deterministic IDs.
 */
function simpleHash(str: string): string {
	let hash = 5381;
	for (let i = 0; i < str.length; i++) {
		// hash * 33 + charCode
		hash = ((hash << 5) + hash) ^ str.charCodeAt(i);
		// Keep within 32-bit signed integer range
		hash = hash | 0;
	}
	// Convert to unsigned 32-bit hex
	return (hash >>> 0).toString(16).padStart(8, '0');
}

export class ResultNormalizer {
	/**
	 * Normalize raw engine results into a unified ResultSet.
	 */
	normalize(rawResults: RawResult[], viewMode: ViewMode = 'unified'): ResultSet {
		// 1. Count totalRaw and totalByEngine
		let totalRaw = 0;
		const totalByEngine: Partial<Record<EngineId, number>> = {};

		for (const raw of rawResults) {
			const count = raw.items.length;
			totalRaw += count;
			totalByEngine[raw.engineId] = count;
		}

		// 2. Convert each RawResultItem to NormalizedResult
		const flat: NormalizedResult[] = [];

		for (const raw of rawResults) {
			const { engineId, items } = raw;
			for (let index = 0; index < items.length; index++) {
				const item = items[index];
				const canonicalIdentifier = item.url ?? item.ip ?? item.identifier ?? '';
				const id = simpleHash(canonicalIdentifier);

				const normalized: NormalizedResult = {
					id,
					canonicalIdentifier,
					title: item.title ?? '',
					snippet: item.snippet ?? '',
					engines: [
						{
							engineId,
							originalUrl: item.url ?? '',
							rank: index,
							metadata: item.metadata
						}
					],
					score: 1,
					firstSeen: item.timestamp,
					metadata: item.metadata
				};

				flat.push(normalized);
			}
		}

		// 3. Deduplicate
		const deduped = this.deduplicate(flat);
		const totalUnique = deduped.length;

		return {
			results: deduped,
			viewMode,
			totalByEngine,
			deduplicationStats: {
				totalRaw,
				totalUnique,
				duplicatesRemoved: totalRaw - totalUnique
			}
		};
	}

	/**
	 * Deduplicate a flat list of NormalizedResults by canonicalIdentifier.
	 * Merges engine attributions for duplicates and re-scores.
	 * Returns sorted by score descending.
	 *
	 * Invariants:
	 *   - output.length <= input.length
	 *   - each canonicalIdentifier unique in output
	 *   - every EngineAttribution from input appears in exactly one output entry
	 *   - every output entry has engines.length >= 1
	 */
	deduplicate(results: NormalizedResult[]): NormalizedResult[] {
		const seen = new Map<string, NormalizedResult>();

		for (const result of results) {
			const key = canonicalKey(result.canonicalIdentifier);

			if (seen.has(key)) {
				const existing = seen.get(key)!;
				// Merge attributions
				existing.engines.push(...result.engines);
				// Re-score with merged attributions
				existing.score = this.score(existing);
			} else {
				// Clone to avoid mutating the input
				seen.set(key, {
					...result,
					engines: [...result.engines]
				});
			}
		}

		// Score all entries (including non-duplicates) and sort descending
		const output = Array.from(seen.values());
		for (const entry of output) {
			entry.score = this.score(entry);
		}

		return output.sort((a, b) => b.score - a.score);
	}

	/**
	 * Score a result based on engine attribution count and recency.
	 *
	 * score = engines.length * recencyWeight
	 * recencyWeight:
	 *   - within last hour:  1.0
	 *   - within last day:   0.8
	 *   - within last week:  0.6
	 *   - older:             0.4
	 */
	score(result: NormalizedResult): number {
		const now = Date.now();
		const firstSeen = new Date(result.firstSeen).getTime();
		const ageMs = now - firstSeen;

		const HOUR = 60 * 60 * 1000;
		const DAY = 24 * HOUR;
		const WEEK = 7 * DAY;

		let recencyWeight: number;
		if (ageMs <= HOUR) {
			recencyWeight = 1.0;
		} else if (ageMs <= DAY) {
			recencyWeight = 0.8;
		} else if (ageMs <= WEEK) {
			recencyWeight = 0.6;
		} else {
			recencyWeight = 0.4;
		}

		return result.engines.length * recencyWeight;
	}
}
