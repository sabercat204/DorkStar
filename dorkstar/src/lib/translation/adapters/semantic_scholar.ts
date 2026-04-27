import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Semantic Scholar academic search adapter.
 * Uses Semantic Scholar-specific field names.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class SemanticScholarAdapter extends AbstractEngineAdapter {
  readonly engineId = 'semantic_scholar' as const;
  readonly displayName = 'Semantic Scholar';
  readonly category = 'academic' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'fieldsOfStudy',
    'venue',
    'minCitationCount',
    'matchType',
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
      case 'fieldsOfStudy':
        return `fieldsOfStudy:${v}`;
      case 'venue':
        return `venue:${v}`;
      case 'minCitationCount':
        return `minCitationCount:${v}`;
      case 'matchType':
        return `matchType:${v}`;
      case 'after':
        return `year:>${v}`;
      case 'before':
        return `year:<${v}`;
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
