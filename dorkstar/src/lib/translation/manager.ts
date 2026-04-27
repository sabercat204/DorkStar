import type { ASTNode } from '../parser/types';
import type { CanonicalOperator } from '../parser/types';
import type { EngineId, TranslationResult } from './types';
import type { EngineAdapter } from './adapters/base';

/**
 * Manages the registry of engine adapters and coordinates AST translation
 * across one or more target engines.
 */
export class TranslationManager {
  constructor(private readonly adapters: Map<EngineId, EngineAdapter>) {}

  /**
   * Translate `ast` for every engine in `engines`.
   * Returns exactly `engines.length` results where `result[i].engineId === engines[i]`.
   *
   * @throws {Error} if an `engineId` in `engines` is not registered.
   */
  translateAll(ast: ASTNode, engines: EngineId[]): TranslationResult[] {
    return engines.map((engineId) => this.translateOne(ast, engineId));
  }

  /**
   * Translate `ast` for a single engine.
   *
   * @throws {Error} if `engineId` is not registered.
   */
  translateOne(ast: ASTNode, engineId: EngineId): TranslationResult {
    const adapter = this.adapters.get(engineId);
    if (!adapter) {
      throw new Error(
        `Engine "${engineId}" is not registered in the TranslationManager. ` +
          `Registered engines: ${[...this.adapters.keys()].join(', ')}`,
      );
    }
    return adapter.translate(ast);
  }

  /**
   * Translate `ast` (originally authored for `sourceEngine`) to each engine
   * in `targetEngines`. The `sourceEngine` parameter is informational — the
   * same `ast` is passed to every target adapter unchanged.
   *
   * Returns one `TranslationResult` per engine in `targetEngines`.
   *
   * @throws {Error} if any engine in `targetEngines` is not registered.
   */
  translateFrom(
    sourceEngine: EngineId,
    ast: ASTNode,
    targetEngines: EngineId[],
  ): TranslationResult[] {
    // sourceEngine is accepted for API symmetry and future use (e.g. logging,
    // source-aware operator mapping). Currently the AST is engine-agnostic.
    void sourceEngine;
    return targetEngines.map((engineId) => this.translateOne(ast, engineId));
  }

  /**
   * Return the list of canonical operators supported by `engineId`.
   *
   * @throws {Error} if `engineId` is not registered.
   */
  getSupportedOperators(engineId: EngineId): CanonicalOperator[] {
    const adapter = this.adapters.get(engineId);
    if (!adapter) {
      throw new Error(`Engine "${engineId}" is not registered in the TranslationManager.`);
    }
    return [...adapter.supportedOperators];
  }

  /**
   * Return the intersection of `supportedOperators` across all specified engines.
   * An operator is included only if every engine in `engines` supports it.
   *
   * Returns an empty array when `engines` is empty.
   *
   * @throws {Error} if any engine in `engines` is not registered.
   */
  getCommonOperators(engines: EngineId[]): CanonicalOperator[] {
    if (engines.length === 0) {
      return [];
    }

    // Start with the operator set of the first engine, then intersect.
    const [first, ...rest] = engines;
    const firstOps = this.getSupportedOperators(first);

    return firstOps.filter((op) =>
      rest.every((engineId) => {
        const adapter = this.adapters.get(engineId);
        if (!adapter) {
          throw new Error(`Engine "${engineId}" is not registered in the TranslationManager.`);
        }
        return adapter.supportsOperator(op);
      }),
    );
  }
}

/**
 * Factory function that creates a `TranslationManager` from an adapter map.
 */
export function createTranslationManager(
  adapters: Map<EngineId, EngineAdapter>,
): TranslationManager {
  return new TranslationManager(adapters);
}
