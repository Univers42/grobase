// App-wide constants

export const GENRES = [
  'Pop', 'Rock', 'Hip-Hop', 'R&B', 'Jazz', 'Classical',
  'Electronic', 'Country', 'Reggae', 'Blues', 'Metal',
  'Folk', 'Latin', 'Punk', 'Soul', 'Funk', 'Indie', 'World',
] as const;

export const MOODS = [
  'Happy', 'Sad', 'Energetic', 'Relaxed', 'Romantic',
  'Focus', 'Party', 'Chill', 'Melancholic', 'Uplifting',
] as const;

export const VISIBILITY_OPTIONS = [
  { label: 'Public', value: 'public', icon: 'earth' },
  { label: 'Private', value: 'private', icon: 'lock' },
] as const;

export const LICENSE_TYPES = [
  { label: 'Open', value: 'open', description: 'Anyone can join' },
  { label: 'Invited Only', value: 'invited_only', description: 'Only invited users' },
  { label: 'Geo + Time', value: 'geo_time', description: 'Location and time restricted' },
] as const;

export const COLLABORATION_TYPES = [
  { label: 'Solo', value: 'solo', description: 'Only you can edit' },
  { label: 'Collaborative', value: 'collaborative', description: 'Multiple editors' },
] as const;

export const PLAN_LABELS = {
  free: 'Free',
  premium: 'Premium',
} as const;

export const PLATFORM_ICONS: Record<string, string> = {
  ios: 'apple',
  android: 'android',
  web: 'web',
};

export const MAX_SEARCH_RESULTS = 25;
export const DEBOUNCE_MS = 400;
export const SOCKET_RECONNECT_ATTEMPTS = 5;
export const SOCKET_RECONNECT_DELAY = 1000;
