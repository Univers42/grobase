/**
 * Feature flag configuration.
 * Controls feature availability across the application.
 */

export interface FeatureFlags {
  /** Enable real-time voting via WebSockets */
  enableVoting: boolean;
  /** Enable collaborative playlist editing */
  enableCollaborativePlaylists: boolean;
  /** Enable IoT device control */
  enableIoT: boolean;
  /** Enable offline mode with sync */
  enableOfflineMode: boolean;
  /** Enable social features (friends, sharing) */
  enableSocial: boolean;
  /** Enable subscription/premium features */
  enableSubscriptions: boolean;
  /** Enable geolocation-based event discovery */
  enableGeolocation: boolean;
  /** Enable push notifications */
  enablePushNotifications: boolean;
  /** Enable analytics tracking */
  enableAnalytics: boolean;
  /** Enable dark mode */
  enableDarkMode: boolean;
}

const defaultFlags: FeatureFlags = {
  enableVoting: true,
  enableCollaborativePlaylists: true,
  enableIoT: false,
  enableOfflineMode: true,
  enableSocial: true,
  enableSubscriptions: true,
  enableGeolocation: true,
  enablePushNotifications: true,
  enableAnalytics: false,
  enableDarkMode: true,
};

let currentFlags: FeatureFlags = { ...defaultFlags };

export function getFeatureFlags(): FeatureFlags {
  return { ...currentFlags };
}

export function isFeatureEnabled(feature: keyof FeatureFlags): boolean {
  return currentFlags[feature] ?? false;
}

export function setFeatureFlags(flags: Partial<FeatureFlags>): void {
  currentFlags = { ...currentFlags, ...flags };
}

export function resetFeatureFlags(): void {
  currentFlags = { ...defaultFlags };
}
