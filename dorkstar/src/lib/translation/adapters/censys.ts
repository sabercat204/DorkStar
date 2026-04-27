import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Censys IoT/network intelligence adapter.
 * Uses Censys query syntax with field-specific mappings.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class CensysAdapter extends AbstractEngineAdapter {
  readonly engineId = 'censys' as const;
  readonly displayName = 'Censys';
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
    'services.port',
    'services.http.response.html_title',
    'protocol',
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
        return `ip:${v}`;
      case 'port':
        return `services.port=${v}`;
      case 'hostname':
        return `parsed.names:${v}`;
      case 'org':
        return `autonomous_system.organization:${v}`;
      case 'asn':
        return `autonomous_system.asn:${v}`;
      case 'net':
        // CIDR range — map to ip field
        return `ip:${v}`;
      case 'country':
        return `location.country_code:${v}`;
      case 'city':
        return `location.city:${v}`;
      case 'os':
        return `metadata.os:${v}`;
      case 'product':
        return `services.software.product:${v}`;
      case 'version':
        return `services.software.version:${v}`;
      case 'services.port':
        return `services.port=${v}`;
      case 'services.http.response.html_title':
        return `services.http.response.html_title:${v}`;
      case 'protocol':
        return `services.transport_protocol:${v}`;
      case 'before':
        return `updated_at:<${v}`;
      case 'after':
        return `updated_at:>${v}`;
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
