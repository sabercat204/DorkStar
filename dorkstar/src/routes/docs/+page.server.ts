import type { PageServerLoad } from './$types';
import { ENGINE_REGISTRY } from '$lib/translation/adapters/registry';
import { ALL_CANONICAL_OPERATORS } from '$lib/parser/types';
import type { CanonicalOperator } from '$lib/parser/types';
import type { EngineId } from '$lib/translation/types';

/**
 * Operator groups for display in the /docs reference table.
 * Each group has a label and the set of operators that belong to it.
 */
const OPERATOR_GROUPS: { label: string; operators: CanonicalOperator[] }[] = [
  {
    label: 'Web / Content',
    operators: [
      'site', 'filetype', 'ext', 'intitle', 'allintitle',
      'inurl', 'allinurl', 'intext', 'allintext', 'inbody',
      'inanchor', 'allinanchor', 'inpage', 'url', 'domain',
      'host', 'mime', 'related', 'cache', 'define',
      'source', 'feed', 'hasfeed', 'contains', 'prefer',
    ],
  },
  {
    label: 'Network / IoT',
    operators: [
      'ip', 'port', 'hostname', 'org', 'asn', 'net',
      'country', 'city', 'os', 'product', 'version', 'vuln',
      'ssl.jarm', 'ssl.ja3s', 'http.favicon.hash', 'has_screenshot',
      'rhost', 'cidr', 'banner', 'service', 'protocol', 'jarm',
      'http.title', 'http.body', 'is_vulnerability', 'tag', 'tech',
      'app', 'ver', 'device',
      'services.port', 'services.http.response.html_title',
    ],
  },
  {
    label: 'Language / Locale',
    operators: ['lang', 'language', 'loc', 'location'],
  },
  {
    label: 'Code Search',
    operators: ['repo', 'user', 'path', 'content', 'symbol'],
  },
  {
    label: 'Social',
    operators: [
      'author', 'subreddit', 'flair', 'self', 'selftext', 'title',
      'from', 'to', 'filter', 'since', 'until',
      'min_retweets', 'min_faves', 'min_replies',
    ],
  },
  {
    label: 'Date',
    operators: ['before', 'after', 'daterange', 'date'],
  },
  {
    label: 'Threat Intelligence',
    operators: ['classification', 'actor', 'tags', 'cve', 'labels'],
  },
  {
    label: 'Academic',
    operators: ['fieldsOfStudy', 'venue', 'minCitationCount', 'matchType'],
  },
  {
    label: 'API / Query Control',
    operators: ['output', 'fl', 'limit', 'collapse'],
  },
];

/**
 * A single row in the operator coverage matrix.
 */
export interface OperatorRow {
  operator: CanonicalOperator;
  /** Map from engineId → true if supported */
  support: Partial<Record<EngineId, boolean>>;
  /** Number of engines that support this operator */
  supportCount: number;
}

/**
 * A group of operator rows with a display label.
 */
export interface OperatorGroup {
  label: string;
  rows: OperatorRow[];
}

export interface PageData {
  /** Ordered list of engine IDs for column headers */
  engineIds: EngineId[];
  /** Engine display names keyed by ID */
  engineNames: Record<EngineId, string>;
  /** Engine docs URLs keyed by ID */
  engineDocs: Record<EngineId, string>;
  /** Engine category keyed by ID */
  engineCategories: Record<EngineId, string>;
  /** Operator groups with per-engine support matrix */
  groups: OperatorGroup[];
  /** Total canonical operators */
  totalOperators: number;
  /** Total engines */
  totalEngines: number;
}

export const load: PageServerLoad = (): PageData => {
  // Build ordered engine list from registry
  const engineIds = ENGINE_REGISTRY.map((e) => e.id);

  const engineNames = Object.fromEntries(
    ENGINE_REGISTRY.map((e) => [e.id, e.displayName])
  ) as Record<EngineId, string>;

  const engineDocs = Object.fromEntries(
    ENGINE_REGISTRY.map((e) => [e.id, e.docsUrl])
  ) as Record<EngineId, string>;

  const engineCategories = Object.fromEntries(
    ENGINE_REGISTRY.map((e) => [e.id, e.category])
  ) as Record<EngineId, string>;

  // Build a fast lookup: engineId → Set<CanonicalOperator>
  const supportMap = new Map<EngineId, Set<CanonicalOperator>>();
  for (const entry of ENGINE_REGISTRY) {
    supportMap.set(entry.id, new Set(entry.supportedOperators));
  }

  // Build operator groups with support matrix
  const coveredOperators = new Set<CanonicalOperator>();

  const groups: OperatorGroup[] = OPERATOR_GROUPS.map(({ label, operators }) => {
    const rows: OperatorRow[] = operators.map((op) => {
      coveredOperators.add(op);
      const support: Partial<Record<EngineId, boolean>> = {};
      let supportCount = 0;
      for (const engineId of engineIds) {
        const supported = supportMap.get(engineId)?.has(op) ?? false;
        if (supported) {
          support[engineId] = true;
          supportCount++;
        }
      }
      return { operator: op, support, supportCount };
    });
    return { label, rows };
  });

  // Append any operators not covered by the groups above (safety net)
  const uncovered = ALL_CANONICAL_OPERATORS.filter((op) => !coveredOperators.has(op));
  if (uncovered.length > 0) {
    const rows: OperatorRow[] = uncovered.map((op) => {
      const support: Partial<Record<EngineId, boolean>> = {};
      let supportCount = 0;
      for (const engineId of engineIds) {
        const supported = supportMap.get(engineId)?.has(op) ?? false;
        if (supported) {
          support[engineId] = true;
          supportCount++;
        }
      }
      return { operator: op, support, supportCount };
    });
    groups.push({ label: 'Other', rows });
  }

  return {
    engineIds,
    engineNames,
    engineDocs,
    engineCategories,
    groups,
    totalOperators: ALL_CANONICAL_OPERATORS.length,
    totalEngines: ENGINE_REGISTRY.length,
  };
};
