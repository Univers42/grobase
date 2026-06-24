# API Endpoints Reference

## Overview

All endpoints are prefixed with `/api`. Authentication is required unless marked as `[Public]`.

---

## Authentication (`/api/auth`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| POST | `/auth/register` | [Public] | Register new user |
| POST | `/auth/login` | [Public] | Login with credentials |
| POST | `/auth/refresh` | [Public] | Refresh access token |
| GET | `/auth/me` | Authenticated | Get current user |

---

## Menus (`/api/menus`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/menus` | [Public] | List all menus (paginated, filterable) |
| GET | `/menus/:id` | [Public] | Get menu details with dishes |
| POST | `/menus` | Admin | Create new menu |
| PUT | `/menus/:id` | Admin | Update menu |
| DELETE | `/menus/:id` | Admin | Delete menu |

**Query Parameters:**
- `page` - Page number (default: 1)
- `limit` - Items per page (default: 10)
- `dietId` - Filter by diet type
- `themeId` - Filter by theme
- `search` - Search in title/description
- `minPersons` - Minimum persons
- `maxPrice` - Maximum price per person

---

## Orders (`/api/orders`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/orders` | Authenticated | List user's orders (admin sees all) |
| GET | `/orders/:id` | Authenticated | Get order details |
| POST | `/orders` | Authenticated | Place new order |
| PATCH | `/orders/:id/status` | Admin/Employee | Update order status |
| DELETE | `/orders/:id` | Authenticated | Cancel order |

**Order Statuses:**
`pending` → `confirmed` → `preparing` → `ready` → `delivering` → `delivered` → `completed`

---

## Dishes (`/api/dishes`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/dishes` | [Public] | List all dishes |
| GET | `/dishes/:id` | [Public] | Get dish with allergens |
| POST | `/dishes` | Admin | Create dish |
| PUT | `/dishes/:id` | Admin | Update dish |
| DELETE | `/dishes/:id` | Admin | Delete dish |

---

## User Profile (`/api/users`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/users/me` | Authenticated | Get profile |
| PUT | `/users/me` | Authenticated | Update profile |
| DELETE | `/users/me` | Authenticated | Delete account (RGPD) |
| POST | `/users/me/gdpr-consent` | Authenticated | Update GDPR consent |
| GET | `/users/me/export` | Authenticated | Export data (RGPD) |

---

## Admin Dashboard (`/api/admin`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/admin/stats` | Admin | Dashboard statistics |
| GET | `/admin/users` | Admin | List all users |
| GET | `/admin/orders` | Admin | List all orders |
| POST | `/admin/employees` | Admin | Create employee |
| GET | `/admin/roles` | Admin | List all roles |

---

## Working Hours (`/api/working-hours`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/working-hours` | [Public] | Get restaurant hours |
| POST | `/working-hours` | Admin | Create hours entry |
| PUT | `/working-hours/:id` | Admin | Update hours |

---

## Reviews (`/api/reviews`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/reviews` | [Public] | List approved reviews |
| GET | `/reviews/me` | Authenticated | Get user's reviews |
| POST | `/reviews` | Authenticated | Create review |
| PATCH | `/reviews/:id/status` | Admin | Approve/reject review |
| DELETE | `/reviews/:id` | Authenticated | Delete review |

---

## Diets (`/api/diets`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/diets` | [Public] | List all diets |
| POST | `/diets` | Admin | Create diet |
| PUT | `/diets/:id` | Admin | Update diet |
| DELETE | `/diets/:id` | Admin | Delete diet |

---

## Themes (`/api/themes`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/themes` | [Public] | List all themes |
| POST | `/themes` | Admin | Create theme |
| PUT | `/themes/:id` | Admin | Update theme |
| DELETE | `/themes/:id` | Admin | Delete theme |

---

## Allergens (`/api/allergens`)

| Method | Endpoint | Access | Description |
|--------|----------|--------|-------------|
| GET | `/allergens` | [Public] | List all allergens |
| GET | `/allergens/:id` | [Public] | Get allergen with dishes |
| POST | `/allergens` | Admin | Create allergen |
| PUT | `/allergens/:id` | Admin | Update allergen |
| DELETE | `/allergens/:id` | Admin | Delete allergen |

---

## Response Format

All responses follow this standard format:

```json
{
  "success": true,
  "statusCode": 200,
  "message": "Success",
  "data": { ... },
  "timestamp": "2026-02-01T20:00:00.000Z",
  "path": "/api/menus"
}
```

## Paginated Response

```json
{
  "data": [...],
  "meta": {
    "total": 100,
    "page": 1,
    "limit": 10,
    "totalPages": 10
  }
}
```

## Error Response

```json
{
  "success": false,
  "statusCode": 400,
  "message": "Validation failed",
  "error": "Bad Request",
  "timestamp": "2026-02-01T20:00:00.000Z",
  "path": "/api/orders"
}
```
