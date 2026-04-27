import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Criminal IP IoT/network intelligence adapter.
 * Uses `key:value` syntax.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class CriminalIPAdapter extends AbstractEngineAdapter {
  readonly engineId = 'criminalip' as const;
  readonly displayName = 'Criminal IP';
  readonly category = 'iot' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'ip',
    'port',
    'hostname',
    'org',
    'asn',
    'country',
    'product',
    'protocol',
    'domain',
    'banner',
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

    return `${operator}:${v}`;
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
