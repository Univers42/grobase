/**
 * Public anonymous consent endpoint.
 *
 * Visitors who are not logged in still need a record of their cookie choice
 * for CNIL / GDPR audit purposes. Logged-in users use /api/gdpr/consent
 * instead (which writes to the relational UserConsent table).
 *
 * This endpoint is append-only, writes to MongoDB AuditLog with a hashed IP
 * to avoid storing PII while still allowing aggregate audit queries.
 */
import { Body, Controller, HttpCode, Post, Req } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { createHash } from 'node:crypto';
import {
  IsBoolean,
  IsIn,
  IsOptional,
  IsString,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { Public } from '../common/decorators/public.decorator';
import { log as logAudit } from '../Model/nosql/services/audit-log.service';

export class AnonymousConsentCategoriesDto {
  @IsBoolean()
  necessary!: boolean;

  @IsBoolean()
  functional!: boolean;

  @IsBoolean()
  analytics!: boolean;

  @IsBoolean()
  marketing!: boolean;
}

export class AnonymousConsentDto {
  @IsOptional()
  @IsString()
  @MaxLength(80)
  anonymousId?: string;

  @IsIn(['accept_all', 'reject_all', 'custom'])
  action!: 'accept_all' | 'reject_all' | 'custom';

  @ValidateNested()
  @Type(() => AnonymousConsentCategoriesDto)
  categories!: AnonymousConsentCategoriesDto;
}

function hashIp(ip: string | undefined): string | undefined {
  if (!ip) return undefined;
  const salt = process.env.JWT_SECRET ?? 'vg-consent-salt';
  return createHash('sha256')
    .update(`${ip}|${salt}`)
    .digest('hex')
    .slice(0, 32);
}

function getClientIp(req: Request): string | undefined {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string') return forwarded.split(',')[0]?.trim();
  return req.ip;
}

@ApiTags('consent')
@Controller('consent')
export class ConsentController {
  @Public()
  @Post('anonymous')
  @HttpCode(204)
  @ApiOperation({
    summary: 'Record a cookie consent event for an anonymous visitor',
  })
  recordAnonymous(@Body() dto: AnonymousConsentDto, @Req() req: Request): void {
    const userAgent = req.headers['user-agent'];
    const ipHash = hashIp(getClientIp(req));

    // Fire-and-forget: don't block the response on Mongo
    void logAudit('create', 'consent_anonymous', {
      newState: {
        action: dto.action,
        categories: dto.categories,
        anonymousId: dto.anonymousId,
      },
      ipAddress: ipHash,
      userAgent: typeof userAgent === 'string' ? userAgent : undefined,
    }).catch(() => {
      // MongoDB unreachable shouldn't break the user's consent flow
    });
  }
}
