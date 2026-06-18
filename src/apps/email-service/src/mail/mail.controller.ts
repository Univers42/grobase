/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mail.controller.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { AuthGuard } from '@mini-baas/common';
import { MailService } from './mail.service';
import { SendEmailDto } from './dto/send-email.dto';

@ApiTags('mail')
@Controller('send')
@UseGuards(AuthGuard)
export class MailController {
  constructor(private readonly service: MailService) {}

  @Post()
  @ApiOperation({ summary: 'Send an email via SMTP' })
  async send(@Body() dto: SendEmailDto) {
    return this.service.send(dto);
  }
}
