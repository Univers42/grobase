/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   observability.module.ts                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 16:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { PrometheusModule } from '@willsoto/nestjs-prometheus';
import { MetricsInterceptor } from './metrics.interceptor';

@Module({
  imports: [
    PrometheusModule.register({
      defaultMetrics: { enabled: true },
      path: '/metrics',
    }),
  ],
  providers: [{ provide: APP_INTERCEPTOR, useClass: MetricsInterceptor }],
  exports: [PrometheusModule],
})
export class ObservabilityModule {}