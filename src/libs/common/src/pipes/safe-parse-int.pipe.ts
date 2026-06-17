/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   safe-parse-int.pipe.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { PipeTransform, Injectable, BadRequestException } from '@nestjs/common';

const MAX_PG_INT = 2147483647;
const MIN_PG_INT = -2147483648;

/**
 * Validates that a string parameter is a valid integer within PostgreSQL INT range.
 * Rejects non-numeric strings, NaN, and out-of-range values with 400.
 */
@Injectable()
export class SafeParseIntPipe implements PipeTransform<string, number> {
  transform(value: string): number {
    if (value === undefined || value === null || value === '') {
      throw new BadRequestException('Validation failed (numeric string is expected)');
    }

    if (!/^-?\d+$/.test(value)) {
      throw new BadRequestException('Validation failed (numeric string is expected)');
    }

    const num = Number.parseInt(value, 10);

    if (Number.isNaN(num)) {
      throw new BadRequestException('Validation failed (numeric string is expected)');
    }

    if (num > MAX_PG_INT || num < MIN_PG_INT) {
      throw new BadRequestException(
        `Validation failed (value must be between ${MIN_PG_INT} and ${MAX_PG_INT})`,
      );
    }

    return num;
  }
}
