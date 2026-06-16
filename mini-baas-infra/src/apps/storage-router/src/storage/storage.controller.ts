/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   storage.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Body, Controller, Delete, Get, Param, Post, Put, Query, Req, Res, UseGuards,
  PayloadTooLargeException,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { StorageService } from './storage.service';
import { PresignDto } from './dto/presign.dto';
import { parseTransform } from './image-transform';
import type { PolicyPrincipal } from './bucket-policy';
import type { Request, Response } from 'express';

// NOTE on routing: the controller base path is the FULL public path
// (`storage/v1`) and the Kong `storage-api` route uses `strip_path: false`, so
// `/storage/v1/<op>/...` is forwarded verbatim and matches here. The previous
// `@Controller('sign')` + `strip_path: true` combination 404'd through Kong
// (Kong stripped `/storage/v1/sign`, leaving `/<bucket>/<key>` which never
// matched `/sign/...`). Health (`/health/*`) and metrics (`/metrics`) keep
// their own controllers and are unaffected by this base path.
@ApiTags('storage')
@Controller('storage/v1')
@UseGuards(AuthGuard)
export class StorageController {
  private static readonly MAX_BYTES = 50 * 1024 * 1024;

  constructor(private readonly service: StorageService) {}

  // ── presigned URLs (direct-S3 path; needs S3_PUBLIC_ENDPOINT to be usable
  //    by external clients) ────────────────────────────────────────────────
  @Post('sign/:bucket/*')
  @ApiParam({ name: 'bucket' })
  @ApiOperation({ summary: 'Generate a presigned URL (key auto-prefixed with user id)' })
  async presign(
    @CurrentUser() user: UserContext,
    @Param('bucket') bucket: string,
    @Req() req: Request,
    @Body() dto: PresignDto,
  ) {
    return this.service.presign(bucket, this.wildcard(req), user.id, dto);
  }

  // ── proxied object I/O (works with the internal minio endpoint) ──────────
  @Put('object/:bucket/*')
  @ApiOperation({ summary: 'Upload an object (binary body, owner-scoped)' })
  async upload(
    @CurrentUser() user: UserContext,
    @Param('bucket') bucket: string,
    @Req() req: Request,
  ) {
    const body = await this.readRawBody(req);
    const contentType = (req.headers['content-type'] as string) || 'application/octet-stream';
    // Pass the authenticated tenant so the write is metered on the tenant
    // dimension (Track-B B1d storage.bytes); falls back to user.id server-side.
    // The principal (A1) is consulted by the bucket-policy ONLY when that flag is
    // ON — otherwise it is inert and the call is byte-parity.
    return this.service.putObject(
      bucket, this.wildcard(req), user.id, body, contentType, user.tenantId, principalOf(user),
    );
  }

  @Get('object/:bucket/*')
  @ApiOperation({ summary: 'Download an object (owner-scoped; ?width=&height=&format= for image variants)' })
  async download(
    @CurrentUser() user: UserContext,
    @Param('bucket') bucket: string,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    // parseTransform returns undefined when STORAGE_TRANSFORMS_ENABLED is OFF (so
    // the original bytes are served, byte-identical) OR when ON with no transform
    // params. A bounded TransformSpec only when at least one valid param is present.
    const transform = parseTransform(req.query as Record<string, unknown>);
    const obj = await this.service.getObject(
      bucket, this.wildcard(req), user.id, principalOf(user), transform,
    );
    res.setHeader('Content-Type', obj.contentType);
    res.setHeader('Content-Length', String(obj.size));
    res.send(obj.body);
  }

  @Delete('object/:bucket/*')
  @ApiOperation({ summary: 'Delete an object (owner-scoped)' })
  async remove(
    @CurrentUser() user: UserContext,
    @Param('bucket') bucket: string,
    @Req() req: Request,
  ) {
    return this.service.deleteObject(bucket, this.wildcard(req), user.id, principalOf(user));
  }

  @Get('list/:bucket')
  @ApiOperation({ summary: 'List objects the caller owns under bucket/prefix' })
  async list(
    @CurrentUser() user: UserContext,
    @Param('bucket') bucket: string,
    @Query('prefix') prefix?: string,
  ) {
    return { objects: await this.service.listObjects(bucket, user.id, prefix ?? '', principalOf(user)) };
  }

  // ── bucket management ────────────────────────────────────────────────────
  @Get('bucket')
  @ApiOperation({ summary: 'List buckets' })
  async listBuckets() {
    return { buckets: await this.service.listBuckets() };
  }

  @Post('bucket/:name')
  @ApiOperation({ summary: 'Create a bucket (idempotent)' })
  async createBucket(@Param('name') name: string) {
    return this.service.createBucket(name);
  }

  // ── helpers ──────────────────────────────────────────────────────────────
  private wildcard(req: Request): string {
    // Object path = the segments after /storage/v1/<op>/<bucket>/. Parsing the
    // URL is robust across path-to-regexp versions (the unnamed `*` param can
    // come back empty depending on the version), and preserves nested paths.
    const pathOnly = (req.path || req.url || '').split('?')[0];
    const segs = pathOnly.split('/').filter(Boolean); // [storage, v1, op, bucket, ...path]
    return segs.slice(4).map((s) => safeDecode(s)).join('/');
  }

  private async readRawBody(req: Request): Promise<Buffer> {
    // If a body parser already produced a Buffer/string, reuse it; otherwise
    // drain the raw stream (octet-stream/binary is not consumed by the JSON
    // parser, so the stream is intact here).
    if (Buffer.isBuffer(req.body)) return req.body;
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of req) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.byteLength;
      if (total > StorageController.MAX_BYTES) {
        throw new PayloadTooLargeException(`object exceeds ${StorageController.MAX_BYTES} bytes`);
      }
      chunks.push(buf);
    }
    return Buffer.concat(chunks);
  }
}

function safeDecode(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

/** The authz subject the A1 bucket-policy is evaluated against (userId + role).
 *  Inert unless STORAGE_BUCKET_POLICY_ENABLED is ON (policy is then undefined). */
function principalOf(user: UserContext): PolicyPrincipal {
  return { userId: user.id, role: user.role ?? 'authenticated' };
}
