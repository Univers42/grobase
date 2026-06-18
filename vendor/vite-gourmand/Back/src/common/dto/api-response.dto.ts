/**
 * API Response DTOs
 * Standard response structures for Swagger documentation
 */
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class ApiSuccessResponse<T> {
  @ApiProperty({ example: true })
  success = true as const;

  @ApiProperty({ example: 200 })
  statusCode!: number;

  @ApiProperty({ example: 'Operation successful' })
  message!: string;

  @ApiProperty()
  data!: T;

  @ApiProperty({ example: '/api/resource' })
  path!: string;

  @ApiProperty({ example: '2024-01-15T10:30:00.000Z' })
  timestamp!: string;
}

export class ApiErrorResponse {
  @ApiProperty({ example: false })
  success = false as const;

  @ApiProperty({ example: 400 })
  statusCode!: number;

  @ApiProperty({ example: 'Validation failed' })
  message!: string;

  @ApiProperty({ example: 'BadRequestException' })
  error!: string;

  @ApiProperty({ example: '/api/resource' })
  path!: string;

  @ApiProperty({ example: '2024-01-15T10:30:00.000Z' })
  timestamp!: string;

  @ApiPropertyOptional()
  details?: unknown;
}
