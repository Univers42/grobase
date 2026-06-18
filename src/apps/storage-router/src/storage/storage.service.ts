/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   storage.service.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  Logger,
  OnModuleInit,
  OnApplicationShutdown,
  BadRequestException,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  S3Client,
  GetObjectCommand,
  PutObjectCommand,
  DeleteObjectCommand,
  ListObjectsV2Command,
  ListBucketsCommand,
  CreateBucketCommand,
  HeadBucketCommand,
  S3ServiceException,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { PresignDto } from './dto/presign.dto';
import { UsageMeter } from './usage-meter';
import { BucketPolicy, type BucketAction, type PolicyPrincipal } from './bucket-policy';
import { applyTransform, isTransformableType, type TransformSpec } from './image-transform';

export interface StorageObject {
  key: string;
  size: number;
  lastModified: string | null;
  etag?: string;
}

export interface BucketInfo {
  name: string;
  createdAt: string | null;
}

@Injectable()
export class StorageService implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger(StorageService.name);
  private s3!: S3Client;
  private defaultExpires!: number;
  private publicEndpoint?: string;
  private maxUploadBytes!: number;
  // Track-B B1d-storage usage meter. `undefined` when STORAGE_METERING is OFF
  // (the default) — see UsageMeter.fromConfig — so the write path is byte-parity.
  private meter?: UsageMeter;
  // A1 bucket-level ABAC policy. `undefined` when STORAGE_BUCKET_POLICY_ENABLED is
  // OFF (the default) — see BucketPolicy.fromConfig — so no rule is ever consulted
  // and the read/write paths are byte-parity (owner-scope governs alone).
  private policy?: BucketPolicy;

  constructor(private readonly config: ConfigService) {}

  onModuleInit(): void {
    // Sub-flags OFF (default) ⇒ fromConfig returns undefined ⇒ no meter / no
    // policy, no interval, no Redis client created. Parity is preserved before I/O.
    this.meter = UsageMeter.fromConfig(process.env);
    this.policy = BucketPolicy.fromConfig(process.env);
    this.s3 = new S3Client({
      endpoint: this.config.getOrThrow<string>('S3_ENDPOINT'),
      region: this.config.get<string>('S3_REGION', 'us-east-1'),
      credentials: {
        accessKeyId: this.config.get<string>('S3_ACCESS_KEY', 'minioadmin'),
        secretAccessKey: this.config.get<string>('S3_SECRET_KEY', 'minioadmin'),
      },
      forcePathStyle: true, // required for MinIO
    });

    this.defaultExpires = this.config.get<number>('PRESIGN_EXPIRES_SECONDS', 3600);
    // Optional public-facing S3 endpoint for presigned URLs that browsers must
    // reach (S3_ENDPOINT is the internal docker hostname minio:9000, which is
    // not routable from outside the network). When unset, presign falls back to
    // S3_ENDPOINT — fine for server-to-server, broken for external clients,
    // which is why upload()/download() proxy through this service instead.
    this.publicEndpoint = this.config.get<string>('S3_PUBLIC_ENDPOINT') || undefined;
    this.maxUploadBytes = this.config.get<number>('STORAGE_MAX_UPLOAD_BYTES', 50 * 1024 * 1024);
    this.logger.log('S3 client initialised');
  }

  /** Lightweight S3 connectivity check (ListBuckets). */
  async isHealthy(): Promise<boolean> {
    try {
      await this.s3.send(new ListBucketsCommand({}));
      return true;
    } catch {
      return false;
    }
  }

  /** Auto-prefix every object key with the caller's user id for isolation. */
  private ownedKey(userId: string, objectPath: string): string {
    const clean = objectPath.replace(/^\/+/, '');
    if (!clean) throw new BadRequestException('object path required');
    return `${userId}/${clean}`;
  }

  /**
   * Consult the bucket-level ABAC policy (A1) — a no-op when the policy flag is
   * OFF (policy === undefined ⇒ byte-parity). When ON, a policy-denied action
   * throws Forbidden (403) and the S3 op is never reached, so a denied principal
   * never learns whether the object exists (no leak beyond the deny decision).
   * The owner-prefix isolation is independent and always applies on top.
   */
  private assertBucketAllowed(
    bucket: string,
    action: BucketAction,
    principal?: PolicyPrincipal,
  ): void {
    if (!this.policy || !principal) return;
    if (!this.policy.allows(bucket, action, principal)) {
      throw new ForbiddenException(`bucket policy denies ${action} on ${bucket}`);
    }
  }

  async presign(bucket: string, objectPath: string, userId: string, dto: PresignDto) {
    const key = this.ownedKey(userId, objectPath);
    const expiresIn = Math.min(Math.max(dto.expiresIn ?? this.defaultExpires, 60), 86400);

    const command =
      dto.method === 'GET'
        ? new GetObjectCommand({ Bucket: bucket, Key: key })
        : new PutObjectCommand({
            Bucket: bucket,
            Key: key,
            ContentType: dto.contentType ?? 'application/octet-stream',
          });

    // Sign against the public endpoint when configured so the URL is reachable
    // by external clients; otherwise use the default (internal) client.
    const signer = this.publicEndpoint
      ? new S3Client({
          endpoint: this.publicEndpoint,
          region: this.config.get<string>('S3_REGION', 'us-east-1'),
          credentials: {
            accessKeyId: this.config.get<string>('S3_ACCESS_KEY', 'minioadmin'),
            secretAccessKey: this.config.get<string>('S3_SECRET_KEY', 'minioadmin'),
          },
          forcePathStyle: true,
        })
      : this.s3;

    const signedUrl = await getSignedUrl(signer, command, { expiresIn });

    return {
      signedUrl,
      expiresAt: new Date(Date.now() + expiresIn * 1000).toISOString(),
      method: dto.method,
      bucket,
      key,
    };
  }

  /** Server-side upload (proxied) — works even with an internal S3 endpoint. On
   *  a SUCCESSFUL write the object's byte size is added to the per-tenant
   *  `storage.bytes` usage meter (Track-B B1d) — recorded AFTER the S3 PutObject
   *  resolves, so a failed/rejected upload is never metered. `tenantId` is the
   *  authenticated tenant the router resolved (UserContext.tenantId); the meter
   *  is `undefined` (and this is a no-op) when STORAGE_METERING is OFF. */
  async putObject(
    bucket: string,
    objectPath: string,
    userId: string,
    body: Buffer,
    contentType?: string,
    tenantId?: string,
    principal?: PolicyPrincipal,
  ) {
    if (body.byteLength > this.maxUploadBytes) {
      throw new BadRequestException(
        `object exceeds max upload size (${this.maxUploadBytes} bytes)`,
      );
    }
    this.assertBucketAllowed(bucket, 'write', principal);
    const key = this.ownedKey(userId, objectPath);
    await this.s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: body,
        ContentType: contentType ?? 'application/octet-stream',
        Metadata: { 'owner-id': userId },
      }),
    );
    // SUCCESS path only — meter the bytes written for this tenant. The fallback
    // to userId keeps single-tenant deployments (tenantId == userId) metered.
    this.meter?.record(tenantId ?? userId, body.byteLength);
    return { bucket, key, size: body.byteLength };
  }

  /**
   * Server-side download (proxied) — returns bytes + content type. When a
   * `transform` spec is supplied (A1, only ever non-undefined while
   * STORAGE_TRANSFORMS_ENABLED is ON) and the object is an image, the bytes are
   * resized/reformatted with sharp BEFORE returning; otherwise the ORIGINAL bytes
   * are returned verbatim (byte-parity). Bucket policy (A1) is consulted first.
   */
  async getObject(
    bucket: string,
    objectPath: string,
    userId: string,
    principal?: PolicyPrincipal,
    transform?: TransformSpec,
  ) {
    this.assertBucketAllowed(bucket, 'read', principal);
    const key = this.ownedKey(userId, objectPath);
    try {
      const out = await this.s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
      const body = out.Body as { transformToByteArray?: () => Promise<Uint8Array> } | undefined;
      if (!body?.transformToByteArray) throw new NotFoundException('object not found');
      const bytes = await body.transformToByteArray();
      const original = Buffer.from(bytes);
      const contentType = out.ContentType ?? 'application/octet-stream';

      if (transform && isTransformableType(contentType)) {
        const variant = await applyTransform(original, transform, contentType);
        return {
          body: variant.body,
          contentType: variant.contentType,
          size: variant.body.byteLength,
        };
      }
      // No transform (or non-image) → original bytes, byte-identical to the
      // pre-transform path.
      return { body: original, contentType, size: out.ContentLength ?? bytes.byteLength };
    } catch (err) {
      throw this.mapS3Error(err, 'object');
    }
  }

  async deleteObject(
    bucket: string,
    objectPath: string,
    userId: string,
    principal?: PolicyPrincipal,
  ) {
    this.assertBucketAllowed(bucket, 'write', principal);
    const key = this.ownedKey(userId, objectPath);
    await this.s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
    return { bucket, key, deleted: true };
  }

  /** List objects the caller owns under bucket/prefix (owner-prefix stripped). */
  async listObjects(
    bucket: string,
    userId: string,
    prefix = '',
    principal?: PolicyPrincipal,
  ): Promise<StorageObject[]> {
    this.assertBucketAllowed(bucket, 'read', principal);
    const ownerPrefix = `${userId}/`;
    const cleanPrefix = prefix.replace(/^\/+/, '');
    try {
      const out = await this.s3.send(
        new ListObjectsV2Command({
          Bucket: bucket,
          Prefix: `${ownerPrefix}${cleanPrefix}`,
          MaxKeys: 1000,
        }),
      );
      return (out.Contents ?? []).map((o) => ({
        key: (o.Key ?? '').slice(ownerPrefix.length),
        size: o.Size ?? 0,
        lastModified: o.LastModified ? o.LastModified.toISOString() : null,
        etag: o.ETag?.replaceAll('"', ''),
      }));
    } catch (err) {
      throw this.mapS3Error(err, 'bucket');
    }
  }

  async listBuckets(): Promise<BucketInfo[]> {
    const out = await this.s3.send(new ListBucketsCommand({}));
    return (out.Buckets ?? []).map((b) => ({
      name: b.Name ?? '',
      createdAt: b.CreationDate ? b.CreationDate.toISOString() : null,
    }));
  }

  async createBucket(name: string): Promise<{ name: string; created: boolean }> {
    this.assertBucketName(name);
    try {
      await this.s3.send(new HeadBucketCommand({ Bucket: name }));
      return { name, created: false }; // already exists — idempotent
    } catch {
      await this.s3.send(new CreateBucketCommand({ Bucket: name }));
      return { name, created: true };
    }
  }

  private assertBucketName(name: string): void {
    if (!/^[a-z0-9][a-z0-9.-]{2,62}$/.test(name)) {
      throw new BadRequestException('invalid bucket name (3-63 chars, lowercase alnum/.-)');
    }
  }

  private mapS3Error(err: unknown, kind: 'object' | 'bucket') {
    if (err instanceof S3ServiceException) {
      const code = err.name;
      if (code === 'NoSuchKey' || code === 'NotFound' || code === 'NoSuchBucket') {
        return new NotFoundException(`${kind} not found`);
      }
    }
    return err;
  }

  /** Flush the last partial usage window + close the meter's Redis client on
   *  graceful shutdown (no-op when metering is OFF). */
  async onApplicationShutdown(): Promise<void> {
    await this.meter?.stop();
  }
}
