import type {
  ASTNode,
  BooleanExpr,
  OperatorExpr,
  ExcludeTerm,
  IncludeTerm,
  ExactPhrase,
  ProximityExpr,
  RangeExpr,
  WildcardPhrase,
  BareWord,
  CanonicalOperator,
  RangeValue,
  WildcardValue,
} from '../../parser/types';
import type { EngineId, EngineCategory, TranslationResult, DegradationWarning } from '../types';

/**
 * Contract that every engine adapter must satisfy.
 */
export interface EngineAdapter {
  readonly engineId: EngineId;
  readonly displayName: string;
  readonly category: EngineCategory;
  readonly tier: 1 | 2 | 3;
  readonly supportedOperators: ReadonlySet<CanonicalOperator>;
  readonly operatorCount: number;

  /**
   * Translate a full AST into a `TranslationResult` for this engine.
   * Collects `DegradationWarning` for every unsupported operator encountered.
   */
  translate(ast: ASTNode): TranslationResult;

  /**
   * Return `true` if this engine supports the given canonical operator.
   */
  supportsOperator(op: CanonicalOperator): boolean;
}

/**
 * Base class that implements the shared AST-walking logic.
 * Subclasses must implement `translateNode()` and declare their
 * `engineId`, `displayName`, `category`, `tier`, and `supportedOperators`.
 */
export abstract class AbstractEngineAdapter implements EngineAdapter {
  abstract readonly engineId: EngineId;
  abstract readonly displayName: string;
  abstract readonly category: EngineCategory;
  abstract readonly tier: 1 | 2 | 3;
  abstract readonly supportedOperators: ReadonlySet<CanonicalOperator>;

  get operatorCount(): number {
    return this.supportedOperators.size;
  }

  supportsOperator(op: CanonicalOperator): boolean {
    return this.supportedOperators.has(op);
  }

  /**
   * Walk the AST, collect degradation warnings, and return a `TranslationResult`.
   */
  translate(ast: ASTNode): TranslationResult {
    const degradations: DegradationWarning[] = [];
    const nativeQuery = this._translateNode(ast, degradations).trim();

    return {
      engineId: this.engineId,
      nativeQuery,
      degradations,
      isFullySupported: degradations.length === 0,
    };
  }

  /**
   * Internal recursive AST walker that accumulates degradation warnings.
   */
  private _translateNode(node: ASTNode, degradations: DegradationWarning[]): string {
    switch (node.kind) {
      case 'BooleanExpr': {
        const n = node as BooleanExpr;
        const left = this._translateNode(n.left, degradations);
        const right = this._translateNode(n.right, degradations);
        return this.formatBoolean(n.op, left, right);
      }

      case 'OperatorExpr': {
        const n = node as OperatorExpr;
        if (!this.supportsOperator(n.operator)) {
          degradations.push({
            operator: n.operator,
            reason: 'unsupported',
            message: `Operator "${n.operator}" is not supported by ${this.displayName}`,
          });
          return '';
        }
        return this.translateOperator(n.operator, n.value);
      }

      case 'ExcludeTerm': {
        const n = node as ExcludeTerm;
        return `-${this._translateNode(n.term, degradations)}`;
      }

      case 'IncludeTerm': {
        const n = node as IncludeTerm;
        return `+${this._translateNode(n.term, degradations)}`;
      }

      case 'ExactPhrase': {
        const n = node as ExactPhrase;
        return `"${n.phrase}"`;
      }

      case 'ProximityExpr': {
        const n = node as ProximityExpr;
        const left = this._translateNode(n.left, degradations);
        const right = this._translateNode(n.right, degradations);
        return `${left} AROUND(${n.distance}) ${right}`;
      }

      case 'RangeExpr': {
        const n = node as RangeExpr;
        if (!this.supportsOperator(n.operator)) {
          degradations.push({
            operator: n.operator,
            reason: 'unsupported',
            message: `Operator "${n.operator}" (range) is not supported by ${this.displayName}`,
          });
          return '';
        }
        return this.translateRange(n.operator, n.min, n.max);
      }

      case 'WildcardPhrase': {
        const n = node as WildcardPhrase;
        if (!this.supportsWildcard()) {
          // Use a sentinel operator name for wildcard degradation warnings.
          // Cast is safe: the warning is informational and the operator field
          // is typed as CanonicalOperator only for structural consistency.
          degradations.push({
            operator: 'intext' as CanonicalOperator, // placeholder — no canonical wildcard operator
            reason: 'unsupported',
            message: `Wildcard patterns are not supported by ${this.displayName}`,
          });
          return '';
        }
        return this.translateWildcard(n.pattern);
      }

      case 'BareWord': {
        const n = node as BareWord;
        return this.escapeBareWord(n.value);
      }

      default:
        return '';
    }
  }

  /**
   * Subclasses implement this to translate a single AST node into a native
   * query fragment. Called by `translate()` via `_translateNode()`.
   *
   * Subclasses that need fine-grained control can override `_translateNode`
   * indirectly by overriding the individual helper methods below.
   */
  protected abstract translateNode(node: ASTNode): string;

  // ─── Overridable helpers ────────────────────────────────────────────────────

  /**
   * Format a boolean expression in the engine's native syntax.
   * Default: `left AND right`, `left OR right`, `NOT right`.
   */
  protected formatBoolean(op: 'AND' | 'OR' | 'NOT', left: string, right: string): string {
    switch (op) {
      case 'AND':
        return `${left} AND ${right}`;
      case 'OR':
        return `${left} OR ${right}`;
      case 'NOT':
        return `NOT ${right}`;
    }
  }

  /**
   * Escape or quote a bare word for the engine's syntax.
   * Default: return the value unchanged.
   */
  protected escapeBareWord(value: string): string {
    return value;
  }

  /**
   * Translate a range expression into the engine's native syntax.
   * Default: `operator:min..max`.
   */
  protected translateRange(
    operator: CanonicalOperator,
    min: number | string,
    max: number | string,
  ): string {
    return `${operator}:${min}..${max}`;
  }

  /**
   * Translate a wildcard pattern into the engine's native syntax.
   * Default: return the pattern unchanged.
   */
  protected translateWildcard(pattern: string): string {
    return pattern;
  }

  /**
   * Return `true` if this engine supports wildcard patterns.
   * Default: `true`.
   */
  protected supportsWildcard(): boolean {
    return true;
  }

  /**
   * Translate a supported operator expression into the engine's native syntax.
   * Default: `operator:value`.
   * Subclasses override this for engine-specific syntax.
   */
  protected translateOperator(
    operator: CanonicalOperator,
    value: string | RangeValue | WildcardValue,
  ): string {
    if (typeof value === 'string') {
      return `${operator}:${value}`;
    }
    if ('pattern' in value) {
      // WildcardValue
      return `${operator}:${value.pattern}`;
    }
    // RangeValue
    return `${operator}:${value.min}..${value.max}`;
  }
}
