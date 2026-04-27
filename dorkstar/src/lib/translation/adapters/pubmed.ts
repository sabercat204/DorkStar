import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * PubMed academic search adapter.
 * Uses PubMed field tag syntax: `value[FieldTag]`.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class PubMedAdapter extends AbstractEngineAdapter {
  readonly engineId = 'pubmed' as const;
  readonly displayName = 'PubMed';
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
        return `${v}[Title]`;
      case 'author':
        return `${v}[Author]`;
      case 'content':
        return `${v}[Text Word]`;
      case 'date':
        return `${v}[Date - Publication]`;
      case 'before':
        return `${v}[Date - Publication]`;
      case 'after':
        return `${v}[Date - Publication]`;
      default:
        return `${v}[${operator}]`;
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
