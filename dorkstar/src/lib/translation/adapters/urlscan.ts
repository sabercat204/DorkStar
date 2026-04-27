import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * urlscan.io threat intelligence adapter.
 * Uses `key:value` syntax with urlscan-specific field names.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class URLScanAdapter extends AbstractEngineAdapter {
  readonly engineId = 'urlscan' as const;
  readonly displayName = 'urlscan.io';
  readonly category = 'threat' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'domain',
    'ip',
    'url',
    'title',
    'tech',
    'country',
    'asn',
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
      case 'domain':
        return `domain:${v}`;
      case 'ip':
        return `ip:${v}`;
      case 'url':
        return `url:${v}`;
      case 'title':
        return `page.title:${v}`;
      case 'tech':
        return `tech:${v}`;
      case 'country':
        return `country:${v}`;
      case 'asn':
        return `asn:${v}`;
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
