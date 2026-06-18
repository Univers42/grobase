# Music Room — API REST Documentation

This directory contains the API reference documentation for Music Room.

## Live Documentation

When the back-end server is running, Swagger UI is available at:

```
GET /api/docs
```

The OpenAPI specification (JSON) can be exported at:

```
GET /api/docs-json
```

## API Overview

### Authentication
| Method | Endpoint                    | Description                    | Auth |
|--------|-----------------------------|--------------------------------|------|
| POST   | `/auth/register`            | Register with email/password   | No   |
| POST   | `/auth/login`               | Login with email/password      | No   |
| POST   | `/auth/refresh`             | Refresh access token           | No   |
| POST   | `/auth/logout`              | Logout (invalidate refresh)    | Yes  |
| GET    | `/auth/verify-email`        | Verify email with token        | No   |
| POST   | `/auth/forgot-password`     | Request password reset         | No   |
| POST   | `/auth/reset-password`      | Reset password with token      | No   |
| GET    | `/auth/google`              | Google OAuth login             | No   |
| GET    | `/auth/google/callback`     | Google OAuth callback          | No   |
| GET    | `/auth/facebook`            | Facebook OAuth login           | No   |
| GET    | `/auth/facebook/callback`   | Facebook OAuth callback        | No   |
| POST   | `/auth/link/google`         | Link Google to existing acct   | Yes  |
| POST   | `/auth/link/facebook`       | Link Facebook to existing acct | Yes  |

### Users
| Method | Endpoint                       | Description                  | Auth |
|--------|--------------------------------|------------------------------|------|
| GET    | `/users/me`                    | Get current user profile     | Yes  |
| PATCH  | `/users/me/profile`            | Update profile               | Yes  |
| PATCH  | `/users/me/music-preferences`  | Update music preferences     | Yes  |
| GET    | `/users/:id/profile`           | Get user profile (privacy)   | Yes  |
| POST   | `/users/:id/friend-request`    | Send friend request          | Yes  |
| POST   | `/users/:id/friend-accept`     | Accept friend request        | Yes  |
| DELETE | `/users/:id/friend`            | Remove friend                | Yes  |
| GET    | `/users/friends`               | List friends                 | Yes  |

### Music (Deezer Proxy)
| Method | Endpoint              | Description                | Auth |
|--------|-----------------------|----------------------------|------|
| GET    | `/music/search`       | Search tracks              | Yes  |
| GET    | `/music/track/:id`    | Get track details          | Yes  |
| GET    | `/music/artist/:id`   | Get artist details         | Yes  |
| GET    | `/music/album/:id`    | Get album details          | Yes  |

### Events (Music Track Vote)
| Method | Endpoint                       | Description                  | Auth |
|--------|--------------------------------|------------------------------|------|
| POST   | `/events`                      | Create event                 | Yes  |
| GET    | `/events`                      | List events                  | Yes  |
| GET    | `/events/:id`                  | Get event details            | Yes  |
| PATCH  | `/events/:id`                  | Update event                 | Yes  |
| DELETE | `/events/:id`                  | Delete event                 | Yes  |
| POST   | `/events/:id/suggest`          | Suggest a track              | Yes  |
| POST   | `/events/:id/vote/:trackId`    | Vote for a track             | Yes  |
| DELETE | `/events/:id/vote/:trackId`    | Remove vote                  | Yes  |
| POST   | `/events/:id/invite`           | Invite users to event        | Yes  |

### Playlists (Music Playlist Editor)
| Method | Endpoint                              | Description             | Auth |
|--------|---------------------------------------|-------------------------|------|
| POST   | `/playlists`                          | Create playlist         | Yes  |
| GET    | `/playlists`                          | List playlists          | Yes  |
| GET    | `/playlists/:id`                      | Get playlist            | Yes  |
| DELETE | `/playlists/:id`                      | Delete playlist         | Yes  |
| POST   | `/playlists/:id/tracks`               | Add track to playlist   | Yes  |
| DELETE | `/playlists/:id/tracks/:trackId`      | Remove track            | Yes  |
| PATCH  | `/playlists/:id/tracks/reorder`       | Reorder tracks          | Yes  |
| POST   | `/playlists/:id/invite`               | Invite collaborators    | Yes  |

