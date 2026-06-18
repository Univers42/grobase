/**
 * Delivery DTOs
 */
import {
  IsString,
  IsOptional,
  IsNumber,
  IsEnum,
  Min,
  Max,
  MaxLength,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export enum DeliveryStatus {
  ASSIGNED = 'assigned',
  PICKED_UP = 'picked_up',
  IN_TRANSIT = 'in_transit',
  DELIVERED = 'delivered',
  FAILED = 'failed',
}

export class CreateDeliveryAssignmentDto {
  @ApiProperty({ example: 1 })
  @IsNumber()
  orderId!: number;

  @ApiPropertyOptional({ example: 5 })
  @IsOptional()
  @IsNumber()
  deliveryPersonId?: number;

  @ApiPropertyOptional({ example: 'car' })
  @IsOptional()
  @IsString()
  @MaxLength(50)
  vehicleType?: string;

  @ApiPropertyOptional({ example: 'Ring doorbell twice' })
  @IsOptional()
  @IsString()
  deliveryNotes?: string;
}

export class UpdateDeliveryAssignmentDto {
  @ApiPropertyOptional({ example: 5 })
  @IsOptional()
  @IsNumber()
  deliveryPersonId?: number;

  @ApiPropertyOptional({ example: 'car' })
  @IsOptional()
  @IsString()
  @MaxLength(50)
  vehicleType?: string;

  @ApiPropertyOptional({ enum: DeliveryStatus, example: 'in_transit' })
  @IsOptional()
  @IsEnum(DeliveryStatus)
  status?: DeliveryStatus;

  @ApiPropertyOptional({ example: 'Ring doorbell twice' })
  @IsOptional()
  @IsString()
  deliveryNotes?: string;

  @ApiPropertyOptional({ example: 'https://example.com/proof.jpg' })
  @IsOptional()
  @IsString()
  @MaxLength(500)
  proofPhotoUrl?: string;
}

export class RateDeliveryDto {
  @ApiProperty({ example: 5, minimum: 1, maximum: 5 })
  @IsNumber()
  @Min(1)
  @Max(5)
  rating!: number;
}
