/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ai.dto.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsString, IsOptional, IsObject, IsNotEmpty } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class ChatMessageDto {
  @ApiPropertyOptional({ description: 'Conversation ID (omit to start a new conversation)' })
  @IsOptional()
  @IsString()
  conversationId?: string;

  @ApiProperty({ example: 'Hello, I need help', description: 'User message' })
  @IsNotEmpty()
  @IsString()
  message!: string;

  @ApiPropertyOptional({ example: 'default', description: 'Prompt mode — maps to a registered system prompt template' })
  @IsOptional()
  @IsString()
  mode?: string;

  @ApiPropertyOptional({
    example: { products: ['Widget A', 'Widget B'] },
    description: 'Arbitrary context injected into the system prompt. The consuming app provides domain data here.',
  })
  @IsOptional()
  @IsObject()
  context?: Record<string, unknown>;
}

export class CreatePromptDto {
  @ApiProperty({ example: 'support', description: 'Unique mode identifier' })
  @IsNotEmpty()
  @IsString()
  mode!: string;

  @ApiProperty({
    example: 'You are a helpful customer support agent. Answer questions based on this context:\n{context}',
    description: 'System prompt template. Use {context} placeholder for injected context.',
  })
  @IsNotEmpty()
  @IsString()
  template!: string;

  @ApiPropertyOptional({ description: 'Human-readable description of this prompt mode' })
  @IsOptional()
  @IsString()
  description?: string;
}
