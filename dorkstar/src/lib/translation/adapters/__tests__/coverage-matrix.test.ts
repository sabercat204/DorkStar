/**
 * Operator Coverage Matrix Test
 *
 * For each of the 39 registered engine adapters, this test suite verifies:
 *   1. The adapter is present in the registry
 *   2. supportedOperators.size > 0
 *   3. operatorCount === supportedOperators.size
 *   4. tier ∈ {1, 2, 3}
 *   5. rateLimit.requestsPerMinute > 0
 *   6. creditModel.requiresConfirmation === true when costPerUnit > 0
 *
 * It also logs a human-readable coverage table to the console for use
 * alongside the /docs operator reference page.
 *
 * Requirements: 3.1, 3.2, 3.3, 17.1, 17.2, 17.3
 */

import { describe, it, expect, afterAll } from 'vitest';
import { adapterRegistry, ENGINE_REGISTRY } from '../registry';
import { ALL_ENGINE_IDS } from '../../types';
import { ALL_CANONICAL_OPERATORS } from '../../../parser/types';

// ─── 1. Registry completeness ────────────────────────────────────────────────

describe('Engine registry completeness', () => {
  it('should contain exactly 39 engines', () => {
    expect(ENGINE_REGISTRY).toHaveLength(39);
    expect(adapterRegistry.size).toBe(39);
  });

  it('should have an adapter for every EngineId in ALL_ENGINE_IDS', () => {
    for (const engineId of ALL_ENGINE_IDS) {
      expect(
        adapterRegistry.has(engineId),
        `Missing adapter for engine "${engineId}"`,
      ).toBe(true);
    }
  });

  it('should have a registry entry for every EngineId in ALL_ENGINE_IDS', () => {
    const registryIds = new Set(ENGINE_REGISTRY.map((e) => e.id));
    for (const engineId of ALL_ENGINE_IDS) {
      expect(
        registryIds.has(engineId),
        `Missing ENGINE_REGISTRY entry for engine "${engineId}"`,
      ).toBe(true);
    }
  });
});

// ─── 2. Per-adapter invariants ───────────────────────────────────────────────

describe('Per-adapter invariants', () => {
  for (const engineId of ALL_ENGINE_IDS) {
    describe(`Adapter: ${engineId}`, () => {
      const adapter = adapterRegistry.get(engineId)!;
      const registryEntry = ENGINE_REGISTRY.find((e) => e.id === engineId)!;

      it('adapter exists in registry', () => {
        expect(adapter).toBeDefined();
      });

      it('supportedOperators.size > 0', () => {
        expect(adapter.supportedOperators.size).toBeGreaterThan(0);
      });

      it('operatorCount === supportedOperators.size', () => {
        expect(adapter.operatorCount).toBe(adapter.supportedOperators.size);
      });

      it('tier is 1, 2, or 3', () => {
        expect([1, 2, 3]).toContain(adapter.tier);
      });

      it('ENGINE_REGISTRY entry exists', () => {
        expect(registryEntry).toBeDefined();
      });

      it('registry operatorCount === supportedOperators.length', () => {
        expect(registryEntry.operatorCount).toBe(registryEntry.supportedOperators.length);
      });

      it('registry tier is 1, 2, or 3', () => {
        expect([1, 2, 3]).toContain(registryEntry.tier);
      });

      it('rateLimit.requestsPerMinute > 0', () => {
        expect(registryEntry.rateLimit.requestsPerMinute).toBeGreaterThan(0);
      });

      it('creditModel.requiresConfirmation === true when costPerUnit > 0', () => {
        if (registryEntry.creditModel && registryEntry.creditModel.costPerUnit > 0) {
          expect(registryEntry.creditModel.requiresConfirmation).toBe(true);
        }
      });

      it('adapter.engineId matches registry id', () => {
        expect(adapter.engineId).toBe(registryEntry.id);
      });

      it('adapter.category matches registry category', () => {
        expect(adapter.category).toBe(registryEntry.category);
      });

      it('adapter.tier matches registry tier', () => {
        expect(adapter.tier).toBe(registryEntry.tier);
      });
    });
  }
});

// ─── 3. Coverage report (logged after all tests) ─────────────────────────────

afterAll(() => {
  const COL_WIDTH = 14;
  const OP_WIDTH = 36;

  // Build header
  const engineIds = [...ALL_ENGINE_IDS];
  const header =
    'Operator'.padEnd(OP_WIDTH) +
    engineIds.map((id) => id.slice(0, COL_WIDTH - 1).padEnd(COL_WIDTH)).join('');

  const separator = '-'.repeat(OP_WIDTH + engineIds.length * COL_WIDTH);

  const rows = ALL_CANONICAL_OPERATORS.map((op) => {
    const cells = engineIds.map((engineId) => {
      const adapter = adapterRegistry.get(engineId);
      return adapter?.supportsOperator(op) ? '✓'.padEnd(COL_WIDTH) : ' '.padEnd(COL_WIDTH);
    });
    const supportCount = engineIds.filter((id) => adapterRegistry.get(id)?.supportsOperator(op)).length;
    return `${op.padEnd(OP_WIDTH)}${cells.join('')}  [${supportCount}/${engineIds.length}]`;
  });

  // Per-engine summary
  const summary = engineIds.map((engineId) => {
    const adapter = adapterRegistry.get(engineId)!;
    return `  ${engineId}: ${adapter.operatorCount} operators (tier ${adapter.tier})`;
  });

  console.log('\n' + '═'.repeat(80));
  console.log('DORKSTAR — Operator Coverage Matrix');
  console.log('═'.repeat(80));
  console.log(header);
  console.log(separator);
  rows.forEach((row) => console.log(row));
  console.log(separator);
  console.log('\nPer-engine operator counts:');
  summary.forEach((s) => console.log(s));
  console.log('═'.repeat(80) + '\n');
});
