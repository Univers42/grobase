import { api } from './api';

export const authApi = {
  register: (data: { email: string; password: string; displayName: string }) =>
    api.post('/auth/register', data),

  login: (data: { email: string; password: string }) =>
    api.post<{ accessToken: string; refreshToken: string }>('/auth/login', data),

  refresh: (refreshToken: string) =>
    api.post<{ accessToken: string; refreshToken: string }>('/auth/refresh', { refreshToken }),

  logout: (refreshToken: string, token: string) =>
    api.post('/auth/logout', { refreshToken }, token),

  forgotPassword: (email: string) =>
    api.post('/auth/forgot-password', { email }),

  resetPassword: (data: { token: string; newPassword: string }) =>
    api.post('/auth/reset-password', data),

  googleMobile: (data: { idToken: string }) =>
    api.post<{ accessToken: string; refreshToken: string }>('/auth/google/mobile', data),

  facebookMobile: (data: { accessToken: string }) =>
    api.post<{ accessToken: string; refreshToken: string }>('/auth/facebook/mobile', data),
};

export const userApi = {
  getMe: (token: string) =>
    api.get('/users/me', token),

  getProfile: (userId: string, token: string) =>
    api.get(`/users/${userId}/profile`, token),

  updatePublicInfo: (data: any, token: string) =>
    api.patch('/users/me/public-info', data, token),

  updateFriendsInfo: (data: any, token: string) =>
    api.patch('/users/me/friends-info', data, token),

  updatePrivateInfo: (data: any, token: string) =>
    api.patch('/users/me/private-info', data, token),

  updateMusicPreferences: (data: any, token: string) =>
    api.patch('/users/me/music-preferences', data, token),

  sendFriendRequest: (userId: string, token: string) =>
    api.post(`/users/${userId}/friend-request`, undefined, token),

  acceptFriendRequest: (userId: string, token: string) =>
    api.post(`/users/${userId}/friend-accept`, undefined, token),

  removeFriend: (userId: string, token: string) =>
    api.delete(`/users/${userId}/friend`, token),

  getFriends: (token: string) =>
    api.get('/users/friends', token),

  getPendingRequests: (token: string) =>
    api.get('/users/friends/pending', token),
};

export const musicApi = {
  searchTracks: (query: string, token: string) =>
    api.get(`/music/search?q=${encodeURIComponent(query)}`, token),

  searchArtists: (query: string, token: string) =>
    api.get(`/music/search/artists?q=${encodeURIComponent(query)}`, token),

  getTrack: (id: number, token: string) =>
    api.get(`/music/track/${id}`, token),

  getArtist: (id: number, token: string) =>
    api.get(`/music/artist/${id}`, token),

  getArtistTopTracks: (id: number, token: string) =>
    api.get(`/music/artist/${id}/top`, token),

  getAlbum: (id: number, token: string) =>
    api.get(`/music/album/${id}`, token),
};

export const eventApi = {
  create: (data: any, token: string) =>
    api.post('/events', data, token),

  getAll: (token: string) =>
    api.get('/events', token),

  getById: (id: string, token: string) =>
    api.get(`/events/${id}`, token),

  update: (id: string, data: any, token: string) =>
    api.patch(`/events/${id}`, data, token),

  delete: (id: string, token: string) =>
    api.delete(`/events/${id}`, token),

  invite: (id: string, userIds: string[], token: string) =>
    api.post(`/events/${id}/invite`, { userIds }, token),

  suggestTrack: (id: string, data: any, token: string) =>
    api.post(`/events/${id}/suggest`, data, token),

  vote: (eventId: string, trackId: string, token: string) =>
    api.post(`/events/${eventId}/vote/${trackId}`, undefined, token),

  removeVote: (eventId: string, trackId: string, token: string) =>
    api.delete(`/events/${eventId}/vote/${trackId}`, token),
};

export const playlistApi = {
  create: (data: any, token: string) =>
    api.post('/playlists', data, token),

  getAll: (token: string, page = 1) =>
    api.get(`/playlists?page=${page}`, token),

  getById: (id: string, token: string) =>
    api.get(`/playlists/${id}`, token),

  update: (id: string, data: any, token: string) =>
    api.patch(`/playlists/${id}`, data, token),

  delete: (id: string, token: string) =>
    api.delete(`/playlists/${id}`, token),

  invite: (id: string, collaboratorIds: string[], token: string) =>
    api.post(`/playlists/${id}/invite`, { collaboratorIds }, token),

  addTrack: (id: string, data: any, token: string) =>
    api.post(`/playlists/${id}/tracks`, data, token),

  removeTrack: (id: string, deezerTrackId: number, baseVersion: number, token: string) =>
    api.delete(`/playlists/${id}/tracks/${deezerTrackId}?baseVersion=${baseVersion}`, token),

  reorderTrack: (id: string, data: any, token: string) =>
    api.patch(`/playlists/${id}/tracks/reorder`, data, token),

  getOperations: (id: string, token: string) =>
    api.get(`/playlists/${id}/operations`, token),
};

export const delegationApi = {
  // Devices
  getMyDevices: (token: string) =>
    api.get('/delegation/devices', token),

  registerDevice: (data: { name: string; platform: string; deviceToken?: string }, token: string) =>
    api.post('/delegation/devices', data, token),

  removeDevice: (deviceId: string, token: string) =>
    api.delete(`/delegation/devices/${deviceId}`, token),

  heartbeat: (deviceId: string, token: string) =>
    api.patch(`/delegation/devices/${deviceId}/heartbeat`, {}, token),

  // Delegations
  getMyDelegations: (token: string) =>
    api.get('/delegation', token),

  createDelegation: (data: {
    delegateId: string;
    targetDeviceId: string;
    permissions: string[];
    expiresAt?: string;
  }, token: string) =>
    api.post('/delegation', data, token),

  acceptDelegation: (delegationId: string, token: string) =>
    api.post(`/delegation/${delegationId}/accept`, undefined, token),

  revokeDelegation: (delegationId: string, token: string) =>
    api.post(`/delegation/${delegationId}/revoke`, undefined, token),

  updatePermissions: (delegationId: string, permissions: string[], token: string) =>
    api.patch(`/delegation/${delegationId}/permissions`, { permissions }, token),
};

export const subscriptionApi = {
  getMySubscription: (token: string) =>
    api.get('/subscriptions/me', token),

  upgrade: (data: { plan: string; paymentMethodId?: string }, token: string) =>
    api.post('/subscriptions/upgrade', data, token),

  cancel: (data: { cancelAtPeriodEnd?: boolean }, token: string) =>
    api.post('/subscriptions/cancel', data, token),
};

export const loggingApi = {
  getRecentLogs: (token: string, limit = 50) =>
    api.get(`/admin/logs/recent?limit=${limit}`, token),

  getPlatformStats: (token: string) =>
    api.get('/admin/logs/platforms', token),

  getErrorStats: (token: string) =>
    api.get('/admin/logs/errors', token),

  getSlowestEndpoints: (token: string, limit = 10) =>
    api.get(`/admin/logs/slowest?limit=${limit}`, token),
};
