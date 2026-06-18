/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   env.validation.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { plainToInstance, Type } from 'class-transformer';
import { IsEnum, IsNumber, IsOptional, IsString, Min, validateSync } from 'class-validator';

export class EnvironmentVariables {
  @IsNumber()
  @Min(1)
  @Type(() => Number)
  PORT!: number;

  @IsString()
  @IsOptional()
  @IsEnum(['debug', 'info', 'warn', 'error', 'fatal'])
  LOG_LEVEL?: string;
}

/**
 * NestJS ConfigModule validation factory.
 * Usage: ConfigModule.forRoot({ validate: validateEnv(MyEnv) })
 */
export function validateEnv<T extends object>(cls: new () => T) {
  return (config: Record<string, unknown>): T => {
    const validated = plainToInstance(cls, config, { enableImplicitConversion: true });
    const errors = validateSync(validated as object, { skipMissingProperties: false });
    if (errors.length > 0) {
      const messages = errors.map((e) => Object.values(e.constraints ?? {}).join(', '));
      throw new Error(`Config validation error:\n${messages.join('\n')}`);
    }
    return validated;
  };
}
