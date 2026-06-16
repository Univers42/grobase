/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   health.module.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { DynamicModule, Module, Provider } from '@nestjs/common';
import { TerminusModule, HealthIndicator } from '@nestjs/terminus';
import { HealthController } from './health.controller';

export interface HealthModuleOptions {
  indicators: Provider<HealthIndicator>[];
}

/**
 * Reusable health module. Import into each app with custom indicators:
 *
 * @example
 * HealthModule.forRoot({ indicators: [PostgresHealthIndicator] })
 */
@Module({})
export class HealthModule {
  static forRoot(options: HealthModuleOptions): DynamicModule {
    return {
      module: HealthModule,
      imports: [TerminusModule],
      controllers: [HealthController],
      providers: [
        ...options.indicators,
        {
          provide: 'HEALTH_INDICATORS',
          useFactory: (...indicators: HealthIndicator[]) => indicators,
          inject: options.indicators as never[],
        },
      ],
    };
  }
}
