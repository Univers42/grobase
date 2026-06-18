# Security Architecture

---

## Authentication & Session Management

| Layer | Implementation |
|-------|---------------|
| **Password hashing** | Bcrypt, minimum 12 salt rounds |
| **JWT tokens** | Short-lived access (15 min), long-lived refresh (7 days) |
| **Session tracking** | `UserSession` table in PostgreSQL |
| **Password reset** | Cryptographic token, 1-hour expiry, single use |
| **2FA** | TOTP for admin/superadmin roles (future) |
| **Rate limiting** | 5 login attempts per 15 minutes per IP |

---

## Database Security

### PostgreSQL

| Measure | Details |
|---------|---------|
| **Prepared statements** | All queries via Prisma ORM (parameterized by default) |
| **Connection encryption** | TLS/SSL required for all connections |
| **Row-level security** | Users can only access own data; admins see all |
| **Soft deletion** | `is_deleted` flag prevents accidental data loss |
| **Audit on sensitive fields** | Trigger logs changes to email, password, role |
| **Backup** | Automated daily, point-in-time recovery enabled |
| **Connection pooling** | PgBouncer or Prisma connection pool (max 20) |

### MongoDB

| Measure | Details |
|---------|---------|
| **Authentication** | SCRAM-SHA-256 with dedicated app user |
| **Network** | Atlas IP whitelist or VPC peering |
| **Encryption** | At rest (Atlas default), in transit (TLS) |
| **TTL indexes** | Auto-expire sensitive logs (30-90 days) |
| **No PII storage** | Only user IDs, never passwords or full addresses |
| **Read-only for analytics** | App user has limited write permissions |

---

## API Security

1. **SQL Injection Prevention** — Prisma ORM uses parameterized queries exclusively
2. **XSS Prevention** — Sanitize all user inputs server-side; CSP headers in responses
3. **CSRF Protection** — CSRF tokens for all state-changing operations
4. **Input Validation** — DTO validation with `class-validator` (NestJS pipes)
5. **File Upload** — Whitelist MIME types, max size 5 MB, virus scan
6. **CORS** — Strict origin whitelist, no wildcards in production
7. **HTTP Headers** — Helmet.js for security headers (HSTS, X-Frame-Options, etc.)

---

## GDPR Compliance Procedures

### Right to Access (Data Export)

```
Client requests export → API serializes:
  - User profile (name, email, phone, addresses)
  - Order history (numbers, dates, amounts)
  - Reviews written
  - Loyalty points balance
  - Consent records
→ Returns JSON or CSV file
→ Audit log entry created in MongoDB
```

### Right to Erasure (Account Deletion)

```
Client requests deletion → DataDeletionRequest created (status: pending)
→ Admin reviews within 72 hours
→ If approved:
  1. Soft-delete user (is_deleted = true, deleted_at = now())
  2. Anonymize PII: email → deleted_<id>@anon, name → "Deleted User"
  3. Retain anonymized order history (legal/financial compliance)
  4. Delete from MongoDB: activity logs, search history
  5. Revoke all sessions
  6. Send confirmation email
→ Physical deletion after 30-day grace period
```

### Right to Rectification

```
User updates profile → PostgreSQL updated_at auto-set
→ Audit log in MongoDB captures old + new values
→ If email changes: re-verification required
```

### Consent Management

```
On registration → UserConsent records created:
  - "terms_of_service": required, cannot be false
  - "marketing": optional, default false
  - "analytics": optional, default false
  - "cookies": required for functionality

Each record stores: ip_address, granted_at, revoked_at
→ User can revoke marketing/analytics consent at any time
→ Revoking analytics consent stops MongoDB tracking for that user
```

---

## Security Checklist

- [x] Bcrypt password hashing (12 rounds)
- [x] Parameterized queries (Prisma)
- [x] JWT with refresh token rotation
- [x] GDPR consent tracking
- [x] Soft deletion with anonymization
- [x] Audit logging (MongoDB)
- [x] Rate limiting on auth endpoints
- [ ] 2FA for admin roles
- [ ] WAF (Web Application Firewall)
- [ ] Penetration testing schedule
- [ ] Dependency vulnerability scanning (Snyk/Dependabot)
- [ ] Security incident response plan