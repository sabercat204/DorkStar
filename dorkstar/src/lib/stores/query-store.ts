import { writable, derived } from 'svelte/store';
import type { EngineId } from '../translation/types';
import type { ASTNode, ParseError } from '../parser/types';
import type { TranslationResult } from '../translation/types';
import { parseQuery } from '../parser/index';
import { TranslationManager } from '../translation/manager';
import { adapterRegistry } from '../translation/adapters/registry';
import { activeEngines } from './engine-store';

const translationManager = new TranslationManager(adapterRegistry);

export type QueryMode = 'unified' | 'per-engine';

export const canonicalQuery = writable<string>('');
export const mode = writable<QueryMode>('unified');
export const perEngineQueries = writable<Partial<Record<EngineId, string>>>({});

// Derived: parse the canonical query reactively
export const parseResult = derived(canonicalQuery, ($query) => {
	return parseQuery($query);
});

export const ast = derived(parseResult, ($result) => $result.ast as ASTNode | null);
export const parseErrors = derived(parseResult, ($result) => $result.errors as ParseError[]);

// Derived: translate AST to all active engines reactively
export const translations = derived(
	[ast, activeEngines],
	([$ast, $activeEngines]) => {
		if (!$ast || $activeEngines.length === 0) return [] as TranslationResult[];
		try {
			return translationManager.translateAll($ast, $activeEngines);
		} catch {
			return [] as TranslationResult[];
		}
	}
);
