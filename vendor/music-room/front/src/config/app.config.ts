import { Platform } from 'react-native';

/**
 * Application-wide configuration constants.
 */
export const APP_CONFIG = {
  name: 'Music Room',
  version: '1.0.0',
  buildNumber: 1,

  // API
  apiBaseUrl: process.env.EXPO_PUBLIC_API_URL || 'http://localhost:3000',
  apiTimeout: 15000,
  maxRetries: 3,

  // WebSocket
  wsUrl: process.env.EXPO_PUBLIC_WS_URL || 'http://localhost:3000',
  wsReconnectAttempts: 5,
  wsReconnectDelay: 3000,

  // Auth
  accessTokenExpiry: 15 * 60 * 1000, // 15 minutes
  refreshTokenExpiry: 7 * 24 * 60 * 60 * 1000, // 7 days
  minPasswordLength: 8,

  // Pagination
  defaultPageSize: 25,
  maxPageSize: 100,

  // Search
  searchDebounceMs: 300,
  minSearchLength: 2,
  maxRecentSearches: 10,

  // Media
  previewDuration: 30, // seconds (Deezer preview)
  maxTrackVoteValue: 1,
  maxTracksPerPlaylist: 500,

  // Location
  defaultNearbyRadius: 5000, // meters
  maxNearbyRadius: 50000,
  locationUpdateInterval: 30000, // 30 seconds

  // Notifications
  maxVisibleNotifications: 50,
  notificationPollInterval: 60000,

  // Platform-specific
  platform: Platform.OS,
  isIOS: Platform.OS === 'ios',
  isAndroid: Platform.OS === 'android',
  isWeb: Platform.OS === 'web',
} as const;

export type AppConfig = typeof APP_CONFIG;
