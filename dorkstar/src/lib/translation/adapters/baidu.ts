import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Baidu Search adapter.
 * Supports standard dork operators.
 * Boolean syntax: implicit AND (space), OR, `-` prefix for NOT.
 */
export class BaiduAdapter extends AbstractEngineAdapter {
  readonly engineId = 'baidu' as const;
  readonly displayName = 'Baidu';
  readonly category = 'web' as const;
  readonly tier = 2 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'site',
    'filetype',
    'intitle',
    'inurl',
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
