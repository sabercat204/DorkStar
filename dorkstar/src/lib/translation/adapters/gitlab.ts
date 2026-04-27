import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * GitLab code search adapter.
 * Uses GitLab-specific field names (project:, language:, etc.).
 * Boolean syntax: uppercase AND, OR, NOT.
 */
export class GitLabAdapter extends AbstractEngineAdapter {
  readonly engineId = 'gitlab' as const;
  readonly displayName = 'GitLab';
  readonly category = 'code' as const;
  readonly tier = 1 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'repo',
    'user',
    'path',
    'content',
    'lang',
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
      case 'repo':
        return `project:${v}`;
      case 'user':
        return `user:${v}`;
      case 'path':
        return `path:${v}`;
      case 'content':
        return `content:${v}`;
      case 'lang':
        return `language:${v}`;
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
