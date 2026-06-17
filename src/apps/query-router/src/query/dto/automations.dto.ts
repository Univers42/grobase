/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   automations.dto.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

import {
  IsArray, IsBoolean, IsIn, IsOptional, IsString, IsUrl,
  MaxLength, ValidateNested, ArrayMaxSize,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';

export const AUTOMATION_TRIGGERS = ['row_added', 'row_updated', 'row_deleted'] as const;
export type AutomationTrigger = (typeof AUTOMATION_TRIGGERS)[number];

export const AUTOMATION_ACTIONS = ['set_property', 'notify', 'webhook'] as const;
export type AutomationActionType = (typeof AUTOMATION_ACTIONS)[number];

export const CONDITION_OPERATORS = [
  'equals', 'not_equals', 'contains', 'greater_than', 'less_than',
  'is_empty', 'is_not_empty',
] as const;
export type AutomationConditionOperator = (typeof CONDITION_OPERATORS)[number];

/** Optional condition on the written row (evaluated server-side). */
export class AutomationConditionDto {
  @ApiProperty({ description: 'Column the condition reads' })
  @IsString()
  @MaxLength(128)
  column!: string;

  @ApiProperty({ enum: CONDITION_OPERATORS })
  @IsIn(CONDITION_OPERATORS)
  operator!: AutomationConditionOperator;

  @ApiPropertyOptional({ description: 'Comparison value (operator-dependent)' })
  @IsOptional()
  value?: unknown;
}

export class AutomationActionDto {
  @ApiProperty({ enum: AUTOMATION_ACTIONS })
  @IsIn(AUTOMATION_ACTIONS)
  type!: AutomationActionType;

  @ApiPropertyOptional({ description: 'set_property: target column' })
  @IsOptional()
  @IsString()
  @MaxLength(128)
  column?: string;

  @ApiPropertyOptional({ description: 'set_property: value to write' })
  @IsOptional()
  value?: unknown;

  @ApiPropertyOptional({ description: 'notify: message broadcast to subscribers' })
  @IsOptional()
  @IsString()
  @MaxLength(500)
  message?: string;

  @ApiPropertyOptional({ description: 'webhook: HTTPS endpoint (SSRF-guarded)' })
  @IsOptional()
  @IsUrl({ protocols: ['https'], require_protocol: true })
  @MaxLength(2000)
  url?: string;
}

export class AutomationRuleDto {
  @ApiProperty({ description: 'Stable rule id (client-generated uuid)' })
  @IsString()
  @MaxLength(64)
  id!: string;

  @ApiProperty()
  @IsString()
  @MaxLength(200)
  name!: string;

  @ApiProperty()
  @IsBoolean()
  enabled!: boolean;

  @ApiProperty({ description: 'Table/collection the rule watches' })
  @IsString()
  @MaxLength(128)
  table!: string;

  @ApiProperty({ enum: AUTOMATION_TRIGGERS })
  @IsIn(AUTOMATION_TRIGGERS)
  trigger!: AutomationTrigger;

  @ApiPropertyOptional({ type: AutomationConditionDto })
  @IsOptional()
  @ValidateNested()
  @Type(() => AutomationConditionDto)
  condition?: AutomationConditionDto;

  @ApiProperty({ type: [AutomationActionDto] })
  @IsArray()
  @ArrayMaxSize(5)
  @ValidateNested({ each: true })
  @Type(() => AutomationActionDto)
  actions!: AutomationActionDto[];
}

/** PUT body: the FULL rule set for the database (replace-all semantics). */
export class PutAutomationsDto {
  @ApiProperty({ type: [AutomationRuleDto] })
  @IsArray()
  @ArrayMaxSize(50)
  @ValidateNested({ each: true })
  @Type(() => AutomationRuleDto)
  rules!: AutomationRuleDto[];
}
