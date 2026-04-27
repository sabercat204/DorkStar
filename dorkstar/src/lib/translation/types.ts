import type { CanonicalOperator } from '../parser/types';

/**
 * All 39 supported search engine identifiers.
 */
export type EngineId =
  // Web search engines
  | 'google'
  | 'bing'
  | 'yandex'
  | 'duckduckgo'
  | 'baidu'
  | 'yahoo'
  // IoT / network intelligence
  | 'shodan'
  | 'censys'
  | 'fofa'
  | 'zoomeye'
  | 'binaryedge'
  | 'onyphe'
  | 'leakix'
  | 'netlas'
  | 'criminalip'
  | 'hunter'
  | 'fullhunt'
  // Code search
  | 'github'
  | 'gitlab'
  | 'sourcegraph'
  | 'grep_app'
  // Threat intelligence
  | 'virustotal'
  | 'urlscan'
  | 'alienvault'
  | 'threatcrowd'
  // Paste / content search
  | 'pastebin'
  | 'gist'
  | 'publicwww'
  | 'grep_io'
  // Social
  | 'twitter'
  | 'reddit'
  | 'linkedin'
  // Academic
  | 'arxiv'
  | 'semantic_scholar'
  | 'pubmed'
  // Alternative web (Tier 3)
  | 'qwant'
  | 'ecosia'
  | 'seznam'
  | 'sogou';

/**
 * Runtime-accessible array of all 39 engine IDs.
 */
export const ALL_ENGINE_IDS: readonly EngineId[] = [
  'google',
  'bing',
  'yandex',
  'duckduckgo',
  'baidu',
  'yahoo',
  'shodan',
  'censys',
  'fofa',
  'zoomeye',
  'binaryedge',
  'onyphe',
  'leakix',
  'netlas',
  'criminalip',
  'hunter',
  'fullhunt',
  'github',
  'gitlab',
  'sourcegraph',
  'grep_app',
  'virustotal',
  'urlscan',
  'alienvault',
  'threatcrowd',
  'pastebin',
  'gist',
  'publicwww',
  'grep_io',
  'twitter',
  'reddit',
  'linkedin',
  'arxiv',
  'semantic_scholar',
  'pubmed',
  'qwant',
  'ecosia',
  'seznam',
  'sogou',
] as const;

/**
 * Classification of search engines by domain.
 */
export type EngineCategory = 'web' | 'iot' | 'code' | 'threat' | 'paste' | 'social' | 'academic';

/**
 * Warning emitted when a canonical operator cannot be fully represented
 * in a target engine's native query syntax.
 */
export interface DegradationWarning {
  operator: CanonicalOperator;
  reason: 'unsupported' | 'partial' | 'approximated';
  message: string;
}

/**
 * The result of translating an AST to a single engine's native query syntax.
 */
export interface TranslationResult {
  engineId: EngineId;
  nativeQuery: string;
  degradations: DegradationWarning[];
  isFullySupported: boolean;
}

/**
 * Per-engine rate limit configuration for the token-bucket rate limiter.
 */
export interface RateLimitConfig {
  requestsPerMinute: number;
  requestsPerDay?: number;
  burstLimit?: number;
}

/**
 * Describes the credit cost model for engines that charge per query or result page.
 */
export interface CreditModel {
  /** Human-readable unit name, e.g. "query" or "result_page". */
  unit: string;
  /** Cost per unit (e.g. 1 credit per query). */
  costPerUnit: number;
  /** When true, the UI must show a confirmation dialog before dispatching. */
  requiresConfirmation: boolean;
}

/**
 * Full metadata entry for a registered search engine.
 */
export interface EngineRegistryEntry {
  id: EngineId;
  displayName: string;
  category: EngineCategory;
  tier: 1 | 2 | 3;
  baseUrl: string;
  apiEndpoint?: string;
  docsUrl: string;
  supportedOperators: CanonicalOperator[];
  operatorCount: number;
  requiresKey: boolean;
  creditModel?: CreditModel;
  rateLimit: RateLimitConfig;
}
