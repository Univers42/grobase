/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   permission.dto.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsNotEmpty, IsString } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class CheckPermissionDto {
  @ApiProperty({ example: 'table', description: 'Resource type: table, collection, bucket, endpoint, …' })
  @IsString()
  @IsNotEmpty()
  resource_type!: string;

  @ApiProperty({ example: 'documents', description: 'Resource name / identifier' })
  @IsString()
  @IsNotEmpty()
  resource_name!: string;

  @ApiProperty({ example: 'read', description: 'Action to check: read, create, update, delete' })
  @IsString()
  @IsNotEmpty()
  action!: string;
}

export class AssignRoleDto {
  @ApiProperty({ example: 'moderator', description: 'Role name to assign' })
  @IsString()
  @IsNotEmpty()
  role_name!: string;

  @ApiProperty({ example: '550e8400-e29b-41d4-a716-446655440000', description: 'Target user UUID' })
  @IsString()
  @IsNotEmpty()
  target_user_id!: string;
}
