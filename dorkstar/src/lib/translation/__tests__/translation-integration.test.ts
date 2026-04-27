/**
 * Translation Layer Integration Tests
 *
 * End-to-end flow: parseQuery() → translateAll() / translateFrom()
 * Verifies:
 *   - All 39 TranslationResult objects returned with correct engineIds
 *   - translateFrom propagation produces no missing results
 *   - Degradation warnings surface for known unsupported operators
 *   - isFullySupported consistency
 *
 * Requirements: 2.1, 2.2, 2.3, 2.4, 2.7, 2.8
 */

import { describe, it, expect } from 'vitest';
import { parseQuery } from '../../parser/index';
import { TranslationManager } from '../manager';
import { adapterRegistry } from '../adapters/registry';
import { ALL_ENGINE_IDS } from '../types';
import type { EngineId } from '../types';

// ─── Shared manager instance ─────────────────────────────────────────────────

const manager = new TranslationManager(adapterRegistry);

// ─── Helper: parse and assert no fatal errors ─────────────────────────────────

function parseOrThrow(query: string) {
  const result = parseQuery(query);
  if (!result.ast) {
    throw new Error(`Failed to parse query: "${query}". Errors: ${JSON.stringify(result.errors)}`);
  }
  return result.ast;
}

// ─── 1. translateAll — count and order invariant ──────────────────────────────

describe('translateAll — count and order invariant', () => {
  it('returns exactly 39 results for all engines', () => {
    const ast = parseOrThrow('site:example.com');
    const results = manager.translateAll(ast, [...ALL_ENGINE_IDS]);

    expect(results).toHaveLength(ALL_ENGINE_IDS.length);
    results.forEach((r, i) => {
      expect(r.engineId).toBe(ALL_ENGINE_IDS[i]);
    });
  });

  it('returns exactly N results for a subset of engines', () => {
    const subset: EngineId[] = ['google', 'shodan', 'github'];
    const ast = parseOrThrow('port:443');
    const results = manager.translateAll(ast, subset);

    expect(results).toHaveLength(3);
    expect(results[0].engineId).toBe('google');
    expect(results[1].engineId).toBe('shodan');
    expect(results[2].engineId).toBe('github');
  });

  it('each result has a non-null degradations array', () => {
    const ast = parseOrThrow('intext:password');
    const results = manager.translateAll(ast, [...ALL_ENGINE_IDS]);

    for (const r of results) {
      expect(r.degradations).toBeDefined();
      expect(Array.isArray(r.degradations)).toBe(true);
    }
  });
});

// ─── 2. isFullySupported consistency ─────────────────────────────────────────

describe('isFullySupported consistency', () => {
  it('isFullySupported === true when degradations is empty', () => {
    // "site:" is supported by Google
    const ast = parseOrThrow('site:example.com');
    const result = manager.translateOne(ast, 'google');

    expect(result.degradations).toHaveLength(0);
    expect(result.isFullySupported).toBe(true);
  });

  it('isFullySupported === false when degradations is non-empty', () => {
    // "vuln:" is not supported by Google
    const ast = parseOrThrow('vuln:CVE-2021-44228');
    const result = manager.translateOne(ast, 'google');

    expect(result.degradations.length).toBeGreaterThan(0);
    expect(result.isFullySupported).toBe(false);
  });

  it('isFullySupported is consistent for all 39 engines on a mixed query', () => {
    const ast = parseOrThrow('site:example.com port:443');
    const results = manager.translateAll(ast, [...ALL_ENGINE_IDS]);

    for (const r of results) {
      expect(r.isFullySupported).toBe(r.degradations.length === 0);
    }
  });
});

// ─── 3. No silent operator drops ─────────────────────────────────────────────

describe('No silent operator drops', () => {
  it('Google: vuln: operator produces a DegradationWarning', () => {
    const ast = parseOrThrow('vuln:CVE-2021-44228');
    const result = manager.translateOne(ast, 'google');

    const vulnWarning = result.degradations.find((d) => d.operator === 'vuln');
    expect(vulnWarning).toBeDefined();
    expect(vulnWarning?.reason).toBe('unsupported');
  });

  it('Google: ip: operator produces a DegradationWarning', () => {
    const ast = parseOrThrow('ip:1.2.3.4');
    const result = manager.translateOne(ast, 'google');

    const ipWarning = result.degradations.find((d) => d.operator === 'ip');
    expect(ipWarning).toBeDefined();
  });

  it('Shodan: filetype: operator produces a DegradationWarning', () => {
    const ast = parseOrThrow('filetype:pdf');
    const result = manager.translateOne(ast, 'shodan');

    const ftWarning = result.degradations.find((d) => d.operator === 'filetype');
    expect(ftWarning).toBeDefined();
    expect(ftWarning?.reason).toBe('unsupported');
  });

  it('Shodan: intitle: operator produces a DegradationWarning', () => {
    const ast = parseOrThrow('intitle:"admin panel"');
    const result = manager.translateOne(ast, 'shodan');

    const titleWarning = result.degradations.find((d) => d.operator === 'intitle');
    expect(titleWarning).toBeDefined();
  });

  it('GitHub: site: operator produces a DegradationWarning', () => {
    const ast = parseOrThrow('site:github.com');
    const result = manager.translateOne(ast, 'github');

    const siteWarning = result.degradations.find((d) => d.operator === 'site');
    expect(siteWarning).toBeDefined();
  });

  it('All engines: every unsupported operator in a complex query has a warning', () => {
    // This query uses operators from many categories
    const ast = parseOrThrow('site:example.com port:443 filetype:pdf vuln:CVE-2021-44228 author:alice');
    const results = manager.translateAll(ast, [...ALL_ENGINE_IDS]);

    for (const result of results) {
      const adapter = adapterRegistry.get(result.engineId)!;
      // Collect operators used in the query that this engine doesn't support
      const queryOperators: Array<'site' | 'port' | 'filetype' | 'vuln' | 'author'> = [
        'site', 'port', 'filetype', 'vuln', 'author',
      ];
      const unsupported = queryOperators.filter((op) => !adapter.supportsOperator(op));

      for (const op of unsupported) {
        const hasWarning = result.degradations.some((d) => d.operator === op);
        expect(
          hasWarning,
          `Engine "${result.engineId}" silently dropped operator "${op}" without a DegradationWarning`,
        ).toBe(true);
      }
    }
  });
});

