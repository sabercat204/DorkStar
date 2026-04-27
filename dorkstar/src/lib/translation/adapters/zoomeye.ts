import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * ZoomEye IoT/network intelligence adapter.
 * Uses `key:value` syntax with ZoomEye-specific field names.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class ZoomEyeAdapter extends AbstractEngineAdapter {
  readonly engineId = 'zoomeye' as const;
  readonly displayName = 'ZoomEye';
  readonly category = 'iot' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'ip',
    'port',
    'hostname',
    'org',
    'asn',
    'country',
    'city',
    'os',
    'product',
    'version',
    'app',
    'ver',
    'device',
    'cidr',
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
        return `ip:${v}`;
      case 'port':
        return `port:${v}`;
      case 'hostname':
        return `hostname:${v}`;
      case 'org':
        return `org:${v}`;
      case 'asn':
        return `asn:${v}`;
      case 'country':
        return `country:${v}`;
      case 'city':
        return `city:${v}`;
      case 'os':
        return `os:${v}`;
      case 'product':
        return `app:${v}`;
      case 'version':
        return `ver:${v}`;
      case 'app':
        return `app:${v}`;
      case 'ver':
        return `ver:${v}`;
      case 'device':
        return `device:${v}`;
      case 'cidr':
        return `cidr:${v}`;
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
