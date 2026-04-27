import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Sourcegraph code search adapter.
 * Uses Sourcegraph-specific field names (file:, lang:, type:symbol, etc.).
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class SourcegraphAdapter extends AbstractEngineAdapter {
  readonly engineId = 'sourcegraph' as const;
  readonly displayName = 'Sourcegraph';
  readonly category = 'code' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'repo',
    'path',
    'content',
    'lang',
    'filetype',
    'symbol',
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
        return `file:${v}`;
      case 'content':
        return `content:${v}`;
      case 'lang':
        return `lang:${v}`;
      case 'filetype':
        return `lang:${v}`;
      case 'symbol':
        return `type:symbol content:${v}`;
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
