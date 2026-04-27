import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Bing Search adapter.
 * Supports Bing-specific search operators.
 * Boolean syntax: explicit AND / OR / NOT keywords.
 */
export class BingAdapter extends AbstractEngineAdapter {
  readonly engineId = 'bing' as const;
  readonly displayName = 'Bing';
  readonly category = 'web' as const;
  readonly tier = 2 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'site',
    'filetype',
    'intitle',
    'inurl',
    'inbody',
    'inanchor',
    'contains',
    'prefer',
    'language',
    'loc',
    'feed',
    'hasfeed',
    'url',
    'ip',
  ]);

  protected translateOperator(
    operator: CanonicalOperator,
    value: string | RangeValue | WildcardValue,
  ): string {
    const v = typeof value === 'string' ? value : 'pattern' in value ? value.pattern : `${value.min}..${value.max}`;

    switch (operator) {
      case 'site':
        return `site:${v}`;
      case 'filetype':
        return `filetype:${v}`;
      case 'intitle':
        return `intitle:${v}`;
      case 'inurl':
        return `inurl:${v}`;
      case 'inbody':
        return `inbody:${v}`;
      case 'inanchor':
        return `inanchor:${v}`;
      case 'contains':
        return `contains:${v}`;
      case 'prefer':
        return `prefer:${v}`;
      case 'language':
        return `language:${v}`;
      case 'loc':
        return `loc:${v}`;
      case 'feed':
        return `feed:${v}`;
      case 'hasfeed':
        return `hasfeed:${v}`;
      case 'url':
        return `url:${v}`;
      case 'ip':
        return `ip:${v}`;
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

  // Required by the abstract class; the base class walking logic uses
  // translateOperator() directly via _translateNode — this stub satisfies
  // the abstract contract.
  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
