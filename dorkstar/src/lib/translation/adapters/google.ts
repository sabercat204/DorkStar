import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Google Search adapter.
 * Supports the standard Google dork operators.
 * Boolean syntax: implicit AND (space), OR, and `-` prefix for NOT.
 */
export class GoogleAdapter extends AbstractEngineAdapter {
  readonly engineId = 'google' as const;
  readonly displayName = 'Google';
  readonly category = 'web' as const;
  readonly tier = 2 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'site',
    'filetype',
    'ext',
    'intitle',
    'allintitle',
    'inurl',
    'allinurl',
    'intext',
    'allintext',
    'inanchor',
    'allinanchor',
    'related',
    'cache',
    'define',
    'daterange',
    'before',
    'after',
    'lang',
    'loc',
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
      case 'ext':
        // `ext` is an alias for `filetype` in Google
        return `filetype:${v}`;
      case 'intitle':
        return `intitle:${v}`;
      case 'allintitle':
        return `allintitle:${v}`;
      case 'inurl':
        return `inurl:${v}`;
      case 'allinurl':
        return `allinurl:${v}`;
      case 'intext':
        return `intext:${v}`;
      case 'allintext':
        return `allintext:${v}`;
      case 'inanchor':
        return `inanchor:${v}`;
      case 'allinanchor':
        return `allinanchor:${v}`;
      case 'related':
        return `related:${v}`;
      case 'cache':
        return `cache:${v}`;
      case 'define':
        return `define:${v}`;
      case 'daterange':
        return `daterange:${v}`;
      case 'before':
        return `before:${v}`;
      case 'after':
        return `after:${v}`;
      case 'lang':
        return `lang:${v}`;
      case 'loc':
        return `loc:${v}`;
      default:
        return `${operator}:${v}`;
    }
  }

  protected formatBoolean(op: 'AND' | 'OR' | 'NOT', left: string, right: string): string {
    switch (op) {
      case 'AND':
        // Google uses implicit AND (space-separated)
        return `${left} ${right}`;
      case 'OR':
        return `${left} OR ${right}`;
      case 'NOT':
        return `-${right}`;
    }
  }

  // Required by the abstract class; the base class walking logic uses
  // translateOperator() directly via _translateNode — this stub satisfies
  // the abstract contract.
  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
