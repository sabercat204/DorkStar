import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * grep.app code search adapter.
 * Uses `key:value` syntax.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class GrepAppAdapter extends AbstractEngineAdapter {
  readonly engineId = 'grep_app' as const;
  readonly displayName = 'grep.app';
  readonly category = 'code' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'repo',
    'path',
    'content',
    'lang',
  ]);

  protected translateOperator(
    operator: CanonicalOperator,
    value: string | RangeValue | WildcardValue,
  ): string {
    const v =
      typeof value === 'string'
        ? value
        : 'pattern' in value
          ? value.pattern
          : `${value.min}..${value.max}`;

    switch (operator) {
      case 'repo':
        return `repo:${v}`;
      case 'path':
        return `path:${v}`;
      case 'content':
        return `content:${v}`;
      case 'lang':
        return `lang:${v}`;
      default:
        return `${operator}:${v}`;
    }
  }

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

  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
