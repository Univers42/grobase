/**
 * Contact DTOs
 */
import { IsString, IsEmail, IsOptional, MaxLength } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateContactMessageDto {
  @ApiProperty({ example: 'Jean Dupont' })
  @IsString()
  @MaxLength(100)
  name!: string;

  @ApiProperty({ example: 'john@example.com' })
  @IsEmail()
  @MaxLength(255)
  email!: string;

  @ApiPropertyOptional({ example: '06 12 34 56 78' })
  @IsOptional()
  @IsString()
  @MaxLength(30)
  phone?: string;

  @ApiProperty({ example: 'Question about catering' })
  @IsString()
  @MaxLength(255)
  title!: string;

  @ApiProperty({ example: 'I would like to know more about your services...' })
  @IsString()
  description!: string;
}

export class ContactMessageResponseDto {
  id!: number;
  title!: string;
  description!: string;
  email!: string;
  ticket_number?: string;
  created_at!: Date;
}
