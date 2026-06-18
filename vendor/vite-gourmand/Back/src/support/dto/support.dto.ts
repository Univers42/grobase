/**
 * Support Ticket DTOs
 */
import {
  IsString,
  IsOptional,
  IsNumber,
  IsEnum,
  IsBoolean,
  MaxLength,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export enum TicketCategory {
  ORDER = 'order',
  DELIVERY = 'delivery',
  PAYMENT = 'payment',
  ACCOUNT = 'account',
  MENU = 'menu',
  OTHER = 'other',
}

export enum TicketPriority {
  LOW = 'low',
  NORMAL = 'normal',
  HIGH = 'high',
  URGENT = 'urgent',
}

export enum TicketStatus {
  OPEN = 'open',
  IN_PROGRESS = 'in_progress',
  WAITING_CUSTOMER = 'waiting_customer',
  RESOLVED = 'resolved',
  CLOSED = 'closed',
}

export class CreateSupportTicketDto {
  @ApiProperty({ enum: TicketCategory, example: 'order' })
  @IsEnum(TicketCategory)
  category!: TicketCategory;

  @ApiProperty({ example: 'Issue with my order' })
  @IsString()
  @MaxLength(255)
  subject!: string;

  @ApiPropertyOptional({ example: 'I received the wrong items...' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ enum: TicketPriority, example: 'normal' })
  @IsOptional()
  @IsEnum(TicketPriority)
  priority?: TicketPriority;
}

export class UpdateSupportTicketDto {
  @ApiPropertyOptional({ enum: TicketStatus, example: 'in_progress' })
  @IsOptional()
  @IsEnum(TicketStatus)
  status?: TicketStatus;

  @ApiPropertyOptional({ enum: TicketPriority, example: 'high' })
  @IsOptional()
  @IsEnum(TicketPriority)
  priority?: TicketPriority;

  @ApiPropertyOptional({ example: 5 })
  @IsOptional()
  @IsNumber()
  assignedTo?: number;
}

export class CreateTicketMessageDto {
  @ApiProperty({ example: 'Thank you for contacting us...' })
  @IsString()
  body!: string;

  @ApiPropertyOptional({
    example: false,
    description: 'Internal note (not visible to customer)',
  })
  @IsOptional()
  @IsBoolean()
  isInternal?: boolean;
}
