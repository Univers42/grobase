/**
 * Newsletter Service
 * API calls for newsletter subscription management
 */
import { apiRequest } from './api';

interface ApiWrapper<T> {
  success: boolean;
  data: T;
}

interface NewsletterResponse {
  message: string;
}

interface NewsletterStats {
  total: number;
  active: number;
  confirmed: number;
}

/**
 * Subscribe to the newsletter (public — no auth needed)
 */
export async function subscribeNewsletter(
  email: string,
  firstName?: string,
): Promise<NewsletterResponse> {
  const wrapper = await apiRequest<ApiWrapper<NewsletterResponse>>('/api/newsletter/subscribe', {
    method: 'POST',
    body: { email, firstName },
  });
  return wrapper.data;
}

/**
 * Confirm newsletter subscription via token
 */
export async function confirmNewsletter(token: string): Promise<NewsletterResponse> {
  const wrapper = await apiRequest<ApiWrapper<NewsletterResponse>>(
    `/api/newsletter/confirm/${token}`,
  );
  return wrapper.data;
}

/**
 * Unsubscribe from the newsletter via token
 */
export async function unsubscribeNewsletter(token: string): Promise<NewsletterResponse> {
  const wrapper = await apiRequest<ApiWrapper<NewsletterResponse>>(
    `/api/newsletter/unsubscribe/${token}`,
  );
  return wrapper.data;
}

/**
 * Get newsletter stats (admin only)
 */
export async function getNewsletterStats(): Promise<NewsletterStats> {
  const wrapper = await apiRequest<ApiWrapper<NewsletterStats>>('/api/newsletter/stats');
  return wrapper.data;
}
