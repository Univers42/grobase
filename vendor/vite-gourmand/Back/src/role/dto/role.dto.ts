/**
 * Role & Permission DTOs
 */
import { IsString, IsOptional, IsArray, IsInt } from 'class-validator';
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';

// Permission DTOs
export class CreatePermissionDto {
  @ApiProperty({ example: 'manage_orders' })
  @IsString()
  name!: string;

  @ApiPropertyOptional({ example: 'Ability to manage customer orders' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'orders' })
  @IsOptional()
  @IsString()
  resource?: string;

  @ApiPropertyOptional({ example: 'write' })
  @IsOptional()
  @IsString()
  action?: string;
}

export class UpdatePermissionDto extends PartialType(CreatePermissionDto) {}

// Role DTOs
export class CreateRoleDto {
  @ApiProperty({ example: 'manager' })
  @IsString()
  name!: string;

  @ApiPropertyOptional({ example: 'Restaurant manager with order access' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ type: [Number], example: [1, 2, 3] })
  @IsOptional()
  @IsArray()
  @IsInt({ each: true })
  permissionIds?: number[];
}

export class UpdateRoleDto extends PartialType(CreateRoleDto) {}

export class AssignPermissionsDto {
  @ApiProperty({ type: [Number], example: [1, 2, 3] })
  @IsArray()
  @IsInt({ each: true })
  permissionIds!: number[];
}
