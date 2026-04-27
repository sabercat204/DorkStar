import type { EngineId } from '../translation/types';

export interface EngineAttribution {
	engineId: EngineId;
	originalUrl: string;
	rank: number;
	metadata: Record<string, unknown>;
}

export interface NormalizedResult {
	id: string; // deterministic hash of canonicalIdentifier
	canonicalIdentifier: string; // URL, IP, or domain
	title: string;
	snippet: string;
	engines: EngineAttribution[];
	score: number; // relevance score
	firstSeen: string; // ISO timestamp
	metadata: Record<string, unknown>;
}

export type ViewMode = 'unified' | 'by-engine' | 'deduplicated';

export interface DeduplicationStats {
	totalRaw: number;
	totalUnique: number;
	duplicatesRemoved: number;
}

export interface ResultSet {
	results: NormalizedResult[];
	viewMode: ViewMode;
	totalByEngine: Partial<Record<EngineId, number>>;
	deduplicationStats: DeduplicationStats;
}