// ─── 4. translateFrom propagation ────────────────────────────────────────────

describe('translateFrom propagation', () => {
  it('returns one result per target engine', () => {
    const ast = parseOrThrow('site:github.com "api_key" filetype:env');
    const targets: EngineId[] = ['github', 'sourcegraph', 'grep_app'];
    const results = manager.translateFrom('google', ast, targets);

    expect(results).toHaveLength(3);
    expect(results[0].engineId).toBe('github');
    expect(results[1].engineId).toBe('sourcegraph');
    expect(results[2].engineId).toBe('grep_app');
  });

  it('returns results for all 39 engines when translating from google', () => {
    const ast = parseOrThrow('site:example.com');
    const results = manager.translateFrom('google', ast, [...ALL_ENGINE_IDS]);

    expect(results).toHaveLength(ALL_ENGINE_IDS.length);
    // No result should be missing
    const returnedIds = new Set(results.map((r) => r.engineId));
    for (const engineId of ALL_ENGINE_IDS) {
      expect(returnedIds.has(engineId), `Missing result for engine "${engineId}"`).toBe(true);
    }
  });

  it('each result has a non-null degradations array', () => {
    const ast = parseOrThrow('port:22 os:Linux');
    const results = manager.translateFrom('shodan', ast, [...ALL_ENGINE_IDS]);

    for (const r of results) {
      expect(r.degradations).toBeDefined();
    }
  });
});

// ─── 5. getCommonOperators ────────────────────────────────────────────────────

describe('getCommonOperators', () => {
  it('returns only operators supported by all specified engines', () => {
    const engines: EngineId[] = ['google', 'shodan', 'censys'];
    const common = manager.getCommonOperators(engines);

    for (const op of common) {
      for (const engineId of engines) {
        const adapter = adapterRegistry.get(engineId)!;
        expect(
          adapter.supportsOperator(op),
          `Operator "${op}" is in common set but not supported by "${engineId}"`,
        ).toBe(true);
      }
    }
  });

  it('returns empty array for empty engine list', () => {
    const common = manager.getCommonOperators([]);
    expect(common).toHaveLength(0);
  });

  it('returns all supported operators for a single engine', () => {
    const googleOps = manager.getCommonOperators(['google']);
    const adapter = adapterRegistry.get('google')!;
    expect(googleOps).toHaveLength(adapter.operatorCount);
  });
});

// ─── 6. Specific engine translation spot-checks ───────────────────────────────

describe('Engine-specific translation spot-checks', () => {
  it('Google: site:example.com translates correctly', () => {
    const ast = parseOrThrow('site:example.com');
    const result = manager.translateOne(ast, 'google');
    expect(result.nativeQuery).toContain('site:example.com');
    expect(result.degradations).toHaveLength(0);
  });

  it('Shodan: port:22 translates correctly', () => {
    const ast = parseOrThrow('port:22');
    const result = manager.translateOne(ast, 'shodan');
    expect(result.nativeQuery).toContain('port:22');
    expect(result.degradations).toHaveLength(0);
  });

  it('Bing: site:example.com filetype:pdf translates correctly', () => {
    const ast = parseOrThrow('site:example.com filetype:pdf');
    const result = manager.translateOne(ast, 'bing');
    expect(result.nativeQuery).toContain('site:example.com');
    expect(result.nativeQuery).toContain('filetype:pdf');
    expect(result.degradations).toHaveLength(0);
  });

  it('GitHub: repo:owner/name path:src content:secret translates correctly', () => {
    const ast = parseOrThrow('repo:owner/name path:src content:secret');
    const result = manager.translateOne(ast, 'github');
    expect(result.nativeQuery.length).toBeGreaterThan(0);
    expect(result.degradations).toHaveLength(0);
  });

  it('Twitter: from:user since:2024-01-01 translates correctly', () => {
    const ast = parseOrThrow('from:user since:2024-01-01');
    const result = manager.translateOne(ast, 'twitter');
    expect(result.nativeQuery.length).toBeGreaterThan(0);
    expect(result.degradations).toHaveLength(0);
  });

  it('arXiv: intitle:quantum translates correctly', () => {
    const ast = parseOrThrow('intitle:quantum');
    const result = manager.translateOne(ast, 'arxiv');
    expect(result.nativeQuery).toContain('ti:quantum');
    expect(result.degradations).toHaveLength(0);
  });

  it('Semantic Scholar: fieldsOfStudy:cs translates correctly', () => {
    const ast = parseOrThrow('fieldsOfStudy:cs');
    const result = manager.translateOne(ast, 'semantic_scholar');
    expect(result.nativeQuery.length).toBeGreaterThan(0);
    expect(result.degradations).toHaveLength(0);
  });
});
