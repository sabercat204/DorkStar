import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * arXiv academic search adapter.
 * Uses arXiv-specific field prefixes (ti:, au:, abs:, submittedDate:).
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class ArxivAdapter extends AbstractEngineAdapter {
  readonly engineId = 'arxiv' as const;
  readonly displayName = 'arXiv';
  readonly category = 'academic' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'intitle',
    'author',
    'content',
    'date',
    'before',
    'after',
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
      case 'intitle':
        return `ti:${v}`;
      case 'author':
        return `au:${v}`;
      case 'content':
        return `abs:${v}`;
      case 'date':
        return `submittedDate:${v}`;
      case 'after':
        return `submittedDate:[${v} TO *]`;
      case 'before':
        return `submittedDate:[* TO ${v}]`;
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
