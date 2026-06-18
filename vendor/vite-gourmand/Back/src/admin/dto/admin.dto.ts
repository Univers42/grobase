/**
 * Admin DTOs
 */
import {
  IsString,
  IsEmail,
  IsNumber,
  MinLength,
  IsOptional,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateEmployeeDto {
  @ApiProperty({ example: 'employee@vitegourmand.fr' })
  @IsEmail()
  email!: string;

  @ApiProperty({ example: 'SecurePass123!' })
  @IsString()
  @MinLength(8)
  password!: string;

  @ApiProperty({ example: 'John' })
  @IsString()
  firstName!: string;

  @ApiPropertyOptional({ example: 'Doe' })
  @IsOptional()
  @IsString()
  lastName?: string;

  @ApiProperty({ example: 3, description: 'Role ID' })
  @IsNumber()
  roleId!: number;
}

export class UpdateUserRoleDto {
  @ApiProperty({ example: 2, description: 'New role ID' })
  @IsNumber()
  roleId!: number;
}
