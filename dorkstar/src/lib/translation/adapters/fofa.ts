import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * FOFA IoT/network intelligence adapter.
 * Uses `key="value"` syntax for all operators.
 * Boolean syntax: `&&` for AND, `||` for OR, `!` prefix for NOT.
 */
export class FofaAdapter extends AbstractEngineAdapter {
  readonly engineId = 'fofa' as const;
  readonly displayName = 'FOFA';
  readonly category = 'iot' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'ip',
    'port',
    'hostname',
    'org',
    'asn',
    'net',
    'country',
    'city',
    'os',
    'product',
    'version',
    'protocol',
    'domain',
    'title',
    'banner',
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
      case 'ip':
        return `ip="${v}"`;
      case 'port':
        return `port="${v}"`;
      case 'hostname':
        return `host="${v}"`;
      case 'org':
        return `org="${v}"`;
      case 'asn':
        return `asn="${v}"`;
      case 'net':
        return `net="${v}"`;
      case 'country':
        return `country="${v}"`;
      case 'city':
        return `city="${v}"`;
      case 'os':
        return `os="${v}"`;
      case 'product':
        return `app="${v}"`;
      case 'version':
        return `version="${v}"`;
      case 'protocol':
        return `protocol="${v}"`;
      case 'domain':
        return `domain="${v}"`;
      case 'title':
        return `title="${v}"`;
      case 'banner':
        return `banner="${v}"`;
      case 'before':
        return `before="${v}"`;
      case 'after':
        return `after="${v}"`;
      default:
        return `${operator}="${v}"`;
    }
  }

  protected formatBoolean(op: 'AND' | 'OR' | 'NOT', left: string, right: string): string {
    switch (op) {
      case 'AND':
        return `${left} && ${right}`;
      case 'OR':
        return `${left} || ${right}`;
      case 'NOT':
        return `!${right}`;
    }
  }

  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
