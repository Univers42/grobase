/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   newsletter.dto.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsString, IsOptional, IsEmail, MaxLength, MinLength, IsNotEmpty } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class SubscribeDto {
  @ApiProperty({ example: 'user@example.com', description: 'Email address to subscribe' })
  @IsEmail()
  @MaxLength(255)
  email!: string;

  @ApiPropertyOptional({ example: 'Jane' })
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(100)
  firstName?: string;
}

export class SendCampaignDto {
  @ApiProperty({ example: 'Weekly digest', description: 'Email subject line' })
  @IsNotEmpty()
  @IsString()
  subject!: string;

  @ApiProperty({ example: '<h1>Hello</h1><p>News...</p>', description: 'Email HTML body' })
  @IsNotEmpty()
  @IsString()
  html!: string;

  @ApiPropertyOptional({ description: 'Plain text fallback (auto-generated from HTML if omitted)' })
  @IsOptional()
  @IsString()
  text?: string;
}
