import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * VirusTotal threat intelligence adapter.
 * Uses `key:value` syntax.
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class VirusTotalAdapter extends AbstractEngineAdapter {
  readonly engineId = 'virustotal' as const;
  readonly displayName = 'VirusTotal';
  readonly category = 'threat' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'url',
    'domain',
    'ip',
    'tag',
    'labels',
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
      case 'url':
        return `url:${v}`;
      case 'domain':
        return `domain:${v}`;
      case 'ip':
        return `ip:${v}`;
      case 'tag':
        return `tag:${v}`;
      case 'labels':
        return `labels:${v}`;
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
