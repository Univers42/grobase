# Analysis of Needs — Role Hierarchy & Data Architecture

---

## Role Hierarchy

```
┌─────────────────────────────────────────────────────────┐
│              SUPERADMIN (bonus, developer)               │
│  Full system access + infrastructure + seeded only       │
├─────────────────────────────────────────────────────────┤
│              ADMIN (José — seeded, not creatable)        │
│  Everything employee can do + create employees +         │
│  analytics charts + disable accounts                     │
├─────────────────────────────────────────────────────────┤
│              EMPLOYEE (created by admin)                  │
│  Menus/dishes CRUD, order status management,             │
│  review moderation, working hours                        │
├─────────────────────────────────────────────────────────┤
│              UTILISATEUR (self-registered client)        │
│  Browse menus, place orders, track orders, leave reviews │
└─────────────────────────────────────────────────────────┘
```

> **Subject rule:** "il ne doit pas être possible de créer un compte Administrateur depuis l'application"

---

## Permission Matrix (subject-grounded)

| Resource | Action | Admin | Employee | Utilisateur | Visitor |
|----------|--------|:-----:|:--------:|:-----------:|:-------:|
| **Menus** | View published | ✅ | ✅ | ✅ | ✅ |
| **Menus** | Create/Update | ✅ | ✅ | ❌ | ❌ |
| **Menus** | Delete | ✅ | ✅ | ❌ | ❌ |
| **Dishes** | CRUD | ✅ | ✅ | ❌ | ❌ |
| **Working Hours** | Update | ✅ | ✅ | ❌ | ❌ |
| **Orders** | Place | ✅ | ❌ | ✅ | ❌ |
| **Orders** | View all | ✅ | ✅ | ❌ | ❌ |
| **Orders** | View own | ✅ | ❌ | ✅ | ❌ |
| **Orders** | Update status | ✅ | ✅ | ❌ | ❌ |
| **Orders** | Cancel (pre-accepted) | ✅ | ❌ | ✅ | ❌ |
| **Orders** | Cancel (with reason) | ✅ | ✅ (contact required) | ❌ | ❌ |
| **Orders** | Modify (pre-accepted) | ✅ | ❌ | ✅ (except menu) | ❌ |
| **Reviews** | Write | ❌ | ❌ | ✅ (after completed) | ❌ |
| **Reviews** | Moderate | ✅ | ✅ | ❌ | ❌ |
| **Employees** | Create account | ✅ | ❌ | ❌ | ❌ |
| **Employees** | Disable account | ✅ | ❌ | ❌ | ❌ |
| **Analytics** | View charts | ✅ | ❌ | ❌ | ❌ |
| **Contact** | Send message | ✅ | ✅ | ✅ | ✅ |
| **Account** | Register | ❌ | ❌ | — | ✅ |
| **Account** | Update own info | ✅ | ✅ | ✅ | ❌ |
| **Account** | Reset password | ✅ | ✅ | ✅ | ❌ |

---

## Data Ownership: What Goes Where?

```
┌──────────────────────────────────────────────────────────┐
│                    PostgreSQL (ACID)                      │
│                                                          │
│  ✅ Users, Roles, Permissions, Sessions                  │
│  ✅ Menus, Dishes, Allergens, Ingredients                │
│  ✅ Orders, OrderItems, OrderStatusHistory               │
│  ✅ Deliveries, Reviews, ReviewImages                    │
│  ✅ Loyalty accounts, Transactions, Discounts            │
│  ✅ Messages, Notifications, Support Tickets             │
│  ✅ Working Hours, Time-off Requests                     │
│  ✅ GDPR Consent, Deletion Requests                     │
│  ✅ Kanban Config, Tags                                  │
│  ✅ Password Reset Tokens                                │
│                                                          │
│  → Source of truth for ALL business logic                 │
│  → Every write is transactional                          │
│  → Referential integrity enforced                        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                    MongoDB (Analytics)                    │
│                                                          │
│  📊 Menu view counts, order counts, revenue per menu     │
│  📊 Dashboard statistics (pre-computed daily/weekly)     │
│  📊 Search query analytics, conversion tracking          │
│  📊 User activity logs (clickstream, navigation)         │
│  📊 Audit logs (who changed what, JSON diffs)            │
│  📊 Order snapshots (denormalized for fast reads)        │
│                                                          │
│  → Expendable: can be rebuilt from PostgreSQL events     │
│  → TTL indexes auto-delete old data                     │
│  → App works without it (analytics just disabled)        │
└──────────────────────────────────────────────────────────┘
```

---

## Subject Business Rules (enforcement)

| Rule (from subject) | Enforcement |
|------|-------------|
| Client cancels only before `accepted` | Backend: reject if `status != 'pending'` |
| Client modifies everything except menu choice | Backend: reject menu_id change if exists |
| Employee contacts client before cancel | Backend: require `cancellation_contact_mode` + `cancellation_reason` |
| 10% discount if persons ≥ person_min + 5 | Backend: compute at order creation |
| Delivery: €5 + €0.59/km outside Bordeaux | Backend: compute based on `delivery_city` |
| Material return: 10 business days | Backend: set `material_return_deadline`, send email |
| Material penalty: €600 | Mentioned in CGV, tracked by deadline |
| Review after order `completed` | Backend: allow Publish creation only if order completed |
| Review = 1-5 stars + comment | Backend: validate note range |
| Admin sees charts from NoSQL | Frontend queries MongoDB via API |
| Admin account seeded, not creatable | No admin creation endpoint; seed script only |
| Welcome email on registration | Backend: email service triggered after user creation |
| Confirmation email on order | Backend: email service triggered after order creation |
| Email on order `completed` | Backend: email service triggered on status change |
| Password: 10 chars, 1 special, 1 upper, 1 lower, 1 digit | Backend + Frontend validation |

---

## Employee Restriction Rules

| Rule | Enforcement |
|------|-------------|
| Cannot cancel confirmed orders | Backend: check `order.status != 'pending'` before allowing cancel |
| Cannot modify order contents post-confirmation | Backend: reject PUT if `status NOT IN ('pending')` |
| Must contact client before major changes | UI: force phone/email dialog before status change |
| Cannot access financial reports | Permission: no `read` on `analytics` resource |
| Cannot create/delete menus | Permission: only `update` on `menus` resource |
| Can moderate reviews | Permission: `update` on `reviews` resource |
| Cannot see other employees' performance | Backend: filter queries by `user_id = currentUser.id` |

---

## Client Business Rules

| Rule | Enforcement |
|------|-------------|
| Can cancel only before confirmation | Backend: check `order.status = 'pending'` |
| Can modify all items before confirmation | Backend: allow PUT on order_items if `status = 'pending'` |
| Notified by email on `delivered` status | Trigger: send email via queue when status changes |
| Can rate 1-5 stars after delivery | Backend: allow review creation only if order `status = 'delivered'` |
| Loyalty points earned on delivery | Trigger: PostgreSQL trigger + update loyalty_account |
| Can request GDPR data export | API endpoint: serialize user data to JSON/CSV |
| Can request account deletion | API endpoint: create DataDeletionRequest, soft-delete after approval |