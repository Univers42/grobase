/**
 * Cookie consent service — talks to the backend depending on whether the
 * visitor is authenticated. The local-storage source of truth lives in
 * ConsentContext; this file is only the network layer.
 */
import { apiRequest, isAuthenticated } from './api';

export type ConsentCategory = 'necessary' | 'functional' | 'analytics' | 'marketing';

export interface ConsentChoice {
  necessary: true; // always true — locked
  functional: boolean;
  analytics: boolean;
  marketing: boolean;
}

export type ConsentAction = 'accept_all' | 'reject_all' | 'custom';

/** Records the choice on the backend. Silent failure — UX must not break. */
export async function recordConsentOnServer(
  action: ConsentAction,
  choice: ConsentChoice,
  anonymousId: string,
): Promise<void> {
  try {
    if (isAuthenticated()) {
      // Logged-in: one POST per non-necessary category into UserConsent table
      const categories: ConsentCategory[] = ['functional', 'analytics', 'marketing'];
      await Promise.all(
        categories.map((cat) =>
          apiRequest('/api/gdpr/consent', {
            method: 'POST',
            body: { consent_type: cat, consented: choice[cat] },
          }).catch(() => null),
        ),
      );
      return;
    }

    await apiRequest('/api/consent/anonymous', {
      method: 'POST',
      body: { action, anonymousId, categories: choice },
    });
  } catch {
    // Silent — the choice still lives in localStorage on the client
  }
}
