/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   validation.pipe.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException, ValidationPipe as NestValidationPipe } from '@nestjs/common';
import { ValidationError } from 'class-validator';

/**
 * Pre-configured validation pipe with strict settings for all DTOs.
 * Whitelist strips unknown properties; forbidNonWhitelisted returns 400.
 */
/** Every constraint message, nested DTOs included (`columns.0.normalized_type …`). */
export function validationMessages(errors: ValidationError[], parent = ''): string[] {
  return errors.flatMap((e) => {
    const path = parent ? `${parent}.${e.property}` : e.property;
    const own = Object.values(e.constraints ?? {}).map((msg) =>
      parent ? `${parent}.${msg}` : msg,
    );
    return [...own, ...validationMessages(e.children ?? [], path)];
  });
}

export function createValidationPipe(): NestValidationPipe {
  return new NestValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
    transformOptions: { enableImplicitConversion: true },
    exceptionFactory: (errors: ValidationError[]) => {
      const messages = validationMessages(errors);
      return new BadRequestException({
        statusCode: 400,
        error: 'Validation Error',
        message: messages,
      });
    },
  });
}
