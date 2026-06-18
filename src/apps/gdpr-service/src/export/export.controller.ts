/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   export.controller.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { ExportService } from './export.service';

@ApiTags('export')
@Controller('export')
@UseGuards(AuthGuard)
@ApiBearerAuth()
@ApiSecurity('apikey')
export class ExportController {
  constructor(private readonly service: ExportService) {}

  @Get()
  @ApiOperation({ summary: 'Export my personal data (GDPR data portability)' })
  async exportMyData(@CurrentUser() user: UserContext) {
    return this.service.exportUserData(user.id);
  }
}
