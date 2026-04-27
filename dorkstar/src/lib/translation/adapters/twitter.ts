import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Twitter/X social search adapter.
 * Uses `key:value` syntax for Twitter advanced search operators.
 * Boolean syntax: implicit AND (space), OR, `-` prefix for NOT.
 */
export class TwitterAdapter extends AbstractEngineAdapter {
  readonly engineId = 'twitter' as const;
  readonly displayName = 'Twitter/X';
  readonly category = 'social' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'from',
    'to',
    'since',
    'until',
    'min_retweets',
    'min_faves',
    'min_replies',
    'filter',
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
      case 'from':
        return `from:${v}`;
      case 'to':
        return `to:${v}`;
      case 'since':
        return `since:${v}`;
      case 'until':
        return `until:${v}`;
      case 'min_retweets':
        return `min_retweets:${v}`;
      case 'min_faves':
        return `min_faves:${v}`;
      case 'min_replies':
        return `min_replies:${v}`;
      case 'filter':
        return `filter:${v}`;
      case 'lang':
        return `lang:${v}`;
      default:
        return `${operator}:${v}`;
    }
  }

  protected formatBoolean(op: 'AND' | 'OR' | 'NOT', left: string, right: string): string {
    switch (op) {
      case 'AND':
        return `${left} ${right}`;
      case 'OR':
        return `${left} OR ${right}`;
      case 'NOT':
        return `-${right}`;
    }
  }

  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
