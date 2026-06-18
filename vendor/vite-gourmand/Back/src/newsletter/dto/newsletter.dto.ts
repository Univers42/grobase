/**
 * Newsletter DTOs
 */
import {
  IsString,
  IsOptional,
  IsEmail,
  MaxLength,
  MinLength,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class SubscribeNewsletterDto {
  @ApiProperty({
    example: 'marie@exemple.fr',
    description: 'Email address to subscribe',
  })
  @IsEmail()
  @MaxLength(255)
  email!: string;

  @ApiPropertyOptional({
    example: 'Marie',
    description: 'First name (optional)',
  })
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(100)
  firstName?: string;
}

export class UnsubscribeNewsletterDto {
  @ApiProperty({ description: 'Unsubscribe token from the email link' })
  @IsString()
  token!: string;
}

export class ConfirmNewsletterDto {
  @ApiProperty({ description: 'Confirmation token from the email link' })
  @IsString()
  token!: string;
}
