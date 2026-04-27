import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Reddit social search adapter.
 * Uses `key:value` syntax for Reddit search operators.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class RedditAdapter extends AbstractEngineAdapter {
  readonly engineId = 'reddit' as const;
  readonly displayName = 'Reddit';
  readonly category = 'social' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'author',
    'subreddit',
    'flair',
    'self',
    'selftext',
    'title',
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
      case 'author':
        return `author:${v}`;
      case 'subreddit':
        return `subreddit:${v}`;
      case 'flair':
        return `flair:${v}`;
      case 'self':
        return `self:${v}`;
      case 'selftext':
        return `selftext:${v}`;
      case 'title':
        return `title:${v}`;
      case 'before':
        return `before:${v}`;
      case 'after':
        return `after:${v}`;
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
