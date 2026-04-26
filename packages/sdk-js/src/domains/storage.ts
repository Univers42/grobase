import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type { PresignInput } from '../types.js';

export class StorageClient {
  constructor(private readonly http: HttpClient) {}

  presign<TResult = unknown>(input: PresignInput): Promise<TResult> {
    return this.http.request<TResult>(routes.storage.sign(input.bucket, input.key), {
      method: 'POST',
      body: {
        method: input.method ?? 'PUT',
        contentType: input.contentType,
      },
    });
  }
}
