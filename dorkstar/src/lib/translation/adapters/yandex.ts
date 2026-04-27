import type { ASTNode, CanonicalOperator, RangeValue, WildcardValue } from '../../parser/types';
import { AbstractEngineAdapter } from './base';

/**
 * Yandex Search adapter.
 * Supports Yandex-specific search operators with Yandex-native syntax.
 * Boolean syntax: `&&` for AND, `||` for OR, `~~` prefix for NOT.
 */
export class YandexAdapter extends AbstractEngineAdapter {
  readonly engineId = 'yandex' as const;
  readonly displayName = 'Yandex';
  readonly category = 'web' as const;
  readonly tier = 2 as const;

  readonly supportedOperators: ReadonlySet<CanonicalOperator> = new Set<CanonicalOperator>([
    'site',
    'url',
    'intitle',
    'filetype',
    'lang',
    'date',
  ]);

  protected translateOperator(
    operator: CanonicalOperator,
    value: string | RangeValue | WildcardValue,
  ): string {
    const v = typeof value === 'string' ? value : 'pattern' in value ? value.pattern : `${value.min}..${value.max}`;

    switch (operator) {
      case 'site':
        return `site:${v}`;
      case 'url':
        return `url:${v}`;
      case 'intitle':
        // Yandex uses `title:` instead of `intitle:`
        return `title:${v}`;
      case 'filetype':
        // Yandex uses `mime:` instead of `filetype:`
        return `mime:${v}`;
      case 'lang':
        return `lang:${v}`;
      case 'date':
        return `date:${v}`;
      default:
        return `${operator}:${v}`;
    }
  }

  protected formatBoolean(op: 'AND' | 'OR' | 'NOT', left: string, right: string): string {
    switch (op) {
      case 'AND':
        return `${left} && ${right}`;
      case 'OR':
        return `${left} || ${right}`;
      case 'NOT':
        return `~~${right}`;
    }
  }

  // Required by the abstract class; the base class walking logic uses
  // translateOperator() directly via _translateNode — this stub satisfies
  // the abstract contract.
  protected translateNode(_node: ASTNode): string {
    return '';
  }
}
