import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * DuckDuckGo Search adapter.
 * Supports standard dork operators.
 * Boolean syntax: implicit AND (space), OR, `-` prefix for NOT.
 */
export class DuckDuckGoAdapter extends AbstractEngineAdapter {
  readonly engineId = 'duckduckgo' as const;
  readonly displayName = 'DuckDuckGo';
  readonly category = 'web' as const;
  readonly tier = 2 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'site',
    'filetype',
    'intitle',
    'inurl',
    'intext',
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
      case 'site':
        return `site:${v}`;
      case 'filetype':
        return `filetype:${v}`;
      case 'intitle':
        return `intitle:${v}`;
      case 'inurl':
        return `inurl:${v}`;
      case 'intext':
        return `intext:${v}`;
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
