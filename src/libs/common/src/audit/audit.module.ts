/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit.module.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 21:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Global, Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { AuditService } from './audit.service';
import { AuditInterceptor } from './audit.interceptor';

/**
 * Importing this module in a service `AppModule.imports` enables the
 * `audit_log` write pipeline for every mutating HTTP request.
 *
 * The interceptor is registered via `APP_INTERCEPTOR`, so no further wiring
 * is needed at the controller level.
 */
@Global()
@Module({
  providers: [
    AuditService,
    {
      provide: APP_INTERCEPTOR,
      useClass: AuditInterceptor,
    },
  ],
  exports: [AuditService],
})
export class AuditModule {}
