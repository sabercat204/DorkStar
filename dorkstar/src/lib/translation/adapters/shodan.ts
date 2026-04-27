import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import type { CreditModel } from '../types';
import { AbstractEngineAdapter } from './base';

/**
 * Credit model for Shodan — each query consumes one credit and requires
 * explicit user confirmation before dispatch.
 */
export const SHODAN_CREDIT_MODEL: CreditModel = {
  unit: 'query',
  costPerUnit: 1,
  requiresConfirmation: true,
};

/**
 * Shodan IoT/network intelligence adapter.
 * Supports Shodan filter syntax (`key:value`).
 * Boolean syntax: explicit AND / OR / NOT keywords.
 */
export class ShodanAdapter extends AbstractEngineAdapter {
  readonly engineId = 'shodan' as const;
  readonly displayName = 'Shodan';
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
    'ssl.jarm',
    'ssl.ja3s',
    'http.favicon.hash',
    'has_screenshot',
    'http.title',
    'http.body',
    'before',
    'after',
  ]);

  protected translateOperator(
    operator: CanonicalOperator,
    value: string | RangeValue | WildcardValue,
  ): string {
    const v = typeof value === 'string' ? value : 'pattern' in value ? value.pattern : `${value.min}..${value.max}`;

    // All Shodan operators use the `key:value` syntax directly.
    // Operators with dots (ssl.jarm, http.title, etc.) are passed through as-is.
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

  // Required by the abstract class; the base class walking logic uses
  // translateOperator() directly via _translateNode — this stub satisfies
  // the abstract contract.
  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
