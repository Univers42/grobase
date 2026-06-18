import { applyDecorators } from '@nestjs/common';
import {
  ApiResponse,
  ApiBearerAuth,
  ApiOperation,
  ApiParam,
  ApiQuery,
  ApiBody,
} from '@nestjs/swagger';

/**
 * Common Swagger decorator for authenticated endpoints
 */
export function ApiAuth() {
  return applyDecorators(
    ApiBearerAuth(),
    ApiResponse({ status: 401, description: 'Unauthorized - Invalid or missing token' }),
    ApiResponse({ status: 403, description: 'Forbidden - Insufficient permissions' }),
  );
}

/**
 * Common Swagger decorator for paginated endpoints
 */
export function ApiPaginated(description?: string) {
  return applyDecorators(
    ApiQuery({ name: 'page', required: false, type: Number, description: 'Page number (default: 1)' }),
    ApiQuery({ name: 'limit', required: false, type: Number, description: 'Items per page (default: 20, max: 100)' }),
    ApiResponse({
      status: 200,
      description: description || 'Paginated list retrieved successfully',
    }),
  );
}

/**
 * Common Swagger decorator for endpoints with MongoDB ObjectId param
 */
export function ApiObjectIdParam(name = 'id', description?: string) {
  return applyDecorators(
    ApiParam({
      name,
      type: String,
      description: description || 'MongoDB ObjectId',
      example: '507f1f77bcf86cd799439011',
    }),
    ApiResponse({ status: 400, description: 'Invalid ObjectId format' }),
    ApiResponse({ status: 404, description: 'Resource not found' }),
  );
}

/**
 * Common Swagger decorator for create endpoints
 */
export function ApiCreate(description: string) {
  return applyDecorators(
    ApiAuth(),
    ApiResponse({ status: 201, description }),
    ApiResponse({ status: 400, description: 'Validation error' }),
    ApiResponse({ status: 409, description: 'Conflict - Resource already exists' }),
  );
}

/**
 * Common Swagger decorator for update endpoints
 */
export function ApiUpdate(description: string) {
  return applyDecorators(
    ApiAuth(),
    ApiResponse({ status: 200, description }),
    ApiResponse({ status: 400, description: 'Validation error' }),
    ApiResponse({ status: 404, description: 'Resource not found' }),
  );
}

/**
 * Common Swagger decorator for delete endpoints
 */
export function ApiDelete(description: string) {
  return applyDecorators(
    ApiAuth(),
    ApiResponse({ status: 200, description }),
    ApiResponse({ status: 404, description: 'Resource not found' }),
  );
}
