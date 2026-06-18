# MongoDB HTTP Service — Validation Report

This document is a line-by-line audit of the `mongo-api` service against the MVP endpoint specification. It confirms that every required endpoint, response format, security mechanism, and validation rule is correctly implemented and ready for integration testing.

**Source file:** `docker/services/mongo-api/server.js`

---

## Table of Contents

- [Endpoint Coverage](#endpoint-coverage)
- [Response Envelope](#response-envelope)
- [Error Handling](#error-handling)
- [Authentication and Authorization](#authentication-and-authorization)
- [User Isolation](#user-isolation)
- [Input Validation](#input-validation)
- [CRUD Operations](#crud-operations)
- [Environment Configuration](#environment-configuration)
- [Kong Route Requirement](#kong-route-requirement)
- [Alignment Summary](#alignment-summary)
- [Post-MVP Improvements](#post-mvp-improvements)

---

## Endpoint Coverage

All six required endpoints are implemented:

| Endpoint | Method | Service Path | Kong Public Path |
|----------|--------|-------------|-----------------|
| Health check | `GET` | `/health` | `/mongo/v1/health` |
| Create document | `POST` | `/collections/:name/documents` | `/mongo/v1/collections/:name/documents` |
| List documents | `GET` | `/collections/:name/documents` | `/mongo/v1/collections/:name/documents` |
| Get document | `GET` | `/collections/:name/documents/:id` | `/mongo/v1/collections/:name/documents/:id` |
| Update document | `PATCH` | `/collections/:name/documents/:id` | `/mongo/v1/collections/:name/documents/:id` |
| Delete document | `DELETE` | `/collections/:name/documents/:id` | `/mongo/v1/collections/:name/documents/:id` |

The service implements paths without the `/mongo/v1` prefix. Kong handles the prefix via `strip_path: true`.

---

## Response Envelope

### Success format

```json
{
  "success": true,
  "data": {},
  "meta": { "total": 150, "limit": 20, "offset": 0 }
}
```

The `meta` field is included only when relevant (list operations with pagination). This matches the specification, which defines `meta` as optional.

### Error format

```json
{
  "success": false,
  "error": {
    "code": "error_code",
    "message": "Human-readable description",
    "details": "Optional additional context"
  }
}
```

The `details` field is included only when present. Both envelope formats follow the specification exactly.

---

## Error Handling

The service defines 13 distinct error codes covering every anticipated failure mode:

| HTTP Status | Code | Trigger |
|-------------|------|---------|
| 500 | `server_config_error` | `JWT_SECRET` not configured at startup |
| 401 | `missing_authorization` | No `Authorization` header in request |
| 401 | `invalid_token` | JWT verification fails or `sub` claim missing |
| 400 | `invalid_collection` | Collection name fails regex `^[a-zA-Z0-9_-]{1,64}$` |
| 400 | `invalid_id` | Path parameter is not a valid MongoDB ObjectId |
| 400 | `invalid_payload` | Request body missing `document` or `patch` object |
| 400 | `forbidden_fields` | Client attempts to set `_id` or `owner_id` |
| 400 | `invalid_filter` | Malformed JSON in `filter` query parameter |
| 400 | `invalid_json` | Request body is not valid JSON |
| 404 | `not_found` | Document does not exist or is not owned by the requester |
| 413 | `payload_too_large` | Request body exceeds 256 KB |
| 503 | `mongo_unavailable` | MongoDB connection is down |
| 500 | `internal_error` | Catch-all for unexpected server errors |

---

## Authentication and Authorization

### JWT extraction

```javascript
const parseBearerToken = (req) => {
  const value = req.headers.authorization || "";
  if (!value.startsWith("Bearer ")) return null;
  return value.slice(7).trim();
};
```

The service extracts the token from the `Authorization: Bearer <token>` header.

### JWT verification

- Algorithm: **HS256**
- Secret: `JWT_SECRET` environment variable (must match GoTrue's signing secret)
- Required claim: `sub` (user UUID) — mapped to `req.user.id`
- Additional claims captured: `email`, `role`

If the token is missing, expired, or signed with the wrong secret, the service returns `401`.

---

## User Isolation

Every data operation enforces tenant isolation through the `owner_id` field:

| Operation | Filter Applied |
|-----------|---------------|
| **Create** | `owner_id` injected from `req.user.id` |
| **List** | Query includes `{ owner_id: req.user.id }` |
| **Get one** | Query includes `{ _id, owner_id: req.user.id }` |
| **Update** | Query includes `{ _id, owner_id: req.user.id }` |
| **Delete** | Query includes `{ _id, owner_id: req.user.id }` |

User B cannot read, modify, or delete user A's documents through any endpoint.

---

## Input Validation

### Collection name

Pattern: `^[a-zA-Z0-9_-]{1,64}$`

Rejects path traversal attempts, special characters, and names longer than 64 characters.

### Document ID

Validated as a MongoDB ObjectId (24-character hexadecimal string). Non-conforming values return `400 invalid_id`.

### Payload size

Express middleware enforces a 256 KB limit:

```javascript
app.use(express.json({ limit: "256kb" }));
```

Oversized payloads return `413 payload_too_large`.

### Forbidden fields

Both `CREATE` and `PATCH` reject request bodies containing `_id` or `owner_id`:

```javascript
if (Object.prototype.hasOwnProperty.call(document, "_id") ||
    Object.prototype.hasOwnProperty.call(document, "owner_id")) {
  return fail(res, 400, "forbidden_fields", "...");
}
```

This prevents clients from overriding server-controlled fields.

---

## CRUD Operations

### Create — `POST /collections/:name/documents`

Request:

```json
{ "document": { "title": "Task 1", "status": "pending" } }
```

Behavior:

1. Validates `document` is a non-array object.
2. Rejects `_id` and `owner_id` in input.
3. Injects `owner_id` from JWT `sub` claim.
4. Sets `created_at` and `updated_at` timestamps.
5. Returns `201` with the generated `id`.

### List — `GET /collections/:name/documents`

Query parameters:

| Parameter | Default | Constraints |
|-----------|---------|-------------|
| `limit` | 20 | 1–100 |
| `offset` | 0 | Non-negative integer |
| `sort` | `created_at:desc` | Field must match `^[a-zA-Z0-9_]{1,64}$` |
| `filter` | `{}` | JSON object; `owner_id` and `_id` keys stripped |

All queries are ANDed with `{ owner_id: req.user.id }`. Response includes `meta` with `total`, `limit`, and `offset`.

### Get one — `GET /collections/:name/documents/:id`

Queries by both `_id` and `owner_id`. Returns `404` if the document does not exist or belongs to another user.

### Update — `PATCH /collections/:name/documents/:id`

Request:

```json
{ "patch": { "status": "completed" } }
```

Uses MongoDB `$set` for sparse (merge) updates. Automatically updates the `updated_at` timestamp. Returns `404` if not found or not owned.

### Delete — `DELETE /collections/:name/documents/:id`

Queries by `_id` and `owner_id`. Checks `deletedCount === 1`. Returns `{ deleted: true }` on success, `404` if not found or not owned.

---

## Environment Configuration

| Variable | Default | Required | Purpose |
|----------|---------|----------|---------|
| `PORT` | `3010` | No | Service listen port |
| `MONGO_URI` | `mongodb://mongo:27017` | No | MongoDB connection string |
| `MONGO_DB_NAME` | `mini_baas` | No | Database name |
| `JWT_SECRET` | *(none)* | **Yes** | Must match GoTrue signing secret |

The service will return `500 server_config_error` on every request if `JWT_SECRET` is not set.

---

## Kong Route Requirement

The service listens on paths without the `/mongo/v1` prefix. Kong provides the prefix and strips it before forwarding:

```yaml
- name: mongo-api
  url: http://mongo-api:3010
  routes:
    - name: mongo-api-routes
      paths: [/mongo/v1]
      strip_path: true
  plugins:
    - name: key-auth
      config: { key_names: [apikey] }
    - name: rate-limiting
      config: { minute: 180, hour: 5000 }
```

This route is already configured in the current `kong.yml`.

---

## Alignment Summary

| Requirement | Specified | Implemented |
|-------------|-----------|-------------|
| 6 CRUD endpoints | Yes | Yes |
| Success response envelope | Yes | Yes |
| Error response envelope | Yes | Yes |
| JWT Bearer token required | Yes | Yes |
| `owner_id` auto-injected on create | Yes | Yes |
| Tenant isolation on all operations | Yes | Yes |
| Collection name validation | Yes | Yes |
| 256 KB payload limit | Yes | Yes |
| Forbidden fields (`_id`, `owner_id`) | Yes | Yes |
| Pagination (limit, offset) | Yes | Yes |
| Sorting | Yes | Yes |
| Filtering (with `owner_id` AND) | Yes | Yes |
| ObjectId validation | Yes | Yes |
| Comprehensive error codes | Yes | Yes (13 codes) |
| Automatic timestamps | Yes | Yes |

The service is fully spec-compliant and ready for integration testing.

---

## Post-MVP Improvements

These items are deferred to future phases:

1. **Request ID tracking** — add a UUID to the `meta` field for distributed tracing.
2. **Audit logging** — log mutations with user identity and timestamp.
3. **Aggregation pipelines** — support MongoDB aggregation for analytical queries.
4. **Multi-document transactions** — atomic operations across related collections.
5. **Bulk operations** — batch create, update, and delete.
