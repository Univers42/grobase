/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   automation-condition.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 23:40:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 23:40:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
/** Tiny server-side condition evaluator over the written row. Exported for
 *  unit tests. Unknown columns make every operator but is_empty false. */
export function evaluateCondition(
  row: Record<string, unknown>,
  condition: { column: string; operator: string; value?: unknown },
): boolean {
  const value = row[condition.column];
  const empty = value === undefined || value === null || value === '';
  switch (condition.operator) {
    case 'is_empty':
      return empty;
    case 'is_not_empty':
      return !empty;
    case 'equals':
      return looseEquals(value, condition.value);
    case 'not_equals':
      return !looseEquals(value, condition.value);
    case 'contains':
      return stringify(value ?? '')
        .toLowerCase()
        .includes(stringify(condition.value ?? '').toLowerCase());
    case 'greater_than':
      return Number(value) > Number(condition.value);
    case 'less_than':
      return Number(value) < Number(condition.value);
    default:
      return false;
  }
}

/** Stable text form of any condition operand. Primitives match `String(x)`
 *  exactly (the normal case); objects serialise to JSON instead of collapsing
 *  to the unhelpful `[object Object]`. */
function stringify(value: unknown): string {
  if (value !== null && typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

/** Equality that treats numeric strings and numbers alike (engines disagree on wire types). */
function looseEquals(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a !== null && b !== null && a !== undefined && b !== undefined) {
    return stringify(a) === stringify(b);
  }
  return false;
}
