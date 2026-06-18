/**
 * AI Agent DTOs
 */
import {
  IsString,
  IsOptional,
  IsNumber,
  IsArray,
  IsObject,
  Min,
  Max,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class ChatContextDto {
  @ApiPropertyOptional({
    description: 'Current page context (home, menu, contact, profile, order)',
  })
  @IsString()
  @IsOptional()
  page?: string;

  @ApiPropertyOptional({
    description: 'Mode of operation (public_assistant, menu_builder)',
  })
  @IsString()
  @IsOptional()
  mode?: string;
}

export class ChatMessageDto {
  @ApiProperty({ description: 'User message to the AI agent' })
  @IsString()
  message!: string;

  @ApiPropertyOptional({ description: 'Conversation ID for multi-turn chat' })
  @IsString()
  @IsOptional()
  conversationId?: string;

  @ApiPropertyOptional({
    description: 'Context about where the user is (page, mode)',
  })
  @IsObject()
  @IsOptional()
  context?: ChatContextDto;

  @ApiPropertyOptional({ description: 'Number of guests for the event' })
  @IsNumber()
  @IsOptional()
  @Min(1)
  @Max(500)
  guestCount?: number;

  @ApiPropertyOptional({ description: 'Budget per person in euros' })
  @IsNumber()
  @IsOptional()
  @Min(0)
  budgetPerPerson?: number;

  @ApiPropertyOptional({ description: 'Diet preference ID' })
  @IsNumber()
  @IsOptional()
  dietId?: number;

  @ApiPropertyOptional({ description: 'Theme preference ID' })
  @IsNumber()
  @IsOptional()
  themeId?: number;

  @ApiPropertyOptional({ description: 'Allergen IDs to exclude' })
  @IsArray()
  @IsOptional()
  excludeAllergens?: number[];
}

export class GenerateMenuDto {
  @ApiProperty({ description: 'Conversation ID with agreed specifications' })
  @IsString()
  conversationId!: string;
}
