import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type { AnalyticsTrackInput } from '../types.js';

export class AnalyticsClient {
  constructor(private readonly http: HttpClient) {}

  async track(input: AnalyticsTrackInput | string, data: Record<string, unknown> = {}): Promise<void> {
    const event = typeof input === 'string' ? { eventType: input, data } : input;

    await this.http.request<void>(routes.analytics.events, {
      method: 'POST',
      body: {
        eventType: event.eventType,
        data: event.data ?? {},
      },
    });
  }
}
