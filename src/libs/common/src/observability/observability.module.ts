/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   observability.module.ts                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 16:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/26 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Global, MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { PrometheusModule } from '@willsoto/nestjs-prometheus';
import { RequestMetricsMiddleware } from './request-metrics.middleware';

/**
 * ObservabilityModule serves /metrics and counts every response. It is global
 * so its middleware is registered before the importing app's own (an ApiKey
 * middleware that answers 401 would otherwise hide the request from it).
 */
@Global()
@Module({
  imports: [
    PrometheusModule.register({
      defaultMetrics: { enabled: true },
      path: '/metrics',
    }),
  ],
  providers: [RequestMetricsMiddleware],
  exports: [PrometheusModule],
})
export class ObservabilityModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(RequestMetricsMiddleware).forRoutes('*');
  }
}
