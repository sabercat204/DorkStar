import { openDB, type IDBPDatabase } from 'idb';
import type { EngineId } from '../translation/types';

const DB_NAME = 'dorkstar-keys';
const STORE_NAME = 'api-keys';
const DB_VERSION = 1;

async function getDB(): Promise<IDBPDatabase> {
	return openDB(DB_NAME, DB_VERSION, {
		upgrade(db) {
			if (!db.objectStoreNames.contains(STORE_NAME)) {
				db.createObjectStore(STORE_NAME);
			}
		}
	});
}

/**
 * Map from EngineId to its VITE_KEY_* environment variable name.
 * Keys configured via `npm run setup` are injected at build time.
 */
const ENV_KEY_MAP: Partial<Record<EngineId, string>> = {
	google:           'VITE_KEY_GOOGLE',
	bing:             'VITE_KEY_BING',
	shodan:           'VITE_KEY_SHODAN',
	censys:           'VITE_KEY_CENSYS',
	fofa:             'VITE_KEY_FOFA',
	zoomeye:          'VITE_KEY_ZOOMEYE',
	binaryedge:       'VITE_KEY_BINARYEDGE',
	onyphe:           'VITE_KEY_ONYPHE',
	leakix:           'VITE_KEY_LEAKIX',
	netlas:           'VITE_KEY_NETLAS',
	criminalip:       'VITE_KEY_CRIMINALIP',
	hunter:           'VITE_KEY_HUNTER',
	fullhunt:         'VITE_KEY_FULLHUNT',
	github:           'VITE_KEY_GITHUB',
	gitlab:           'VITE_KEY_GITLAB',
	sourcegraph:      'VITE_KEY_SOURCEGRAPH',
	virustotal:       'VITE_KEY_VIRUSTOTAL',
	urlscan:          'VITE_KEY_URLSCAN',
	alienvault:       'VITE_KEY_ALIENVAULT',
	pastebin:         'VITE_KEY_PASTEBIN',
	twitter:          'VITE_KEY_TWITTER',
	reddit:           'VITE_KEY_REDDIT',
	arxiv:            'VITE_KEY_ARXIV',
	semantic_scholar: 'VITE_KEY_SEMANTIC_SCHOLAR',
	pubmed:           'VITE_KEY_PUBMED',
};

/**
 * Read a VITE_KEY_* env var injected at build time by the setup wizard.
 * Returns null if not set or set to the literal string "none".
 */
function getEnvKey(engineId: EngineId): string | null {
	const envVar = ENV_KEY_MAP[engineId];
	if (!envVar) return null;
	// import.meta.env is replaced at build time by Vite
	const val = (import.meta.env as Record<string, string | undefined>)[envVar];
	if (!val || val === 'none' || val === '') return null;
	return val;
}

/**
 * Seed IndexedDB from build-time env vars on first access.
 * Only seeds if the key is not already in IndexedDB (user-set keys take priority).
 */
let seeded = false;
async function seedFromEnv(): Promise<void> {
	if (seeded) return;
	seeded = true;
	const db = await getDB();
	for (const engineId of Object.keys(ENV_KEY_MAP) as EngineId[]) {
		const envKey = getEnvKey(engineId);
		if (!envKey) continue;
		// Don't overwrite existing user-set keys
		const existing = await db.get(STORE_NAME, engineId);
		if (!existing) {
			await db.put(STORE_NAME, envKey, engineId);
		}
	}
}

/**
 * IndexedDB-backed key store for per-engine API keys.
 * Keys are stored exclusively in the browser's IndexedDB — never transmitted to any server.
 * On first load, keys configured via `npm run setup` (.env.keys) are seeded automatically.
 */
export const keyStore = {
	/**
	 * Retrieve the API key for the given engine, or null if not set.
	 */
	async getKey(engineId: EngineId): Promise<string | null> {
		await seedFromEnv();
		const db = await getDB();
		const value = await db.get(STORE_NAME, engineId);
		return typeof value === 'string' ? value : null;
	},

	/**
	 * Store or update the API key for the given engine.
	 */
	async setKey(engineId: EngineId, key: string): Promise<void> {
		await seedFromEnv();
		const db = await getDB();
		await db.put(STORE_NAME, key, engineId);
	},

	/**
	 * Remove the API key for the given engine.
	 */
	async deleteKey(engineId: EngineId): Promise<void> {
		const db = await getDB();
		await db.delete(STORE_NAME, engineId);
	},

	/**
	 * List all engine IDs that currently have a stored key.
	 */
	async listEnginesWithKeys(): Promise<EngineId[]> {
		await seedFromEnv();
		const db = await getDB();
		const keys = await db.getAllKeys(STORE_NAME);
		return keys as EngineId[];
	},

	/**
	 * Remove all stored API keys.
	 */
	async clearAll(): Promise<void> {
		const db = await getDB();
		await db.clear(STORE_NAME);
		seeded = false; // allow re-seeding from env on next access
	}
};