### Delegation (Music Control)
| Method | Endpoint                 | Description                    | Auth |
|--------|--------------------------|--------------------------------|------|
| POST   | `/devices`               | Register device                | Yes  |
| GET    | `/devices`               | List user devices              | Yes  |
| DELETE | `/devices/:id`           | Remove device                  | Yes  |
| POST   | `/delegations`           | Delegate control               | Yes  |
| GET    | `/delegations`           | List delegations               | Yes  |
| DELETE | `/delegations/:id`       | Revoke delegation              | Yes  |
| PATCH  | `/delegations/:id`       | Update delegation permissions  | Yes  |

### Subscriptions (Bonus)
| Method | Endpoint                    | Description               | Auth |
|--------|-----------------------------|---------------------------|------|
| GET    | `/subscriptions/me`         | Get current subscription   | Yes  |
| POST   | `/subscriptions/upgrade`    | Upgrade subscription plan  | Yes  |
| POST   | `/subscriptions/cancel`     | Cancel subscription        | Yes  |
| POST   | `/subscriptions/webhook`    | Payment webhook            | No   |

### IoT (Bonus — MQTT)
| Method | Endpoint                       | Description                     | Auth |
|--------|--------------------------------|---------------------------------|------|
| GET    | `/iot/status`                  | Check MQTT connection status    | Yes  |
| POST   | `/iot/playback/command`        | Send playback command to IoT    | Yes  |
| POST   | `/iot/playback/status`         | Publish playback status to IoT  | Yes  |
| POST   | `/iot/device/pair`             | Pair IoT device via MQTT        | Yes  |
| POST   | `/iot/event/:eventId/broadcast`| Broadcast now-playing to event  | Yes  |

### Admin / Logging
| Method | Endpoint                    | Description                     | Auth |
|--------|-----------------------------|--------------------------------|------|
| GET    | `/admin/logs/platforms`     | Platform usage statistics       | Yes  |
| GET    | `/admin/logs/errors`        | Error rate statistics           | Yes  |
| GET    | `/admin/logs/slowest`       | Slowest endpoints               | Yes  |
| GET    | `/admin/logs/recent`        | Recent request logs             | Yes  |

## WebSocket Events

### Vote Gateway (namespace: `/vote`)
| Event (Client → Server) | Payload                    | Description          |
|--------------------------|----------------------------|----------------------|
| `join-event`             | `{ eventId: string }`      | Join event room      |
| `leave-event`            | `{ eventId: string }`      | Leave event room     |

| Event (Server → Client)  | Payload                   | Description          |
|---------------------------|---------------------------|----------------------|
| `playlist-updated`        | `{ playlist: Track[] }`   | Playlist changed     |
| `vote-received`           | `{ trackId, voteCount }`  | New vote on track    |

### Playlist Gateway (namespace: `/playlist`)
| Event (Client → Server) | Payload                           | Description         |
|--------------------------|-----------------------------------|---------------------|
| `join-playlist`          | `{ playlistId: string }`          | Join playlist room  |
| `leave-playlist`         | `{ playlistId: string }`          | Leave playlist room |

| Event (Server → Client)  | Payload                          | Description         |
|---------------------------|----------------------------------|---------------------|
| `track-added`             | `{ track, position }`            | Track added         |
| `track-removed`           | `{ trackId }`                    | Track removed       |
| `track-reordered`         | `{ trackId, from, to }`          | Track moved         |

## Exchange Format

All endpoints use **JSON** (`application/json`) for request and response bodies.

## Authentication

All authenticated endpoints require a Bearer token in the `Authorization` header:

```
Authorization: Bearer <access_token>
```

## Error Format

```json
{
  "statusCode": 400,
  "message": "Validation failed",
  "error": "Bad Request"
}
```
