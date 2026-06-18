export const ERROR_MESSAGES = {
  // Auth
  INVALID_CREDENTIALS: 'Invalid email or password',
  EMAIL_ALREADY_EXISTS: 'An account with this email already exists',
  USERNAME_ALREADY_EXISTS: 'This username is already taken',
  TOKEN_EXPIRED: 'Token has expired',
  TOKEN_INVALID: 'Invalid token',
  TOKEN_REVOKED: 'Token has been revoked',
  UNAUTHORIZED: 'You are not authorized to perform this action',
  FORBIDDEN: 'Access denied',

  // User
  USER_NOT_FOUND: 'User not found',
  CANNOT_FRIEND_SELF: 'You cannot send a friend request to yourself',
  ALREADY_FRIENDS: 'You are already friends with this user',
  FRIEND_REQUEST_EXISTS: 'A friend request already exists',
  FRIEND_REQUEST_NOT_FOUND: 'Friend request not found',

  // Event
  EVENT_NOT_FOUND: 'Event not found',
  EVENT_FULL: 'This event has reached its maximum number of participants',
  EVENT_ENDED: 'This event has already ended',
  ALREADY_JOINED: 'You have already joined this event',
  NOT_EVENT_OWNER: 'Only the event owner can perform this action',
  WRONG_EVENT_PASSWORD: 'Incorrect event password',

  // Playlist
  PLAYLIST_NOT_FOUND: 'Playlist not found',
  TRACK_ALREADY_IN_PLAYLIST: 'This track is already in the playlist',
  TRACK_NOT_IN_PLAYLIST: 'This track is not in the playlist',
  MAX_TRACKS_REACHED: 'Maximum number of tracks reached',
  NOT_PLAYLIST_OWNER: 'Only the playlist owner can perform this action',

  // Music
  TRACK_NOT_FOUND: 'Track not found on Deezer',
  DEEZER_API_ERROR: 'Failed to fetch data from Deezer',
  SEARCH_QUERY_REQUIRED: 'Search query is required',

  // Subscription
  ALREADY_SUBSCRIBED: 'You already have an active subscription',
  SUBSCRIPTION_NOT_FOUND: 'Subscription not found',
  FEATURE_NOT_AVAILABLE: 'This feature is not available on your plan',

  // Delegation
  DELEGATION_NOT_FOUND: 'Delegation not found',
  DELEGATION_EXPIRED: 'This delegation has expired',
  DEVICE_NOT_FOUND: 'Device not found',

  // General
  VALIDATION_ERROR: 'Validation failed',
  INTERNAL_ERROR: 'An internal server error occurred',
  NOT_FOUND: 'Resource not found',
  RATE_LIMIT_EXCEEDED: 'Too many requests, please try again later',
} as const;

export type ErrorMessage = typeof ERROR_MESSAGES[keyof typeof ERROR_MESSAGES];
